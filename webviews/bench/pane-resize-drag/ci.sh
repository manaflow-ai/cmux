#!/usr/bin/env bash
# Runs bench/pane-resize-drag.bench.ts on a Linux CI box and leaves its JSON in $FAST_CHECKS_OUT.
#
# From webviews/ on a lane VM (the run happens on the org's runners at the PR's head, never here):
#   cmux-ci test --setup playwright --artifact /tmp/dragbench -- bash bench/pane-resize-drag/ci.sh
#   cmux-ci test --setup playwright --artifact /tmp/dragbench -- bash bench/pane-resize-drag/ci.sh --turns=700 --engines=chromium
# Any argument is passed to the bench (--turns, --engines, --rounds, --driver, --wide, --narrow, --no-spans,
# --profile). Then `scripts/bench/cmux-bench pane-resize-drag --import /tmp/dragbench/summary.json` records it.
#
# `--setup playwright` installs WebKit and the system Chrome (fast-checks.yml) and exports
# CMUX_CHROME_HEADLESS_SHELL, which bench/browsers.ts launches for Chromium. Elsewhere (a fleet Linux
# step) this installs WebKit into the cmux-ci cache and asks ensure-system-chrome.sh for Chrome, as
# scripts/ci/run-webviews-tests.sh does for the browser lane. Never on a Mac (no Playwright on Macs).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
if [ "$(uname -s)" = Darwin ] && [ "${GITHUB_ACTIONS:-}" != true ]; then
  echo "pane-resize-drag: not on a Mac (no Playwright on Macs); run it with cmux-ci test" >&2
  exit 2
fi

out="${FAST_CHECKS_OUT:-/tmp/pane-resize-drag}"
mkdir -p "$out"

if [ "${GITHUB_ACTIONS:-}" != true ]; then
  playwright_version="$(python3 -c 'import json; print(json.load(open("package.json"))["devDependencies"]["playwright"])' 2> /dev/null || echo unknown)"
  export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-${CMUX_CI_CACHE_DIR:-$HOME/.cache/cmux-ci}/playwright-$playwright_version}"
  ./node_modules/.bin/playwright install webkit || echo "pane-resize-drag: webkit install failed; the webkit case will report it" >&2
fi
if [ -z "${CMUX_CHROME_HEADLESS_SHELL:-}" ] && [ -x ../scripts/ci/ensure-system-chrome.sh ]; then
  chrome_out="$(../scripts/ci/ensure-system-chrome.sh --optional || true)"
  printf '%s\n' "$chrome_out"
  shell_line="$(printf '%s\n' "$chrome_out" | grep '^CMUX_CHROME_HEADLESS_SHELL=' | tail -1 || true)"
  [ -n "$shell_line" ] && export CMUX_CHROME_HEADLESS_SHELL="${shell_line#CMUX_CHROME_HEADLESS_SHELL=}"
fi

# Host facts beside the numbers: a CI box's frame times are only comparable on the same class of box.
{
  echo "uname: $(uname -a)"
  echo "cpus: $(getconf _NPROCESSORS_ONLN 2> /dev/null || echo unknown)"
  echo "load: $(cat /proc/loadavg 2> /dev/null || echo unknown)"
  echo "head: $(git rev-parse HEAD 2> /dev/null || echo unknown)"
} > "$out/host.txt"

status=0
bun bench/pane-resize-drag.bench.ts --out="$out" "$@" 2>&1 | tee "$out/bench.log" || status=$?
echo "pane-resize-drag: summary"
cat "$out/summary.txt" 2> /dev/null || true
exit "$status"
