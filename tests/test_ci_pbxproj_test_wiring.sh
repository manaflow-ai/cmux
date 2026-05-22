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
// pretend-pbxproj with no test references
PBX

if "$LINT" --repo-root "$SANDBOX" >"$SANDBOX/out" 2>&1; then
  echo "test_ci_pbxproj_test_wiring: lint should have failed on the unwired sandbox test" >&2
  cat "$SANDBOX/out" >&2
  exit 1
fi
if ! grep -q "FakeOrphanTests.swift" "$SANDBOX/out"; then
  echo "test_ci_pbxproj_test_wiring: lint output missing FakeOrphanTests.swift" >&2
  cat "$SANDBOX/out" >&2
  exit 1
fi
if ! grep -q "in-Sources hits=0" "$SANDBOX/out"; then
  echo "test_ci_pbxproj_test_wiring: lint output missing 'in-Sources hits=0'" >&2
  cat "$SANDBOX/out" >&2
  exit 1
fi

# (c) Target-membership regression — drop a file that is referenced in the
# pbxproj (PBXFileReference + group child) but NOT a member of the cmuxTests
# target (no PBXBuildFile / PBXSourcesBuildPhase entry). This is the silent
# failure mode the original lint missed: bare filename hits >= 2 but Xcode
# still skips the file. The lint must still flag it.
SANDBOX2="$(mktemp -d)"
trap 'rm -rf "$SANDBOX" "$SANDBOX2"' EXIT
mkdir -p "$SANDBOX2/cmuxTests"
mkdir -p "$SANDBOX2/cmux.xcodeproj"

cat > "$SANDBOX2/cmuxTests/FakeGroupOnlyTests.swift" <<'SWIFT'
import XCTest
final class FakeGroupOnlyTests: XCTestCase {
    func testNoop() { XCTAssert(true) }
}
SWIFT

# Two filename hits, zero target-membership hits.
cat > "$SANDBOX2/cmux.xcodeproj/project.pbxproj" <<'PBX'
// PBXFileReference entry (would be inside /* Begin PBXFileReference section */)
ABCDEF0000000000000000A1 /* FakeGroupOnlyTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = FakeGroupOnlyTests.swift; sourceTree = "<group>"; };
// cmuxTests group children list (would be inside /* Begin PBXGroup section */)
        ABCDEF0000000000000000A1 /* FakeGroupOnlyTests.swift */,
// NOTE: no PBXBuildFile and no PBXSourcesBuildPhase reference, so the file
// is in the project but not a member of the cmuxTests target.
PBX

if "$LINT" --repo-root "$SANDBOX2" >"$SANDBOX2/out" 2>&1; then
  echo "test_ci_pbxproj_test_wiring: lint should have failed on file with group membership only" >&2
  cat "$SANDBOX2/out" >&2
  exit 1
fi
if ! grep -q "FakeGroupOnlyTests.swift" "$SANDBOX2/out"; then
  echo "test_ci_pbxproj_test_wiring: lint output missing FakeGroupOnlyTests.swift" >&2
  cat "$SANDBOX2/out" >&2
  exit 1
fi
if ! grep -q "in-Sources hits=0" "$SANDBOX2/out"; then
  echo "test_ci_pbxproj_test_wiring: lint output missing 'in-Sources hits=0' for group-only fixture" >&2
  cat "$SANDBOX2/out" >&2
  exit 1
fi

echo "test_ci_pbxproj_test_wiring: ok"
