#!/usr/bin/env bash
# DEVOP-587 — one-off historical secrets sweep across the org.
#
# Runs trufflehog + gitleaks against the full git history of every repo
# in `allora-network` and writes JSON reports per repo.
#
# Usage:
#   export GH_TOKEN=<a read-only PAT with `repo` scope, NOT GH_READONLY_PAT
#                    (which is org-wide and we're rotating per DEVOP-586)>
#   bash scripts/secrets-sweep.sh
#
# Run inside an ephemeral VM/container with NO other secrets present.
# All outputs land in /tmp/sweep — tar them up, hand the bundle to a
# triage owner, then `shred` the VM.

set -euo pipefail

ORG="${ORG:-allora-network}"
OUT="${OUT:-/tmp/sweep}"
CLONES="${CLONES:-/tmp/clones}"

command -v trufflehog >/dev/null || { echo "trufflehog not installed (brew install trufflehog)"; exit 1; }
command -v gitleaks   >/dev/null || { echo "gitleaks not installed (brew install gitleaks)"; exit 1; }
command -v gh         >/dev/null || { echo "gh not installed"; exit 1; }
command -v jq         >/dev/null || { echo "jq not installed"; exit 1; }

mkdir -p "$OUT" "$CLONES"

# Track repos whose scans failed entirely (vs. completed-with-or-without findings).
# We surface these as ERROR rows in the summary so they cannot be silently
# treated as clean.
declare -a TRUFFLEHOG_ERRORS=()
declare -a GITLEAKS_ERRORS=()

echo ">> fetching repo list for $ORG"
# Fetch the repo list with explicit error detection. `mapfile < <(... | sort)`
# loses the pipeline exit status of `gh` because the process substitution
# is non-blocking and `set -o pipefail` doesn't cross the `< <(...)`
# boundary. Stage to a temp file and check exit codes explicitly so an
# auth/network failure cannot silently produce an empty repo list (which
# would otherwise look like a successful 0-repo sweep).
REPO_LIST_FILE="$(mktemp)"
trap 'rm -f "$REPO_LIST_FILE"' EXIT
if ! gh repo list "$ORG" --limit 300 --json name -q '.[].name' > "$REPO_LIST_FILE"; then
  echo "ERROR: gh repo list failed for org=$ORG — refusing to run a 0-repo sweep." >&2
  echo "       Check that GH_TOKEN is set, scoped, and not rate-limited." >&2
  exit 2
fi
mapfile -t REPOS < <(sort "$REPO_LIST_FILE")
if [ "${#REPOS[@]}" -eq 0 ]; then
  echo "ERROR: gh repo list returned zero repos for org=$ORG." >&2
  echo "       This almost certainly means a credential/permission problem; refusing to proceed." >&2
  exit 2
fi
echo ">> ${#REPOS[@]} repos to scan"

i=0
for repo in "${REPOS[@]}"; do
  i=$((i+1))
  echo ""
  echo "[$i/${#REPOS[@]}] $repo"
  # Skip archived repos? trufflehog is fast enough that we scan all.

  # trufflehog: scan remote directly, only verified.
  # Capture exit explicitly so we can flag scan failures in the summary
  # rather than have them silently render as "0 findings".
  set +e
  trufflehog git "https://github.com/$ORG/$repo" \
    --only-verified --json --no-update \
    > "$OUT/$repo.trufflehog.jsonl" 2>"$OUT/$repo.trufflehog.err"
  th_rc=$?
  set -e
  if [ "$th_rc" -ne 0 ]; then
    echo "  trufflehog exit=$th_rc (recorded as scan error)"
    TRUFFLEHOG_ERRORS+=("$repo:$th_rc")
  fi

  # gitleaks: needs a local clone (bare is fine, faster)
  bare="$CLONES/$repo.git"
  if [ ! -d "$bare" ]; then
    if ! git clone --quiet --bare "https://github.com/$ORG/$repo" "$bare"; then
      echo "  clone failed; recording gitleaks scan error"
      GITLEAKS_ERRORS+=("$repo:clone-failed")
      continue
    fi
  fi
  # gitleaks exits non-zero when findings are present, which is normal.
  # We only treat exit codes >= 2 as scan errors (gitleaks convention:
  # 0 = no leaks, 1 = leaks found, other = error). Anything else means
  # the scan didn't complete and we must not count it as "0 findings".
  set +e
  gitleaks detect --source "$bare" --no-banner \
    --report-format json --report-path "$OUT/$repo.gitleaks.json" \
    > "$OUT/$repo.gitleaks.log" 2>&1
  gl_rc=$?
  set -e
  if [ "$gl_rc" -ge 2 ]; then
    echo "  gitleaks exit=$gl_rc (recorded as scan error)"
    GITLEAKS_ERRORS+=("$repo:$gl_rc")
  fi
