# DEVOP-579 — NetworkPolicy egress rollout plan

**Status:** plan only. Execution is staged across 3 engineer-weeks. Do NOT deploy any NetworkPolicies based on this plan without the rollout owner signing off on the scope of each phase.

## Goal

Add `default-deny-egress` NetworkPolicies to every Kubernetes namespace across our 13 clusters, then layer explicit egress allowlists per workload. Closes the "compromised pod can call out to attacker-controlled C2" Shai-Hulud propagation path.

## Why this is hard (the 3-engineer-week estimate)

NetworkPolicies are stateless and additive — meaning a `default-deny` policy will silently break every workload that has a legitimate outbound dependency that isn't yet enumerated. Production-impacting blast radius if rushed. The bulk of the work is **discovery**, not deployment.

## Phase 0 — Pre-flight (week 1, days 1–2)

- [ ] Confirm CNI on every cluster supports NetworkPolicy (Calico, Cilium, Antrea — yes; flannel without --network-policy — no).
- [ ] Stand up `network-policy-engine` (Calico) or use Cilium's native NPL on any cluster that's still on flannel.
- [ ] Enable flow logs on at least one staging cluster: `cilium hubble enable` or `calicoctl flow logs enable`. We need ~7 days of baseline traffic to enumerate legitimate egress. Note: these are L3/L4 logs — they give source/destination IP, port, and protocol only, **not** FQDNs.
- [ ] Enable verbose DNS query logging on the same cluster so Phase 1 can map destination IPs back to FQDNs. Concretely:
  - CoreDNS: add the `log` plugin to the Corefile (`log { class denial error success }`) and ship CoreDNS logs to the same sink as the flow logs so they can be joined on `(srcPodIP, dstIP, timestamp ± window)`.
  - On Cilium clusters where we plan to author DNS-aware policies anyway, enable Cilium L7 DNS visibility (`hubble observe --type=dns` works once the DNS proxy is in path) — this gives per-pod resolved FQDNs directly and removes the join step.
  - Confirm log retention covers the full 7-day baseline window before Phase 1 starts.

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
- [ ] Resolve those destinations to FQDNs by joining the flow logs against the CoreDNS query logs (or Cilium L7 DNS events) enabled in Phase 0, on `(srcPodIP, dstIP)` within a short time window. Destinations that have no matching DNS lookup (e.g., hard-coded IP literals, `169.254.169.254`, raw cloud-metadata IPs) get carried through as IP-only entries and are scrutinized in the suspect-destination step below.
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

Per namespace, write two files:
- `network-policies/<cluster>/<namespace>/default-deny.yaml` — applies to all pods in the namespace, blocks all egress except DNS.
- `network-policies/<cluster>/<namespace>/allowlist.yaml` — explicit egress rules derived from Phase 1.

Patterns to standardize:
- DNS always allowed to kube-dns / coredns (53/udp, 53/tcp).
- NTP always allowed (123/udp).
- Cluster-internal pod-to-pod within same namespace: allow by default.
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
- [ ] Days 7+: roll forward through remaining production namespaces in priority-inverse order (lowest-blast-radius first), keeping a 48h soak between each cluster cohort.

A stage may only advance if the prior soak completed with zero
NetworkPolicy-attributable incidents. If anything broke, hold the
window open until the root cause is fixed (or the policy is amended)
and restart the 48-hour clock for that stage.

**Rollback procedure** (must be documented before Day 1):
- `kubectl delete networkpolicy default-deny -n <ns>` — un-breaks egress instantly.
- Have this command ready as a runbook step in the on-call channel.

## Phase 4 — Steady state

- [ ] Add NetworkPolicy schemas to Kyverno (after DEVOP-588 lands) so any new namespace without a `default-deny` is auto-flagged.
- [ ] Monthly review of `discovery/<namespace>.md` for changes in legitimate egress (new vendor SaaS, etc.).
- [ ] **Document the rollout and steady-state policies in `SECURITY-RUNBOOK.md`** (DEVOP-571): add a NetworkPolicy section covering (a) the default-deny model, (b) where the per-namespace allowlists live in this repo, (c) the rollback command (`kubectl delete networkpolicy default-deny -n <ns>`), and (d) the on-call escalation path when a workload reports egress failures. Without this hook into the runbook, on-call has no reference for diagnosing "my pod can't reach X" pages once default-deny is org-wide.

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
  plus `ingress-allowlist.yaml`. Pattern: deny all inbound by default,
  allow from the ingress controller's pod selector, allow from
  same-namespace pods, then explicit allow rules per legitimate
  upstream.
- **Phase 3 (staged rollout)**: same 48-hour soak windows. Ingress
  blast radius is generally *higher* than egress (a misconfigured
  ingress policy can take a service offline for real users, not just
  internal callouts), so the production cohort starts later and
  proceeds slower than egress.
- **Phase 4 (steady state)**: Kyverno rule asserting both
  `default-deny-egress` AND `default-deny-ingress` exist per namespace.
  Runbook section covers both.

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
- Cilium NetworkPolicy reference: https://docs.cilium.io/en/stable/security/policy/
- Calico NetworkPolicy reference: https://docs.tigera.io/calico/latest/network-policy/
