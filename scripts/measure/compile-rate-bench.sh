#!/usr/bin/env bash
# A machine's maximum cold compile rate, so hardware classes compare from one harness: a clean
# `cargo build --release` of one cmux-tui package (default acpmux: about 650 crates, C builds for
# sqlite, zstd and mimalloc, no zig), with no compiler cache and no incremental state, timed at
# jobs = the performance cores and at jobs = every core. Leo, 2026-11-26 (ask-b9328bff38): "pls dont
# just guess. look at max rate stuff. the compiles the time the speed etc. efficiency core things are
# slower so". The two modes show what the efficiency cores add; the wall time of the all-cores pass
# is the rate a buy decision compares (cmuxterm-hq build-fleet/mini-ops/hw_buy.py reads these lines).
# Run alone on an idle worker, one class at a time (or pin a worker with --target-worker):
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/compile-rate-bench.sh \
#     --ref SHA [--target-worker WORKER] [--arg runs=2] [--arg crate=acpmux] \
#     --artifact .build/artifacts/compile-rate-bench.txt
# A Linux worker runs it too (--os linux): pcores = nproc and ecores = 0 there.
#
# Output (the step log and .build/artifacts/compile-rate-bench.txt):
#   COMPILE-RATE-MACHINE host=<short name, lower case> model=<hw.model> chip="<brand string>" ncpu=N pcores=N ecores=N mem_gib=N os=<version>
#   COMPILE-RATE-SOURCE sha=<commit> crate=<name>
#   COMPILE-RATE-LOAD before|after <load averages>
#   COMPILE-RATE-BENCH crate=<name> mode=pcores|all jobs=N run=I wall_s=X.XX user_s=X.XX sys_s=X.XX
# A value with a space is in double quotes. (hw_buy.py parses exactly these fields.)
# Dependencies are fetched first (`cargo fetch`, untimed); each timed pass starts from an empty
# target directory, which the script removes when it ends.
set -euo pipefail
export LC_ALL=C

main() {
  # shellcheck source-path=SCRIPTDIR source=../cmux-next/lib/fleet-only.sh
  source "$(dirname "${BASH_SOURCE[0]}")/../cmux-next/lib/fleet-only.sh"

  local runs=2 crate=acpmux arg
  for arg in "$@"; do
    case "$arg" in
      runs=*) runs="${arg#runs=}" ;;
      crate=*) crate="${arg#crate=}" ;;
      *) echo "compile-rate-bench.sh: unknown argument '$arg' (runs=N, crate=NAME)" >&2; exit 2 ;;
    esac
  done
  [[ "$runs" =~ ^[1-9]$ ]] || { echo "compile-rate-bench.sh: runs must be 1-9 (got '$runs')" >&2; exit 2; }
  [[ "$crate" =~ ^[a-z0-9][a-z0-9_-]*$ ]] ||
    { echo "compile-rate-bench.sh: crate must be a cmux-tui package name (got '$crate')" >&2; exit 2; }

  cmux_next_require_fleet compile-rate-bench.sh "cargo build --release" "none (a measurement)" \
    "cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/compile-rate-bench.sh --ref SHA"

  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
  [[ -f "$root/cmux-tui/Cargo.toml" ]] || { echo "compile-rate-bench.sh: no cmux-tui/Cargo.toml" >&2; exit 2; }
  mkdir -p "$root/.build/artifacts"
  report="$root/.build/artifacts/compile-rate-bench.txt"
  : >"$report"
  target="$root/.build/compile-rate-bench-target"
  trap cleanup EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT

  # The toolchain the repo pins (rustup's shim first, as replay-build-bench.sh); no compiler cache and
  # no incremental state, so every pass compiles every crate.
  cd "$root/cmux-tui"
  local toolchain_cargo
  toolchain_cargo="$(rustup which cargo)"
  PATH="$(dirname "$toolchain_cargo"):$PATH"
  export PATH
  unset RUSTC_WRAPPER CARGO_BUILD_RUSTC_WRAPPER SCCACHE_DIR
  export CARGO_INCREMENTAL=0 CARGO_TARGET_DIR="$target"

  local os host model chip ncpu pcores ecores mem_gib
  os="$(uname -s)"
  host="$(hostname -s 2>/dev/null || hostname)"
  host="$(printf '%s' "${host%%.*}" | tr '[:upper:]' '[:lower:]')"
  if [[ "$os" == Darwin ]]; then
    model="$(sysctl -n hw.model)"
    chip="$(sysctl -n machdep.cpu.brand_string)"
    ncpu="$(sysctl -n hw.ncpu)"
    pcores="$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || echo "$ncpu")"
    ecores="$(sysctl -n hw.perflevel1.logicalcpu 2>/dev/null || echo 0)"
    mem_gib=$(( $(sysctl -n hw.memsize) / 1073741824 ))
    os="$(sw_vers -productVersion)"
  else
    model="$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo unknown)"
    chip="$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -n 1)"
    ncpu="$(nproc)"
    pcores="$ncpu"
    ecores=0
    mem_gib=$(( $(sed -n 's/^MemTotal: *\([0-9]*\) kB/\1/p' /proc/meminfo) / 1048576 ))
    os="$(uname -r)"
  fi
  note "COMPILE-RATE-MACHINE host=$(field "$host") model=$(field "$model") chip=\"$chip\" ncpu=$ncpu pcores=$pcores ecores=$ecores mem_gib=$mem_gib os=$(field "$os")"
  note "COMPILE-RATE-SOURCE sha=$(git rev-parse --short=11 HEAD) crate=$crate"

  cargo fetch --locked >/dev/null

  note "COMPILE-RATE-LOAD before $(uptime | sed 's/.*load averages*: //')"
  local run mode jobs
  for run in $(seq 1 "$runs"); do
    for mode in pcores all; do
      jobs=$ncpu
      [[ "$mode" == pcores ]] && jobs=$pcores
      timed_build "$jobs" "$mode" "$run"
    done
  done
  note "COMPILE-RATE-LOAD after $(uptime | sed 's/.*load averages*: //')"

  local want=$((runs * 2))
  [[ "$(grep -c '^COMPILE-RATE-BENCH ' "$report")" -eq "$want" ]] ||
    { echo "compile-rate-bench.sh: expected $want COMPILE-RATE-BENCH lines" >&2; exit 1; }
}

# One clean release build at JOBS, timed by the shell's `time` (real, user, sys in seconds).
timed_build() {
  local jobs=$1 mode=$2 run=$3 times
  rm -rf "$target"
  local TIMEFORMAT='%R %U %S'
  times="$( { time cargo build --locked --release --offline -p "$crate" -j "$jobs" >/dev/null 2>"$target.log"; } 2>&1 )" || {
    tail -n 40 "$target.log" >&2
    echo "compile-rate-bench.sh: cargo build -p $crate -j $jobs failed" >&2
    exit 1
  }
  local wall user sys
  read -r wall user sys <<<"$times"
  note "COMPILE-RATE-BENCH crate=$crate mode=$mode jobs=$jobs run=$run wall_s=$wall user_s=$user sys_s=$sys"
}

# A value as KEY=VALUE writes it: bare, or in double quotes when it holds a space.
field() {
  case "$1" in
    *[[:space:]]*) printf '"%s"' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

note() { printf '%s\n' "$*" | tee -a "$report"; }

# shellcheck disable=SC2317 # run by the EXIT trap
cleanup() {
  [[ -n "${target:-}" ]] || return 0
  rm -rf "$target" "$target.log"
}

report=/dev/null
target=""
crate=""
main "$@"; exit $?
