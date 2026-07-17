#!/usr/bin/env bash
#
# shai-hulud-ioc-sweep.sh — scan a GitHub org for Shai-Hulud indicators of
# compromise. Consumed by .github/workflows/shai-hulud-sweep.yml.
#
# === Vendoring note ===
# This is a verbatim copy of the canonical script at:
#   allora-network/skills @ skills/shai-hulud-defense/scripts/shai-hulud-ioc-sweep.sh
#   pinned commit: 71aeefb422b2dd0d41118277b3aa122345190c7b  (PR #69, open)
#
# We vendor instead of cloning the skills repo at workflow time because
# allora-network/skills is private and the default GITHUB_TOKEN cannot read it;
# vendoring also makes the daily sweep robust to upstream rename / outage.
# Refresh procedure: when the upstream script changes (skills repo PR merged
# or follow-up commits land), copy the file back into this path, update the
# pinned commit above, and bump the schema-version header in this script's
# error path if the IOC file format also changed.
#
# Read-only. Exit codes:
#   0  clean — no findings at all
#   1  IOC finding(s) — INVOKE INCIDENT RESPONSE
#   2  operational issues only (clone_failed / check_skipped / go_local_replace)
#
# Usage:
#   shai-hulud-ioc-sweep.sh <org> [ioc-packages.txt] [ioc-hashes.txt]
#
# Env:
#   OUTPUT_DIR             — defaults to ./.shai-hulud-sweep/<UTC timestamp>
#   GO_TRUSTED_HOSTS_RE    — extended regex of trusted module-path prefixes for
#                            Go `replace` RHS. Defaults to allora-network's
#                            allowlist; override per org to silence false
#                            `go_suspicious_replace` findings.
#   GO_REPLACE_ALLOWED_FILE — optional path to a list of explicit
#                            `LHS_top_level => RHS_top_level` aliases that are
#                            allowed despite top-level path mismatch (one per
#                            line, `#` comments allowed). Defends Scenario C
#                            in-org redirect attacks.
#
# Requires: gh (authenticated, non-SSH), jq, sha256sum (or shasum -a 256),
#           git, find, awk.

set -euo pipefail

ORG="${1:-${GITHUB_ORG:-}}"
PACKAGES_FILE="${2:-./ioc-packages.txt}"
HASHES_FILE="${3:-./ioc-hashes.txt}"
OUTPUT_DIR="${OUTPUT_DIR:-./.shai-hulud-sweep/$(date -u +%Y%m%d-%H%M%S)}"

# Default trust allowlist matches REFERENCE.md's hardened CI workflow snippet.
# Other orgs override via GO_TRUSTED_HOSTS_RE so they don't get false
# `go_suspicious_replace` findings for their own GitHub mirrors.
GO_TRUSTED_HOSTS="${GO_TRUSTED_HOSTS_RE:-github\.com/(allora-network|cometbft|cosmos|ethereum|fluxcd)|gopkg\.in|google\.golang\.org|go\.uber\.org|k8s\.io|sigs\.k8s\.io|go\.opentelemetry\.io}"
GO_REPLACE_ALLOWED_FILE="${GO_REPLACE_ALLOWED_FILE:-}"

[ -n "$ORG" ] || { echo "usage: $0 <org> [packages.txt] [hashes.txt]" >&2; exit 2; }
[ -f "$PACKAGES_FILE" ] || { echo "missing IOC packages file: $PACKAGES_FILE" >&2; exit 2; }
[ -f "$HASHES_FILE" ]   || { echo "missing IOC hashes file: $HASHES_FILE" >&2; exit 2; }
command -v gh >/dev/null   || { echo "gh required" >&2; exit 2; }
command -v jq >/dev/null   || { echo "jq required" >&2; exit 2; }

# Schema-version assertion — a silent schema break in the sibling .github repo
# (e.g. dropping the `ecosystem:` prefix) would otherwise corrupt parsing and
# produce a false-clean sweep. Bump in lockstep when the seed-list format
# changes. Both seed files (packages + hashes) carry the header so a future
# reformat of either side fails loud instead of silently zero-matching against
# the whole org.
if ! head -n1 "$PACKAGES_FILE" | grep -qE '^#[[:space:]]*schema:v1'; then
  echo "IOC packages file $PACKAGES_FILE missing '# schema:v1' header — refusing to run (would silently false-clean on parser drift)." >&2
  exit 2
fi
if ! head -n1 "$HASHES_FILE" | grep -qE '^#[[:space:]]*schema:v1'; then
  echo "IOC hashes file $HASHES_FILE missing '# schema:v1' header — refusing to run (would silently false-clean on parser drift)." >&2
  exit 2
