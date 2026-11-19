#!/usr/bin/env bash
# coord-sim on Linux: several synthetic coordinator chats at once against a release acpmux (crate
# cmux-tui/crates/coord-sim). Builds coord-sim and acpmux, generates the chats from the checked-in shape (histograms
# only, no transcript), drives them, then `coord-sim report`. Run at a pushed head:
#   cmux-ci test --setup rust -- bash -c 'scripts/measure/coord-sim-linux.sh [coordinators=3] [rate=10] [seconds=300] [seed=1] [readers=4]'
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
build_only=0
for arg in "$@"; do
  case "$arg" in
    coordinators=*) coordinators="${arg#coordinators=}" ;;
    rate=*) rate="${arg#rate=}" ;;
    seconds=*) seconds="${arg#seconds=}" ;;
    seed=*) seed="${arg#seed=}" ;;
    readers=*) readers="${arg#readers=}" ;;
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
shape="$crate/shapes/default.json"
"$sim" gen --format script --shape "$shape" --seed "$seed" --coordinators "$coordinators" --scale 1 \
  --out "$work/chats" >&2
"$sim" drive --coordinators "$coordinators" --rate "$rate" --target acpmux --duration "$seconds" --seed "$seed" \
  --readers "$readers" --shape "$shape" --scripts "$work/chats" --acpmux "$tui_target/release/acpmux" --out "$run_dir" >&2
# The driver's run.json carries no commit or shape hash: the report takes them here.
"$sim" report "$run_dir" --rows --commit "$(git rev-parse HEAD)" --seed "$seed" \
  --shape-hash "$(sha256sum "$shape" | cut -c1-16)"
