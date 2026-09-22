#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE_DIR="${ROOT}/Native/CommandPaletteNucleoFFI"
DERIVED_DATA="${CMUX_NUCLEO_FFI_DERIVED_DATA:-/tmp/cmux-nucleo-ffi-unit}"
LOG_PATH="${CMUX_NUCLEO_FFI_LOG:-/tmp/cmux-nucleo-ffi-tests.log}"

cargo build --manifest-path "${CRATE_DIR}/Cargo.toml" --release

LIB_PATH="${CRATE_DIR}/target/release/libcmux_command_palette_nucleo_ffi.dylib"
if [ ! -f "${LIB_PATH}" ]; then
  echo "error: expected nucleo FFI library at ${LIB_PATH}" >&2
  exit 1
fi

if [ "${CMUX_NUCLEO_FFI_CLEAN:-0}" = "1" ]; then
  rm -rf "${DERIVED_DATA}"
fi
# The frame-budget benchmarks are gated out of the sharded app-host unit suite
# (skipUnlessCommandPaletteSearchBenchmarksAreEnabled in
# cmuxTests/CommandPaletteNucleoFixtures.swift). This focused invocation is
# their home, so enable them here; the BENCH grep below asserts they ran.
NSUnbufferedIO=YES CMUX_NUCLEO_FFI_LIB="${LIB_PATH}" \
  CMUX_COMMAND_PALETTE_SEARCH_BENCHMARKS=1 \
  TEST_RUNNER_CMUX_COMMAND_PALETTE_SEARCH_BENCHMARKS=1 \
  xcodebuild \
    -project "${ROOT}/cmux.xcodeproj" \
    -scheme cmux-unit \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "${DERIVED_DATA}" \
    -only-testing:cmuxTests/CommandPaletteNucleoFFITests \
    test | tee "${LOG_PATH}"

if ! grep 'BENCH cmd+p nucleo-ffi' "${LOG_PATH}"; then
  echo "error: CommandPaletteNucleoFFITests did not emit benchmark output" >&2
  exit 1
fi

# The edge-case typing benchmark only runs when the benchmark gate is honored,
# so its BENCH line also proves CMUX_COMMAND_PALETTE_SEARCH_BENCHMARKS reached
# the test process.
if ! grep 'BENCH cmd+p nucleo-ffi edge-typing' "${LOG_PATH}"; then
  echo "error: edge-case typing benchmark did not run (benchmark gate not honored?)" >&2
  exit 1
fi
