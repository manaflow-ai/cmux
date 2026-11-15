#!/usr/bin/env bash
# What acpmux holds per chat in the infinite-items run (CMUX-571): a dhat-heap acpmux at each count, its peak heap
# by allocation site (scripts/measure/dhat-top.py). Run at a pushed head through cmux-ci test:
#   scripts/measure/infinite-items-profile.sh [counts=10,300]
set -euo pipefail
counts="10,300"
for arg in "$@"; do
  case "$arg" in
    counts=*) counts="${arg#counts=}" ;;
    *) echo "infinite-items-profile.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
root="$(git rev-parse --show-toplevel)"
bash "$root/scripts/measure/infinite-items-linux.sh" build-only
export PATH="$HOME/.cargo/bin:$PATH"
cd "$root/cmux-tui"
target="$(cargo metadata --locked --no-deps --format-version 1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
dhat_target="$(mktemp -d)"
CARGO_TARGET_DIR="$dhat_target" cargo build --locked --release -p acpmux --bin acpmux --features dhat-heap 2>&1 | tail -n 3
cd "$root"
ulimit -n 65536 2>/dev/null || true
for n in ${counts//,/ }; do
  out="$dhat_target/dhat-$n.json"
  ACPMUX_DHAT_OUT="$out" python3 scripts/measure/infinite-items.py --acpmux "$dhat_target/release/acpmux" \
    --tui "$target/release/cmux-tui" --counts "$n" --days 0 --window 2 --park-idle 2>&1 | grep -E "^INFINITE(-PERITEM|-ROLE)? |park-tabs" || true
  if [ -f "$out" ]; then python3 scripts/measure/dhat-top.py "$out" 30; else echo "DHAT none for $n"; fi
done
rm -rf "$dhat_target"
