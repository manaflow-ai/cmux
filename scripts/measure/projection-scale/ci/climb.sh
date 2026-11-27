#!/usr/bin/env bash
# One hill climb on a runner (cmux-ci test --not-tests): builds slice_bench, climbs on a git copy of
# cmux-tui/crates (about 300 MB) at each profile named, rows into $FAST_CHECKS_OUT (or ./climb-out).
# slice_bench is found where measure.py looks: $CARGO_TARGET_DIR, else cmux-tui/target.
set -uo pipefail
cd "$(dirname "$0")/../../../.." || exit 2
out="${FAST_CHECKS_OUT:-$PWD/climb-out}"; mkdir -p "$out"
(cd cmux-tui && cargo build -q --release -p cmux-projection --example slice_bench) || exit 1
tree="$(mktemp -d)"
git archive HEAD cmux-tui/crates | tar -x -C "$tree"
(cd "$tree" && git init -q && git add -A && git -c user.email=climb@local -c user.name=climb commit -qm tree)
command -v rg >/dev/null || echo "climb: rg missing on this runner" >&2
status=0
for profile in ${CLIMB_PROFILES:-store-v6-1-low store-v6-8}; do
  python3 -I scripts/measure/projection-scale/hillclimb.py "$tree" --profile "$profile" \
    --steps "${CLIMB_STEPS:-rg,gitstatus}" --rounds 2 --out "$out/climb-$profile" || status=1
done
exit "$status"
