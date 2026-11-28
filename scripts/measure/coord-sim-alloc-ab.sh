#!/usr/bin/env bash
# coord-sim (streaming coordinator chats and the fan-in ramp) against acpmux on glibc's malloc and on mimalloc
# (bench feature mimalloc-gnu), from one head, interleaved REPEAT times (cmux#58257). Both build with no LTO and 16
# codegen units into a target of their own, as infinite-items-linux.sh alloc_ab=1 does. Each run prints its report's
# rows line tagged `CSAB arm=A rI`. Other arguments pass to coord-sim-linux.sh.
#   cmux-ci test -- bash -c 'scripts/measure/coord-sim-alloc-ab.sh [repeat=2] [arms=glibc,mimalloc,glibc-a4] [seconds=120] [fanin=50,200]'
# glibc-aN (after glibc in arms=) runs the glibc binary with MALLOC_ARENA_MAX=N.
set -euo pipefail
repeat=2
arms="glibc mimalloc"
pass=()
for arg in "$@"; do
  case "$arg" in
    repeat=*) repeat="${arg#repeat=}" ;;
    arms=*) arms="${arg#arms=}"; arms="${arms//,/ }" ;;
    *) pass+=("$arg") ;;
  esac
done
root="$(git rev-parse --show-toplevel)"
export CARGO_PROFILE_RELEASE_LTO=false CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16
export CARGO_TARGET_DIR="${RUNNER_TEMP:-/tmp}/coord-sim-alloc-ab-target"
command -v cargo >/dev/null || "$root/scripts/install-rust-ci.sh"
export PATH="$HOME/.cargo/bin:$PATH"
bins="$(mktemp -d)"
trap 'rm -rf "$bins"' EXIT
for arm in $arms; do
  if [[ "$arm" == glibc-a* ]]; then
    # glibc with fewer arenas than acpmux's own 16 (malloc_arenas.rs): the glibc binary under MALLOC_ARENA_MAX.
    printf '#!/bin/sh\nexec env MALLOC_ARENA_MAX=%s "%s" "$@"\n' "${arm#glibc-a}" "$bins/acpmux-glibc" >"$bins/acpmux-$arm"
    chmod +x "$bins/acpmux-$arm"
    continue
  fi
  feat=(); [[ "$arm" == mimalloc ]] && feat=(--features mimalloc-gnu)
  t0=$SECONDS
  (cd "$root/cmux-tui" && cargo build --locked --release -p acpmux --bin acpmux ${feat[@]+"${feat[@]}"} 2>&1 | tail -n 3)
  cp "$CARGO_TARGET_DIR/release/acpmux" "$bins/acpmux-$arm"
  echo "CSAB-BUILD arm=$arm seconds=$((SECONDS - t0))"
done
unset CARGO_TARGET_DIR CARGO_PROFILE_RELEASE_LTO CARGO_PROFILE_RELEASE_CODEGEN_UNITS
status=0
for r in $(seq 1 "$repeat"); do
  for arm in $arms; do
    COORD_SIM_KEEP="$bins/run-$arm-$r" bash "$root/scripts/measure/coord-sim-linux.sh" acpmux_bin="$bins/acpmux-$arm" \
      ${pass[@]+"${pass[@]}"} >"$bins/out" 2>"$bins/err" || { status=$?; tail -n 5 "$bins/err" | sed "s/^/CSAB arm=$arm r$r ERR /"; }
    tail -n 1 "$bins/out" | sed "s/^/CSAB arm=$arm r$r /"
  done
done
exit "$status"
