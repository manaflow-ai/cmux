#!/usr/bin/env bash
# Manual hosted runner for reconnect-hole.harness.ts: records the fix (the checkout as is), then
# the base (direct.ts from BASE_SHA, the same harness), into ${FAST_CHECKS_OUT:-$PWD/reconnect-hole}.
# A shallow fleet checkout may lack the base commit: a copy of the base direct.ts at BASE_DIRECT
# (default .reconnect-hole-base/direct.ts at the checkout's root) stands in for it.
set -euo pipefail
base_sha="${BASE_SHA:-c74a1844964f93b165d5a5eb5cecfae74880ce9d}"
root="$(git rev-parse --show-toplevel)"
base_direct="${BASE_DIRECT:-$root/.reconnect-hole-base/direct.ts}"
cd "$root/webviews"
out="${FAST_CHECKS_OUT:-$PWD/reconnect-hole}"
mkdir -p "$out"
bun scripts/pages/gen-strings.mjs --best-effort
run() {
  set +e
  CMUX_BROWSER_TESTS=1 CMUX_RECONNECT_CAPTURE_DIR="$out" CMUX_RECONNECT_LABEL="$1" \
    bun scripts/agent-pane/reconnect-hole.harness.ts > "$out/$1.log" 2>&1
  local status=$?
  set -e
  printf 'RECONNECT_HOLE_%s_STATUS=%s\n' "$1" "$status"
  cat "$out/$1.log"
}
run after
if [ -f "$base_direct" ]; then
  cp "$base_direct" src/agent-session/acpmux/direct.ts
else
  git checkout "$base_sha" -- src/agent-session/acpmux/direct.ts
fi
run before
git checkout HEAD -- src/agent-session/acpmux/direct.ts
ls -la "$out"
# The build fleet keeps no $FAST_CHECKS_OUT files: the videos travel in the log, base64 between
# markers (CMUX_RECONNECT_VIDEO_IN_LOG=0 skips it).
if [ "${CMUX_RECONNECT_VIDEO_IN_LOG:-1}" = 1 ]; then
  for label in after before; do
    [ -f "$out/$label.webm" ] || continue
    echo "RECONNECT_HOLE_VIDEO_BEGIN $label"
    base64 -w 0 "$out/$label.webm"
    echo
    echo "RECONNECT_HOLE_VIDEO_END $label"
  done
fi