fi

# Auth assertion — refuse to run unauthenticated; private repos would silently
# clone_failed and the sweep would mislabel a partial scan as org-wide.
if ! gh auth token >/dev/null 2>&1; then
  echo "gh is not authenticated — run 'gh auth login' first. Sweep would silently skip every private repo." >&2
  exit 2
fi
# Token capture removed from execution after PRRT_kwDOQ91i5M6EVwmd / cubic#218:
# we now delegate to `gh auth git-credential` inside the per-clone credential
# helper, which keeps the token out of git's argv entirely. Restore this line
# only if reverting to an inlined-token credential helper, AND first fix the
# argv-exposure issue (e.g. single-quote the helper body and `export
# GH_TOKEN_VALUE` so it's expanded by the helper's subshell at credential
# time, not by the parent shell at git-launch time).
# GH_TOKEN_VALUE="$(gh auth token 2>/dev/null)"

# Warn loudly if operator has SSH-default git_protocol set — historically a
# common silent failure mode; the credential-helper override below mitigates it
# but the warning makes the precondition explicit.
if [ "$(gh config get git_protocol 2>/dev/null || true)" = "ssh" ]; then
  echo "WARN: gh git_protocol=ssh detected. Sweep injects the gh OAuth token via credential helper so private repos still clone, but interactive operators may see unexpected SSH-key prompts disabled. Continuing." >&2
fi

SHA256_CMD="$(command -v sha256sum || true)"
[ -n "$SHA256_CMD" ] || SHA256_CMD="shasum -a 256"

mkdir -p "$OUTPUT_DIR"
FINDINGS="$OUTPUT_DIR/findings.json"
FINDINGS_NDJSON="$OUTPUT_DIR/findings.ndjson"
SUMMARY="$OUTPUT_DIR/summary.md"
EVIDENCE_DIR="$OUTPUT_DIR/evidence"
: > "$FINDINGS_NDJSON"
mkdir -p "$EVIDENCE_DIR"
: > "$OUTPUT_DIR/.dirty-repos"

# IOC rule names that count toward the IR-incident exit code (1). All other
# findings are operational (clone_failed / check_skipped / go_local_replace)
# and only escalate to exit code 2, never the IR banner.
IOC_RULES_RE='^(ioc_package_match|ioc_bundle_hash|persistence_workflow|suspicious_lifecycle_script|public_exfil_repo|public_exfil_repo_member|go_suspicious_replace|go_replace_path_mismatch|go_unsafe_env|go_unsafe_env_indirect)$'

# Per-repo IOC-finding presence is tracked in a plain file (one repo per line,
# deduped on lookup) instead of a bash assoc array. macOS ships /bin/bash 3.2
# which lacks `declare -A`; using a file keeps the script portable to stock
# macOS Homebrew/CI runners.
DIRTY_REPOS_FILE="$OUTPUT_DIR/.dirty-repos"

log()    { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
# finding() appends one NDJSON object per call. O(1) per write, atomic via
# POSIX O_APPEND for line-bounded writes, and safe for any future xargs -P
# parallelization of the per-repo loop. Aggregated into a JSON array at the
# end of the run.
finding(){
  local repo="$1" rule="$2" path="$3" detail="$4"
  jq -nc --arg r "$repo" --arg ru "$rule" --arg p "$path" --arg d "$detail" \
    '{repo:$r, rule:$ru, path:$p, detail:$d, ts: now}' \
    >> "$FINDINGS_NDJSON"
  # Track which repos produced any finding so we can preserve their working
  # tree as forensic evidence (see end-of-loop cleanup). Operational-only
  # findings (clone_failed, check_skipped, go_local_replace) don't have a
  # clone to preserve in the first place.
  case "$rule" in
    clone_failed|check_skipped|go_local_replace) ;;
    *) printf '%s\n' "$repo" >> "$DIRTY_REPOS_FILE" ;;
  esac
}

sort "$PACKAGES_FILE" -o "$OUTPUT_DIR/packages.sorted"
  # Normalize to bare 64-hex lines before matching: the seed file allows
  # `  # comment` suffixes (see ioc-hashes.txt header), and the JS scan's
  # `grep -qFx` whole-line match can never succeed against a raw sort of
  # the seed file — every line would be `<hash>  # comment`, silently
  # disabling the entire ioc_bundle_hash layer (false-clean).
  awk '!/^[[:space:]]*(#|$)/ {print $1}' "$HASHES_FILE" | sort > "$OUTPUT_DIR/hashes.sorted"

