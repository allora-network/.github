# IOC list refresh process

These files (`.github/security/ioc-packages.txt`, `.github/security/ioc-hashes.txt`)
are consumed by the daily org-wide IOC sweep workflow (DEVOP-560). They must
stay current to be useful.

## Cadence

- **Weekly** (Mondays, before standup): refresh from Socket's free advisory
  feed (https://socket.dev/threat-feed) filtered to `category:supply-chain`
  and `tag:shai-hulud`. Cross-check against the GitHub Advisory Database
  (`gh api graphql -F query=@advisories.graphql` — see runbook).
- **Ad hoc**: any time a new wave is disclosed publicly (Socket blog,
  GitHub Security blog, CrowdStrike intel). Page the on-call security
  engineer; do not batch.

## How

1. Open a branch in `allora-network/.github`: `security/ioc-refresh-YYYY-MM-DD`.
2. Diff the current `ioc-packages.txt` against the upstream feed; add new
   `<ecosystem>:<name>@<version>` lines. Do NOT remove old entries — the
   sweep workflow must continue to flag them for any repo that still pins
   a vulnerable version.
3. For `ioc-hashes.txt`, only add hashes confirmed by at least two
   independent sources (Socket + GHSA, or Socket + StepSecurity, etc.).
   Annotate each line with the advisory ID in a `# comment`.
4. PR title: `chore(security): refresh IOC lists YYYY-MM-DD`.
5. Tag `@allora-network/security-oncall` for review. Single approval is
   sufficient; this is additive content, not policy.
6. After merge, manually trigger the sweep workflow once to confirm the
   new IOCs are picked up: `gh workflow run shai-hulud-sweep.yml --repo
   allora-network/.github`.

## Refreshing the Datadog 2.0 snapshot

The Shai-Hulud 2.0 (Nov 2025 wave) section of `ioc-packages.txt` is imported
verbatim from Datadog's consolidated 7-vendor CSV. To refresh:

```bash
curl -fsSL https://raw.githubusercontent.com/DataDog/indicators-of-compromise/main/shai-hulud-2.0/consolidated_iocs.csv -o /tmp/datadog-iocs.csv

python3 - <<'PY'
import csv
with open('/tmp/datadog-iocs.csv') as f:
    r = csv.reader(f); next(r)
    for name, versions, _ in r:
        for v in (x.strip() for x in versions.split(',') if x.strip()):
            print(f"npm:{name}@{v}")
PY
```

Replace the block under `# npm — Shai-Hulud 2.0 (Datadog consolidated snapshot…)`
with the new output, bump "Snapshot: fetched YYYY-MM-DD", and PR as in the
generic flow above. Do not edit the snapshot rows by hand — always
re-import the full block so the file stays diff-able against upstream.

## Audit trail

Every refresh PR must link the upstream advisory in the PR body. The
SECURITY-RUNBOOK.md (DEVOP-571) has the long-form decision tree.
