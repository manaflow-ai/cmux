# shellcheck shell=bash
# Sourced by scripts/ci/package-test-lane.sh and scripts/ci/run-swift-testing-suites.sh.
# Sets swift_test_debug_info_args: the SwiftPM debug-info option that every
# `swift build`/`swift test` of one CI or fleet test run passes, the build and
# the test runs alike (a run whose flags differ from the build's rebuilds).
#
# CMUX_SWIFT_TEST_DEBUG_INFO:
#   dwarf  SwiftPM's default (-g). swift-driver adds a dsymutil job to every
#          Darwin link with -g, so each test build also writes a dSYM of the
#          whole test bundle.
#   none   -debug-info-format none: no DWARF, no dSYM. The bundle keeps its
#          symbol table, so `sample` stacks (hung_test_watchdog.py) and crash
#          reports still name functions; lldb has no source lines.
# Default: none; dwarf for a sanitizer run (CMUX_SWIFT_SANITIZE), whose
# reports need source lines. Set dwarf to debug a test in lldb.
# Returns 2 on any other value.
swift_test_debug_info_args=()
swift_test_debug_info_default=none
[ -z "${CMUX_SWIFT_SANITIZE:-}" ] || swift_test_debug_info_default=dwarf
case "${CMUX_SWIFT_TEST_DEBUG_INFO:-$swift_test_debug_info_default}" in
  dwarf) ;;
  none) swift_test_debug_info_args=(-debug-info-format none) ;;
  *)
    echo "CMUX_SWIFT_TEST_DEBUG_INFO must be dwarf or none (got '${CMUX_SWIFT_TEST_DEBUG_INFO}')" >&2
    return 2
    ;;
esac
