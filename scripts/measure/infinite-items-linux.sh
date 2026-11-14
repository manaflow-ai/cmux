#!/usr/bin/env bash
# Infinite items on Linux (CMUX-571): the daemons (scripts/measure/infinite-items.py) and the headless
# chat pages (webviews/bench/chat-pages-memory.bench.ts, RELEASE=1), at each count. Run at a pushed head:
#   cmux-ci test -- bash -c 'scripts/measure/infinite-items-linux.sh [counts=10,100,1000] [days=3] [pages=0]; echo rc=$?'
# Builds release acpmux and cmux-tui (cmux-tui/), then prints INFINITE and PERF_ROW lines.
set -euo pipefail
counts="10,100,1000"
days=3
pages=1
page_counts=""
extra=()
for arg in "$@"; do
  case "$arg" in
    counts=*) counts="${arg#counts=}" ;;
    days=*) days="${arg#days=}" ;;
    pages=*) pages="${arg#pages=}" ;;
    page_counts=*) page_counts="${arg#page_counts=}" ;;
    --*) extra+=("$arg") ;;
    *) echo "infinite-items-linux.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
root="$(git rev-parse --show-toplevel)"
cd "$root"
# cmux-tui's terminal engine builds from the ghostty-next submodule, which a fast-checks snapshot leaves empty.
[ -f ghostty-next/build.zig ] || [ -n "${CMUX_GHOSTTY_SRC:-}" ] || git submodule update --init --depth 1 ghostty-next
cd "$root/cmux-tui"
cargo build --locked --release -p acpmux --bin acpmux -p cmux-tui --bin cmux-tui 2>&1 | tail -n 3
target="$(cargo metadata --locked --no-deps --format-version 1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
cd "$root"
out="${FAST_CHECKS_OUT:-$(mktemp -d)}"
status=0
ulimit -n 65536 2>/dev/null || ulimit -n "$(ulimit -Hn)" || true
python3 scripts/measure/infinite-items.py --acpmux "$target/release/acpmux" --tui "$target/release/cmux-tui" \
  --counts "$counts" --days "$days" --out "$out/infinite-items.json" ${extra[@]+"${extra[@]}"} || status=$?
if [[ "$pages" == 1 ]]; then
  cd "$root/webviews"
  if command -v bun >/dev/null; then
    [ -d node_modules ] || bun install --frozen-lockfile >/dev/null 2>&1 || bun install >/dev/null
    # The pages a renderer holds when every chat but the newest is released (the app's idle release), at each
    # count: the renderer side of the same items.
    RELEASE=1 REOPEN=10 bun bench/chat-pages-memory.bench.ts "${page_counts:-10,100}" 20 || status=$?
  else
    echo "infinite-items-linux.sh: no bun; pages skipped" >&2
  fi
fi
exit "$status"
