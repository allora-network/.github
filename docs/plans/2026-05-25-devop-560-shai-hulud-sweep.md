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
  when the run produces **new** IOC findings — defined as `rc == 1` AND
  (no prior IOC-grade rolling-issue comment exists, OR today's IOC stamp
  differs from the previous one, OR ≥ `WEEKLY_REPAGE_S` (7 days) have
  elapsed since the last Slack page). Operational findings (clone_failed /
  check_skipped / go_local_replace, exit 2) update the rolling issue but
  do not page Slack. The dedup stamp is `sha256` of the sorted
  `{repo, rule, path, detail}` TSV of IOC-grade rows from `findings.json`
  (`ts` is intentionally excluded so an identical IOC set produces an
  identical stamp across daily runs). Previous-run state is recovered
  from hidden HTML markers embedded in the rolling-issue comment:
  `<!-- shai-hulud-ioc-stamp: ... -->` (always on IOC-grade comments) and
  `<!-- shai-hulud-paged-at: ... -->` (only on comments where Slack was
  actually paged, so a deduped run preserves the older real timestamp
  and the weekly re-page window stays honest). Do NOT regress this to a
  bare `if: rc == '1'` Slack gate — that's the alert-fatigue regression
  surfaced by cubic (`PRRT_kwDOLZ5Xss6Ee5gN`) and corroborated by four
  ce-code-review reviewers (anchor 100). A standing unresolved IOC pages
  daily under bare gating and conditions responders to mute the channel.
  Both the dedup gate AND the weekly re-page are required: bare dedup
  without re-page lets a forgotten standing IOC silently age out forever.
  IOC_RULES_RE in the workflow's dedup step MUST stay in sync with
  `scripts/shai-hulud-ioc-sweep.sh` (search for `IOC_RULES_RE`) — drift
  would either mis-dedup a real new IOC or re-page on operational-only
  changes that didn't bump the stamp.
- **Schedule:** `cron: '7 4 * * *'` (04:07 UTC, off-peak + off-minute), plus
  `workflow_dispatch` for manual / debugging runs.
- **Permissions:** `contents: read` + `issues: write`. No other scopes.
- **Member exfil search:** the default `GITHUB_TOKEN` does not carry `read:org`,
  so member enumeration will emit `check_skipped` operational findings. Wire a
  `GH_ORG_READ_TOKEN` secret in a follow-up if/when org-admin signs off — the
  workflow already prefers it when present.

## Third-party action SHA rotation

Both third-party actions used by `.github/workflows/shai-hulud-sweep.yml` are
pinned to immutable commit SHAs (not floating tags). Pinning to a SHA is the
hard requirement; **rotation is the maintenance burden that comes with it.**

| Action | Current pin | Tag at pin | Released |
| --- | --- | --- | --- |
| `actions/checkout` | `11bd71901bbe5b1630ceea73d27597364c9af683` | `v4.2.2` | 2024-10 |
| `actions/upload-artifact` | `b4b15b8c7c6ac21ea08fcf65892d2ee8f75cf882` | `v4.4.3` | 2024-10 |

- **Owner:** `@allora-network/devops`. The workflow file is co-owned by
  `@allora-network/security` (per `.github/CODEOWNERS`), so a SHA bump still
  goes through security review — devops drives the cadence, security signs
  off.
- **Cadence:** quarterly review (Jan / Apr / Jul / Oct) **plus** an immediate
  rotation on any CVE alert affecting either action. The quarterly cadence is
  cheap (two SHAs, ~10 minutes per cycle) and keeps us from drifting more
  than ~3 months behind upstream security fixes.
- **Canonical source for the latest release SHA:**
  - `actions/checkout`: <https://github.com/actions/checkout/releases> →
    pick the latest `vN.N.N` release → expand "Assets" → copy the **commit
    SHA** from the release tag's commit (NOT the release-tag's own object
    SHA, which is a tag object).
  - `actions/upload-artifact`: <https://github.com/actions/upload-artifact/releases>
    → same procedure.
  - Verify a candidate SHA against the action's signed releases tab before
    bumping. Never pin off `main` or a branch tip.
- **Rotation procedure:**
  1. Update the `uses: actions/...@<new-sha>` line in
     `.github/workflows/shai-hulud-sweep.yml`.
  2. Update the inline `# SHA pin: ... vX.Y.Z (YYYY-MM)` comment to match.
  3. Update this table.
  4. Open a PR — security CODEOWNER will be auto-requested by virtue of the
     workflow path rule.
- **Automation follow-up:** add `.github/dependabot.yml` with a
  `github-actions` package-ecosystem entry so Dependabot opens a PR with the
  new SHA on each release. This is additive and out of scope for the initial
  workflow ship — track separately. When added, the quarterly manual cadence
  collapses into "review the Dependabot PR within the same calendar quarter".

## Follow-ups (org-admin / out-of-scope for this PR)

- **Branch protection: require CODEOWNERS review on `main`.** The in-repo
  `.github/CODEOWNERS` rule is wired (DEVOP-560 Finding A), but it only
  enforces auto-requested reviewers — the actual blocking gate ("Require
  review from Code Owners") lives in branch protection / rulesets and is
  org-admin territory. Open as a separate issue once this PR is merged.
- **Missed-run / daily-cron observability (DEVOP-560 Finding F).** GitHub
  Actions silently auto-disables scheduled workflows after 60 days of repo
  inactivity, and there is no native "the daily cron didn't fire" signal.
  The current workflow relies on the rolling issue being updated daily; if a
  run is silently skipped, that signal is absent rather than negative. Out
  of scope for this PR because the fix is materially additive — either a
  second watchdog workflow (different repo, hourly, that pings the API for
  this workflow's last successful run timestamp and pages Slack if > 26h
  old) or a healthchecks.io / Better Stack heartbeat URL hit at the end of
  every successful run. Track separately.
- **Dependabot for `github-actions`.** See SHA-rotation section above. Adds
  `.github/dependabot.yml` with a `github-actions` ecosystem entry. Additive
  + low-risk; can ship alongside or after this PR.
