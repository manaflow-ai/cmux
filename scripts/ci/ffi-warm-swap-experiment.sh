#!/usr/bin/env bash
# Manual fleet proof for the opt-in app FFI loader. This is deliberately not a
# workflow job or release gate: it downloads one published dylib, loads it, and
# checks both the matching and intentionally mismatched ABI paths.
set -euo pipefail

source_sha="${1:-a6710e00290515b653c0a849ce0e7bbf4796eb4d}"
expected_abi="${2:-1}"
base="https://github.com/manaflow-ai/cmux/releases/download/cmux-app-ffi-${source_sha}"
work="$(mktemp -d "${TMPDIR:-/tmp}/cmux-ffi-warm-swap.XXXXXX")"
trap 'rm -rf "$work"' EXIT
archive="$work/CCmuxAppFFI.xcframework.zip"
curl --fail --location --silent --show-error --connect-timeout 20 --max-time 180 \
  "$base/CCmuxAppFFI.xcframework.zip" -o "$archive"
echo "archive sha256: $(shasum -a 256 "$archive" | awk '{print $1}')"
unzip -q "$archive" -d "$work"
dylib="$(find "$work/CCmuxAppFFI.xcframework" -name libcmux_app_ffi.dylib -type f -print -quit)"
test -n "$dylib" && test -f "$dylib"

run_loader() {
  local expected="$1" status
  local log="$work/loader-$expected.log"
  set +e
  (cd cmux-tui && cargo run --locked --manifest-path crates/cmux-app-ffi/Cargo.toml \
    --example ffi_warm_swap -- "$dylib" --expect-abi "$expected") >"$log" 2>&1
  status=$?
  set -e
  cat "$log"
  return "$status"
}

run_loader "$expected_abi"
if run_loader 4294967295; then
  echo "error: intentionally mismatched ABI was accepted" >&2
  exit 1
else
  mismatch_status=$?
  grep -q 'ABI mismatch:' "$work/loader-4294967295.log" || {
    echo "error: mismatch invocation failed without the loader's ABI diagnostic" >&2
    exit 1
  }
  [[ "$mismatch_status" -eq 3 ]] || {
    echo "error: mismatch invocation exited $mismatch_status, expected loader exit 3" >&2
    exit 1
  }
fi
echo "PASS: loaded $source_sha and rejected the intentional ABI mismatch"
