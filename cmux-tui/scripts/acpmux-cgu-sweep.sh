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
# Each rebuild also prints acpmux's unit from cargo's --timings report: its
# whole time, and rmeta_time, when its metadata was ready and dependents could
# start (the front end; the rest is code generation). That bounds what a crate
# split could overlap.
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
  cargo build --release --locked --timings --target "$target" -j "$2" -p acpmux-standalone --bin acpmux-standalone \
    $features "$(cfg "$1")"
}
unit_times() { # acpmux's and acpmux-standalone's units in the newest --timings report
  local report
  report=$(ls -t "$CARGO_TARGET_DIR"/cargo-timings/cargo-timing-*.html 2>/dev/null | head -1)
  [[ -n "$report" ]] || return 0
  # The report's unit list is pretty-printed JSON: one unit spans many lines.
  tr -d '\n' < "$report" | grep -oE '"name": *"acpmux(-standalone)?",[^}]{0,1500}' \
    | while read -r unit; do
        grep -oE '"(name|target|duration|rmeta_time)": *("[^"]*"|[0-9.]+)' <<<"$unit" | paste -sd " " | sed 's/^/sweep: unit /'
      done || true
  # SWEEP_REPORT_DIR keeps the whole report, for a layout this does not read.
  [[ -z "${SWEEP_REPORT_DIR:-}" ]] || { mkdir -p "$SWEEP_REPORT_DIR" && cp "$report" "$SWEEP_REPORT_DIR/"; }
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
    unit_times
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
