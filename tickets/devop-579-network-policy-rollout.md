# DEVOP-579 — NetworkPolicy egress rollout plan

**Status:** plan only. Execution is staged across 3 engineer-weeks. Do NOT deploy any NetworkPolicies based on this plan without the rollout owner signing off on the scope of each phase.

## Goal

Add `default-deny-egress` NetworkPolicies to every Kubernetes namespace across our 13 clusters, then layer explicit egress allowlists per workload. Closes the "compromised pod can call out to attacker-controlled C2" Shai-Hulud propagation path.

## Why this is hard (the 3-engineer-week estimate)

NetworkPolicies are stateless and additive — meaning a `default-deny` policy will silently break every workload that has a legitimate outbound dependency that isn't yet enumerated. Production-impacting blast radius if rushed. The bulk of the work is **discovery**, not deployment.

## Phase 0 — Pre-flight (week 1, days 1–2)

- [ ] Confirm CNI on every cluster supports NetworkPolicy (Calico, Cilium, Antrea — yes; flannel without --network-policy — no).
- [ ] Stand up `network-policy-engine` (Calico) or use Cilium's native NPL on any cluster that's still on flannel.
- [ ] Enable flow logs on at least one staging cluster: `cilium hubble enable` or `calicoctl flow logs enable`. We need ~7 days of baseline traffic to enumerate legitimate egress.

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
- [ ] Enumerate destination CIDRs, DNS names, and ports.
- [ ] Group by category: `internal` (other Allora namespaces), `infra` (cloud-provider metadata, DNS, NTP, GKE), `vendor-saas` (Datadog, Slack, etc.), `package-registries` (npm, pypi, docker.io, ghcr.io, quay.io — these become Harbor proxy-cache after DEVOP-589), `customer-traffic` (per-namespace).
- [ ] Document in this repo as `network-policies/discovery/<namespace>.md` for future audit.

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

- [ ] Day 1: apply policies to **1 staging namespace** in **1 staging cluster**. Observe 24h.
- [ ] Day 2: apply to all staging namespaces in 1 cluster. Observe 24h.
- [ ] Day 3: apply to 1 production namespace (lowest-risk: docs site). Observe 24h.
- [ ] Days 4–5: roll forward through remaining production namespaces in priority-inverse order (lowest-blast-radius first).

**Rollback procedure** (must be documented before Day 1):
- `kubectl delete networkpolicy default-deny -n <ns>` — un-breaks egress instantly.
- Have this command ready as a runbook step in the on-call channel.

## Phase 4 — Steady state

- [ ] Add NetworkPolicy schemas to Kyverno (after DEVOP-588 lands) so any new namespace without a `default-deny` is auto-flagged.
- [ ] Monthly review of `discovery/<namespace>.md` for changes in legitimate egress (new vendor SaaS, etc.).

## Dependencies

- Harbor proxy-cache projects (DEVOP-589) must land **before** Phase 2, or the allowlists will be churn — they'd need to allow direct `ghcr.io` etc., then be rewritten to allow only `harbor.allora-network.io`.
- Kyverno on all clusters (DEVOP-588) is a soft dependency: Phase 4 needs it but Phases 0–3 can proceed.

## Out of scope for this ticket

- IDS/anomaly detection on egress flow logs — separate ticket (Falco rules, DEVOP-570).
- Ingress NetworkPolicies — separate hardening pass, not in Shai-Hulud scope.

## Who runs this

- Owner: cluster-admin / platform team.
- Reviewer: security team (sign-off on each phase before proceeding to the next).
- Estimated total engineer-time: ~3 engineer-weeks calendar, ~50% utilization (lots of waiting for flow-log baselines to accumulate).

## Links

- Linear: https://linear.app/alloralabs/issue/DEVOP-579
- Cilium NetworkPolicy reference: https://docs.cilium.io/en/stable/security/policy/
- Calico NetworkPolicy reference: https://docs.tigera.io/calico/latest/network-policy/
