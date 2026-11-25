#!/usr/bin/env bash
# Manual hosted runner for reconnect-hole.harness.ts: records the fix (the checkout as is), then
# the base (direct.ts from BASE_SHA, the same harness), into ${FAST_CHECKS_OUT:-$PWD/reconnect-hole},
# against a daemon that pages a reconnect's attach forward (acpmux) and one that ignores `afterSeq`
# (an older acpmux or a peer). A shallow fleet checkout may lack the base commit: a copy of the base
# direct.ts at BASE_DIRECT (default .reconnect-hole-base/direct.ts at the checkout's root) stands in.
# Bring the videos back with `cmux-ci test --artifact DIR`.
set -euo pipefail
base_sha="${BASE_SHA:-HEAD~1}"
root="$(git rev-parse --show-toplevel)"
base_direct="${BASE_DIRECT:-$root/.reconnect-hole-base/direct.ts}"
cd "$root/webviews"
out="${FAST_CHECKS_OUT:-$PWD/reconnect-hole}"
mkdir -p "$out"
bun scripts/pages/gen-strings.mjs --best-effort
run() {
  set +e
  CMUX_BROWSER_TESTS=1 CMUX_RECONNECT_CAPTURE_DIR="$out" CMUX_RECONNECT_LABEL="$1" CMUX_RECONNECT_IGNORE_AFTER_SEQ="$2" \
    bun scripts/agent-pane/reconnect-hole.harness.ts > "$out/$1.log" 2>&1
  local status=$?
  set -e
  printf 'RECONNECT_HOLE_%s_STATUS=%s\n' "$1" "$status"
  grep '^RECONNECT_HOLE_RECEIPT=' "$out/$1.log" || tail -40 "$out/$1.log"
}
run after 0
run after-newest-page 1
cp src/agent-session/acpmux/direct.ts "$out/.fix-direct.ts"
if [ -f "$base_direct" ]; then
  cp "$base_direct" src/agent-session/acpmux/direct.ts
else
  git show "$base_sha:webviews/src/agent-session/acpmux/direct.ts" > src/agent-session/acpmux/direct.ts
fi
run before 0
run before-newest-page 1
cp "$out/.fix-direct.ts" src/agent-session/acpmux/direct.ts
rm -f "$out/.fix-direct.ts"
ls -la "$out"
