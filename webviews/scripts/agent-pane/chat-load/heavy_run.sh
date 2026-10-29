#!/usr/bin/env bash
# Heavy chat load benchmark (heavy_bench.mjs) on a Linux VM with the webviews browser snapshot:
# builds the shipped agent pane unminified (readable profile names) and runs the bench in Chromium.
#
#   heavy_run.sh OUT_DIR [heavy_bench.mjs options...]
#
# Run from the repository root. Through the fleet: cmux-ci test -- webviews/scripts/agent-pane/chat-load/heavy_run.sh OUT
set -euo pipefail
out="$1"; shift
mkdir -p "$out"; out="$(cd "$out" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../../.." && pwd)"
work="$(mktemp -d /tmp/heavy-chat-load.XXXXXX)"
trap 'rm -rf "$work"' EXIT
(cd "$root/webviews" && bun install --frozen-lockfile >/dev/null)
if [[ "${HEAVY_MINIFY:-}" != 1 ]]; then
  cp "$root/webviews/scripts/agent-pane/bundle.mjs" "$work/bundle.mjs.orig"
  sed -i 's/minify: !cssInputsOnly/minify: false/' "$root/webviews/scripts/agent-pane/bundle.mjs"
  restore() { cp "$work/bundle.mjs.orig" "$root/webviews/scripts/agent-pane/bundle.mjs"; rm -rf "$work"; }
  trap restore EXIT
fi
"$root/scripts/cmux-next/build-agent-pane-web.sh" --out "$work/pane"
# The webviews browser snapshot's browsers when the VM has them, else Playwright's own install.
if [[ -z "${PLAYWRIGHT_BROWSERS_PATH:-}" && -d /opt/pw-webviews/browsers ]]; then export PLAYWRIGHT_BROWSERS_PATH=/opt/pw-webviews/browsers; fi
(cd "$root/webviews" && node "$here/heavy_bench.mjs" --pane "$work/pane" --out "$out/heavy.json" "$@") | tee "$out/heavy.txt"
echo "results in $out"
