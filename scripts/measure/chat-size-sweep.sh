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
#
# Any runner is a producer of NOW's infinite_chat_size_ratio_max (cmuxterm-hq now_benches.py), beside the perf
# cron's fleet Mac part (scripts/cmux-next/chat-size-ratio.py, which stays authoritative while fresh): the run also
# writes chat-size-row.json into $FAST_CHECKS_OUT (else $TMPDIR), {"row": "chat_size.ratio_max", "value", "axis",
# "size", "sizes", "sha", "host", "at"}, value null when a size or axis had no reading. Publish it from a lane VM:
#   cmux-ci test --artifact DIR -- bash scripts/measure/chat-size-sweep.sh 1M,100M,1G
#   python3 tools/fleet-reconcilers/now_hand_measures.py chat-size DIR/chat-size-row.json --step JOB   (cmuxterm-hq)
#
# The heap behind a number: CHAT_SIZE_DHAT=1 builds the daemon with `--features dhat-heap` (line tables, so inlined
# frames have names) and the harness adds each size's allocation sites, cold (`heap`) and restarted
# (`restartHeap`), to its CHAT-SIZE line. Its RSS readings are dhat's allocator, not the shipped one: profile
# with it, measure without it.
#   cmux-ci test --timeout 7200 -- env CHAT_SIZE_DHAT=1 ACPMUX_GOD_DHAT_FRAMES=6 bash scripts/measure/chat-size-sweep.sh 1G
set -euo pipefail
sizes="${1:-1M,100M,1G,4G}"
features=()
if [ "${CHAT_SIZE_DHAT:-}" = 1 ]; then
  features=(--features dhat-heap)
  export ACPMUX_GOD_DHAT=1 CARGO_PROFILE_RELEASE_DEBUG=line-tables-only
fi
root="$(cd "$(dirname "$0")/../.." && pwd)"
out_dir="${FAST_CHECKS_OUT:-${TMPDIR:-/tmp}}"
mkdir -p "$out_dir"
log="$out_dir/chat-size-sweep.log"
[ -n "${FAST_CHECKS_OUT:-}" ] && exec > >(tee -a "$log") 2>&1
head_sha="$(git -C "$root" rev-parse HEAD)"
echo "CHAT-SIZE-HEAD $head_sha"
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
run_log="$(mktemp)"
trap 'rm -f "$run_log"' EXIT
code=0
ACPMUX_CHAT_SIZES="$sizes" ACPMUX_CHAT_SIM_BIN="$sim_bin" \
  cargo test -p acpmux --release "${features[@]}" --test god_daemon chat_size_sweep -- --ignored --nocapture 2>&1 | tee "$run_log" \
  || code=$?
# The row any runner publishes: the harness's last `infinite_chat_size_ratio_max <ratio> <axis> <size>` line.
python3 - "$run_log" "$out_dir/chat-size-row.json" "$sizes" "$head_sha" "$(hostname -s 2>/dev/null || hostname)" <<'PY'
import datetime, json, sys
src, dst, sizes, sha, host = sys.argv[1:6]
value = axis = size = None
for line in open(src, errors="replace"):
    parts = line.split()
    if parts[:1] == ["infinite_chat_size_ratio_max"]:
        try:
            value, axis, size = float(parts[1]), parts[2] if len(parts) > 2 else None, parts[3] if len(parts) > 3 else None
        except (IndexError, ValueError):
            value = axis = size = None
row = {"row": "chat_size.ratio_max", "value": value, "axis": axis, "size": size, "sizes": sizes, "sha": sha,
       "host": host, "at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
with open(dst, "w") as f:
    json.dump(row, f)
print("CHAT-SIZE-ROW " + json.dumps(row))
PY
exit "$code"
