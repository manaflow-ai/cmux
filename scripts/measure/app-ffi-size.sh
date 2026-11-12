#!/usr/bin/env bash
# What the app FFI (CCmuxAppFFI, scripts/cmux-next/build-app-ffi.sh) adds to
# Contents/MacOS/cmux, per LTO mode, built the same way on the same Mac:
#
#   cmux-ci run --class exclusive --label measure --script scripts/measure/app-ffi-size.sh \
#     --ref <sha> --artifact artifacts/app-ffi-size.json [--arg=off --arg=fat]
#
# For each mode (default: off fat) it builds the arm64 library as the release
# does, then links it alone, with -dead_strip, into a dylib that exports only
# the C ABIs: what the app's own -dead_strip link keeps of it. Nothing else in
# the app changes with the FFI's LTO mode, so the difference between two modes
# is the difference in MacOS/cmux. Prints one `app-ffi-size MODE text=N
# file=N archive=N` line per mode and writes artifacts/app-ffi-size.json.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="$(mktemp -d "${TMPDIR:-/tmp}/app-ffi-size.XXXXXX")"
trap 'rm -rf "$out"' EXIT
mkdir -p "$root/artifacts"
modes=("$@")
((${#modes[@]})) || modes=(off fat)
(cd "$root/cmux-tui/crates/cmux-app-ffi" && rustup target add aarch64-apple-darwin >/dev/null)
json="{"
for mode in "${modes[@]}"; do
  start=$SECONDS
  CMUX_APP_FFI_LTO="$mode" CMUX_APP_FFI_ARCHS=arm64 CMUX_APP_FFI_OUT="$out/$mode" \
    bash "$root/scripts/cmux-next/build-app-ffi.sh" >&2
  seconds=$((SECONDS - start))
  lib="$out/$mode/macos/libcmux_app_ffi.a"
  nm -gU "$lib" | awk '$2 == "T" {print $3}' | sort -u > "$out/$mode.exports"
  clang -arch arm64 -mmacosx-version-min=14.0 -dynamiclib -dead_strip \
    -Wl,-exported_symbols_list,"$out/$mode.exports" -Wl,-force_load,"$lib" \
    -Wl,-undefined,dynamic_lookup -lc++ -o "$out/$mode.dylib"
  strip -x "$out/$mode.dylib"
  text="$(size -m "$out/$mode.dylib" | awk '/Section __text:/ {print $3; exit}')"
  file="$(stat -f %z "$out/$mode.dylib")"
  archive="$(stat -f %z "$lib")"
  exports="$(wc -l < "$out/$mode.exports" | tr -d ' ')"
  printf 'app-ffi-size %s text=%s file=%s archive=%s exports=%s build_seconds=%s\n' \
    "$mode" "$text" "$file" "$archive" "$exports" "$seconds"
  [[ "$json" == "{" ]] || json+=","
  json+="\"$mode\":{\"text\":$text,\"file\":$file,\"archive\":$archive,\"exports\":$exports,\"build_seconds\":$seconds}"
done
printf '%s}\n' "$json" | tee "$root/artifacts/app-ffi-size.json"
