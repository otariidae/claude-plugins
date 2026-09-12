#!/usr/bin/env bash
# Wait for GitHub mergeable status, and when CONFLICTING list conflict
# files via read-only git merge-tree.
#
# Usage:
#   check-conflicts.sh <PR_NUMBER> [baseRefName]
#
# If baseRefName is omitted, it is read from `gh pr view`.
#
# Prints one JSON object:
#   {
#     "mergeable": "MERGEABLE"|"CONFLICTING"|"UNKNOWN"|...,
#     "mergeStateStatus": "...",
#     "baseRefName": "...",
#     "conflictFiles": ["path", ...],
#     "localCheck": "skipped"|"conflicts"|"clean"|"error"
#   }
#
# Env (optional):
#   INTERVAL_SEC   retry interval while UNKNOWN (default: 30)
#   MAX_ATTEMPTS   max polls for mergeable (default: 4)
#   REMOTE         remote name for fetch/merge-tree (default: origin)

set -euo pipefail

PR="${1:?usage: check-conflicts.sh <PR_NUMBER> [baseRefName]}"
BASE_REF="${2:-}"
INTERVAL_SEC="${INTERVAL_SEC:-30}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-4}"
REMOTE="${REMOTE:-origin}"

if [ -z "$BASE_REF" ]; then
  BASE_REF=$(gh pr view "$PR" --json baseRefName --jq '.baseRefName')
fi

MERGEABLE='UNKNOWN'
MERGE_STATE=''

for i in $(seq 1 "$MAX_ATTEMPTS"); do
  RESULT=$(gh pr view "$PR" --json mergeable,mergeStateStatus)
  MERGEABLE=$(printf '%s' "$RESULT" | jq -r '.mergeable')
  MERGE_STATE=$(printf '%s' "$RESULT" | jq -r '.mergeStateStatus')
  if [ "$MERGEABLE" != "UNKNOWN" ]; then
    break
  fi
  if [ "$i" -lt "$MAX_ATTEMPTS" ]; then
    sleep "$INTERVAL_SEC"
  fi
done

conflict_files_json='[]'
local_check='skipped'

list_conflicts_write_tree() {
  local remote_ref="$1"
  local merge_out merge_ec
  set +e
  merge_out=$(git merge-tree --write-tree --name-only --no-messages HEAD "$remote_ref" 2>&1)
  merge_ec=$?
  set -e

  case "$merge_ec" in
    0)
      local_check='clean'
      conflict_files_json='[]'
      return 0
      ;;
    1)
      local_check='conflicts'
      conflict_files_json=$(
        printf '%s\n' "$merge_out" | tail -n +2 | awk 'NF' | jq -R . | jq -s .
      )
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

list_conflicts_classic() {
  local remote_ref="$1"
  local merge_base merge_out files
  if ! merge_base=$(git merge-base HEAD "$remote_ref" 2>/dev/null); then
    return 1
  fi
  set +e
  merge_out=$(git merge-tree "$merge_base" HEAD "$remote_ref" 2>&1)
  set -e

  files=$(
    printf '%s\n' "$merge_out" | awk '
      /^(changed in both|added in both)$/ { grab = 1; next }
      grab && /^  their/ { print $NF; grab = 0 }
    ' | sort -u
  )

  if [ -z "$files" ]; then
    local_check='clean'
    conflict_files_json='[]'
  else
    local_check='conflicts'
    conflict_files_json=$(printf '%s\n' "$files" | jq -R . | jq -s .)
  fi
}

if [ "$MERGEABLE" = "CONFLICTING" ]; then
  if ! git fetch "$REMOTE" "$BASE_REF" >/dev/null 2>&1; then
    local_check='error'
  else
    remote_ref="${REMOTE}/${BASE_REF}"
    if ! list_conflicts_write_tree "$remote_ref"; then
      if ! list_conflicts_classic "$remote_ref"; then
        local_check='error'
        conflict_files_json='[]'
      fi
    fi
  fi
fi

jq -n \
  --arg mergeable "$MERGEABLE" \
  --arg mergeStateStatus "$MERGE_STATE" \
  --arg baseRefName "$BASE_REF" \
  --arg localCheck "$local_check" \
  --argjson conflictFiles "$conflict_files_json" \
  '{
    mergeable: $mergeable,
    mergeStateStatus: $mergeStateStatus,
    baseRefName: $baseRefName,
    conflictFiles: $conflictFiles,
    localCheck: $localCheck
  }'
