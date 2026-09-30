#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${1:-}" ]]; then
  printf 'Usage: %s <tab_id|page> [dashboard-url]\n' "${0##*/}" >&2
  exit 2
fi

TAB="$1"
DASHBOARD_URL="${2:-https://app.example.com/dashboard}"

# Saved state (state save|load) was removed; the tab keeps its login in the
# browser profile. Waits are not supported yet, so check state yourself.
cmux browser "$TAB" navigate "$DASHBOARD_URL"
cmux browser "$TAB" state
cmux browser "$TAB" snapshot --interactive

echo "If the state shows a login URL, fill the fields by ref from the snapshot:"
printf '  cmux browser %q fill e1 "$APP_USERNAME"\n' "$TAB"
