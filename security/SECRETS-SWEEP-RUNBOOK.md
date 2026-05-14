# Historical secrets sweep runbook — DEVOP-587

This is the compensating control for not buying GitHub Advanced Security: a one-off (then monthly) trufflehog + gitleaks sweep across the full git history of every repo in `allora-network`. Cost: ~$0. Recovers ~95% of the value of GHAS historical secret scanning.

## When to run

- **Once now** as the baseline.
- After every credential rotation (DEVOP-563) — confirms the rotated value no longer hits.
- Monthly via cron (planned: scheduled workflow in this repo; see "Future work" below).
- After any incident (DEVOP-573 tabletop).

## Pre-flight

- [ ] Stand up a **single-purpose** VM or container. No other Allora credentials present. No SSH keys for production. No 1Password Connect. Just `gh`, `trufflehog`, `gitleaks`, `jq`, `git`.
- [ ] Set `GH_TOKEN` to a **fine-grained personal access token** with:
    - **Resource owner:** `allora-network`
    - **Repository access:** *All repositories* (the sweep enumerates the full org)
    - **Repository permissions** (read-only, nothing else):
      - `Contents: Read-only`
      - `Metadata: Read-only`
    - No account permissions. No write permissions of any kind.

    Do **not** use a classic PAT with the `repo` scope — that scope is read+write on every accessible repo and is overprovisioned for a sweep that must never write. Do **not** use `GH_READONLY_PAT` — that org secret is being rotated per DEVOP-586.

    > A long-lived org-scoped fine-grained PAT is being provisioned under DEVOP-577 for the scheduled re-sweep workflow. Until that lands, generate a *personal* fine-grained PAT scoped per the above for the baseline run, and delete it immediately after triage.
- [ ] Confirm disk: ~5 GB free for clones across 225 repos.

## Run

```bash
# from this repo root
bash scripts/secrets-sweep.sh
```

Approximate runtime: 30–60 min depending on the size of monorepos like `allora-chain` and `eliza-allora-plugin`.

## Triage

The script writes everything to `/tmp/sweep`:
- `SUMMARY.md` — a markdown table of repos with non-zero hits.
- `<repo>.trufflehog.jsonl` — trufflehog raw output (one JSON object per line).
- `<repo>.gitleaks.json` — gitleaks raw output.
- `<repo>.trufflehog.err` / `<repo>.gitleaks.log` — stderr.

Triage steps:

1. Open `SUMMARY.md`. Sort by trufflehog verified count descending.
2. For every **verified** trufflehog hit:
   - The credential is currently active. Rotate immediately. Order matters — rotate before continuing the sweep so the value in subsequent commits doesn't keep being "verified".
   - Mark the row in the tracking spreadsheet (link from SECURITY-RUNBOOK.md) as "rotated YYYY-MM-DD by @handle".
3. For every gitleaks hit that trufflehog didn't verify:
   - Spot-check the commit and surrounding code. Common false positives: example fixtures, test wallets, public mainnet addresses.
   - If real but inactive, document and rotate anyway (defense in depth).
4. After all hits triaged, tar `/tmp/sweep` and store in a **password-protected** archive in 1Password (or equivalent). The raw output contains actual secret values until rotated.
5. `shred -uvz /tmp/sweep/*; shred -uvz /tmp/clones/<repo>.git/* 2>/dev/null; rm -rf /tmp/sweep /tmp/clones`.
6. **Tear down the VM** (do not reuse).

## Output of the baseline run

When the baseline runs, paste the contents of `SUMMARY.md` into the comment thread on DEVOP-587 (Linear). Do **not** include any actual secret values — just counts.

## Future work

- Scheduled monthly re-sweep — small workflow in this repo that runs the script on a GitHub-hosted runner, uploads the encrypted bundle to a private GCS bucket, and posts SUMMARY.md to Slack `#sec-ops`. Gated on:
  - `GH_TOKEN` provisioning as a read-only org-scoped fine-grained PAT (DEVOP-577).
  - A private GCS bucket for the encrypted reports.
- Add `secretscan-baseline.txt` (list of known false-positive commit SHAs) so monthly runs don't keep re-flagging the same fixtures.

## Tools

- `trufflehog` (≥3.x) — `brew install trufflehog`.
- `gitleaks` (≥8.x) — `brew install gitleaks`.
- `gh` — `brew install gh`.
- `jq` — `brew install jq`.

Reference: https://github.com/trufflesecurity/trufflehog · https://github.com/gitleaks/gitleaks
