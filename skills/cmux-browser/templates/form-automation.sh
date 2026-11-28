#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${1:-}" || -z "${2:-}" ]]; then
  printf 'Usage: %s <url> <tab_id|page>\n' "${0##*/}" >&2
  exit 2
fi

URL="$1"
TAB="$2"

# navigate returns once the load starts, so mark the current document and
# wait (up to about 15s) for a new one to finish loading before reading it.
cmux browser "$TAB" eval 'window.__cmuxNavPending = true' >/dev/null || true
cmux browser "$TAB" navigate "$URL"
loaded=0
for _ in $(seq 1 60); do
  if cmux --json browser "$TAB" eval '!window.__cmuxNavPending && document.readyState === "complete"' 2>/dev/null |
    grep -E '"value"[[:space:]]*:[[:space:]]*true' >/dev/null; then
    loaded=1
    break
  fi
  sleep 0.25
done
[[ "$loaded" == 1 ]] || printf 'warning: %s did not finish loading; the snapshot may be stale\n' "$URL" >&2
cmux browser "$TAB" state
cmux browser "$TAB" snapshot --interactive

echo "Now run fill/click commands using refs from the snapshot above."
