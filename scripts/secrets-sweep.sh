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

echo ">> fetching repo list for $ORG"
mapfile -t REPOS < <(gh repo list "$ORG" --limit 300 --json name -q '.[].name' | sort)
echo ">> $(echo ${#REPOS[@]}) repos to scan"

i=0
for repo in "${REPOS[@]}"; do
  i=$((i+1))
  echo ""
  echo "[$i/${#REPOS[@]}] $repo"
  # Skip archived repos? trufflehog is fast enough that we scan all.

  # trufflehog: scan remote directly, only verified
  trufflehog git "https://github.com/$ORG/$repo" \
    --only-verified --json --no-update \
    > "$OUT/$repo.trufflehog.jsonl" 2>"$OUT/$repo.trufflehog.err" || \
    echo "  trufflehog exit=$? (continuing)"

  # gitleaks: needs a local clone (bare is fine, faster)
  bare="$CLONES/$repo.git"
  if [ ! -d "$bare" ]; then
    git clone --quiet --bare "https://github.com/$ORG/$repo" "$bare" || {
      echo "  clone failed; skipping gitleaks"; continue
    }
  fi
  gitleaks detect --source "$bare" --no-banner \
    --report-format json --report-path "$OUT/$repo.gitleaks.json" \
    > "$OUT/$repo.gitleaks.log" 2>&1 || \
    echo "  gitleaks exit=$? (continuing; non-zero exit = findings present, normal)"
done

echo ""
echo ">> aggregating summary"
{
  echo "# DEVOP-587 sweep — $(date -u +%FT%TZ)"
  echo ""
  echo "## Counts per repo (verified trufflehog hits / gitleaks hits)"
  echo "| repo | trufflehog verified | gitleaks findings |"
  echo "| --- | ---: | ---: |"
  for repo in "${REPOS[@]}"; do
    th=$(wc -l <"$OUT/$repo.trufflehog.jsonl" 2>/dev/null || echo 0)
    gl=$(jq -r 'length' "$OUT/$repo.gitleaks.json" 2>/dev/null || echo 0)
    if [ "${th:-0}" != "0" ] || [ "${gl:-0}" != "0" ]; then
      echo "| $repo | $th | $gl |"
    fi
  done
} > "$OUT/SUMMARY.md"

echo ""
echo ">> done. report dir: $OUT"
echo ">> review $OUT/SUMMARY.md first; rotate every verified credential immediately."
