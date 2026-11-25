#!/usr/bin/env bash
# The layout-motion scenario run: renders the contract's scenario entries in the gallery (Chromium, with a
# video and a still per play step), then prints the undeclared-move table (undeclared-table.ts). One harness
# for the before and after numbers. Run it on the fleet from the repository root:
#
#   cmux-ci test --setup playwright --artifact /tmp/motion -- 'bash scripts/gallery-matrix/undeclared-run.sh'
#
# ENTRIES (comma-separated gallery entry ids) widens it; OUT defaults to $FAST_CHECKS_OUT.
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
entries="${ENTRIES:-layout.motion-scenarios,agent-pane.shift-scenarios}"
out="${OUT:-${FAST_CHECKS_OUT:-$root/.motion-run}}"
work="$(mktemp -d)"
mkdir -p "$out"
cd "$root/webviews"
bun install --frozen-lockfile >/dev/null
bun scripts/gallery/manifest.ts --frame component --entries "$entries" --themes default --out "$work/manifest.json"
CMUX_GALLERY_OUT_DIR="$work/gallery" bun run gallery:build >/dev/null
cd "$root/scripts/gallery-matrix"
bun install --frozen-lockfile >/dev/null
"$root/scripts/ci/ensure-system-chrome.sh" >/dev/null
CMUX_GALLERY_IN_VM=1 CMUX_GALLERY_RECORD_VIDEO=1 CMUX_GALLERY_ECHO_TRACE="${TRACE:-0}" bun runner.ts --manifest "$work/manifest.json" --gallery-dir "$work/gallery" \
  --output-dir "$out" --engines chromium || true
DETAIL="${TRACE:-0}" bun undeclared-table.ts --results "$out" | tee "$out/undeclared-table.md"
