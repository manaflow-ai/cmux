#!/usr/bin/env bash
# coord-sim on Linux: several synthetic coordinator chats at once against a release acpmux (crate
# cmux-tui/crates/coord-sim). Builds coord-sim and acpmux, generates the chats from the checked-in shape (histograms
# only, no transcript), drives them, then `coord-sim report`. Run at a pushed head:
#   cmux-ci test --setup rust -- bash -c 'scripts/measure/coord-sim-linux.sh [coordinators=3] [rate=10] [seconds=300] [seed=1] [readers=4]
#     [fanin=50,200] [fanin_window=60] [fanin_hosts=10]'
#   fanin=RAMPS also runs `coord-sim fanin` (goal sessions-2000-attached: N sessions over fanin_hosts host daemons, one
#   controller) at those ramps when the crate has it, and the report carries its tables (fanin=0 skips it).
#   coord-sim-linux.sh build-only: only the release builds (the perf cron builds under a cap of its own).
# Keeps the run's raw files and report in $COORD_SIM_KEEP (default: $FAST_CHECKS_OUT/coord-sim when set, so a
# cmux-ci run returns them as its artifact). Prints the report (coord-sim-run.v1) on one line, then its rows as one
# JSON object ({"rows": [...]}) on the last line: the report perf-cron.py's coord-sim part reads (rows
# webui.coord_sim.*), and the one scripts/bench/benches/coord_sim.py ingests.
set -euo pipefail
coordinators=3
rate=10
seconds=300
seed=1
readers=4
fanin=50,200
fanin_window=60
fanin_hosts=10
build_only=0
for arg in "$@"; do
  case "$arg" in
    coordinators=*) coordinators="${arg#coordinators=}" ;;
    rate=*) rate="${arg#rate=}" ;;
    seconds=*) seconds="${arg#seconds=}" ;;
    seed=*) seed="${arg#seed=}" ;;
    readers=*) readers="${arg#readers=}" ;;
    fanin=*) fanin="${arg#fanin=}" ;;
    fanin_window=*) fanin_window="${arg#fanin_window=}" ;;
    fanin_hosts=*) fanin_hosts="${arg#fanin_hosts=}" ;;
    build-only) build_only=1 ;;
    *) echo "coord-sim-linux.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
root="$(git rev-parse --show-toplevel)"
cd "$root"
# A bare runner (the perf cron's Linux part): the pinned Rust and the native build tools.
command -v cargo >/dev/null || ./scripts/install-rust-ci.sh
command -v clang >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq clang libclang-dev pkg-config; }
export PATH="$HOME/.cargo/bin:$PATH"
crate="$root/cmux-tui/crates/coord-sim"
(cd "$root/cmux-tui" && cargo build --locked --release -p acpmux --bin acpmux 2>&1 | tail -n 3)
(cd "$crate" && cargo build --locked --release 2>&1 | tail -n 3)
[[ "$build_only" == 1 ]] && exit 0
tui_target="$(cd "$root/cmux-tui" && cargo metadata --locked --no-deps --format-version 1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
sim_target="$(cd "$crate" && cargo metadata --locked --no-deps --format-version 1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
sim="$sim_target/release/coord-sim"
keep="${COORD_SIM_KEEP:-${FAST_CHECKS_OUT:+$FAST_CHECKS_OUT/coord-sim}}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
run_dir="${keep:-$work/run}"
mkdir -p "$run_dir" "$work/chats"
# The built-in default shape (shape.rs DEFAULT_SHAPE); shapes/default.json became lane-host.json in cmux#47315, which
# left this path naming no file, and every coord-sim part since failed at `gen`. COORD_SIM_SHAPE picks another.
shape="${COORD_SIM_SHAPE:-$crate/shapes/leo-peak.json}"
[[ -f "$shape" ]] || { echo "coord-sim-linux: no shape file $shape" >&2; exit 1; }
"$sim" gen --format script --shape "$shape" --seed "$seed" --coordinators "$coordinators" --scale 1 \
  --out "$work/chats" >&2
"$sim" drive --coordinators "$coordinators" --rate "$rate" --target acpmux --duration "$seconds" --seed "$seed" \
  --readers "$readers" --shape "$shape" --scripts "$work/chats" --acpmux "$tui_target/release/acpmux" --out "$run_dir" >&2
fanin_args=()
if [[ "$fanin" != 0 && -f "$crate/src/fanin.rs" ]]; then
  # Under /tmp (sticky): acpmux refuses a state directory below a writable, non-sticky ancestor.
  fanin_dir="$(mktemp -d /tmp/coord-sim-fanin.XXXXXX)"
  chmod 700 "$fanin_dir"
  ulimit -n 65536 2>/dev/null || true
  max_n="${fanin##*,}"
  "$sim" fanin --hosts "$fanin_hosts" --sessions "$max_n" --ramps "$fanin" --rate 0.333 --window-s "$fanin_window" \
    --out "$fanin_dir" --acpmux "$tui_target/release/acpmux" --wall-clock-cap 1200 2>&1 | grep -v '^FANIN_SUMMARY' >&2 || true
  "$sim" fanin teardown --out "$fanin_dir" >&2 || true
  if [[ -f "$fanin_dir/fanin-summary.json" ]]; then
    fanin_args=(--fanin "$fanin_dir")
    [[ -z "$keep" ]] || cp "$fanin_dir/fanin-summary.json" "$run_dir/"
  fi
fi
# The driver's run.json carries no commit or shape hash: the report takes them here.
"$sim" report "$run_dir" --rows --commit "$(git rev-parse HEAD)" --seed "$seed" \
  --shape-hash "$(sha256sum "$shape" | cut -c1-16)" ${fanin_args[@]+"${fanin_args[@]}"}
[[ -z "${fanin_dir:-}" ]] || rm -rf "$fanin_dir"
