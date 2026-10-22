#!/usr/bin/env bash
# Build and run the cmux-tui libFuzzer targets with the pinned stable toolchain
# (no cargo-fuzz, no nightly). Linux only (CI, rbx); never on the laptop.
#
# usage: fuzz/run.sh [--seconds N] [--jobs N] [--build-only] [--replay] TARGET... | all
#   --seconds N   fuzz each target for N seconds (default 60)
#   --build-only  build the targets and stop
#   --replay      run every file in corpus/TARGET and regressions/TARGET once
#                 (no fuzzing) and fail on the first crash
#   --list        print the target names
#
# Inputs: corpus/TARGET (checked-in seeds, read only) and
# regressions/TARGET (crash inputs; each one must pass once its fix lands).
# Outputs under $FUZZ_OUT (default $CARGO_TARGET_DIR/fuzz-out or fuzz/target/fuzz-out):
#   corpus/TARGET     the corpus libFuzzer grows (keep it between runs)
#   artifacts/TARGET  crash-*, oom-*, timeout-* inputs
#   logs/TARGET.log   the libFuzzer log with the stats line
# Exit status: 0 when every target ran clean; 1 when any target found a crash.
set -euo pipefail

FUZZ_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$FUZZ_DIR"

seconds=60
build_only=0
replay=0
targets=()
while [ $# -gt 0 ]; do
  case "$1" in
    --seconds) seconds=$2; shift 2 ;;
    --build-only) build_only=1; shift ;;
    --replay) replay=1; shift ;;
    --list) sed -n 's/^name = "\(.*\)"$/\1/p' Cargo.toml | grep -v '^cmux-tui-fuzz$'; exit 0 ;;
    -h|--help) sed -n '2,19p' "$FUZZ_DIR/run.sh"; exit 0 ;;
    all) mapfile -t -O "${#targets[@]}" targets < <("$FUZZ_DIR/run.sh" --list); shift ;;
    -*) echo "run.sh: unknown option $1" >&2; exit 2 ;;
    *) targets+=("$1"); shift ;;
  esac
done
if [ ${#targets[@]} -eq 0 ]; then
  echo "run.sh: name a target or 'all' (--list prints them)" >&2
  exit 2
fi

host=$(rustc -vV | sed -n 's/^host: //p')
# Sanitizer coverage for libFuzzer on stable rustc, the flags cargo-fuzz
# passes minus the nightly-only sanitizer (-Zsanitizer): edge counters,
# the PC table, compare tracing, plus debug assertions and overflow checks.
# --target keeps these flags off build scripts and proc macros.
export RUSTFLAGS="--cfg fuzzing -Cpasses=sancov-module \
-Cllvm-args=-sanitizer-coverage-level=4 \
-Cllvm-args=-sanitizer-coverage-inline-8bit-counters \
-Cllvm-args=-sanitizer-coverage-pc-table \
-Cllvm-args=-sanitizer-coverage-trace-compares \
-Cdebug-assertions -Coverflow-checks"
target_dir=${CARGO_TARGET_DIR:-$FUZZ_DIR/target}/fuzz
out=${FUZZ_OUT:-$target_dir-out}

bin_args=()
for target in "${targets[@]}"; do bin_args+=(--bin "$target"); done
# Not --locked: a fuzzed crate that gains a dependency in ../Cargo.lock would
# otherwise break this build until someone refreshes fuzz/Cargo.lock. Without
# --locked cargo keeps every version already pinned here and only adds the new
# package; commit the refreshed lock when you see it change.
CARGO_TARGET_DIR=$target_dir cargo build --release --target "$host" "${bin_args[@]}"
[ "$build_only" = 1 ] && exit 0

status=0
for target in "${targets[@]}"; do
  binary=$target_dir/$host/release/$target
  if [ "$replay" = 1 ]; then
    inputs=()
    for dir in corpus/$target regressions/$target; do
      [ -d "$dir" ] && while IFS= read -r -d '' file; do inputs+=("$file"); done \
        < <(find "$dir" -type f ! -name '.*' -print0)
    done
    [ ${#inputs[@]} -eq 0 ] && continue
    echo "== replay $target: ${#inputs[@]} input(s)"
    "$binary" -runs=1 "${inputs[@]}" || { echo "== $target: an input crashed"; status=1; }
    continue
  fi
  mkdir -p "$out/corpus/$target" "$out/artifacts/$target" "$out/logs"
  seeds=()
  [ -d "corpus/$target" ] && seeds+=("corpus/$target")
  [ -d "regressions/$target" ] && seeds+=("regressions/$target")
  echo "== fuzz $target for ${seconds}s"
  set +e
  "$binary" "$out/corpus/$target" "${seeds[@]}" \
    -max_total_time="$seconds" -timeout=20 -rss_limit_mb=4096 -max_len=65536 \
    -print_final_stats=1 -artifact_prefix="$out/artifacts/$target/" \
    > "$out/logs/$target.log" 2>&1
  code=$?
  set -e
  execs=$(sed -n 's/^stat::number_of_executed_units: *//p' "$out/logs/$target.log" | tail -1 || true)
  cov=$(grep -o 'cov: [0-9]*' "$out/logs/$target.log" | tail -1 || true)
  echo "== $target: exit $code, ${execs:-?} execs in ${seconds}s, ${cov:-cov: ?}"
  if [ "$code" != 0 ]; then
    status=1
    echo "== $target FOUND A CRASH; tail of $out/logs/$target.log:"
    tail -60 "$out/logs/$target.log"
    ls -1 "$out/artifacts/$target"
  fi
done
exit "$status"
