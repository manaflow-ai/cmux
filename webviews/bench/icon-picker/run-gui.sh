#!/bin/sh
# Icon picker bench on a GUI host (cmux-lawrence-2 or a fleet Mac with a console; never the
# laptop: wk-bench opens a small non-activating panel). Run from a checkout at the commit to
# measure:
#   webviews/bench/icon-picker/run-gui.sh [out-dir]
# Writes <out-dir>/catalog.json (the system SF Symbol catalog as the host sends it) and
# <out-dir>/wk-bench.json (open, keystroke, scroll fps per grid and rendering mode, jumps).
# With bun and webviews/node_modules present it also writes <out-dir>/model-bench.json (the
# headless store bench on the real catalog).
set -eu
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)"
OUT="${1:-$ROOT/artifacts/icon-picker-bench}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"
swiftc -O -parse-as-library "$ROOT/webviews/bench/icon-picker/wk-bench.swift" -o "$WORK/wk-bench"
"$WORK/wk-bench" --dump-catalog "$OUT/catalog.json"
"$WORK/wk-bench" "$ROOT/Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages/icon-picker/index.html" \
  "$ROOT/webviews/bench/icon-picker/page-bench.js" > "$OUT/wk-bench.json"
if command -v bun >/dev/null 2>&1 && [ -d "$ROOT/webviews/node_modules" ]; then
  (cd "$ROOT/webviews" && CMUX_ICON_BENCH_CATALOG="$OUT/catalog.json" bun bench/icon-picker/model-bench.ts) > "$OUT/model-bench.json"
fi
echo "wrote $OUT"