# Build per-ecosystem needle lists once. The previous single-substring grep
# missed most lockfile formats (pip/poetry/Pipfile/go.sum/modern
# package-lock.json) because each ecosystem encodes dependency identity
# differently. PEP-503-normalize pip names. Emit multiple needle shapes per
# IOC so we catch both yarn/pnpm `name@version` patterns and modern
# package-lock.json `"version": "x.y.z"` entries scoped to the right package
# key.
: > "$OUTPUT_DIR/needles.npm"
: > "$OUTPUT_DIR/needles.pip"
: > "$OUTPUT_DIR/needles.go"
awk -F: '
  /^[[:space:]]*#/ { next }
  /^[[:space:]]*$/ { next }
  NF < 2 { next }
  {
    eco = $1
    sub("^" eco ":", "", $0)
    pkg = $0
    sub(/[[:space:]]+$/, "", pkg)
    # Split name@version, allowing @ inside module path (Go).
    n = 0
    for (i = length(pkg); i >= 1; i--) {
      if (substr(pkg, i, 1) == "@") { n = i; break }
    }
    if (n == 0) next
    name = substr(pkg, 1, n - 1)
    ver  = substr(pkg, n + 1)
    if (name == "" || ver == "") next
    if (eco == "npm") {
      print name "@" ver           >> "'"$OUTPUT_DIR"'/needles.npm"
      # Bare "name" needle is intentionally NOT emitted — it produced false
      # positives on any quoted occurrence of the package name at any
      # version (see PRRT_kwDOQ91i5M6EVwmh / cubic#145). Modern npm v2/v3
      # package-lock.json coverage is provided by a structured jq pass in
      # the lockfile loop (`if [ "$bn" = "package-lock.json" ]`), which
      # walks `.packages[].version` (v2/v3) and the recursive
      # `.dependencies` tree (v1) and exact-matches projected name@version
      # tuples against this same needle file. That structured pass closes
      # the false-clean gap for lockfiles written without `resolved` URLs
      # (workspaces, private-registry overrides, npm omit-resolved
      # configs) without reintroducing the false-positive risk.
      print name "-" ver ".tgz"    >> "'"$OUTPUT_DIR"'/needles.npm"
    } else if (eco == "pip") {
      lname = tolower(name)
      gsub(/[._]+/, "-", lname)
      print lname "==" ver         >> "'"$OUTPUT_DIR"'/needles.pip"
    } else if (eco == "go") {
      print name " " ver           >> "'"$OUTPUT_DIR"'/needles.go"
    }
  }
' "$OUTPUT_DIR/packages.sorted"

# Canonical exclude args for every find walk in the per-repo loop. Without
# these, lockfiles/JS bundles/go.mod files committed under node_modules/
# vendor/.git balloon scan time by orders of magnitude on monorepos AND
# produce false positives whose path field points at vendored transitive
# dependencies (misleads triage).
EXCLUDE_FIND=( -not -path '*/node_modules/*' -not -path '*/vendor/*' -not -path '*/.git/*' )

# Map lockfile basename → ecosystem so each lockfile is grepped only against
# its own ecosystem's IOC needles (a pip IOC against a yarn.lock is noise).
lockfile_eco() {
  case "$1" in
    package-lock.json|pnpm-lock.yaml|yarn.lock|bun.lock) echo npm ;;
    requirements.txt|requirements.lock|poetry.lock|Pipfile.lock) echo pip ;;
    go.sum) echo go ;;
    *) echo unknown ;;
  esac
}

log "Listing repos in $ORG..."
# Paginate the full repo list — fixed --limit silently truncates large orgs.
# `gh api ... --paginate` walks Link headers; jq filters to non-empty default branches.
gh api -H "Accept: application/vnd.github+json" --paginate \
  "/orgs/$ORG/repos?per_page=100&type=all" \
  --jq '.[] | select(.default_branch != null and .default_branch != "") | .name' \
  > "$OUTPUT_DIR/repos.txt"
REPO_COUNT=$(wc -l < "$OUTPUT_DIR/repos.txt" | tr -d ' ')
log "Found $REPO_COUNT repos (full pagination). Sweeping..."

