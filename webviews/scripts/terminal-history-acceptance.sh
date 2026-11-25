#!/usr/bin/env bash
# On a Linux fleet runner from cmux-tui: bash ../webviews/scripts/terminal-history-acceptance.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$work"' EXIT
bash "$root/scripts/ci/ensure-bun.sh" 1.4.4 "$work/bin"
export PATH="$work/bin:$PATH"
export CMUX_HISTORY_BROWSER_BUN="$work/bin/bun"
export CMUX_HISTORY_PACKED_PAGES="$work/pages"
export CMUX_HISTORY_WEBVIEWS="$root/webviews"
bash "$root/scripts/cmux-next/build-pages-web.sh" --out "$CMUX_HISTORY_PACKED_PAGES"
cd "$root/webviews"
bash "$root/scripts/ci/ensure-system-chrome.sh" > "$work/chrome.log" || { cat "$work/chrome.log"; exit 1; }
CMUX_CHROME_HEADLESS_SHELL="$(sed -n 's/^CMUX_CHROME_HEADLESS_SHELL=//p' "$work/chrome.log" | tail -n 1)"
export CMUX_CHROME_HEADLESS_SHELL
cd "$root/cmux-tui"
cargo test -p acpmux --test chats_transcript packed_history_visible_600mib -- --exact --ignored --nocapture
