#!/usr/bin/env bash
# The ghostty-web terminal's Linux checks, end to end against a real daemon:
#   1. the Playwright test (e2e/ghostty-terminal.e2e.mjs): type, see the echo;
#   2. with --measure, first paint and keydown-to-echo on loopback for the
#      default renderer and for ?terminal=ghostty (scripts/measure-in-browser.mjs,
#      the method of #50231), each against a fresh headless daemon.
#
#   scripts/ghostty-e2e.sh [--measure] [--bin PATH]
#
# With no --bin and no CMUX_TUI_BIN it builds cmux-tui (ghostty-next, zig).
# Results and screenshots go to $FAST_CHECKS_OUT (else a temp folder).
set -euo pipefail

measure=0
bin=${CMUX_TUI_BIN:-}
while [ $# -gt 0 ]; do
  case "$1" in
    --measure) measure=1; shift ;;
    --bin) bin=$2; shift 2 ;;
    *) echo "ghostty-e2e: unknown argument $1" >&2; exit 2 ;;
  esac
done

web=$(cd "$(dirname "$0")/.." && pwd)
root=$(git -C "$web" rev-parse --show-toplevel)
out=${FAST_CHECKS_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/ghostty-e2e-out.XXXXXX")}
mkdir -p "$out"

if [ -z "$bin" ]; then
  (
    cd "$root"
    bash scripts/ci/init-submodule.sh ghostty-next
    ./scripts/install-zig-ci.sh
    ./scripts/ci/fetch-ghostty-zig-packages.sh ghostty-next
    cd cmux-tui && GHOSTTY_ZIG_SOURCE=ghostty-next cargo build -p cmux-tui --locked
  )
  target=${CARGO_TARGET_DIR:-$root/cmux-tui/target}
  case "$target" in /*) ;; *) target=$root/cmux-tui/$target ;; esac
  bin=$target/debug/cmux-tui
fi
[ -x "$bin" ] || { echo "ghostty-e2e: no cmux-tui at $bin" >&2; exit 2; }

(cd "$root/cmux-tui/bindings/typescript" && npm ci --no-audit --no-fund && npm run build)
(cd "$web" && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --no-audit --no-fund)
work=$(mktemp -d "${TMPDIR:-/tmp}/ghostty-e2e.XXXXXX")
trap 'rm -rf "$work"' EXIT
pages=$work/pages
(cd "$web" && npx vp build --base ./ --outDir "$pages/web" --emptyOutDir)

# System Chrome or the pinned chrome-headless-shell, never Playwright's Chromium.
chrome_line=$(cd "$web" && bash "$root/scripts/ci/ensure-system-chrome.sh" | tail -1)
case "$chrome_line" in CMUX_CHROME_HEADLESS_SHELL=*) export CMUX_CHROME_HEADLESS_SHELL=${chrome_line#*=} ;; esac
if [ -z "${CMUX_CHROME_HEADLESS_SHELL:-}" ]; then
  CMUX_CHROME=$(command -v google-chrome-stable || command -v google-chrome)
  export CMUX_CHROME
fi

(cd "$web" && CMUX_TUI_BIN=$bin CMUX_TUI_PAGES_DIR=$pages \
  npx playwright test -c e2e/playwright.config.mjs --output "$out/playwright")

[ "$measure" = 1 ] || exit 0
run_measure() { # NAME PORT QUERY
  local log=$work/$1.log
  CMUX_TUI_PAGES_DIR=$pages bash "$web/scripts/serve-from-daemon.sh" --no-build --bin "$bin" \
    --session "measure-$1" --port "$2" > "$log" 2>&1 &
  local pid=$!
  local url=
  for _ in $(seq 1 100); do
    url=$(sed -n 's/^cmux on the web: //p' "$log")
    [ -n "$url" ] && break
    sleep 0.1
  done
  [ -n "$url" ] || { cat "$log" >&2; kill "$pid"; return 1; }
  url=${url/\/pages\/web\/#/\/pages\/web\/$3#}
  node "$web/scripts/measure-in-browser.mjs" "$url" "$out/measure-$1" 40
  kill "$pid"
  wait "$pid" 2>/dev/null || true
}
run_measure default 7691 ""
run_measure ghostty 7692 "?terminal=ghostty"
