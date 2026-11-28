#!/usr/bin/env bash
# The app FFI's per-keystroke paths (cmux-app-ffi examples/hot_path_bench.rs)
# at each release opt-level given (default: 3 z), under duress: every CPU but
# one kept busy for the whole run. The per-package opt-level pins in
# cmux-app-ffi/Cargo.toml apply as they do in the app. Prints the example's
# `hot-path NAME ns_per_call=N` lines prefixed with the opt-level.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="$(mktemp -d "${TMPDIR:-/tmp}/app-ffi-hot-bench.XXXXXX")"
burners=()
cleanup() { for pid in ${burners[@]+"${burners[@]}"}; do kill "$pid" 2>/dev/null || true; done; rm -rf "$out"; }
trap cleanup EXIT
opts=("$@")
((${#opts[@]})) || opts=(3 z)
cd "$root/cmux-tui/crates/cmux-app-ffi"
for opt in "${opts[@]}"; do
  CARGO_PROFILE_RELEASE_OPT_LEVEL="$opt" CARGO_TARGET_DIR="$out/target-$opt" \
    cargo build --locked --release --example hot_path_bench >&2
done
n=$(( $(nproc) - 1 )); (( n > 0 )) || n=1
for _ in $(seq "$n"); do (while :; do :; done) & burners+=($!); done
echo "duress: $n busy loops on $(nproc) CPUs"
for round in 1 2; do
  for opt in "${opts[@]}"; do
    "$out/target-$opt/release/examples/hot_path_bench" | sed "s/^/opt=$opt round=$round /"
  done
done
