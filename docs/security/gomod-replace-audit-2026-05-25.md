# `go.mod` replace-directive audit — 2026-05-25

Linear: [DEVOP-617](https://linear.app/alloralabs/issue/DEVOP-617)
(Shai-Hulud Go-side defense layer)

## Method

1. Enumerated every Go module in the `allora-network` org via
   `gh search code --owner allora-network 'filename:go.mod' --limit 200`.
   GitHub code search returned 12 distinct `<repo>/<path>` tuples across
   11 repos (one repo — `allora-chain` — has a sub-module under
   `linter/maprange/`; another — `allora-forge-platform`,
   `allora-workers`, `forge-v2` — keeps `go.mod` in a subdirectory).
2. Fetched each `go.mod` from its default branch via
   `gh api repos/<owner>/<repo>/contents/<path>` and base64-decoded.
3. Extracted every `replace` directive — single-line *and* block form
   (`replace (...)`) — using the canonical awk extractor from
   `shai-hulud-defense/REFERENCE.md` §Go specifics.
4. Classified each `replace` RHS against the canonical trusted-host
   allowlist (same regex used by
   `scripts/shai-hulud-ioc-sweep.sh#GO_TRUSTED_HOSTS` and the hardened
   reusable workflows):
   `github.com/(allora-network|cosmos|ethereum|fluxcd) | gopkg.in | google.golang.org | go.uber.org | go.opentelemetry.io | k8s.io | sigs.k8s.io`.

## Summary

| Metric | Count |
|---|---|
| Go modules scanned | **12** (across 11 repos) |
| Modules with **zero** replace directives | **9** (12 scanned − 3 with replaces = 9) |
| Modules with at least one replace directive | **3** (`allora-chain/go.mod`, `allora-sdk-go/go.mod`, `forge-v2/backend/go.mod`) |
| Total `replace` directives found | **6** |
| Allowlisted-host RHS | 2 |
| Non-allowlisted-host RHS (all version-pin pattern) | 4 |
| Local relative (`./`, `../`) RHS | 0 |
| Absolute-path (`/`) RHS | 0 |
| **SUSPICIOUS — attacker-fork redirect** | **0** |
| Escalated to incident response | **0** |

> **No suspicious replace directives found.** Every non-allowlisted entry
> is a same-path version-pin (`LHS module path == RHS module path`),
> which structurally cannot redirect to an attacker fork — the RHS is
> the identical upstream module, just forced to a specific version. See
> classification table below.

## Repos with zero replace directives

These nine modules carry no `replace` directives at all (clean):

- `allora-network/allora-chain` — `linter/maprange/go.mod`
- `allora-network/allora-forge-platform` — `apps/backend/go.mod`
- `allora-network/allora-indexer` — `go.mod`
- `allora-network/allora-offchain-operator` — `go.mod`
- `allora-network/allora-producer` — `go.mod`
- `allora-network/allora-workers` — `scripts/go.mod`
- `allora-network/cosmopilot` — `go.mod`
- `allora-network/forge-data-service` — `go.mod`
- `allora-network/tokenomics` — `go.mod`

## Findings (all `replace` directives present)

| # | Repo | go.mod path | Line | LHS module | RHS module | RHS version | Classification | Notes |
|---|---|---|---|---|---|---|---|---|
| 1 | `allora-network/allora-chain` | `go.mod` | 11 | `github.com/gin-gonic/gin` | `github.com/gin-gonic/gin` | `v1.9.1` | legitimate — same-path version pin | Inside `replace (...)` block. Adjacent comment references [`cosmos/cosmos-sdk#10409`](https://github.com/cosmos/cosmos-sdk/issues/10409) and the cosmos-sdk `simapp/go.mod` pin — this is the canonical Cosmos SDK simapp pattern. LHS==RHS path; not a redirect. |
| 2 | `allora-network/allora-chain` | `go.mod` | 13 | `github.com/syndtr/goleveldb` | `github.com/syndtr/goleveldb` | `v1.0.1-0.20210819022825-2ae1ddf74ef7` | legitimate — same-path version pin | Same block, comment says "Downgraded to avoid bugs in following commits which caused simulations to fail." LevelDB Go port, widely used by Cosmos / Ethereum chains. LHS==RHS; not a redirect. |
| 3 | `allora-network/allora-sdk-go` | `go.mod` | 5 | `github.com/cosmos/cosmos-sdk` | `github.com/cosmos/cosmos-sdk` | `v0.50.13` | legitimate — allowlisted host + same-path version pin | Allowlisted host (`github.com/cosmos`). LHS==RHS; not a redirect. |
| 4 | `allora-network/allora-sdk-go` | `go.mod` | 7 | `github.com/cometbft/cometbft` | `github.com/cometbft/cometbft` | `v0.38.17` | legitimate — same-path version pin | CometBFT is the canonical BFT consensus engine for Cosmos chains (successor to Tendermint). LHS==RHS; not a redirect. Not currently on the trusted-host allowlist — **see recommendation 1 below**. |
| 5 | `allora-network/forge-v2` | `backend/go.mod` | 5 | `github.com/cosmos/cosmos-sdk` | `github.com/cosmos/cosmos-sdk` | `v0.50.13` | legitimate — allowlisted host + same-path version pin | Identical to finding #3. |
| 6 | `allora-network/forge-v2` | `backend/go.mod` | 7 | `github.com/cometbft/cometbft` | `github.com/cometbft/cometbft` | `v0.38.17` | legitimate — same-path version pin | Identical to finding #4. |

## Classification key

| Class | Meaning |
|---|---|
| `legitimate — allowlisted host + same-path version pin` | RHS host is in the canonical trusted-host allowlist AND `LHS module path == RHS module path` (the directive is a version pin, not a redirect). |
| `legitimate — same-path version pin` | `LHS module path == RHS module path` even though the host is not in the canonical allowlist. Structurally cannot redirect to an attacker fork — the RHS is the same upstream module. Safe; flagged only by the host-allowlist filter. |
| `SUSPICIOUS` | RHS host is not allowlisted AND `LHS module path != RHS module path`. Genuine redirect candidate; escalate to incident response. |
| `investigate-absolute` | RHS begins with `/` (absolute filesystem path). Can resolve outside the checked-out tree on writable runners; treat as IOC-grade. |

No findings in this audit fell into the `SUSPICIOUS` or `investigate-absolute` classes.

## Recommendations

1. **Add `github.com/cometbft` to the canonical trusted-host allowlist**
   (`REFERENCE.md` §Go specifics, `scripts/shai-hulud-ioc-sweep.sh#GO_TRUSTED_HOSTS`,
   and `.github/workflows/gomod-replace-audit.yml`). CometBFT is the
   canonical BFT consensus engine for Cosmos chains (publisher succeeded
   Tendermint at `github.com/cometbft`). Excluding it produces a steady
   stream of low-value findings on every Cosmos-SDK-based module. Track
   under a follow-up DEVOP ticket and roll out via PR to this same repo.
2. **Document the "same-path version pin" pattern as known-safe** in
   `shai-hulud-defense/REFERENCE.md` so future audits don't re-litigate
   findings #1–#6 each refresh. The existing
   `scripts/shai-hulud-ioc-sweep.sh#go_replace_path_mismatch` rule
   correctly distinguishes this (it only fires when `lhs_top != rhs_top`)
   — propagate the same distinction into this no-clone Contents-API
   workflow when we revisit it.
3. **No immediate action on any of the six findings.** All are legitimate
   version pins from the cosmos/simapp pattern. Re-audit on the next
   weekly run; escalate any new entry that breaks the same-path pattern.

## Cross-pipeline follow-ups (deferred — not blocking this PR)

The following items surfaced during PR #9 ce-code-review require touching
the sibling DEVOP-560 PR's files (`scripts/shai-hulud-ioc-sweep.sh`,
`shai-hulud-defense/REFERENCE.md`) or adding new test infrastructure.
Tracking here so they don't fall off the radar:

- **Extract `GO_TRUSTED_HOSTS_RE` to a single committed text file**
  (e.g. `.github/security/go-trusted-hosts.regex`) so the workflow,
  `shai-hulud-ioc-sweep.sh`, and `REFERENCE.md` all consume the same
  source. Today the regex lives in three places with a "must match"
  comment instead of structural enforcement — the first cometbft
  allowlist edit will fan out across all three.
- **Extract the awk `replace`-directive extractor to
  `scripts/extract-go-replace.awk`** so both this workflow and the
  daily sweep parse go.mod with the same code path.
- **Add fixture-based parser tests** under `scripts/test-fixtures/`
  covering: single-line replace, `replace (...)` block, commented
  historical replace inside a block (false-positive vector), trailing
  `// comment` after a single-line replace, blank lines inside blocks,
  CRLF / UTF-8 BOM, and the full classification matrix
  (`legitimate-*` × `investigate-*` × `SUSPICIOUS`).
- **Add a regex lookalike-bypass corpus test** asserting positives
  (`github.com/allora-network/x`, `gopkg.in/x`, `k8s.io`) and negatives
  (`github.com/allora-network-evil/x`, `gopkg.in.attacker.com/x`,
  `evil.gopkg.in/x`, `github.com/cosmosmalicious/x`) all classify
  correctly. The `(/|$)` boundary anchor is load-bearing; protect it
  with CI.

## Cross-reference

- `.github/security/REFRESH.md` — IOC seed-list refresh cadence.
- `SECURITY-RUNBOOK.md` §Scenario C — incident response if a future
  audit returns any SUSPICIOUS row.
- DEVOP-560 (`.github/workflows/shai-hulud-sweep.yml`) — deeper daily
  forensic sweep that clones each repo and runs the full
  `go_suspicious_replace` / `go_replace_path_mismatch` / `go_local_replace`
  rule set on the cloned tree.
