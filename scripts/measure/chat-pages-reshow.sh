#!/usr/bin/env bash
# Switch back to a hidden agent chat, as a kept page against a view in one shared document, on a Mac with GPU
# raster (goal memory-per-chat; Leo, 2026-11-17: "instant > memory"). Runs webviews/bench/chat-pages-memory.bench.ts
# timing-only and headed at COUNT chats of TURNS turns in four arms: HIDDEN=1 (kept page), SHARED=1 with each hide
# style (display:none, content-visibility:hidden, visibility:hidden). Reads chat_pages_memory.reshow_many and
# chat_pages_memory.shared_reshow.* PERF_ROWs, p50/p95 in ms.
#   cmux-ci run --class exclusive --measurement --script scripts/measure/chat-pages-reshow.sh --ref SHA \
#     [--arg=count=10] [--arg=turns=100] [--arg=arms=hidden,none,cv,vis]
set -euo pipefail
count=10 turns=100 arms=hidden,none,cv,vis
for arg in "$@"; do
  case "$arg" in
    count=*) count=${arg#count=} ;;
    turns=*) turns=${arg#turns=} ;;
    arms=*) arms=${arg#arms=} ;;
    *) echo "chat-pages-reshow: unknown argument $arg (count= turns= arms=)" >&2; exit 2 ;;
  esac
done
cd "$(dirname "$0")/../../webviews"
[[ -d node_modules/vite ]] || bun install --frozen-lockfile
# A headed launch runs the installed Google Chrome; without it, Playwright's own Chromium.
if [[ "$(uname)" == Darwin && ! -d "/Applications/Google Chrome.app" ]]; then
  export CMUX_PLAYWRIGHT_BUNDLED_CHROMIUM=1
  bunx playwright install chromium
fi
status=0
IFS=, read -r -a list <<<"$arms"
for arm in "${list[@]}"; do
  echo "== chat-pages-reshow: arm $arm, $count chats x $turns turns"
  case "$arm" in
    hidden) HIDDEN=1 REOPEN="$count" bun bench/chat-pages-memory.bench.ts "$count" "$turns" || status=$? ;;
    none) SHARED=1 REOPEN="$count" bun bench/chat-pages-memory.bench.ts "$count" "$turns" || status=$? ;;
    cv | vis) SHARED=1 SHARED_HIDE="$arm" REOPEN="$count" bun bench/chat-pages-memory.bench.ts "$count" "$turns" || status=$? ;;
    *) echo "chat-pages-reshow: unknown arm $arm (hidden, none, cv, vis)" >&2; status=2 ;;
  esac
done
exit "$status"
