#!/usr/bin/env bash
# Linux proxy for scripts/measure/app-ffi-size.sh: builds the app FFI staticlib
# for the host target once per release opt-level (default: 3 z), links each
# alone with --gc-sections into a shared object that exports only the C ABIs,
# and prints `app-ffi-size-linux OPT text=N file=N build_seconds=N`. The
# per-package opt-level pins in cmux-app-ffi/Cargo.toml still apply.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="$(mktemp -d "${TMPDIR:-/tmp}/app-ffi-size-linux.XXXXXX")"
trap 'rm -rf "$out"' EXIT
opts=("$@")
((${#opts[@]})) || opts=(3 z)
cd "$root/cmux-tui/crates/cmux-app-ffi"
for opt in "${opts[@]}"; do
  start=$SECONDS
  CARGO_PROFILE_RELEASE_OPT_LEVEL="$opt" CARGO_TARGET_DIR="$out/target-$opt" \
    cargo build --lib --locked --release >&2
  lib="$out/target-$opt/release/libcmux_app_ffi.a"
  nm -g --defined-only "$lib" 2>/dev/null | awk '$2 == "T" && $3 ~ /^cmux_/ {print $3}' | sort -u > "$out/$opt.exports"
  { echo "{ global:"; sed 's/$/;/' "$out/$opt.exports"; echo "local: *; };"; } > "$out/$opt.map"
  cc -shared -Wl,--gc-sections -Wl,--version-script="$out/$opt.map" \
    -Wl,--whole-archive "$lib" -Wl,--no-whole-archive -lpthread -ldl -lm -o "$out/$opt.so"
  strip "$out/$opt.so"
  text="$(size -A "$out/$opt.so" | awk '$1 == ".text" {print $2}')"
  file="$(stat -c %s "$out/$opt.so")"
  printf 'app-ffi-size-linux %s text=%s file=%s exports=%s build_seconds=%s\n' \
    "$opt" "$text" "$file" "$(wc -l < "$out/$opt.exports")" "$((SECONDS - start))"
done
