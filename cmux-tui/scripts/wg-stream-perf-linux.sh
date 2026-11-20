#!/usr/bin/env bash
# cmux-wg's three stream workloads (small, frames, bulk) on Linux, for the perf cron's wg-stream part:
# remote_stream_bench --perf-suite (crates/cmux-wg/examples/remote_stream_perf/suite.rs). Run at a pushed head:
#   cmux-ci test --setup rust -- 'cmux-tui/scripts/wg-stream-perf-linux.sh'
#   wg-stream-perf-linux.sh build-only: only the release build (the perf cron builds under a cap of its own).
# The suite's one JSON object ({"rows": [...]}) is the last line of stdout: the report perf-cron.py's Linux part
# reads (its rows are webui.wg_stream.*).
set -euo pipefail
build_only=0
for arg in "$@"; do
  case "$arg" in
    build-only) build_only=1 ;;
    *) echo "wg-stream-perf-linux.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
root="$(git rev-parse --show-toplevel)"
cd "$root"
# A bare runner (the perf cron's Linux part): the pinned Rust and the native build tools.
command -v cargo >/dev/null || ./scripts/install-rust-ci.sh
command -v clang >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq clang libclang-dev pkg-config; }
export PATH="$HOME/.cargo/bin:$PATH"
cd "$root/cmux-tui"
cargo build --locked --release -p cmux-wg --example remote_stream_bench 2>&1 | tail -n 3
[[ "$build_only" == 1 ]] && exit 0
target="$(cargo metadata --locked --no-deps --format-version 1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
"$target/release/examples/remote_stream_bench" --perf-suite