done

echo ""
echo ">> aggregating summary"

# Build quick-lookup sets of repos whose scans errored so we can surface
# them in the summary as ERROR rather than a zero-finding row.
declare -A TRUFFLEHOG_ERR_SET=()
for entry in "${TRUFFLEHOG_ERRORS[@]:-}"; do
  [ -z "$entry" ] && continue
  TRUFFLEHOG_ERR_SET["${entry%%:*}"]="${entry#*:}"
done
declare -A GITLEAKS_ERR_SET=()
for entry in "${GITLEAKS_ERRORS[@]:-}"; do
  [ -z "$entry" ] && continue
  GITLEAKS_ERR_SET["${entry%%:*}"]="${entry#*:}"
done

{
  echo "# DEVOP-587 sweep — $(date -u +%FT%TZ)"
  echo ""
  echo "Scanned ${#REPOS[@]} repos. Scan errors: trufflehog=${#TRUFFLEHOG_ERR_SET[@]}, gitleaks=${#GITLEAKS_ERR_SET[@]}."
  echo ""
  echo "## Counts per repo (verified trufflehog hits / gitleaks hits)"
  echo ""
  echo "An ERROR value means the scanner did not complete for that repo —"
  echo "treat it as **unscanned**, NOT clean. See \`<repo>.trufflehog.err\`"
  echo "or \`<repo>.gitleaks.log\` for the failure mode."
  echo ""
  echo "| repo | trufflehog verified | gitleaks findings |"
  echo "| --- | ---: | ---: |"
  for repo in "${REPOS[@]}"; do
    if [ -n "${TRUFFLEHOG_ERR_SET[$repo]:-}" ]; then
      th="ERROR(${TRUFFLEHOG_ERR_SET[$repo]})"
    elif [ -s "$OUT/$repo.trufflehog.jsonl" ] || [ -f "$OUT/$repo.trufflehog.jsonl" ]; then
      th=$(wc -l <"$OUT/$repo.trufflehog.jsonl" 2>/dev/null | tr -d ' ')
      th="${th:-0}"
    else
      th="ERROR(missing-output)"
    fi

    if [ -n "${GITLEAKS_ERR_SET[$repo]:-}" ]; then
      gl="ERROR(${GITLEAKS_ERR_SET[$repo]})"
    elif [ -f "$OUT/$repo.gitleaks.json" ]; then
      if gl_parsed=$(jq -r 'length' "$OUT/$repo.gitleaks.json" 2>/dev/null); then
        gl="$gl_parsed"
      else
        gl="ERROR(unparseable-report)"
      fi
    else
      gl="ERROR(missing-report)"
    fi

    # Surface every non-zero/non-clean row. A clean row (0/0) is omitted
    # to keep the summary readable; ERROR rows are always surfaced.
    if [ "$th" != "0" ] || [ "$gl" != "0" ]; then
      echo "| $repo | $th | $gl |"
    fi
  done

  if [ "${#TRUFFLEHOG_ERR_SET[@]}" -gt 0 ] || [ "${#GITLEAKS_ERR_SET[@]}" -gt 0 ]; then
    echo ""
    echo "## Scan errors — must be re-run before declaring this sweep complete"
    echo ""
    for repo in "${!TRUFFLEHOG_ERR_SET[@]}"; do
      echo "- trufflehog: $repo (exit=${TRUFFLEHOG_ERR_SET[$repo]})"
    done
    for repo in "${!GITLEAKS_ERR_SET[@]}"; do
      echo "- gitleaks: $repo (exit=${GITLEAKS_ERR_SET[$repo]})"
    done
  fi
} > "$OUT/SUMMARY.md"

echo ""
echo ">> done. report dir: $OUT"
echo ">> review $OUT/SUMMARY.md first; rotate every verified credential immediately."
if [ "${#TRUFFLEHOG_ERR_SET[@]}" -gt 0 ] || [ "${#GITLEAKS_ERR_SET[@]}" -gt 0 ]; then
  echo ">> WARNING: ${#TRUFFLEHOG_ERR_SET[@]} trufflehog and ${#GITLEAKS_ERR_SET[@]} gitleaks scan errors recorded."
  echo ">>          Sweep is NOT complete until these repos are re-scanned."
  exit 3
fi
