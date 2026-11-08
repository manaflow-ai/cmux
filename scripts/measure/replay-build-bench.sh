#!/usr/bin/env bash
# Replay build time of ghostty-vt's vt_replay_bounded in a release build: one text
# layout against two (the reference path), 120x40 with 10,000 lines of history,
# arms interleaved in one process (replay_build_bench_one_pass_against_two).
# Run alone on an idle worker:
#   cmux-ci run --class exclusive --measurement --script scripts/measure/replay-build-bench.sh \
#     --ref SHA [--arg=runs=5]
# Prints REPLAY-BENCH-MACHINE, the host load before and after, and one
# REPLAY-BUILD-BENCH line per run (also in .build/artifacts/replay-build-bench.txt).
# A measure script not on the controller's list runs only at a commit on
# feat-cmux-next or main. Before that, the same test runs in the dev profile
# (Rust opt-level 1; libghostty-vt is ReleaseFast in every profile) as a test
# step: cmux-ci run --class isolated --os macos --script scripts/ci/cmux-tui-rust-check.sh
#   --arg terminal --arg replay_build_bench --env CMUX_REPLAY_BUILD_BENCH=5
#   --artifact .build/artifacts/replay-build-bench.txt
set -euo pipefail
runs=5
for arg in "$@"; do
  case "$arg" in
    runs=*) runs="${arg#runs=}" ;;
    *) echo "replay-build-bench.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$runs" =~ ^[1-9][0-9]?$ ]] || { echo "replay-build-bench.sh: runs must be 1-99" >&2; exit 2; }
[[ -n "${CMUX_CI_STEP_KEY:-}" ]] || { echo "replay-build-bench.sh runs cargo and runs only as a fleet step" >&2; exit 2; }
umask 022
root="$(git rev-parse --show-toplevel)"
cd "$root"
export CARGO_TARGET_DIR="$root/.build/replay-build-bench-target"
if [[ -z "$(git submodule status ghostty-next 2>/dev/null || true)" && -f ghostty-next/build.zig ]]; then
  echo "ghostty-next: synced copy"
else
  git submodule update --init --depth 1 ghostty-next
fi
cd cmux-tui
toolchain_cargo="$(rustup which cargo)"
export PATH="$(dirname "$toolchain_cargo"):$PATH"
echo "REPLAY-BENCH-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) cpu=\"$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)\" cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc) sha=$(git rev-parse --short=11 HEAD)"
rm -f "$root/.build/artifacts/replay-build-bench.txt"
echo "REPLAY-BENCH-LOAD before $(uptime | sed 's/.*load averages*: //')"
CMUX_REPLAY_BUILD_BENCH="$runs" cargo test --locked --release -p ghostty-vt --lib -- --exact --nocapture \
  terminal::replay_layout_tests::replay_build_bench_one_pass_against_two 2>&1 |
  grep -v '^ *\(Compiling\|Finished\|Running\)'
echo "REPLAY-BENCH-LOAD after $(uptime | sed 's/.*load averages*: //')"
grep -c REPLAY-BUILD-BENCH "$root/.build/artifacts/replay-build-bench.txt" | grep -qx "$runs" || {
  echo "replay-build-bench.sh: expected $runs REPLAY-BUILD-BENCH lines" >&2
  exit 1
}
