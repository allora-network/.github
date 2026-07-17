# DEVOP-617 — Org-wide go.mod `replace`-directive audit

Linear: https://linear.app/alloralabs/issue/DEVOP-617

## Goal
Detect attacker-fork redirects in any allora-network Go module's
`replace` directive — the canonical Go-side Shai-Hulud vector.

## Deliverables
1. `.github/workflows/gomod-replace-audit.yml` — weekly + manual-dispatch
   org sweep. Enumerates every `go.mod` via per-repo sharded `gh api search/code`, fetches each
   from its default branch, runs the awk extractor from
   `shai-hulud-defense/REFERENCE.md` (covers single-line + `replace (...)`
   blocks), and filters against the trusted-host allowlist. Non-allowlisted
   RHS → rolling GitHub Issue (label `gomod-replace-audit`) + Slack page on
   IOC-grade findings. Distinct label from DEVOP-560's `shai-hulud-sweep`
   so the two pipelines don't collide.
2. `docs/security/gomod-replace-audit-2026-05-25.md` — initial point-in-time
   audit report: every `replace` directive in the org today, classified.

## Scope notes
- Uses the same canonical allowlist as REFERENCE.md and
  `scripts/shai-hulud-ioc-sweep.sh` (`GO_TRUSTED_HOSTS` default).
- The sweep script's `go_suspicious_replace` rule already covers this
  detection on cloned-repo workspaces; this workflow adds a lighter-weight
  no-clone pass via the Contents API so it can scale to all org repos
  weekly without re-cloning everything (DEVOP-560 stays the deeper daily
  forensic sweep).
- Permissions: `contents: read`, `issues: write` only. All `uses:` SHA-pinned.
- Honors user-rules: new files only (workflow + plan + report); no
  application code changes.
