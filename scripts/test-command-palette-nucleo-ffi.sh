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

# CI caches resolved Swift packages outside DerivedData; a local run needs no
# such directory and lets xcodebuild use its own.
XCODEBUILD_EXTRA_ARGS=()
if [ -n "${CMUX_NUCLEO_FFI_SOURCE_PACKAGES:-}" ]; then
  XCODEBUILD_EXTRA_ARGS+=(
    -clonedSourcePackagesDirPath "${CMUX_NUCLEO_FFI_SOURCE_PACKAGES}"
    -disableAutomaticPackageResolution
  )
fi

# The wall-clock command-palette search benchmarks are gated out of the sharded
# app-host unit suite (skipUnlessCommandPaletteSearchBenchmarksAreEnabled in
# cmuxTests/CommandPaletteNucleoFixtures.swift). This focused invocation is
# their home, so it enables the gate AND names both classes that hold gated
# benchmarks: CommandPaletteNucleoFFITests (the FFI frame-budget pair) and
# CommandPaletteSearchEngineTests (the four engine benchmarks). Naming only the
# first is how the engine benchmarks previously ran nowhere at all. The BENCH
# greps below assert every one of them actually ran.
NSUnbufferedIO=YES CMUX_NUCLEO_FFI_LIB="${LIB_PATH}" \
  CMUX_COMMAND_PALETTE_SEARCH_BENCHMARKS=1 \
  TEST_RUNNER_CMUX_COMMAND_PALETTE_SEARCH_BENCHMARKS=1 \
  xcodebuild \
    -project "${ROOT}/cmux.xcodeproj" \
    -scheme cmux-unit \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "${DERIVED_DATA}" \
    "${XCODEBUILD_EXTRA_ARGS[@]+"${XCODEBUILD_EXTRA_ARGS[@]}"}" \
    -only-testing:cmuxTests/CommandPaletteNucleoFFITests \
    -only-testing:cmuxTests/CommandPaletteSearchEngineTests \
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

# One grep per gated CommandPaletteSearchEngineTests benchmark. A skipped
# benchmark still passes the suite, so only its own BENCH line proves it ran:
# without these the -only-testing above could silently stop covering them again.
missing_engine_benchmarks=0
while IFS='|' read -r pattern test_name; do
  [ -n "$pattern" ] || continue
  if ! grep -F "$pattern" "${LOG_PATH}" > /dev/null; then
    echo "error: ${test_name} did not emit '${pattern}'" >&2
    missing_engine_benchmarks=1
  fi
done <<'BENCHMARKS'
BENCH cmd+shift+p reference=|testCommandSearchBenchmarkBeatsLegacyPipeline
BENCH cmd+p reference=|testSwitcherSearchBenchmarkBeatsLegacyPipeline
BENCH cmd+p large-workspaces reference=|testLargeWorkspaceSwitcherSearchBenchmarkAvoidsPerQueryPreparationCost
BENCH cmd+p fast-typing full=|testFastTypingPreviewSearchBenchmarkReportsEstimatedDroppedFrames
BENCHMARKS

if [ "$missing_engine_benchmarks" -ne 0 ]; then
  echo "error: CommandPaletteSearchEngineTests benchmarks did not all run" >&2
  exit 1
fi
