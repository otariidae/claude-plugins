#!/usr/bin/env bash
# Wait for GitHub mergeable status; when CONFLICTING, list conflict files
# via read-only `git merge-tree --write-tree` (requires git 2.38+).
#
# Usage: check-conflicts.sh <PR_NUMBER> [baseRefName]
#
# Prints one JSON object:
#   {mergeable, mergeStateStatus, baseRefName, conflictFiles, localCheck}
# localCheck: skipped | conflicts | clean | error
#
# Env: INTERVAL_SEC (30), MAX_ATTEMPTS (4), REMOTE (origin)

set -euo pipefail

PR="${1:?usage: check-conflicts.sh <PR_NUMBER> [baseRefName]}"
BASE_REF="${2:-}"
INTERVAL_SEC="${INTERVAL_SEC:-30}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-4}"
REMOTE="${REMOTE:-origin}"

RESULT=''
for i in $(seq 1 "$MAX_ATTEMPTS"); do
  RESULT=$(gh pr view "$PR" --json mergeable,mergeStateStatus,baseRefName)
  if [ "$(jq -r '.mergeable' <<<"$RESULT")" != "UNKNOWN" ]; then
    break
  fi
  if [ "$i" -lt "$MAX_ATTEMPTS" ]; then
    sleep "$INTERVAL_SEC"
  fi
done

MERGEABLE=$(jq -r '.mergeable' <<<"$RESULT")
MERGE_STATE=$(jq -r '.mergeStateStatus' <<<"$RESULT")
BASE_REF="${BASE_REF:-$(jq -r '.baseRefName' <<<"$RESULT")}"

conflict_files_json='[]'
local_check='skipped'

if [ "$MERGEABLE" = "CONFLICTING" ]; then
  if ! git fetch "$REMOTE" "$BASE_REF" >/dev/null 2>&1; then
    local_check='error'
  else
    set +e
    merge_out=$(git merge-tree --write-tree --name-only --no-messages HEAD "${REMOTE}/${BASE_REF}" 2>&1)
    merge_ec=$?
    set -e
    case "$merge_ec" in
      0) local_check='clean' ;;
      1)
        local_check='conflicts'
        conflict_files_json=$(printf '%s\n' "$merge_out" | tail -n +2 | awk 'NF' | jq -R . | jq -s .)
        ;;
      *) local_check='error' ;;
    esac
  fi
fi

jq -n \
  --arg mergeable "$MERGEABLE" \
  --arg mergeStateStatus "$MERGE_STATE" \
  --arg baseRefName "$BASE_REF" \
  --arg localCheck "$local_check" \
  --argjson conflictFiles "$conflict_files_json" \
  '{mergeable:$mergeable, mergeStateStatus:$mergeStateStatus, baseRefName:$baseRefName, conflictFiles:$conflictFiles, localCheck:$localCheck}'
