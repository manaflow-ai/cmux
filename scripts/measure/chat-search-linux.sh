#!/usr/bin/env bash
# The Cmd-K chats page's search typed a key at a time on 2,000 chats, on Linux (cmuxterm-hq goal
# chat-history-search): the release acpmux test cmux-tui/crates/acpmux/tests/chats_search_bench.rs. Run at a
# pushed head:
#   cmux-ci test --setup rust -- 'scripts/measure/chat-search-linux.sh [chats=2000] [mib=1]'
#   mib: the fixture's size factor (1 is the measured store sizes, about 4.4 GB at 2,000 chats).
#   chat-search-linux.sh build-only: only the release build (the perf cron builds under a cap of its own).
# Prints the bench's lines, PERF_ROW ones among them, then the rows as one JSON object ({"rows": [...]}) on a
# line of its own: the report perf-cron.py's Linux part reads (its rows are webui.chat_search.*).
set -euo pipefail
chats=2000
mib=1
build_only=0
for arg in "$@"; do
  case "$arg" in
    chats=*) chats="${arg#chats=}" ;;
    mib=*) mib="${arg#mib=}" ;;
    build-only) build_only=1 ;;
    *) echo "chat-search-linux.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
root="$(git rev-parse --show-toplevel)"
cd "$root"
# A bare runner (the perf cron's Linux part): the pinned Rust and the native build tools.
command -v cargo >/dev/null || ./scripts/install-rust-ci.sh
command -v clang >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq clang libclang-dev pkg-config; }
export PATH="$HOME/.cargo/bin:$PATH"
cd "$root/cmux-tui"
cargo test --locked --release -p acpmux --test chats_search_bench --no-run 2>&1 | tail -n 3
[[ "$build_only" == 1 ]] && exit 0
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
CHAT_SEARCH_BENCH_CHATS="$chats" CHAT_SEARCH_BENCH_MIB="$mib" \
  cargo test --locked --release -p acpmux --test chats_search_bench -- --ignored --nocapture 2>&1 | tee "$out/bench.log"
python3 -c 'import json,sys
rows = [json.loads(l[len("PERF_ROW "):]) for l in open(sys.argv[1]) if l.startswith("PERF_ROW ")]
print(json.dumps({"rows": rows}))' "$out/bench.log"
