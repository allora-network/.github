# DEVOP-579 — NetworkPolicy egress rollout plan

**Status:** plan only. Execution is staged across 3 engineer-weeks. Do NOT deploy any NetworkPolicies based on this plan without the rollout owner signing off on the scope of each phase.

## Goal

Add `default-deny-egress` NetworkPolicies to every Kubernetes namespace across our 13 clusters, then layer explicit egress allowlists per workload. Closes the "compromised pod can call out to attacker-controlled C2" Shai-Hulud propagation path.

## Why this is hard (the 3-engineer-week estimate)

NetworkPolicies are stateful (return traffic for an allowed connection is implicitly permitted via connection tracking) and additive — meaning a `default-deny` policy will silently break every workload that has a legitimate outbound dependency that isn't yet enumerated. Production-impacting blast radius if rushed. The bulk of the work is **discovery**, not deployment.

## Phase 0 — Pre-flight (week 1, days 1–2)

- [ ] Confirm CNI on every cluster supports NetworkPolicy (Calico with Felix as the enforcer — yes; Cilium — yes, native; Antrea — yes; flannel without the `--network-policy` flag — no).
- [ ] For any cluster still on flannel-without-NetworkPolicy, plan a CNI migration to Calico or Cilium before proceeding. NetworkPolicy enforcement is unavailable otherwise; this rollout cannot land on those clusters until the CNI migration is done.
- [ ] Enable flow logs on at least one staging cluster. We need ~7 days of baseline traffic to enumerate legitimate egress. Note: these are L3/L4 logs — they give source/destination IP, port, and protocol only, **not** FQDNs. CNI-specific enablement:
  - Cilium: `cilium hubble enable` (and ensure flow retention covers 7 days; `hubble-relay` persists in-memory by default, so for the baseline window export to a sink the team can query later — Loki, S3, or BigQuery).
  - Calico OSS: patch the `default` `FelixConfiguration` CR with `spec.flowLogsFileEnabled: true` (plus `flowLogsFileIncludeLabels: true` so workload identity is queryable). Felix writes per-node JSON flow logs under `/var/log/calico/flowlogs/`; ship those to the same sink as above. OSS file-based flow logs cover allow/deny actions only — for richer flow context, Calico Enterprise / Calico Cloud is required, otherwise prefer the Cilium staging cluster for baseline capture.
  - Antrea: enable the `FlowExporter` feature gate on the agent and run `flow-aggregator` to export to the sink.
- [ ] Enable DNS message capture on the same cluster so Phase 1 can map destination IPs back to FQDNs. The capture mechanism must include the DNS *response* (specifically the A / AAAA answer-section IPs), not just the query — without those resolved IPs there is nothing to join the flow-log `dstIP` against. Concretely:
  - CoreDNS: enable the `dnstap` plugin with the `full` flag (e.g., `dnstap /var/run/dnstap.sock full` or `dnstap tcp://<collector>:6000 full`) and run a dnstap collector (such as `golang-dnstap` or `dnstap-receiver`) that decodes the wire-format messages and ships `(timestamp, client_pod_ip, query_name, response_ips[])` records to the same sink as the flow logs. The query-only `log` plugin is insufficient — it emits client IP, query name, and response code but not the answer-section IPs, so the `dstIP` join cannot be made from `log` output alone. The DNS messages are then joined to the flow logs on `(srcPodIP == client_pod_ip, dstIP ∈ response_ips, timestamp ± window)`.
  - On Cilium clusters where we plan to author DNS-aware policies anyway, enable Cilium L7 DNS visibility (`hubble observe --type=dns` works once the DNS proxy is in path) — Hubble records per-pod resolved FQDNs *and* the answer IPs together, which removes the cross-source join entirely.
  - Confirm dnstap / Hubble retention covers the full 7-day baseline window before Phase 1 starts.

## Phase 1 — Discovery (week 1, days 3–5; week 2, days 1–2)

For each namespace, in priority order (highest-value first):
1. `allora-chain-validators`
2. `allora-chain-rpc`
3. `harbor`
4. `flux-system`
5. ingress-nginx / traefik
6. cert-manager
7. application namespaces (`robonet`, `eliza-allora`, etc.)
8. system namespaces last (`kube-system`, `gke-system`)

