#!/usr/bin/env bash
# The daemon's part of the infinite-chats goal (cmuxterm-hq#14331): one coordinator chat per size, opened,
# scrolled, prompted and restarted on the real acpmux daemon (release), from one harness
# (cmux-tui/crates/acpmux/tests/god_daemon.rs `chat_size_sweep`). Prints `CHAT-SIZE {...}` per size,
# `CHAT-SIZE-RATIO {...}` against the first size and `infinite_chat_size_ratio_max <ratio> <key> <size>`.
#
# Leo, 2026-11-19: "we need to be able to have infinite chats, infinitely long chats ... on current day hardware".
#
# Run at a pushed head (a lane VM; Linux pool):
#   cmux-ci test --route fleet --timeout 7200 -- bash scripts/measure/chat-size-sweep.sh [SIZES]
# SIZES: comma separated, binary units (default 1M,100M,1G,4G). The chats come from coord-sim
# (cmux-tui/crates/coord-sim) when this tree has it, else from acpmux's chat_size_fixture.rs; each line
# names its "source". Every chat is generated in the run, into the test's scratch, and removed after its size.
set -euo pipefail
sizes="${1:-1M,100M,1G,4G}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
log="${FAST_CHECKS_OUT:-${TMPDIR:-/tmp}}/chat-size-sweep.log"
[ -n "${FAST_CHECKS_OUT:-}" ] && exec > >(tee -a "$log") 2>&1
echo "CHAT-SIZE-HEAD $(git -C "$root" rev-parse HEAD)"
echo "CHAT-SIZE-HOST $(hostname) $(uname -sm)"
df -h "${TMPDIR:-/tmp}" "$root" 2>/dev/null || true
nproc 2>/dev/null || true
sim_bin=""
if [ -f "$root/cmux-tui/crates/coord-sim/Cargo.toml" ] && [ "${CHAT_SIZE_SOURCE:-}" != "fixture" ]; then
  # Its own target folder: a runner's CARGO_TARGET_DIR would put the binary elsewhere.
  sim_target="$root/cmux-tui/crates/coord-sim/target"
  (cd "$root/cmux-tui/crates/coord-sim" && cargo build --release -q --target-dir "$sim_target")
  sim_bin="$sim_target/release/coord-sim"
  [ -x "$sim_bin" ] || { echo "chat-size-sweep: coord-sim did not build at $sim_bin" >&2; exit 1; }
fi
cd "$root/cmux-tui"
ACPMUX_CHAT_SIZES="$sizes" ACPMUX_CHAT_SIM_BIN="$sim_bin" \
  cargo test -p acpmux --release --test god_daemon chat_size_sweep -- --ignored --nocapture
