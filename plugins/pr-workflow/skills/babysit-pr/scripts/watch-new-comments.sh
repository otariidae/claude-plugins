#!/usr/bin/env bash
# Poll a PR for review comments newer than a baseline timestamp.
# Prints matching JSON objects (one per line) and exits 0 on first hit.
# Prints TIMEOUT and exits 0 if none appear within the watch window.
#
# Usage:
#   watch-new-comments.sh <PR_NUMBER> <BASELINE_ISO8601>
#
# Env (optional):
#   INTERVAL_SEC   poll interval in seconds (default: 60)
#   MAX_ATTEMPTS   number of polls (default: 30 → 30 min at 60s)

set -euo pipefail

PR="${1:?usage: watch-new-comments.sh <PR_NUMBER> <BASELINE_ISO8601>}"
export BASE="${2:?usage: watch-new-comments.sh <PR_NUMBER> <BASELINE_ISO8601>}"
INTERVAL_SEC="${INTERVAL_SEC:-60}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-30}"

for i in $(seq 1 "$MAX_ATTEMPTS"); do
  NEW=$(
    {
      gh api --paginate "repos/{owner}/{repo}/pulls/${PR}/reviews" \
        --jq '.[] | select(.submitted_at > $ENV.BASE) | select((.body|length>0) or .state!="COMMENTED") | {kind:"review", author:.user.login, state, body, at:.submitted_at, url:.html_url}'
      gh api --paginate "repos/{owner}/{repo}/pulls/${PR}/comments" \
        --jq '.[] | select(.created_at > $ENV.BASE) | {kind:"inline", author:.user.login, path, line, body, at:.created_at, url:.html_url}'
      gh api --paginate "repos/{owner}/{repo}/issues/${PR}/comments" \
        --jq '.[] | select(.created_at > $ENV.BASE) | {kind:"conversation", author:.user.login, body, at:.created_at, url:.html_url}'
    } 2>/dev/null || true
  )

  if [ -n "$NEW" ]; then
    printf '%s\n' "$NEW"
    exit 0
  fi

  if [ "$i" -lt "$MAX_ATTEMPTS" ]; then
    sleep "$INTERVAL_SEC"
  fi
done

echo "TIMEOUT: 監視ウィンドウ内に新着コメントなし"
exit 0