# Build the `go_replace` aliased-alias allowlist as a normalized lookup file
# (one `LHS_top<TAB>RHS_top` tuple per line). File-based instead of assoc
# array so stock macOS /bin/bash 3.2 still works. Each input line is:
#   github.com/legit/x github.com/legit-mirror/x
GO_REPLACE_ALLOW_NORM="$OUTPUT_DIR/.go-replace-allow"
: > "$GO_REPLACE_ALLOW_NORM"
if [ -n "$GO_REPLACE_ALLOWED_FILE" ] && [ -f "$GO_REPLACE_ALLOWED_FILE" ]; then
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    lhs_top="${line%% *}"
    rhs_top="${line##* }"
    if [ -n "$lhs_top" ] && [ -n "$rhs_top" ]; then
      printf '%s\t%s\n' "$lhs_top" "$rhs_top" >> "$GO_REPLACE_ALLOW_NORM"
    fi
  done < "$GO_REPLACE_ALLOWED_FILE"
fi

# Clones directory is purely scratch — preserved evidence lives in
# $EVIDENCE_DIR. Even on unclean exits (signal, set -e abort, transient
# clone failure), drop the scratch tree so disk doesn't fill on long runs.
trap 'rm -rf -- "$OUTPUT_DIR/clones" 2>/dev/null || true' EXIT

