#!/usr/bin/env bash
# CI guard for ./scripts/lint-pbxproj-test-wiring.sh.
#
# Verifies the lint script (a) reports "ok" on the real cmux repo, and (b)
# correctly fails when a test file is dropped in without pbxproj wiring.
# The second case is what prevents the lint itself from rotting into a no-op.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LINT="$ROOT_DIR/scripts/lint-pbxproj-test-wiring.sh"
if [ ! -x "$LINT" ]; then
  echo "test_ci_pbxproj_test_wiring: lint not executable at $LINT" >&2
  exit 1
fi

# (a) Real repo must lint clean.
"$LINT" --repo-root "$ROOT_DIR"

# (b) Synthetic regression — drop an unwired test file in a sandbox repo and
# confirm the lint flags it.
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/cmuxTests"
mkdir -p "$SANDBOX/cmux.xcodeproj"

cat > "$SANDBOX/cmuxTests/FakeOrphanTests.swift" <<'SWIFT'
import XCTest
final class FakeOrphanTests: XCTestCase {
    func testNoop() { XCTAssert(true) }
}
SWIFT

cat > "$SANDBOX/cmux.xcodeproj/project.pbxproj" <<'PBX'
// pretend-pbxproj with no reference to FakeOrphanTests.swift
PBX

if "$LINT" --repo-root "$SANDBOX" >"$SANDBOX/out" 2>&1; then
  echo "test_ci_pbxproj_test_wiring: lint should have failed on the unwired sandbox test" >&2
  cat "$SANDBOX/out" >&2
  exit 1
fi
grep -q "FakeOrphanTests.swift" "$SANDBOX/out"
grep -q "hits=0" "$SANDBOX/out"

echo "test_ci_pbxproj_test_wiring: ok"
