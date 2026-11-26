#!/usr/bin/env bash
# An ABBA duress comparison of one acpmux change, on a CI Linux runner, from the repo root:
#   cmux-ci test --setup rust --timeout 10800 --artifact DIR -- \
#     bash cmux-tui/crates/coord-sim/src/fanin/abba.sh BASE [RAMPS] [WINDOW_S] [HOSTS] [ROUNDS]
# BASE is the commit the change sits on: the base daemon is this checkout with
# cmux-tui/crates/acpmux as BASE has it, the head daemon this checkout as it is. Runs ci.sh four
# times (base, head, head, base) with each daemon in turn, samples every host daemon's CPU each
# second, and writes abba.md: per run the hosts' CPU per prompt over each fan-out burst (above the
# idle rate of the 10 s before it, divided by the sessions), the fan-out spread and lost/dup.
set -uo pipefail
BASE=${1:?usage: abba.sh BASE [RAMPS] [WINDOW_S] [HOSTS] [ROUNDS]}
shift
ROOT=$(pwd)
OUT=${FAST_CHECKS_OUT:-/tmp/abba-out}
HERE=cmux-tui/crates/coord-sim/src/fanin
mkdir -p "$OUT"
export CARGO_TARGET_DIR=$ROOT/target-fanin
BINS=$(mktemp -d /tmp/abba-bin.XXXXXX)
git cat-file -e "$BASE^{commit}" 2>/dev/null || git fetch --quiet --depth=1 origin "$BASE" \
  || { echo "ABBA: cannot fetch base $BASE"; exit 1; }
echo "ABBA: base $BASE, head $(git rev-parse HEAD); acpmux files that differ:"
git diff --stat "$BASE" HEAD -- cmux-tui/crates/acpmux | tail -20
build() {
  (cd cmux-tui && cargo build --release -p acpmux --bin acpmux) || { echo "ABBA: $1 build failed"; exit 1; }
  cp "$CARGO_TARGET_DIR/release/acpmux" "$BINS/$1"
}
build head
git checkout "$BASE" -- cmux-tui/crates/acpmux || { echo "ABBA: cannot check out base acpmux"; exit 1; }
build base
git checkout HEAD -- cmux-tui/crates/acpmux
git diff --quiet HEAD -- cmux-tui/crates/acpmux || { echo "ABBA: head acpmux not restored"; exit 1; }

for run in base1 head1 head2 base2; do
  bin=$BINS/${run%[0-9]}
  mkdir -p "$OUT/$run"
  python3 -I "$ROOT/$HERE/abba.py" sample "$OUT/$run/hostcpu.ndjson" &
  sampler=$!
  echo "ABBA: $run ($bin)"
  FAST_CHECKS_OUT=$OUT/$run FANIN_ACPMUX_BIN=$bin bash "$HERE/ci.sh" "$@" 2>&1 | grep '^FANIN n=\|^FANIN exit\|ERROR'
  kill "$sampler" 2>/dev/null
  wait "$sampler" 2>/dev/null
done
rm -rf "$BINS"
python3 -I "$ROOT/$HERE/abba.py" table "$OUT" | tee "$OUT/abba.md"
