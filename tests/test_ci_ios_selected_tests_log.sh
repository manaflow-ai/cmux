#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATOR="$ROOT_DIR/scripts/ci/validate-ios-selected-tests-log.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-ios-selected-tests.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -x "$VALIDATOR" ]] || fail "missing executable validator: $VALIDATOR"

cat > "$TMP_ROOT/passed.log" <<'EOF'
Test Suite 'cmuxUITests' passed at 2026-07-31 07:41:27.524.
Executed 1 test, with 0 failures (0 unexpected) in 40.253 seconds
Test Suite 'Selected tests' passed at 2026-07-31 07:41:27.525.
EOF
"$VALIDATOR" "$TMP_ROOT/passed.log" \
  || fail "one passing selected test should validate"

cat > "$TMP_ROOT/zero.log" <<'EOF'
Test Suite 'Selected tests' passed at 2026-07-31 07:41:27.525.
Executed 0 tests, with 0 failures (0 unexpected) in 0.000 seconds
EOF
if "$VALIDATOR" "$TMP_ROOT/zero.log"; then
  fail "zero selected tests must not validate"
fi

cat > "$TMP_ROOT/failed.log" <<'EOF'
Test Case '-[cmuxUITests.cmuxUITests testExample]' failed (1.000 seconds).
Test Suite 'Selected tests' failed at 2026-07-31 07:41:27.525.
Executed 1 test, with 1 failure (0 unexpected) in 1.000 seconds
EOF
if "$VALIDATOR" "$TMP_ROOT/failed.log"; then
  fail "a failing selected test must not validate"
fi

printf 'PASS: iOS selected-test log validation rejects zero and failed tests\n'
