#!/bin/sh
# Target runner of the sanitizer lane (cmux-tui/scripts/sanitize.sh): nextest
# starts every test process through it. It appends `PID<TAB>BINARY_ID$TEST` to
# $CMUX_SANITIZE_TESTS, then execs the test, which keeps the pid, so the
# runtime's report.<pid> names the test it came from.
if [ -n "${CMUX_SANITIZE_TESTS:-}" ] && [ -n "${NEXTEST_TEST_NAME:-}" ]; then
  printf '%s\t%s$%s\n' "$$" "${NEXTEST_BINARY_ID:-}" "$NEXTEST_TEST_NAME" >>"$CMUX_SANITIZE_TESTS"
fi
# macOS SIP drops DYLD_* when /bin/sh starts; nextest keeps copies as NEXTEST_DYLD_*.
if [ -n "${NEXTEST_DYLD_FALLBACK_LIBRARY_PATH:-}" ] && [ -z "${DYLD_FALLBACK_LIBRARY_PATH:-}" ]; then
  export DYLD_FALLBACK_LIBRARY_PATH="$NEXTEST_DYLD_FALLBACK_LIBRARY_PATH"
fi
if [ -n "${NEXTEST_DYLD_LIBRARY_PATH:-}" ] && [ -z "${DYLD_LIBRARY_PATH:-}" ]; then
  export DYLD_LIBRARY_PATH="$NEXTEST_DYLD_LIBRARY_PATH"
fi
exec "$@"
