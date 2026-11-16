#!/usr/bin/env bash
# One live chat's disk growth on Linux (goal chats-flat-at-any-length): a release acpmux, then
# scripts/measure/chat-disk-growth.py at 100,000 rows. Run at a pushed head:
#   cmux-ci test --setup rust -- 'scripts/measure/chat-disk-growth-linux.sh [rows=100000] [cold]'
#   cold: agents.chats.coldSegments on (sealed segments move to cold-segments/); without it, the default.
#   chat-disk-growth-linux.sh build-only: only the release build (the perf cron builds under a cap of its own).
# Prints CHATDISK and PERF_ROW lines, then the rows as one JSON object ({"rows": [...]}) on a line of its own: the
# report perf-cron.py's Linux part reads (its rows are webui.chat_disk.*).
set -euo pipefail
rows=100000
build_only=0
cold=()
for arg in "$@"; do
  case "$arg" in
    rows=*) rows="${arg#rows=}" ;;
    build-only) build_only=1 ;;
    cold) cold=(--cold-segments) ;;
    *) echo "chat-disk-growth-linux.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
root="$(git rev-parse --show-toplevel)"
cd "$root"
# A bare runner (the perf cron's Linux part): the pinned Rust and the native build tools.
command -v cargo >/dev/null || ./scripts/install-rust-ci.sh
command -v clang >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq clang libclang-dev pkg-config; }
export PATH="$HOME/.cargo/bin:$PATH"
cd "$root/cmux-tui"
cargo build --locked --release -p acpmux --bin acpmux 2>&1 | tail -n 3
[[ "$build_only" == 1 ]] && exit 0
target="$(cargo metadata --locked --no-deps --format-version 1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
cd "$root"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
python3 scripts/measure/chat-disk-growth.py --acpmux "$target/release/acpmux" --rows "$rows" --turn-secs 30 \
  --sample-turns 250 "${cold[@]}" --out "$out/chat-disk-growth.json"
python3 -c 'import json,sys; print(json.dumps({"rows": json.load(open(sys.argv[1]))["rows"]}))' "$out/chat-disk-growth.json"
