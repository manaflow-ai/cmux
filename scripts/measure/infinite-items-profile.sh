#!/usr/bin/env bash
# What the daemons hold per item in the infinite-items run (CMUX-571): dhat-heap builds of acpmux and cmux-tui at
# each count, every tab parked (--park-idle) so only the daemons' own records are left; their heap at exit by
# allocation site (scripts/measure/dhat-top.py). Run at a pushed head through cmux-ci test:
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
dhat_target="$(mktemp -d)"
trap 'rm -rf "$dhat_target"' EXIT
CARGO_TARGET_DIR="$dhat_target" cargo build --locked --release -p acpmux --bin acpmux --features dhat-heap 2>&1 | tail -n 3
CARGO_TARGET_DIR="$dhat_target" cargo build --locked --release -p cmux-tui --bin cmux-tui --bin cmux-tui-host \
  --features dhat-heap 2>&1 | tail -n 3
cd "$root"
ulimit -n 65536 2>/dev/null || true
for n in ${counts//,/ }; do
  acp="$dhat_target/acpmux-$n.json"
  tui="$dhat_target/cmux-tui-$n.json"
  ACPMUX_DHAT_OUT="$acp" CMUX_TUI_DHAT_OUT="$tui" python3 scripts/measure/infinite-items.py \
    --acpmux "$dhat_target/release/acpmux" --tui "$dhat_target/release/cmux-tui" --counts "$n" --days 1 --window 2 \
    --park-idle 2>&1 | grep -E "^INFINITE(-PERITEM|-ROLE)? |park-tabs" || true
  for out in "$acp" "$tui"; do
    if [ -f "$out" ]; then python3 scripts/measure/dhat-top.py "$out" 30; else echo "DHAT none: $out"; fi
  done
done
