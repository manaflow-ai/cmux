#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${1:-}" ]]; then
  printf 'Usage: %s <surface> [state-file] [dashboard-url]\n' "${0##*/}" >&2
  exit 2
fi

SURFACE="$1"
STATE_FILE="${2:-./auth-state.json}"
DASHBOARD_URL="${3:-https://app.example.com/dashboard}"

if [ -f "$STATE_FILE" ]; then
  cmux browser --surface "$SURFACE" state load "$STATE_FILE"
fi

cmux browser --surface "$SURFACE" goto "$DASHBOARD_URL"
cmux browser --surface "$SURFACE" get url
cmux browser --surface "$SURFACE" wait --load-state complete --timeout-ms 15000
cmux browser --surface "$SURFACE" snapshot --interactive

echo "If redirected to login, complete login flow then run:"
printf '  cmux browser --surface %q state save %q\n' "$SURFACE" "$STATE_FILE"
