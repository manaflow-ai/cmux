#!/usr/bin/env bash
# Time to a settled page against its derived bound, on Linux, in one job (goal settled-page-ceiling, cmuxterm-hq
# goals/settled-page-ceiling.md): webviews/bench/settled-page.bench.ts through the web UI suite, as the perf cron's
# web-ui-settled part runs it (perf-cron.py). For a pinned hand measure while the cron has not reached the part:
#
#   cmux-ci test -- bash scripts/measure/settled-page-linux.sh [rounds=5] [only=chat_switch,workspace_switch]
#
# Prints the bench's PERF_ROW lines and one `SETTLED_PAGE_SCORE <value>` line: settled_page.score_max, the worst
# scenario's median settled_ms / bound_ms plus one per shifted frame, the value NOW's settled_page_score_max reads.
# Publish it: cmuxterm-hq tools/fleet-reconcilers/now_hand_measures.py publish
#   --row webui.settled_page.score_max@<runner> --value V --step <job> --sha SHA.
set -euo pipefail
rounds=""
only=""
for arg in "$@"; do
  case "$arg" in
    rounds=*) rounds="${arg#rounds=}" ;;
    only=*) only="${arg#only=}" ;;
    *) echo "settled-page-linux.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
root="$(git rev-parse --show-toplevel)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
# Chromium's singleton socket path must fit a unix socket's 108 bytes.
export TMPDIR="$out"
command -v bun >/dev/null || { curl -fsSL https://bun.sh/install | bash -s bun-v1.4.4 >/dev/null; }
export PATH="$HOME/.bun/bin:$PATH"
cd "$root/webviews"
[[ -d node_modules ]] || bun install --frozen-lockfile >/dev/null
[[ -n "${CMUX_CHROME_HEADLESS_SHELL:-}" ]] || [[ ! -x "$root/scripts/ci/ensure-system-chrome.sh" ]] ||
  export "$("$root/scripts/ci/ensure-system-chrome.sh" 2>/dev/null | grep -m1 '^CMUX_CHROME_HEADLESS_SHELL=' || echo CMUX_NO_HEADLESS_SHELL=1)"
status=0
if [[ -n "$rounds" || -n "$only" ]]; then
  ONLY="$only" bun bench/settled-page.bench.ts ${rounds:+"$rounds"} >"$out/bench.log" 2>&1 || status=$?
else
  bun bench/web-ui-suite.ts --only settled-page >"$out/bench.log" 2>&1 || status=$?
fi
grep -v BABEL "$out/bench.log" | grep -E "PERF_ROW|^settled_page\." || true
score="$(grep -oE '"name":"(webui\.)?settled_page\.score_max","p50":[0-9.]+' "$out/bench.log" | tail -1 | grep -oE '[0-9.]+$' || true)"
if [[ -z "$score" ]]; then
  echo "settled-page-linux.sh: no settled_page.score_max row (bench exit $status):"
  grep -v BABEL "$out/bench.log" | tail -n 30
  exit 1
fi
echo "SETTLED_PAGE_SCORE $score"
exit "$status"
