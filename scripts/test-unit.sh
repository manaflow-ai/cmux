#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="cmux.xcodeproj"
SCHEME="cmux-unit"
CONFIGURATION="${CMUX_TEST_CONFIGURATION:-Debug}"
DESTINATION="${CMUX_TEST_DESTINATION:-platform=macOS}"

# Default to `test` when no explicit xcodebuild action is provided.
if [ "$#" -eq 0 ]; then
  set -- test
fi

# cmuxTests emits no Swift module, as in CI (scripts/ci/compile-app-host-test-product.sh).
# Nothing imports cmuxTests.swiftmodule, but its emit-module job type-checks
# every test declaration serially: 26 s of a 31 s one-test-file rebuild. The
# standalone driver with -no-emit-module-separately skips it (4.1 s, #14364).
# Only cmuxTests changes; every other target keeps its arguments. Switching
# between this and an Xcode build in the same DerivedData rebuilds cmuxTests
# once each way. CMUX_TEST_EMIT_MODULE=1 keeps the module, for example to
# debug test frames with lldb. A caller's own OTHER_SWIFT_FLAGS comes later and
# wins, which drops the flag and brings the module back.
# shellcheck disable=SC2016 # Xcode expands $(TARGET_NAME), not the shell
no_module_settings=(
  'SWIFT_USE_INTEGRATED_DRIVER=$(CMUX_TEST_INTEGRATED_DRIVER_$(TARGET_NAME):default=YES)'
  CMUX_TEST_INTEGRATED_DRIVER_cmuxTests=NO
  'OTHER_SWIFT_FLAGS=$(inherited) $(CMUX_TEST_SWIFT_FLAGS_$(TARGET_NAME))'
  CMUX_TEST_SWIFT_FLAGS_cmuxTests=-no-emit-module-separately
  'SWIFT_INSTALL_MODULE=$(CMUX_TEST_INSTALL_MODULE_$(TARGET_NAME):default=YES)'
  CMUX_TEST_INSTALL_MODULE_cmuxTests=NO
)
if [ "${CMUX_TEST_EMIT_MODULE:-0}" = 1 ]; then
  no_module_settings=()
fi

exec xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  ${no_module_settings[@]+"${no_module_settings[@]}"} \
  "$@"