while IFS= read -r repo; do
  log "  $repo"
  WORK="$OUTPUT_DIR/clones/$repo"
  mkdir -p "$(dirname "$WORK")"
  # Use the gh OAuth token via a per-clone credential helper so private-repo
  # access does not depend on whatever credential helper / SSH key happens to
  # be configured on the operator's workstation. Previously, an operator with
  # `gh config get git_protocol = ssh` could silently `clone_failed` every
  # private repo, producing a partial sweep mislabeled as org-wide. Plain
  # `gh repo clone` likewise honors the operator's git_protocol setting.
  #
  # Delegate to `gh auth git-credential` instead of inlining the token in a
  # shell-expanded helper body: the previous form embedded $GH_TOKEN_VALUE in
  # git's argv (visible via `ps`/`/proc/<pid>/cmdline`), and gh's built-in
  # credential helper resolves the token from gh's own auth state at fetch
  # time without putting it on any command line. (Auth presence is asserted
  # above via `gh auth token`, so this helper always has a credential to
  # return.) See PRRT_kwDOQ91i5M6EVwmd / cubic#218.
  if ! git -c "credential.helper=" \
         -c "credential.helper=!gh auth git-credential" \
         clone --depth 1 --no-tags --quiet \
         "https://github.com/$ORG/$repo.git" "$WORK" 2>/dev/null; then
    finding "$repo" "clone_failed" "" "git clone (gh-token credential helper) failed (network/empty repo/permission)"
    continue
  fi

  # Single tree walk per repo collects every file we care about (lockfiles,
  # JS files for hash IOCs, package.json, go.mod, workflow YAMLs). One find
  # invocation replaces 9+ per-target walks and the per-IOC inner grep loop
  # is replaced by a single `grep -F -f needles` per lockfile.
  LOCKS_FILE="$OUTPUT_DIR/.scan/$repo.locks"
  JS_FILE="$OUTPUT_DIR/.scan/$repo.js"
  PKG_FILE="$OUTPUT_DIR/.scan/$repo.pkg"
  GOMOD_FILE="$OUTPUT_DIR/.scan/$repo.gomod"
  WF_FILE="$OUTPUT_DIR/.scan/$repo.wf"
  PERSIST_FILE="$OUTPUT_DIR/.scan/$repo.persist"
  mkdir -p "$(dirname "$LOCKS_FILE")"
  : > "$LOCKS_FILE"; : > "$JS_FILE"; : > "$PKG_FILE"; : > "$GOMOD_FILE"; : > "$WF_FILE"; : > "$PERSIST_FILE"

  while IFS= read -r path; do
    bn="${path##*/}"
    case "$bn" in
      package-lock.json|pnpm-lock.yaml|yarn.lock|bun.lock|requirements.txt|requirements.lock|poetry.lock|Pipfile.lock|go.sum)
        printf '%s\n' "$path" >> "$LOCKS_FILE" ;;
      package.json)
        printf '%s\n' "$path" >> "$PKG_FILE" ;;
      go.mod)
        printf '%s\n' "$path" >> "$GOMOD_FILE" ;;
    esac
    case "$bn" in
      *.js|*.cjs|*.mjs)
        # Cap at 2MB so a hostile/large JS file can't stall sha256sum on the
        # whole org sweep; bundlers rarely emit >2MB single files.
        if [ "$(stat -f%z "$path" 2>/dev/null || stat -c%s "$path" 2>/dev/null || echo 0)" -le 2097152 ]; then
          printf '%s\n' "$path" >> "$JS_FILE"
        fi
        ;;
    esac
    # GitHub Actions only executes workflows under $REPO_ROOT/.github/workflows/.
    # Anchor on $WORK/.github/workflows/ so nested .github copies (vendored
    # examples, test fixtures, monorepo subpackage scaffolding) cannot produce
    # false `persistence_workflow` (rule 3) or `go_unsafe_env` /
    # `go_unsafe_env_indirect` (rule 6) hits — those rules consume $WF_FILE /
    # $PERSIST_FILE populated here. See PRRT_kwDOQ91i5M6EVwmg / cubic#258.
    #
    # The persistence_workflow basename match is INTENTIONALLY narrowed to the
    # exact filenames known to be dropped by the Shai-Hulud worm
    # (`shai-hulud.yml`, `shai-hulud.yaml`, `shai-hulud-workflow.yml`,
    # `shai-hulud-workflow.yaml`). A broader `shai-hulud*` glob would self-
    # detect the legitimate defense workflow this script is invoked from
    # (`.github/workflows/shai-hulud-sweep.yml` in this very repo) on every
    # daily sweep, producing a guaranteed false IOC page that conditions
    # responders to mute the channel — textbook alert fatigue. Keep this glob
    # explicit; if a new worm variant ships a new filename, add it here
    # rather than reverting to a wildcard.
    case "$path" in
      "$WORK/.github/workflows/"*)
        case "$bn" in
          *.yml|*.yaml)
            printf '%s\n' "$path" >> "$WF_FILE"
            case "$bn" in
              shai-hulud.yml|shai-hulud.yaml|shai-hulud-workflow.yml|shai-hulud-workflow.yaml)
                printf '%s\n' "$path" >> "$PERSIST_FILE" ;;
            esac
            ;;
        esac
        ;;
    esac
  done < <(find "$WORK" -type f "${EXCLUDE_FIND[@]}" 2>/dev/null)

  # 1. Lockfile IOC scan (npm/pip/Go), per-ecosystem matchers.
  # The previous `grep -qF "$nameversion"` against every lockfile silently
  # missed pip/poetry/Pipfile/go.sum and modern package-lock.json formats —
  # the daily-IOC workflow trusted a `Clean.` summary that was structurally
  # incapable of finding hits in those ecosystems.
  while IFS= read -r lockpath; do
    lockbn="${lockpath##*/}"
    eco="$(lockfile_eco "$lockbn")"
    [ "$eco" = "unknown" ] && continue
    needles="$OUTPUT_DIR/needles.$eco"
    [ -s "$needles" ] || continue
    # Structured pass for npm package-lock.json. Modern v2/v3 lockfiles
    # encode dependency identity in `.packages["node_modules/<name>"].version`
    # rather than embedding `name@version` or `name-version.tgz` substrings.
    # Lockfiles produced without `resolved` URLs (workspaces,
    # private-registry overrides, npm omit-resolved configs) carry NO
    # matchable substring at all, so the grep-only path below silently
    # false-cleans even when a compromised IOC version is installed —
    # exactly the signal the daily-IOC workflow trusts. Project
    # name@version structurally via jq and exact-line match against the
    # npm needles. The v1 fallback walks the recursive `.dependencies`
    # tree (older lockfiles also lack `resolved` URLs in some configs).
    # See PRRT_kwDOQ91i5M6EcQEH / cubic#159.
    if [ "$lockbn" = "package-lock.json" ]; then
      while IFS= read -r needle; do
        finding "$repo" "ioc_package_match" "${lockpath#"$WORK"/}" "npm:$needle"
      done < <(
        {
          jq -r '
            (.packages // {})
            | to_entries[]?
            | select(.key != "" and (.value.version // "") != "")
            | (.key | sub("^.*node_modules/"; "")) + "@" + .value.version
          ' "$lockpath" 2>/dev/null || true
          jq -r '
            def walk: to_entries[]? | (.key + "@" + (.value.version // "")), (.value.dependencies // {} | walk);
            (.dependencies // {}) | walk
          ' "$lockpath" 2>/dev/null || true
        } | grep -Fxf "$needles" 2>/dev/null | sort -u
      )
    fi
    # Substring grep — covers yarn.lock / pnpm-lock.yaml / bun.lock /
    # pip / Go lockfiles plus npm lockfiles that DO embed
    # `name-version.tgz` in resolved URLs. Runs on package-lock.json too
    # as a defense-in-depth signal alongside the structured pass above.
    while IFS= read -r needle; do
      finding "$repo" "ioc_package_match" "${lockpath#"$WORK"/}" "$eco:$needle"
    done < <(grep -F -f "$needles" "$lockpath" 2>/dev/null | sort -u)
  done < "$LOCKS_FILE"

  # 2. JS hash scan. Hash IOCs are content-keyed by nature, so filename-
  # pinning to `bundle.js` would let any worm variant trivially bypass the
  # layer by renaming the dropper. Scan every .js/.cjs/.mjs file under 2MB
  # (collected above with exclusions) and match against the hash IOC list.
  while IFS= read -r path; do
    hash="$($SHA256_CMD "$path" | awk '{print $1}')"
    grep -qFx "$hash" "$OUTPUT_DIR/hashes.sorted" \
      && finding "$repo" "ioc_bundle_hash" "${path#"$WORK"/}" "$hash"
  done < "$JS_FILE"

  # 3. Persistence workflow file — only the repo-root .github/workflows/ is
  # executed by GitHub Actions, so $PERSIST_FILE is already scoped to that
  # path by the case statement above. Nested .github/workflows directories
  # (vendored examples, test fixtures) would only produce false IOC hits.
  while IFS= read -r f; do
    finding "$repo" "persistence_workflow" "${f#"$WORK"/}" "shai-hulud workflow file present"
  done < "$PERSIST_FILE"

  # 4. Suspicious lifecycle script patterns (npm). Broader regex covers
  # `node ./bundle.js`, `node dist/bundle.js`, npx, `eval $(curl ...)`,
  # `base64 --decode` / `-D`, and `| bash` pipes — the narrow original
  # regex missed common Shai-Hulud variant patterns.
  while IFS= read -r pkgjson; do
    jq -e '.scripts // {} | to_entries[] | select(.key | test("install|postinstall|preinstall")) | .value | test("node[[:space:]]+\\S*bundle\\.js|curl[[:space:]].*\\|[[:space:]]?(ba)?sh|wget[[:space:]].*\\|[[:space:]]?(ba)?sh|base64[[:space:]]+(-d|--decode|-D)|eval[[:space:]]+\\$\\(|npx[[:space:]]+.*bundle")' \
      "$pkgjson" >/dev/null 2>&1 \
      && finding "$repo" "suspicious_lifecycle_script" "${pkgjson#"$WORK"/}" "matches Shai-Hulud postinstall pattern"
  done < "$PKG_FILE"

  # 5. Go: replace directives pointing outside trusted hosts, AND a parallel
  # path-equality rule that catches the Scenario C in-org compromise where
  # an attacker swaps `replace github.com/allora/legit => github.com/allora/
  # attacker-fork` (which the host allowlist alone passes through).
  while IFS= read -r gomod; do
    # Read awk output via process substitution so the inner loop runs in
    # the parent shell — finding() writes to DIRTY_REPOS (an assoc array)
    # and a piped subshell would drop those writes, breaking forensic
    # evidence preservation for go-replace findings.
    while IFS=$'\t' read -r lhs rhs line; do
      case "$rhs" in
        ./*|../*)
          finding "$repo" "go_local_replace" "${gomod#"$WORK"/}" "$line"
          continue
          ;;
        /*)
          # Absolute-path replace can resolve outside the checked-out tree
          # on writable runners — REFERENCE.md flags this as a real
          # hardening-gate bypass, treat as IOC-grade.
          finding "$repo" "go_suspicious_replace" "${gomod#"$WORK"/}" "absolute-path replace: $line"
          continue
          ;;
      esac
      # Host-allowlist gate.
      if ! printf '%s\n' "$rhs" | grep -qE "^($GO_TRUSTED_HOSTS)(/|$)"; then
        finding "$repo" "go_suspicious_replace" "${gomod#"$WORK"/}" "$line"
        continue
      fi
      # Path-equality gate (defends Scenario C in-org compromise where
      # both LHS and RHS sit under an allowlisted host). The top-level
      # 3-segment path of LHS and RHS must match unless explicitly
      # allowlisted via GO_REPLACE_ALLOWED_FILE.
      lhs_top="$(printf '%s\n' "$lhs" | awk -F/ 'NF>=3{print $1"/"$2"/"$3} NF<3{print $0}')"
      rhs_top="$(printf '%s\n' "$rhs" | awk -F/ 'NF>=3{print $1"/"$2"/"$3} NF<3{print $0}')"
      if [ "$lhs_top" != "$rhs_top" ]; then
        if ! grep -qFx "$(printf '%s\t%s' "$lhs_top" "$rhs_top")" "$GO_REPLACE_ALLOW_NORM" 2>/dev/null; then
          finding "$repo" "go_replace_path_mismatch" "${gomod#"$WORK"/}" "top-level path mismatch: $line"
        fi
      fi
    done < <(awk '
      /^[[:space:]]*replace[[:space:]]*\(/ { inblock=1; next }
      inblock && /^[[:space:]]*\)/        { inblock=0; next }
      /^[[:space:]]*replace[[:space:]]/ || inblock {
        n = index($0, "=>")
        if (n == 0) next
        lhs_raw = substr($0, 1, n - 1)
        rhs_raw = substr($0, n + 2)
        sub(/^[[:space:]]*replace[[:space:]]+/, "", lhs_raw)
        sub(/^[[:space:]]+/, "", lhs_raw); sub(/[[:space:]]+$/, "", lhs_raw)
        sub(/[[:space:]]+v[0-9].*$/, "", lhs_raw)
        sub(/^[[:space:]]+/, "", rhs_raw); sub(/[[:space:]]+v[0-9].*$/, "", rhs_raw)
        sub(/[[:space:]]+$/, "", rhs_raw)
        if (rhs_raw == "") next
        gsub(/\t/, " ", $0)
        printf "%s\t%s\t%s\n", lhs_raw, rhs_raw, $0
      }
    ' "$gomod")
  done < "$GOMOD_FILE"

  # 6. Go: dangerous env settings in workflows. The grep is now run against
  # the workflow file with `#`-prefixed lines stripped, so a documentation
  # comment like `# Forbid GOSUMDB=off in CI` does not trigger a false
  # `go_unsafe_env` finding. A second pass looks for indirect references via
  # `vars`/`secrets`/`env`/`inputs` contexts that would otherwise slip past
  # a literal-only grep.
  while IFS= read -r wf; do
    if sed 's/[[:space:]]*#.*$//' "$wf" \
         | grep -qE 'GONOSUMCHECK|GOSUMDB[=:][[:space:]]*["'\'']?off|GOINSECURE[=:]|GOFLAGS[=:].*-insecure'; then
      finding "$repo" "go_unsafe_env" "${wf#"$WORK"/}" "GOSUMDB/sumcheck/insecure-fetch bypassed in CI"
    fi
    if grep -qE '\$\{\{[[:space:]]*(vars|secrets|env|inputs|matrix)\.(GOSUMDB|GOINSECURE|GOFLAGS|GONOSUMCHECK)' "$wf"; then
      finding "$repo" "go_unsafe_env_indirect" "${wf#"$WORK"/}" "indirect Go env reference — review for runtime bypass"
    fi
  done < "$WF_FILE"

  # End-of-repo cleanup — preserve the working tree for forensic inspection
  # whenever this repo emitted any IOC-grade finding. REFERENCE.md §Incident
  # response requires the matched file to be inspectable to confirm the
  # multi-IOC gate; deleting the clone forces a re-clone (point-in-time
  # evidence may have moved). Clean repos are still removed to bound disk.
  if grep -qFx "$repo" "$DIRTY_REPOS_FILE" 2>/dev/null; then
    mkdir -p "$EVIDENCE_DIR/$(dirname "$repo")"
    mv "$WORK" "$EVIDENCE_DIR/$repo" 2>/dev/null || true
  else
    rm -rf "$WORK"
  fi
done < "$OUTPUT_DIR/repos.txt"

# Drop the per-repo scratch index files now that aggregation is done.
rm -rf "$OUTPUT_DIR/.scan" 2>/dev/null || true

# 7. Exfil repo search
log "Searching for public Shai-Hulud exfil repos..."
# Wrap the OR group in parentheses — without them GitHub search parses
# `OR` as a top-level Boolean operator and the second branch becomes
# unscoped (`shai_hulud` matches any repo on GitHub). Without parens, any
# external attacker can create a `shai_hulud-*` repo to poison every org's
# sweep with a false `public_exfil_repo` for their own org.
EXFIL_OUT="$OUTPUT_DIR/.exfil.out"
EXFIL_ERR="$OUTPUT_DIR/.exfil.err"
if gh api -X GET search/repositories -f q="org:$ORG (shai-hulud OR shai_hulud)" \
     --jq '.items[]?.full_name' > "$EXFIL_OUT" 2> "$EXFIL_ERR"; then
  while IFS= read -r exfil; do
    [ -n "$exfil" ] && finding "$exfil" "public_exfil_repo" "" "matches ^[Ss]hai-[Hh]ulud naming"
  done < "$EXFIL_OUT"
else
  finding "$ORG" "check_skipped" "" "org-scoped exfil search failed (rate limit or auth): $(head -1 "$EXFIL_ERR" 2>/dev/null)"
fi

# Member-side exfil search requires `read:org`. Probe once; if scope is
# missing we emit a `check_skipped` operational finding instead of silently
# producing a false-clean for a compromised-member scenario. Rate-limit:
# GitHub authenticated search is 30 req/min, so insert a small pause per
# member to stay inside the budget.
MEMBERS_OUT="$OUTPUT_DIR/.members.out"
MEMBERS_ERR="$OUTPUT_DIR/.members.err"
if gh api orgs/"$ORG"/members --paginate --jq '.[].login' \
     > "$MEMBERS_OUT" 2> "$MEMBERS_ERR"; then
  while IFS= read -r member; do
    [ -n "$member" ] || continue
    MEMBER_OUT="$OUTPUT_DIR/.member.$member.out"
    MEMBER_ERR="$OUTPUT_DIR/.member.$member.err"
    # Same parenthesized OR group as the org-scoped search above —
    # `shai-hulud` alone misses `shai_hulud` underscore-variant exfil
    # repos, and unparenthesized OR would unscope the second branch.
    if gh api -X GET "search/repositories" -f q="user:$member (shai-hulud OR shai_hulud)" \
         --jq '.items[]?.full_name' > "$MEMBER_OUT" 2> "$MEMBER_ERR"; then
      while IFS= read -r hit; do
        [ -n "$hit" ] && finding "$hit" "public_exfil_repo_member" "" "shai-hulud-named repo under org member"
      done < "$MEMBER_OUT"
    else
      finding "$member" "check_skipped" "" "per-member exfil search failed (likely search rate limit): $(head -1 "$MEMBER_ERR" 2>/dev/null)"
    fi
    rm -f "$MEMBER_OUT" "$MEMBER_ERR"
    sleep 2
  done < "$MEMBERS_OUT"
else
  finding "$ORG" "check_skipped" "" "orgs/$ORG/members enumeration failed (token likely lacks read:org scope): $(head -1 "$MEMBERS_ERR" 2>/dev/null)"
fi
rm -f "$EXFIL_OUT" "$EXFIL_ERR" "$MEMBERS_OUT" "$MEMBERS_ERR"

# Aggregate NDJSON → JSON array.
jq -s '.' "$FINDINGS_NDJSON" > "$FINDINGS"

# Split IOC findings from operational findings so a single transient
# clone_failed / check_skipped / go_local_replace does not trigger
# `INVOKE INCIDENT RESPONSE`. Exit codes:
#   0 — clean (no findings at all)
#   1 — IOC findings present (incident response)
#   2 — operational issues only (review, but not an incident)
IOC_COUNT=$(jq --arg re "$IOC_RULES_RE" '[.[] | select(.rule | test($re))] | length' "$FINDINGS")
OP_COUNT=$(jq --arg re "$IOC_RULES_RE" '[.[] | select(.rule | test($re) | not)] | length' "$FINDINGS")
TOTAL_COUNT=$(jq 'length' "$FINDINGS")

{
  echo "# Shai-Hulud IOC sweep — $ORG"
  echo
  echo "**Run:** $(date -u)"
  echo "**Repos scanned:** $REPO_COUNT"
  echo "**IOC findings:** $IOC_COUNT"
  echo "**Operational findings:** $OP_COUNT"
  echo "**Total findings:** $TOTAL_COUNT"
  echo
  if [ "$IOC_COUNT" -gt 0 ]; then
    echo "## IOC findings"
    jq -r --arg re "$IOC_RULES_RE" '.[] | select(.rule | test($re)) | "- **\(.repo)** [\(.rule)] \(.path) — \(.detail)"' "$FINDINGS"
    echo
    echo "**INVOKE INCIDENT RESPONSE IMMEDIATELY.** See REFERENCE.md §Incident response."
    echo "Forensic evidence preserved under: \`$EVIDENCE_DIR/<repo>/\`."
  fi
  if [ "$OP_COUNT" -gt 0 ]; then
    echo
    echo "## Operational findings (review, not an incident)"
    jq -r --arg re "$IOC_RULES_RE" '.[] | select(.rule | test($re) | not) | "- **\(.repo)** [\(.rule)] \(.path) — \(.detail)"' "$FINDINGS"
  fi
  if [ "$TOTAL_COUNT" -eq 0 ]; then
    echo "Clean. No IOCs matched the current seed lists."
  fi
} > "$SUMMARY"

log "Done. Summary: $SUMMARY"
if [ "$IOC_COUNT" -gt 0 ]; then exit 1
elif [ "$OP_COUNT" -gt 0 ]; then exit 2
else exit 0
fi
