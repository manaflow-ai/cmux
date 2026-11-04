#!/bin/bash
# The dependency-cache bench for .github/workflows/machine-join-e2e.yml (bench=deps): run by
# machine-join-e2e.ts as the disposable user while its machine is joined to the development platform.
#
#   deps-bench.sh ACPMUX
#
# The workflow lays out the base (the script's parent's parent): bin/ (acpmux, bun, this script),
# toolchain/ (the pinned Rust sysroot) and bench/ (cmux-tui's sources, the webviews manifest and
# lockfile). Every cache lives under bench/, never in the home the harness scans for secrets.
#
# For Cargo (cmux-tui) and bun (webviews), from empty caches each time:
#   cold  the plain install (`cargo fetch --locked`, `bun install --frozen-lockfile`)
#   seed  `acpmux machine deps warm`: a restore, or (on a miss) the install and an upload
#   warm  `acpmux machine deps warm` again: the restore the seed guarantees, then the install
# The last line is one JSON object of numbers and plain strings, the bench's evidence.
set -euo pipefail

acpmux="$1"
base="$(cd -- "$(dirname -- "$0")/.." && pwd)"
bench="$base/bench"
export PATH="$base/toolchain/bin:$base/bin:/usr/local/bin:/usr/bin:/bin"
export CARGO_HOME="$bench/cargo-home"
export BUN_INSTALL="$bench/bun-home"
export BUN_INSTALL_CACHE_DIR="$bench/bun-cache"
export XDG_CACHE_HOME="$bench/xdg-cache"
export TMPDIR="$bench/tmp"
export CARGO_TERM_COLOR=never NO_COLOR=1
mkdir -p -- "$TMPDIR" "$bench/logs"

cargo_dir="$bench/cmux-tui"
bun_dir="$bench/webviews"

now() { date +%s%N; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", (b - a) / 1e9 }'; }

wipe() {
  case "$1" in
    cargo) rm -rf -- "$CARGO_HOME" ;;
    bun) rm -rf -- "$bun_dir/node_modules" "$BUN_INSTALL_CACHE_DIR" "$BUN_INSTALL" ;;
  esac
  mkdir -p -- "$CARGO_HOME"
}

# Runs the command with its output in a log; on failure prints the log's tail and exits.
logged() {
  local name="$1"
  shift
  if ! "$@" >"$bench/logs/$name.log" 2>&1; then
    echo "$name failed:"
    tail -n 20 -- "$bench/logs/$name.log"
    exit 1
  fi
}

declare -A out
put() { out["$1"]="$2"; }

# One `machine deps warm` of DIR, timed; its report's fields for ECOSYSTEM go in under PREFIX.
warm() {
  local prefix="$1" eco="$2" dir="$3" t0 t1 json
  json="$bench/logs/$prefix.json"
  t0="$(now)"
  if ! "$acpmux" machine deps warm "$dir" --json >"$json" 2>"$bench/logs/$prefix.log"; then
    echo "$prefix failed:"
    tail -n 20 -- "$bench/logs/$prefix.log"
    exit 1
  fi
  t1="$(now)"
  put "${prefix}S" "$(secs "$t0" "$t1")"
  local field
  for field in restore upload fetchMs unpackMs installMs packMs uploadMs archiveBytes installOk error; do
    local v
    v="$(jq -r --arg eco "$eco" --arg f "$field" '[.projects[] | select(.ecosystem == $eco)][0][$f] // empty' -- "$json" 2>/dev/null || true)"
    if [ -n "$v" ]; then put "${prefix}${field^}" "$v"; fi
  done
}

for eco in cargo bun; do
  if [ "$eco" = cargo ]; then dir="$cargo_dir"; install=(cargo fetch --locked); else dir="$bun_dir"; install=(bun install --frozen-lockfile); fi

  wipe "$eco"
  t0="$(now)"
  (cd -- "$dir" && logged "${eco}Cold" "${install[@]}")
  t1="$(now)"
  put "${eco}ColdS" "$(secs "$t0" "$t1")"
  echo "$eco cold: ${out[${eco}ColdS]}s"

  wipe "$eco"
  warm "${eco}Seed" "$eco" "$dir"
  echo "$eco seed: ${out[${eco}SeedS]}s (${out[${eco}SeedRestore]:-?}, upload ${out[${eco}SeedUpload]:-none})"

  wipe "$eco"
  warm "${eco}Warm" "$eco" "$dir"
  echo "$eco warm: ${out[${eco}WarmS]}s (${out[${eco}WarmRestore]:-?})"
  # The CLI exits 0 when the cache is off or a restore fails; a warm number that was not a restore is no number.
  if [ "${out[${eco}WarmRestore]:-}" != restored ]; then
    echo "$eco warm did not restore from the cache (${out[${eco}WarmRestore]:-no report}): $(tail -n 5 -- "$bench/logs/${eco}Warm.log" | tr -cd 'A-Za-z0-9 ._:/-' | cut -c1-300)"
    exit 1
  fi
done

# Numbers stay numbers; everything else is a string.
args=()
for k in "${!out[@]}"; do args+=(--arg "$k" "${out[$k]}"); done
jq -cn "${args[@]}" '$ARGS.named | with_entries(.value |= (tonumber? // .))'
