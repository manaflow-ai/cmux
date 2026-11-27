#!/usr/bin/env bash
# The acpmux lib's release build time, binary size and run-time numbers at each
# codegen-units count, from one warm target directory. Measures; changes nothing.
#
#   cmux-tui/scripts/acpmux-cgu-sweep.sh [CGU...]   (default: 1 4 8 16)
#
# For each count it touches acpmux's sources and rebuilds acpmux-standalone with
# the shipping features, at 4 jobs (the darwin leg's share for the group) and at
# every core, then runs the hub carrier's pipe numbers (an on-demand acpmux test)
# against a lib built at that count. Env: SWEEP_TARGET (default: the host),
# SWEEP_JOBS (default: "4 <cores>"), SWEEP_RUNTIME=0 skips the run-time numbers.
set -euo pipefail
tui="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(cd "$tui/.." && pwd)"
cd "$tui"
cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
target=${SWEEP_TARGET:-$(rustc -vV | sed -n 's/^host: //p')}
jobs_list=${SWEEP_JOBS:-"4 $cores"}
cgus=("$@"); ((${#cgus[@]})) || cgus=(1 4 8 16)
features=$("$repo_root/scripts/ci/acpmux-build-features.sh" "$tui/crates/acpmux/Cargo.toml" "$target" acpmux || true)
export CARGO_TARGET_DIR="${SWEEP_TARGET_DIR:-$tui/target/cgu-sweep}"
cfg() { printf '%s\n' "--config=profile.release.package.acpmux.codegen-units=$1"; }
build() { # <cgu> <jobs>
  # shellcheck disable=SC2086 # $features is one flag or empty
  cargo build --release --locked --target "$target" -j "$2" -p acpmux-standalone --bin acpmux-standalone \
    $features "$(cfg "$1")"
}
echo "sweep: host $(uname -sm), $cores cores, target $target, features ${features:-none}, rustc $(rustc -V)"
echo "sweep: warm-up build (dependencies) at codegen-units 1"
start=$(date +%s); build 1 "$cores" >/dev/null 2>&1 || build 1 "$cores"
echo "sweep: warm-up $(( $(date +%s) - start )) s"
bin="$CARGO_TARGET_DIR/$target/release/acpmux-standalone"
printf '%s\n' "| codegen-units | jobs | rebuild s | binary bytes |" "|---|---|---|---|" > "$CARGO_TARGET_DIR/sweep.md"
for n in "${cgus[@]}"; do
  for j in $jobs_list; do
    touch "$tui/crates/acpmux/src/lib.rs"
    start=$(date +%s)
    build "$n" "$j" >/dev/null 2>&1 || build "$n" "$j"
    s=$(( $(date +%s) - start ))
    size=$(stat -c %s "$bin" 2>/dev/null || stat -f %z "$bin")
    echo "sweep: codegen-units $n, jobs $j: rebuild $s s, binary $size bytes"
    printf '| %s | %s | %s | %s |\n' "$n" "$j" "$s" "$size" >> "$CARGO_TARGET_DIR/sweep.md"
  done
  if [[ "${SWEEP_RUNTIME:-1}" != 0 ]]; then
    echo "sweep: codegen-units $n: hub carrier pipe numbers"
    cargo test --release --locked --target "$target" -j "$cores" -p acpmux --features hub-carrier "$(cfg "$n")" \
      --test hub_carrier hub_carrier_pipe_numbers -- --ignored --nocapture 2>&1 \
      | grep -vE '^\s+(Compiling|Downloaded|Downloading)' | tail -20 | sed "s/^/sweep: cgu $n runtime: /"
  fi
done
echo "sweep: table"
cat "$CARGO_TARGET_DIR/sweep.md"
