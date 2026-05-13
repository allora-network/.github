# Security Incident Response Runbook

**Scope.** Supply-chain compromise of the kind seen in the Shai-Hulud
worm waves (Sept 2025–): a poisoned npm or PyPI release with a
`postinstall` or `setup.py` payload that exfiltrates credentials, mines
the org's git history for tokens, and republishes a worm-baked version
of any package the credential can publish. Adjacent scenarios — leaked
PAT, malicious GitHub Action, compromised Docker base image — share
most of the response steps and are folded in.

**Audience.** Anyone at Allora who notices something. Page the
on-call DevOps engineer; this runbook is the script they will run.

**Plain-language priority.** Stop the bleed first; preserve evidence
second; restore service third; write the post-mortem last.

---

## Table of contents

1. [Detection sources — where alerts come from](#1-detection-sources)
2. [Triage decision tree](#2-triage-decision-tree)
3. [Scenario A — Developer workstation suspected infected](#3-scenario-a--developer-workstation-suspected-infected)
4. [Scenario B — CI runner suspected infected](#4-scenario-b--ci-runner-suspected-infected)
5. [Scenario C — Compromised package published from our org](#5-scenario-c--compromised-package-published-from-our-org)
6. [Scenario D — Cluster pod suspected compromised](#6-scenario-d--cluster-pod-suspected-compromised)
7. [Token rotation cadence](#7-token-rotation-cadence)
8. [Tabletop exercise schedule](#8-tabletop-exercise-schedule)
9. [Appendix — useful commands](#9-appendix--useful-commands)

---

## 1. Detection sources

Alerts that should trigger this runbook:

| Source | Channel | What it means | Owner |
|---|---|---|---|
| **Falco** (cluster runtime) | `#security-alerts` Slack via Falcosidekick | A container did something its workload profile shouldn't — wrote to `~/.npmrc`, scanned `/proc/*/environ`, opened an outbound connection to a non-allowlisted host. **Treat as Scenario D.** | DevOps on-call |
| **Org-wide IOC sweep** (`allora-network/.github` daily workflow, DEVOP-560) | GitHub issue auto-filed on `allora-network/incident-response`; cross-posted to Slack | A repo's lockfile or vendored artifact matches `.github/security/ioc-packages.txt` or `.github/security/ioc-hashes.txt`. **Treat as Scenario C if we are the publisher; otherwise pin a clean version (Scenario A workflow #1).** | DevOps on-call |
| **Dependabot alert** | GitHub Security tab + Slack #security-alerts | A direct or transitive dep has a published advisory. Most are low-noise; cross-reference against the daily sweep before paging. | Repo CODEOWNER |
| **Secret scanning push protection** | GitHub web UI (push blocked) + audit log | A developer attempted to push a recognized secret. Almost always a near-miss; still requires rotating the secret. | Pusher + DevOps on-call |
| **Manual report** (Slack, email, PR comment) | Whatever channel saw it | Engineer noticed something odd — `pnpm install` warnings, unexpected outbound traffic on their laptop, a Sigstore signature mismatch from a downstream consumer. | DevOps on-call |

If you are the on-call: **acknowledge in `#security-alerts` within 5 minutes**, even if the ack is "looking into it, no triage yet." Silent acknowledgments are how the team loses confidence that the runbook is running.

---

## 2. Triage decision tree

Run this from the top. It takes 5–10 minutes when the answer is "false positive"; it takes the rest of the day when it isn't.

```
START
  │
  ├── Is the alert from Falco AND does the rule have a known false-positive
  │   (e.g. arc-runner image pull, syft sbom scan)?
  │     yes → ack in Slack; tune the rule in flux-*/falco/rules.yaml in a
  │           follow-up PR; STOP.
  │     no  → continue.
  │
  ├── Is the alert "package@version matches IOC list"?
  │     yes →
  │       ├── Did WE publish that package?
  │       │     yes → Scenario C (compromised publish). PAGE PUBLISHER + on-call.
  │       │     no  → pin a known-good version; open a PR; STOP. (Not an incident.)
  │       │
  │       └── (always) confirm no other repo pulls the bad version transitively.
  │
  ├── Is the alert "secret detected in commit / leaked env"?
  │     yes → rotate the secret NOW (see §7); audit anywhere it could have
  │           been used in the last 90 days; STOP if no exfil signal.
  │           ESCALATE to incident if exfil is plausible.
  │
  ├── Is the alert "weird behavior on a developer workstation"?
  │     yes → Scenario A.
  │
  ├── Is the alert "weird behavior on a CI runner / GitHub-hosted or
  │   self-hosted Arc"?
  │     yes → Scenario B.
  │
  ├── Is the alert "weird behavior on a running pod"?
  │     yes → Scenario D.
  │
  └── None of the above → ack, dig in, write up findings as a follow-up
      ticket in the `Shai-Hulud Mitigation` Linear project. DO NOT close
      the alert silently.
```

Anyone can stop the bleed; only the on-call gets to *declare* the
incident over. If you escalated to incident, the on-call writes the
post-mortem (see §8).

---

## 3. Scenario A — Developer workstation suspected infected

**Indicators**

- Unexpected outbound network from `npm install` / `pnpm install` /
  `pip install` (verify with Little Snitch / `tcpdump` / Console.app
  network privacy log).
- `~/.npmrc`, `~/.pypirc`, `~/.aws/credentials`, `~/.gnupg/`,
  `~/.ssh/` accessed by a process you didn't launch.
- A package install hung or produced an unexpected `postinstall` log.
- Pre-commit `.git/hooks` modified that you didn't write.

**Stop the bleed (first 10 minutes, in order, no skipping)**

1. **Disconnect the machine from the network.** Pull the wifi
   dropdown / unplug ethernet. This is the single most important step.
2. Open Slack on your phone, post in `#security-alerts`:
   > Possible workstation compromise — `<your hostname>`, disconnected,
   > paging on-call. Last package operation: `<npm|pip|...> <pkg>`.
3. From your phone, revoke every long-lived credential the machine
   could read (do **not** reconnect to revoke — use a different device):
   - GitHub personal access tokens: <https://github.com/settings/tokens>
     → revoke all PATs. Reissue fine-grained-only later.
   - GitHub fine-grained tokens.
   - GitHub SSH keys: revoke any tied to the laptop.
   - npm tokens: `npm token revoke <token>` from a clean machine,
     or web UI <https://www.npmjs.com/settings/~/tokens>.
   - PyPI API tokens: <https://pypi.org/manage/account/token/> →
     revoke all.
   - AWS access keys: AWS console → IAM → your user → access keys →
     deactivate. (If you only use SSO/aws-vault, also expire the SSO
     session.)
   - Dashlane / 1Password / browser-stored passwords: rotate the
     vault master password from a clean device; revoke active
     device sessions for every account that lives in the vault.
   - Slack: <https://allora.slack.com/account/settings#sessions> →
     sign out all sessions.

**Preserve evidence**

4. From a different machine, SSH-or-ARD into the suspect machine **for
   forensic capture only** if the team's DFIR capability needs it
   (usually not — see §3 final note). If skipping forensics, go to step 5.
5. The infected machine stays off and disconnected until step 6.

**Restore service**

6. Wipe + reinstall macOS (or your OS). Do not restore from any
   backup taken after the suspected infection. Restore application
   data from cloud sources (Drive, Dropbox, Notion, Linear, GitHub)
   that you can audit.
7. Reissue credentials from the wiped machine. Use **only** fine-grained
   GitHub tokens; do not create classic PATs.
8. Reinstall package manager configs from scratch. Add the
   `npmrc`-from-CONTRIBUTING.md (`ignore-scripts=true` per
   DEVOP-553/572). Add `--require-hashes --only-binary=:all:` aliases
   for pip (per DEVOP-572).

**Close-out**

9. Post in `#security-alerts`: timeline, what was rotated, residual
   risk, blast radius (anything you can't fully prove the malware
   *didn't* touch). On-call decides whether to escalate to a written
   post-mortem (any token rotation that included `NPM_TOKEN` for a
   package we publish: yes, post-mortem mandatory).

**Note on forensics.** We do not currently have an in-house DFIR
capability. The standard response is to wipe + rebuild rather than
attempt malware analysis. If you find evidence of lateral movement
into the cluster or another team member's environment, escalate to
the security advisor on retainer (contact info in 1Password →
"Security retainer — DFIR firm").

---

## 4. Scenario B — CI runner suspected infected

Three flavors: GitHub-hosted runner, our self-hosted Arc runners (`arc-allora-network-*`), or our reusable workflows themselves running on someone else's runner.

**Indicators**

- A workflow run pushed an unexpected commit, opened an unexpected
  PR, or published a package version not tied to a tag.
- Falco fired on an Arc runner pod doing something outside its
  workload profile (DEVOP-570 rules will surface this directly).
- Cosign verification (DEVOP-564) fails on an image that should
  have been signed.
- A reusable workflow ran with permissions it shouldn't have had
  (audit log shows `id-token: write` granted for a workflow that
  doesn't sign anything, etc.).

**Stop the bleed**

1. **Disable the affected workflow immediately.** Either:
   - `gh workflow disable <name> --repo <owner>/<repo>` for a single
     workflow, or
   - Move the affected runner pool out of rotation: edit the
     `RunnerSet` manifest in `flux-gcp-labs/.../arc/` to scale
     replicas to 0 and commit. Flux reconciles in ~1 minute.
2. Post in `#security-alerts` with the workflow run URL.

**Audit blast radius**

3. List everything the runner had access to:
   - For GitHub-hosted: `GITHUB_TOKEN` (scoped to the repo, with
     whatever the workflow declared in `permissions:`) +
     `secrets.*` referenced in the workflow YAML. Pull the secret
     names from the file.
   - For Arc self-hosted: same, plus anything the underlying
     `ServiceAccount` could read in the cluster
     (`kubectl auth can-i --list --as=system:serviceaccount:arc:<sa-name>`).
4. Rotate **every** credential in that scope. Treat anything the
   runner could have read in the last 90 days as exposed. The
   list:
   - `CI_HARBOR_USERNAME`, `CI_HARBOR_SECRET`, `CI_HARBOR_REGISTRY`
     (regenerate in Harbor → robot accounts).
   - `NPM_TOKEN` for any package the workflow publishes
     (`npm token revoke` + reissue as a granular token).
   - `PYPI_API_TOKEN` for any package the workflow publishes.
   - AWS roles assumed via OIDC: review the trust policy and
     `Conditions` (the OIDC subject claim should pin the
     `repo:org/repo:ref:refs/heads/main` claim, not `*`). If
     `*` is in there, fix it now.
   - Slack webhooks, Sentry DSNs, third-party API keys.
5. Audit recent publishes:
   - npm: `npm view <pkg> versions --json` → diff against tagged
     git releases. Any version that doesn't map to a tag is
     suspect.
   - PyPI: `pip index versions <pkg>` → same diff.
   - Harbor: `harbor-cli artifact list <project>/<repo>` →
     compare digests against CI artifact records.
   - If any suspect version published: jump to Scenario C.

**Restore service**

6. Re-enable the workflow only after every step above is complete
   AND the runner image has been rebuilt from a clean base (for
   Arc) or you've waited at least one GitHub-hosted runner image
   refresh cycle (24 hours).

**Close-out**

7. Post-mortem mandatory if any secret was rotated. File a ticket
   on the `Shai-Hulud Mitigation` project tagging the runbook
   author for an update; runbook stays in sync with what actually
   happened.

---

## 5. Scenario C — Compromised package published from our org

The expensive scenario. If we published a poisoned version of
`@allora-network/<pkg>` or `allora-<pkg>` to npm/PyPI, every
downstream consumer of ours is now at risk and we are obligated to
notify them.

**Stop the bleed**

1. **Yank the version from the registry.**
   - npm: `npm deprecate <pkg>@<version> "Compromised — do not use. See <advisory URL>."` then `npm unpublish <pkg>@<version>` if within the 72-hour unpublish window. **Do NOT delete the package outright** — unpublishing the whole package permanently burns the name and is a destructive action that requires a separate authorization (do NOT run unless the publisher and on-call both agree, in writing in `#security-alerts`).
   - PyPI: <https://pypi.org/manage/project/<pkg>/release/<version>/> → "Delete release". PyPI does not allow re-uploading a deleted version, so the next clean release must bump.
   - Harbor: `curl -X DELETE 'https://<harbor>/api/v2.0/projects/<project>/repositories/<pkg>/artifacts/<digest>'` — and the operator must verify the cosign signature is also revoked from Rekor (`cosign tree <image>` shows the attestations).
2. Open a GitHub security advisory on the affected repo
   (`Security` tab → Advisories → New draft). Include affected
   versions, severity, and a placeholder for the fixed version.
3. Pin a known-good version everywhere: open PRs in every consumer
   repo (the daily sweep workflow's report has the full list) to
   pin the override.

**Publish a corrected version from a clean environment**

4. **Do NOT publish from any machine that could have been
   compromised.** Use a freshly-provisioned GitHub Actions
   runner (or a known-clean dev machine that has not been
   anywhere near the suspect code).
5. Cut a fresh release on a new minor bump (do not reuse the bad
   version number even if the registry would allow it).
6. The publish workflow MUST follow the post-DEVOP-545 pattern:
   - `--ignore-scripts` on the install.
   - `NPM_TOKEN` / `PYPI_API_TOKEN` written to `~/.npmrc` /
     `~/.pypirc` **after** install, **before** publish, then
     deleted in the same step.
   - cosign signature + SBOM attestation (DEVOP-564/565).
7. Publish the GitHub security advisory.

**Notify downstream**

8. Email + Slack DM every confirmed downstream consumer (we
   maintain a list in 1Password → "Package consumers"; if not
   listed, post on the org's social channels). Required content:
   - Affected versions.
   - Indicators of compromise (what the malware did).
   - Recommended action (pin clean version + rotate any
     credential the malware could have read).
   - Contact email for follow-up questions.
9. Update the Shai-Hulud IOC list
   (`allora-network/.github/.github/security/ioc-packages.txt`,
   DEVOP-561) to include the compromised version. The daily sweep
   will then page on any straggler.

**Close-out**

10. Post-mortem mandatory. Tag the publisher, the on-call, the
    DevOps lead, and the founders.

---

## 6. Scenario D — Cluster pod suspected compromised

**Indicators**

- Falco fired on a workload pod (the rules in DEVOP-570 cover the
  Shai-Hulud behavior set: writes to `~/.npmrc` outside of an
  install workload, scans of `/proc/*/environ`, outbound to
  non-allowlisted hosts, exec into other pods).
- Audit log shows `kubectl exec` from a service account that
  shouldn't be using exec.
- A pod's egress is hitting a CDN/IP that is not on the
  NetworkPolicy allowlist (DEVOP-579 will block this once
  deployed; until then, only detect it).

**Stop the bleed**

1. **Cordon the node** (so nothing else schedules there while we
   investigate):
   ```bash
   kubectl cordon <node-name>
   ```
2. **Capture forensic data BEFORE deleting the pod**, in this order:
   ```bash
   POD=<pod-name>; NS=<namespace>
   kubectl -n "$NS" describe pod "$POD" > /tmp/$POD-describe.txt
   kubectl -n "$NS" get pod "$POD" -o yaml > /tmp/$POD.yaml
   kubectl -n "$NS" logs "$POD" --all-containers --previous > /tmp/$POD-logs-prev.txt
   kubectl -n "$NS" logs "$POD" --all-containers > /tmp/$POD-logs.txt
   kubectl -n "$NS" exec "$POD" -- ps auxf > /tmp/$POD-ps.txt || true
   kubectl -n "$NS" exec "$POD" -- ss -tnap > /tmp/$POD-netstat.txt || true
   # Falco events for the pod, last 1h:
   kubectl -n falco logs -l app=falco --since=1h | grep "$POD" > /tmp/$POD-falco.txt
   ```
   Upload to the incident drive (`drive/incidents/<date>-<scenario>/`).
3. **Delete the pod** (it will recreate elsewhere; the deployment
   stays scaled at its current count). If the threat is acute
   (active exfiltration in progress), scale the deployment to 0
   instead:
   ```bash
   kubectl -n "$NS" scale deployment <name> --replicas=0
   ```

**Audit blast radius**

4. List secrets the pod could read. **Derive the ServiceAccount
   from the pod YAML you captured in step 2**, not from the live
   pod — by this point the pod is gone or rescheduled, and a live
   lookup will fail or (worse) return the SA of a freshly-recreated
   replacement that you may not have audited yet:
   ```bash
   # Read SA from the snapshot captured in step 2 (works after pod deletion).
   # Requires yq (https://github.com/mikefarah/yq); fall back to grep if absent.
   SA=$(yq '.spec.serviceAccountName' /tmp/$POD.yaml 2>/dev/null \
        || grep -E '^\s*serviceAccountName:' /tmp/$POD.yaml | awk '{print $2}')
   kubectl auth can-i --list --as=system:serviceaccount:$NS:$SA
   kubectl -n "$NS" get secret -o name | xargs -I{} kubectl -n "$NS" describe {} | head
   ```
5. Rotate every secret in that list. If the pod could `get
   secrets` cluster-wide, that's a Scenario B + D combined — page
   the founders.

**Restore service**

6. Once the offending image has been replaced (rebuild from clean
   source — see Scenario C if the image came from one of our
   pipelines) and the secrets are rotated, uncordon the node:
   ```bash
   kubectl uncordon <node-name>
   ```

**Close-out**

7. Post-mortem mandatory. Include the Falco rule output,
   timeline, and any Kyverno policy gap that allowed the bad
   image to run in the first place (file follow-up tickets if so).

---

## 7. Token rotation cadence

| Credential class | Rotation cadence | Trigger to rotate immediately |
|---|---|---|
| GitHub PAT (any kind) | **Quarterly**, on the 1st of the month | Suspected workstation/runner compromise; pat appears in any leaked log |
| GitHub fine-grained tokens | **Quarterly** | Same |
| npm publish tokens (`NPM_TOKEN`) | **Quarterly**; ideally migrate to OIDC Trusted Publishers (DEVOP-578) | Any CI run that could have read it shows anomaly; suspected workstation compromise of a publisher |
| PyPI API tokens | **Quarterly**; ideally migrate to PyPI Trusted Publishers | Same as npm |
| Harbor robot accounts (`CI_HARBOR_*`) | **Quarterly**; ideally migrate to OIDC (DEVOP-574) | Any CI runner anomaly; any Falco hit on a build pod |
| AWS access keys (long-lived) | **Should be ZERO** — use OIDC `AssumeRoleWithWebIdentity`. If one exists, rotate every 30 days and file a ticket to eliminate it. | Always |
| Slack webhooks, Sentry DSNs, third-party API keys | **Annually** | Suspected runner compromise |
| Cluster ServiceAccount tokens | Bound-token only (1h TTL via projected volumes); no long-lived SA tokens. If you find one, file an issue. | — |
| Privy delegated wallet keys | Per the Privy rotation policy — see backend `wallet_service.py` docs | Any reported user-facing wallet incident |

The quarterly rotation calendar lives in 1Password → "Security
rotation calendar". The on-call rotation owner is responsible for
walking the list each quarter and either rotating or filing tickets
to migrate the credential to OIDC.

---

## 8. Tabletop exercise schedule

**Annual cadence.** Once per calendar year, in Q1 (when product
load is lowest). See DEVOP-573 for the active scenario. The exercise
is a 90-minute synchronous session, run by the security on-call,
attended by:

- All DevOps engineers
- One backend engineer
- One frontend engineer (so the dev-workstation scenarios are
  exercised by someone whose dev environment matches the
  representative target)
- The founder on-call

**Format.** Inject the scenario in `#security-alerts` at a pre-
arranged time. The attendees run this runbook against the inject in
real time. The facilitator times each step, notes friction, and
files follow-up tickets in the `Shai-Hulud Mitigation` Linear
project for every step that ran slow or hit ambiguity. The runbook
is then updated based on the tickets — the exercise's primary
output is a cleaner runbook, not a passing grade.

**Skip rules.** Skipping a year requires explicit founder approval.
Defaulting to "we'll do it next year" is how runbooks rot.

---

## 9. Appendix — useful commands

### Find every repo that pulls a specific package version

```bash
# npm (across the allora-network org)
gh search code --owner allora-network 'extension:json "<package-name>"' --limit 200 | jq -r '.repository.name' | sort -u

# pypi (across the allora-network org)
gh search code --owner allora-network 'filename:requirements.txt "<package-name>=="' --limit 200
```

### Verify an image's cosign signature + SBOM

```bash
# Replace registry/repo/digest with your image
IMAGE=harbor.allora-network.io/allora-network/<image>@sha256:<digest>

# Signature
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp "^https://github.com/allora-network/" \
  "$IMAGE"

# SBOM attestation
cosign verify-attestation --type spdx \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp "^https://github.com/allora-network/" \
  "$IMAGE" | jq '.payload | @base64d | fromjson | .predicate.packages[] | {name, versionInfo}'
```

### Force-trigger the daily IOC sweep

```bash
gh workflow run shai-hulud-sweep.yml --repo allora-network/.github
gh run watch --repo allora-network/.github
```

### Drain and replace a suspect node

```bash
NODE=<node-name>
kubectl cordon "$NODE"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force
# After investigation:
kubectl delete node "$NODE"   # auto-replaced by autoscaler
```

---

**Runbook owner:** DevOps on-call. **Last full review:** 2026-05-13
(initial publication, DEVOP-571). **Next review:** annual, in
conjunction with the tabletop exercise (DEVOP-573).
