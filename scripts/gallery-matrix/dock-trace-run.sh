#!/usr/bin/env bash
# Frame-by-frame bottom-dock + transcript-end trace for the composer move reds (load and turn end).
# Fleet route, no --setup: installs Chromium itself.
#   cmux-ci test --artifact /tmp/trace -- 'bash scripts/gallery-matrix/dock-trace-run.sh'
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
out="${FAST_CHECKS_OUT:-$root/.motion-run}"
mkdir -p "$out"
cd "$root/webviews"
bun install --frozen-lockfile >/dev/null
bunx playwright install --with-deps chromium
cd "$root/scripts/gallery-matrix"
bun install --frozen-lockfile >/dev/null
cd "$root"
export CMUX_GALLERY_INIT_SCRIPT="$root/scripts/gallery-matrix/dock-trace.js"
ENTRIES="${ENTRIES:-agent-pane.composer-send-one-motion,agent-pane.start-folder}" TRACE=1 OUT="$out" \
  bash scripts/gallery-matrix/undeclared-run.sh > "$out/trace-run.log" 2>&1 || echo "undeclared-run exit $?"
grep -c "motion-trace dock" "$out/trace-run.log" || true
grep "motion-trace" "$out/trace-run.log" > "$out/dock-trace.txt" || true
tail -n 60 "$out/trace-run.log"
