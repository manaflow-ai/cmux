#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE_DIR="${ROOT}/Native/CommandPaletteNucleoFFI"
DERIVED_DATA="${CMUX_NUCLEO_FFI_DERIVED_DATA:-/tmp/cmux-nucleo-ffi-unit}"
LOG_PATH="${CMUX_NUCLEO_FFI_LOG:-/tmp/cmux-nucleo-ffi-tests.log}"
SOURCE_PACKAGES_DIR="${CMUX_NUCLEO_FFI_SOURCE_PACKAGES_DIR:-${ROOT}/.ci-source-packages}"

CMUX_NUCLEO_FFI_REQUIRE_CARGO=1 "${ROOT}/scripts/build-command-palette-nucleo-ffi.sh"

LIB_PATH="${CRATE_DIR}/target/cmux-nucleo-ffi/libcmux_command_palette_nucleo_ffi.dylib"
if [ ! -f "${LIB_PATH}" ]; then
  echo "error: expected nucleo FFI library at ${LIB_PATH}" >&2
  exit 1
fi

if [ "${CMUX_NUCLEO_FFI_CLEAN:-0}" = "1" ]; then
  rm -rf "${DERIVED_DATA}"
fi
mkdir -p "${SOURCE_PACKAGES_DIR}"

xcodebuild_command=(xcodebuild)
if [ -x "${ROOT}/scripts/ci/xcodebuild_noninteractive.py" ]; then
  xcodebuild_command=("${ROOT}/scripts/ci/xcodebuild_noninteractive.py" xcodebuild)
fi

only_testing=(
  "-only-testing:cmuxTests/CommandPaletteNucleoFFITests"
  "-only-testing:cmuxTests/CommandPaletteSearchEngineTests/testNucleoResolvedSearchMatchesReturnFullFinalResultSetWhenUnbounded"
  "-only-testing:cmuxTests/CommandPaletteSearchEngineTests/testNucleoEmptyResultsFallBackToSwiftSingleEditMatching"
  "-only-testing:cmuxTests/CommandPaletteSearchEngineTests/testNucleoPartialResultsIncludeSwiftSingleEditFallback"
  "-only-testing:cmuxTests/CommandPaletteSearchEngineTests/testNucleoFullPageResultsIncludeSwiftSingleEditFallback"
  "-only-testing:cmuxTests/CommandPaletteSearchEngineTests/testNucleoExactPartialResultsDoNotRunSwiftSingleEditFallback"
)

NSUnbufferedIO=YES \
CMUX_NUCLEO_FFI_LIB="${LIB_PATH}" \
CMUX_NUCLEO_FFI_REQUIRE_CARGO=1 \
CMUX_SKIP_ZIG_BUILD=1 \
  "${xcodebuild_command[@]}" \
  -project "${ROOT}/cmux.xcodeproj" \
  -scheme cmux-unit \
  -configuration Debug \
  -clonedSourcePackagesDirPath "${SOURCE_PACKAGES_DIR}" \
  -derivedDataPath "${DERIVED_DATA}" \
  -destination 'platform=macOS' \
  CMUX_SKIP_ZIG_BUILD=1 \
  "${only_testing[@]}" \
  test | tee "${LOG_PATH}"

if ! grep -q 'BENCH cmd+p nucleo-ffi' "${LOG_PATH}"; then
  echo "error: CommandPaletteNucleoFFITests did not emit benchmark output" >&2
  exit 1
fi

if grep -E "Test Case '.*CommandPalette(NucleoFFI|SearchEngine).*' skipped|CommandPalette(NucleoFFI|SearchEngine).*skipped" "${LOG_PATH}"; then
  echo "error: focused nucleo FFI lane skipped selected XCTest coverage" >&2
  exit 1
fi
