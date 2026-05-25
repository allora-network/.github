# DEVOP-560 — Daily Shai-Hulud IOC sweep workflow

Linear: <https://linear.app/alloralabs/issue/DEVOP-560>

## Decisions

- **Script location: vendored, not cloned.** The canonical script lives in
  `allora-network/skills` (PR #69, currently open), which is a **private repo**.
  The org `.github` workflow runs under the default `GITHUB_TOKEN` whose scope is
  bounded to this repo, so cross-repo private clones would require provisioning
  an extra deploy token / GitHub App. Self-containment also keeps the daily
  sweep working if the skills repo is ever rotated, renamed, or temporarily
  unavailable. Vendor a verbatim copy at `scripts/shai-hulud-ioc-sweep.sh`,
  with a header pointer to the canonical upstream path + commit SHA and a
  refresh procedure for keeping it in sync.
- **IOC inputs:** read `.github/security/ioc-packages.txt` and
  `.github/security/ioc-hashes.txt` from the workflow checkout (merged in PR #2
  via DEVOP-561). The script validates the `# schema:v1` header before running.
- **Rolling issue:** find the open issue labelled `shai-hulud-sweep` in this
  repo. If new findings exist and an open issue is present, append a comment
  with the run summary; if no open issue exists, open one with that label. The
  workflow never auto-closes; humans drive close-and-reopen so triage state is
  preserved across runs.
- **Slack alert path:** post the run summary to `SLACK_SECURITY_WEBHOOK` only
  when the run produces **new** IOC findings (sweep exits 1). Operational
  findings (clone_failed / check_skipped / go_local_replace, exit 2) update the
  issue but do not page Slack.
- **Schedule:** `cron: '7 4 * * *'` (04:07 UTC, off-peak + off-minute), plus
  `workflow_dispatch` for manual / debugging runs.
- **Permissions:** `contents: read` + `issues: write`. No other scopes.
- **Member exfil search:** the default `GITHUB_TOKEN` does not carry `read:org`,
  so member enumeration will emit `check_skipped` operational findings. Wire a
  `GH_ORG_READ_TOKEN` secret in a follow-up if/when org-admin signs off — the
  workflow already prefers it when present.
