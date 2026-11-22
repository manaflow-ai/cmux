#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${1:-}" ]]; then
  printf 'Usage: %s <tab_id|page> [dashboard-url]\n' "${0##*/}" >&2
  exit 2
fi

TAB="$1"
DASHBOARD_URL="${2:-https://app.example.com/dashboard}"

# Saved state (state save|load) was removed; the tab keeps its login in the
# browser profile.
# navigate returns once the load starts, so mark the current document and
# wait (up to about 15s) for a new one to finish loading before reading it.
cmux browser "$TAB" eval 'window.__cmuxNavPending = true' >/dev/null || true
cmux browser "$TAB" navigate "$DASHBOARD_URL"
loaded=0
for _ in $(seq 1 60); do
  if cmux --json browser "$TAB" eval '!window.__cmuxNavPending && document.readyState === "complete"' 2>/dev/null |
    grep -E '"value"[[:space:]]*:[[:space:]]*true' >/dev/null; then
    loaded=1
    break
  fi
  sleep 0.25
done
[[ "$loaded" == 1 ]] || printf 'warning: %s did not finish loading; the snapshot may be stale\n' "$DASHBOARD_URL" >&2
cmux browser "$TAB" state
cmux browser "$TAB" snapshot --interactive

echo "If the state shows a login URL, fill the fields by ref from the snapshot:"
printf '  cmux browser %q fill e1 "$APP_USERNAME"\n' "$TAB"