For each:
- [ ] Capture 7 days of egress flow logs from baseline.
- [ ] Enumerate destination CIDRs and ports directly from the flow logs (these are the only fields L3/L4 actually carries).
- [ ] Resolve those destinations to FQDNs by joining the flow logs against the CoreDNS dnstap stream (or Cilium L7 DNS events) enabled in Phase 0, on `(srcPodIP == DNS client IP, dstIP ∈ DNS response answer IPs, timestamp ± window)`. Destinations that have no matching DNS lookup (e.g., hard-coded IP literals, `169.254.169.254`, raw cloud-metadata IPs) get carried through as IP-only entries and are scrutinized in the suspect-destination step below.
- [ ] Group by category: `internal` (other Allora namespaces), `infra` (cloud-provider metadata, DNS, NTP, GKE), `vendor-saas` (Datadog, Slack, etc.), `package-registries` (npm, pypi, docker.io, ghcr.io, quay.io — these become Harbor proxy-cache after DEVOP-589), `customer-traffic` (per-namespace).
- [ ] **Explicitly flag suspect egress destinations** for incident review before they get added to any allowlist. Treat the following as suspect by default:
  - Generic webhook receivers (`*.webhook.site`, `discord.com/api/webhooks/*`, `hooks.slack.com/services/*` that aren't ours, `*.pipedream.net`, `*.requestbin.com`, etc.).
  - Pastebin-family services (`pastebin.com`, `paste.ee`, `hastebin.com`, `gist.githubusercontent.com` raw fetches from non-org accounts, `transfer.sh`, `0x0.st`).
  - Tunnel / reverse-proxy services (`*.ngrok.io`, `*.ngrok-free.app`, `*.loca.lt`, `*.trycloudflare.com`, `*.serveo.net`).
  - Cloud-instance metadata endpoints from inside a pod (`169.254.169.254`, `metadata.google.internal`, `100.100.100.200`) — these should be blocked outright unless a specific workload demonstrably needs them, and even then via an IRSA / Workload Identity allowlist, not raw IP.
  - Anything resolving to a residential/dynamic-DNS provider (`*.duckdns.org`, `*.no-ip.com`, `*.dyndns.org`).
  Each flagged destination needs an incident-response review: confirm a legitimate owner, document the use case, and either allowlist with a tight CIDR / FQDN or open a remediation ticket. Do NOT roll suspect destinations into the allowlist by default just because they appear in the 7-day baseline.
- [ ] Document in this repo as `network-policies/discovery/<namespace>.md` for future audit, including the suspect-destination review notes.

## Phase 2 — Allowlist authoring (week 2, days 3–5)

### NetworkPolicy naming convention (pinned — runbook depends on it)

Every NetworkPolicy this rollout creates uses one of these exact `metadata.name` values, in the namespace it targets. The rollback runbook (Phase 3) and the Kyverno asserter (Phase 4) both grep on these names, so deviations break both.

| Direction | File name | `metadata.name` | Purpose |
|---|---|---|---|
| Egress | `default-deny-egress.yaml` | `default-deny-egress` | Deny all egress except the baseline allows in `egress-baseline-allow.yaml`. |
| Egress | `egress-baseline-allow.yaml` | `egress-baseline-allow` | Cluster-wide always-on allows: DNS to kube-dns / CoreDNS (53/udp, 53/tcp) and NTP (123/udp). Lives in every namespace so clock sync and name resolution survive the default-deny. |
| Egress | `egress-allowlist.yaml` | `egress-allowlist` | Per-namespace workload-specific egress allows derived from Phase 1. |
| Ingress | `default-deny-ingress.yaml` | `default-deny-ingress` | Deny all ingress except the per-namespace allows in `ingress-allowlist.yaml`. |
| Ingress | `ingress-allowlist.yaml` | `ingress-allowlist` | Per-namespace ingress allows (ingress controller, same-namespace pods, explicit upstreams). |

Per namespace, write the two egress files (`default-deny-egress.yaml` plus `egress-allowlist.yaml`) under `network-policies/<cluster>/<namespace>/`. The baseline-allow policy is generated from a single template applied to every namespace; do not hand-author it per-namespace.

### Patterns derived from Phase 1

- DNS to kube-dns / CoreDNS (53/udp, 53/tcp): lives in `egress-baseline-allow`, never in per-workload allowlists.
- NTP (123/udp): lives in `egress-baseline-allow`.
- Cluster-internal pod-to-pod within same namespace: allow by default in the per-namespace `egress-allowlist`.
- Outbound to other Allora namespaces: explicit per-namespace allow (no blanket).
- Outbound to public internet: only through a designated egress proxy (or whitelist by CIDR).

## Phase 3 — Staged rollout (week 3)

DEVOP-579 specifies **48-hour soak windows** between rollout stages
(not 24h) so a full business-day cycle plus a quieter overnight cycle
both elapse before the next stage advances. This catches workloads
whose egress only fires on cron/batch schedules.

- [ ] Days 1–2: apply policies to **1 staging namespace** in **1 staging cluster**. Soak 48h.
- [ ] Days 3–4: apply to all staging namespaces in 1 cluster. Soak 48h.
- [ ] Days 5–6: apply to 1 production namespace (lowest-risk: docs site). Soak 48h.
- [ ] Days 7+: roll forward through remaining production namespaces in priority-inverse order (lowest-blast-radius first), keeping a 48h soak between each cohort — one cohort is one namespace.

A stage may only advance if the prior soak completed with zero
NetworkPolicy-attributable incidents. If anything broke, hold the
window open until the root cause is fixed (or the policy is amended)
and restart the 48-hour clock for that stage.

**Rollback procedure** (must be documented before Day 1):
- Egress emergency: `kubectl delete networkpolicy default-deny-egress -n <ns>` — restores all egress instantly. The per-namespace `egress-allowlist` and the `egress-baseline-allow` policies are additive-only and safe to leave in place.
- Ingress emergency (once Phase 3 has rolled the ingress cohort): `kubectl delete networkpolicy default-deny-ingress -n <ns>` — restores all ingress instantly.
- Both names match the pinned naming convention in Phase 2. If you find a workload whose `default-deny-egress` policy has a different name, treat it as a policy-drift incident and fix the name before relying on the rollback command.
- Have both commands ready as runbook steps in the on-call channel.

## Phase 4 — Steady state

- [ ] Add Kyverno policies (after DEVOP-588 lands) that fail any new non-system namespace which is missing either a `default-deny-egress` or a `default-deny-ingress` NetworkPolicy. Match by `metadata.name` exactly — these are the names pinned in the Phase 2 convention table.
- [ ] Monthly review of `discovery/<namespace>.md` for changes in legitimate egress (new vendor SaaS, etc.).
- [ ] **Document the rollout and steady-state policies in `SECURITY-RUNBOOK.md`** (DEVOP-571): add a NetworkPolicy section covering (a) the default-deny model, (b) where the per-namespace allowlists live in this repo, (c) the rollback commands (`kubectl delete networkpolicy default-deny-egress -n <ns>` and `kubectl delete networkpolicy default-deny-ingress -n <ns>` — both required, named per the Phase 2 convention), and (d) the on-call escalation path when a workload reports egress or ingress failures. Without this hook into the runbook, on-call has no reference for diagnosing "my pod can't reach X" pages once default-deny is org-wide.

## Dependencies

- Harbor proxy-cache projects (DEVOP-589) must land **before** Phase 2, or the allowlists will be churn — they'd need to allow direct `ghcr.io` etc., then be rewritten to allow only `harbor.allora-network.io`.
- Kyverno on all clusters (DEVOP-588) is a soft dependency: Phase 4 needs it but Phases 0–3 can proceed.

## Ingress default-deny — same model, separate rollout cohort

DEVOP-579 requires default-deny for both egress **and** ingress. The
two share a rollout shape but have different blast-radius and
different discovery inputs, so they run as parallel cohorts rather
than as one combined sweep.

For ingress, mirror Phases 0–4 above with these substitutions:

- **Phase 1 (discovery)**: capture the *inbound* flow logs per
  namespace for 7 days. Categorize sources by `internal` (other
  Allora namespaces), `infra` (ingress controllers, load balancers,
  health-check probes), `vendor-saas` (webhook callbacks, etc.), and
  `public-traffic` (customer-facing routes). Apply the same suspect-
  destination flagging in reverse: any inbound source that resolves
  to a residential-DNS / tunnel service / cloud-metadata range is
  reviewed before allowlisting.
- **Phase 2 (allowlist authoring)**: per namespace, write
  `network-policies/<cluster>/<namespace>/default-deny-ingress.yaml`
  (`metadata.name: default-deny-ingress`) plus
  `ingress-allowlist.yaml` (`metadata.name: ingress-allowlist`). Both
  names match the pinned convention in the egress Phase 2 table.
  Pattern: deny all inbound by default, allow from the ingress
  controller's pod selector, allow from same-namespace pods, then
  explicit allow rules per legitimate upstream.
- **Phase 3 (staged rollout)**: same 48-hour soak windows. Ingress
  blast radius is generally *higher* than egress (a misconfigured
  ingress policy can take a service offline for real users, not just
  internal callouts), so the production cohort starts later and
  proceeds slower than egress.
- **Phase 4 (steady state)**: Kyverno rule asserting that every
  non-system namespace has both a `default-deny-egress` and a
  `default-deny-ingress` NetworkPolicy (greps on the pinned
  `metadata.name` values from the Phase 2 table). Runbook section
  covers both rollback commands.

Run egress first (it's lower-risk because the failure mode is
"workload can't reach Datadog" rather than "customers can't reach our
API"). Start ingress discovery in parallel during Phase 0–1 of the
egress rollout so the two cohorts can converge on Phase 4 around the
same time.

## Out of scope for this ticket

- IDS/anomaly detection on egress flow logs — separate ticket (Falco rules, DEVOP-570).

## Who runs this

- Owner: cluster-admin / platform team.
- Reviewer: security team (sign-off on each phase before proceeding to the next).
- Estimated total engineer-time: ~3 engineer-weeks calendar, ~50% utilization (lots of waiting for flow-log baselines to accumulate).

## Links

- Linear: https://linear.app/alloralabs/issue/DEVOP-579
- Related tickets: DEVOP-571 (https://linear.app/alloralabs/issue/DEVOP-571), DEVOP-588 (https://linear.app/alloralabs/issue/DEVOP-588), DEVOP-589 (https://linear.app/alloralabs/issue/DEVOP-589)
- Cilium NetworkPolicy reference: https://docs.cilium.io/en/stable/security/policy/
- Calico NetworkPolicy reference: https://docs.tigera.io/calico/latest/network-policy/
