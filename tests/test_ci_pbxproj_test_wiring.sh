#!/usr/bin/env bash
# CI guard for ./scripts/lint-pbxproj-test-wiring.sh.
#
# The project uses Xcode's filesystem-synchronized format (objectVersion 70):
# cmuxTests/ is a PBXFileSystemSynchronizedRootGroup owned by the cmuxTests
# target, so every on-disk test file compiles automatically. The lint guards
# the invariants that keep that true. This self-test verifies the lint
# reports OK on the real cmux repo and correctly fails on every silent-skip
# failure mode it is meant to catch. The negative cases are what prevent the
# lint itself from rotting into a no-op.
#
# Cases:
#   (a) Real cmux repo lints clean.
#   (b) membershipExceptions on the synchronized cmuxTests group (target =
#       cmuxTests) excludes .swift test files (top-level and nested). Xcode
#       writes such an entry when target membership is unticked; the excluded
#       test never compiles or runs on CI. Must fail and name the files.
#   (c) An exception set on the cmuxTests group for a DIFFERENT target
#       (which ADDS the listed files to that target rather than removing
#       them from cmuxTests). Must pass — no false positive.
#   (d) The synchronized cmuxTests group exists but the cmuxTests target
#       does not own it via fileSystemSynchronizedGroups, so nothing under
#       cmuxTests/ compiles. Must fail.
#   (e) cmuxTests reverted to a plain PBXGroup with per-file wiring (the
#       pre-conversion layout whose silent-skip failure mode the
#       synchronized format eliminated). Must fail.
#   (f) membershipExceptions excludes only non-Swift content (e.g. a fixture
#       resource). Must pass — only excluded .swift files can silently skip.

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

# Shared sandbox cleanup.
SANDBOX_PARENT="$(mktemp -d)"
trap 'rm -rf "$SANDBOX_PARENT"' EXIT

# Helper: write a minimal synchronized-format pbxproj.
#   $1 — output path
#   $2 — PBXFileSystemSynchronizedBuildFileExceptionSet entries (may be empty)
#   $3 — lines for the cmuxTests group's exceptions = ( ... ) list (may be empty)
#   $4 — lines for the target's fileSystemSynchronizedGroups = ( ... ) list
#        (pass an empty string to simulate a target that does not own the group)
#
# UUIDs:
#   AAAA000000000000000000T1 — cmuxTests native target
#   AAAA000000000000000000T2 — cmux native target (for additive exceptions)
#   AAAA00000000000000000G01 — synchronized cmuxTests root group
#   AAAA00000000000000000E01 / E02 — exception sets supplied via $2/$3
write_sync_pbxproj() {
  local pbxproj="$1"
  local exception_sets="${2:-}"
  local group_exceptions="${3:-}"
  local owner_groups="${4-AAAA00000000000000000G01 /* cmuxTests */,}"

  cat > "$pbxproj" <<PBX
// Minimal synthetic project for lint testing — synchronized layout.
/* Begin PBXFileSystemSynchronizedBuildFileExceptionSet section */
${exception_sets}
/* End PBXFileSystemSynchronizedBuildFileExceptionSet section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
		AAAA00000000000000000G01 /* cmuxTests */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			exceptions = (
${group_exceptions}
			);
			explicitFileTypes = {
			};
			explicitFolders = (
			);
			path = cmuxTests;
			sourceTree = "<group>";
		};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXNativeTarget section */
		AAAA000000000000000000T1 /* cmuxTests */ = {
			isa = PBXNativeTarget;
			buildPhases = (
				AAAA000000000000000000S1 /* Sources */,
			);
			fileSystemSynchronizedGroups = (
				${owner_groups}
			);
			name = cmuxTests;
		};
		AAAA000000000000000000T2 /* cmux */ = {
			isa = PBXNativeTarget;
			buildPhases = (
			);
			name = cmux;
		};
/* End PBXNativeTarget section */

/* Begin PBXSourcesBuildPhase section */
		AAAA000000000000000000S1 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */
PBX
}

# Helper: a sandbox needs an on-disk cmuxTests dir with at least one file.
make_sandbox() {
  local dir="$1"
  mkdir -p "$dir/cmuxTests" "$dir/cmux.xcodeproj"
  cat > "$dir/cmuxTests/FakeKeptTests.swift" <<'SWIFT'
import XCTest
final class FakeKeptTests: XCTestCase { func testNoop() { XCTAssert(true) } }
SWIFT
}

# ---------------------------------------------------------------------------
# (b) membershipExceptions excludes .swift test files (top-level and nested).
SANDBOX_B="$SANDBOX_PARENT/b"
make_sandbox "$SANDBOX_B"
mkdir -p "$SANDBOX_B/cmuxTests/Sub"
cat > "$SANDBOX_B/cmuxTests/FakeExcludedTests.swift" <<'SWIFT'
import XCTest
final class FakeExcludedTests: XCTestCase { func testNoop() { XCTAssert(true) } }
SWIFT
cat > "$SANDBOX_B/cmuxTests/Sub/FakeNestedTests.swift" <<'SWIFT'
import XCTest
final class FakeNestedTests: XCTestCase { func testNoop() { XCTAssert(true) } }
SWIFT
write_sync_pbxproj "$SANDBOX_B/cmux.xcodeproj/project.pbxproj" '		AAAA00000000000000000E01 /* Exceptions for "cmuxTests" folder in "cmuxTests" target */ = {
			isa = PBXFileSystemSynchronizedBuildFileExceptionSet;
			membershipExceptions = (
				FakeExcludedTests.swift,
				Sub/FakeNestedTests.swift,
			);
			target = AAAA000000000000000000T1 /* cmuxTests */;
		};' '				AAAA00000000000000000E01 /* Exceptions for "cmuxTests" folder in "cmuxTests" target */,'

if "$LINT" --repo-root "$SANDBOX_B" >"$SANDBOX_B/out" 2>&1; then
  echo "test_ci_pbxproj_test_wiring: (b) lint should have failed on membershipExceptions excluding test files" >&2
  cat "$SANDBOX_B/out" >&2
  exit 1
fi
for name in FakeExcludedTests.swift Sub/FakeNestedTests.swift; do
  if ! grep -qF "  - $name" "$SANDBOX_B/out"; then
    echo "test_ci_pbxproj_test_wiring: (b) lint output missing excluded file $name" >&2
    cat "$SANDBOX_B/out" >&2
    exit 1
  fi
done
if ! grep -q "membershipExceptions" "$SANDBOX_B/out"; then
  echo "test_ci_pbxproj_test_wiring: (b) lint output missing membershipExceptions diagnostic" >&2
  cat "$SANDBOX_B/out" >&2
  exit 1
fi
if grep -qF "  - FakeKeptTests.swift" "$SANDBOX_B/out"; then
  echo "test_ci_pbxproj_test_wiring: (b) lint should NOT flag FakeKeptTests.swift (it is not excluded)" >&2
  cat "$SANDBOX_B/out" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# (c) Exception set on the cmuxTests group for a different target. Such a set
# ADDS the listed files to that other target; it does not remove them from
# cmuxTests. The lint must not flag it.
SANDBOX_C="$SANDBOX_PARENT/c"
make_sandbox "$SANDBOX_C"
cat > "$SANDBOX_C/cmuxTests/FakeSharedTests.swift" <<'SWIFT'
import XCTest
final class FakeSharedTests: XCTestCase { func testNoop() { XCTAssert(true) } }
SWIFT
write_sync_pbxproj "$SANDBOX_C/cmux.xcodeproj/project.pbxproj" '		AAAA00000000000000000E02 /* Exceptions for "cmuxTests" folder in "cmux" target */ = {
			isa = PBXFileSystemSynchronizedBuildFileExceptionSet;
			membershipExceptions = (
				FakeSharedTests.swift,
			);
			target = AAAA000000000000000000T2 /* cmux */;
		};' '				AAAA00000000000000000E02 /* Exceptions for "cmuxTests" folder in "cmux" target */,'

if ! "$LINT" --repo-root "$SANDBOX_C" >"$SANDBOX_C/out" 2>&1; then
  echo "test_ci_pbxproj_test_wiring: (c) lint should have passed on an additive exception set for another target" >&2
  cat "$SANDBOX_C/out" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# (d) Synchronized group exists but the cmuxTests target does not own it.
SANDBOX_D="$SANDBOX_PARENT/d"
make_sandbox "$SANDBOX_D"
write_sync_pbxproj "$SANDBOX_D/cmux.xcodeproj/project.pbxproj" '' '' ''

if "$LINT" --repo-root "$SANDBOX_D" >"$SANDBOX_D/out" 2>&1; then
  echo "test_ci_pbxproj_test_wiring: (d) lint should have failed when cmuxTests target does not own the synchronized group" >&2
  cat "$SANDBOX_D/out" >&2
  exit 1
fi
if ! grep -q "does not own it via fileSystemSynchronizedGroups" "$SANDBOX_D/out"; then
  echo "test_ci_pbxproj_test_wiring: (d) lint output missing ownership diagnostic" >&2
  cat "$SANDBOX_D/out" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# (e) Pre-conversion layout: cmuxTests is a plain PBXGroup with a manually
# wired Sources build phase and no synchronized root group. Reverting to this
# layout reintroduces the per-file-wiring silent-skip failure mode, so the
# lint must reject it outright.
SANDBOX_E="$SANDBOX_PARENT/e"
make_sandbox "$SANDBOX_E"
cat > "$SANDBOX_E/cmux.xcodeproj/project.pbxproj" <<'PBX'
// Minimal synthetic project for lint testing — pre-conversion layout.
/* Begin PBXBuildFile section */
		BBBB000000000000000000B1 /* FakeKeptTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = BBBB000000000000000000F1 /* FakeKeptTests.swift */; };
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		BBBB000000000000000000F1 /* FakeKeptTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = FakeKeptTests.swift; sourceTree = "<group>"; };
/* End PBXFileReference section */

/* Begin PBXGroup section */
		BBBB000000000000000000G1 /* cmuxTests */ = {
			isa = PBXGroup;
			children = (
				BBBB000000000000000000F1 /* FakeKeptTests.swift */,
			);
			path = cmuxTests;
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		AAAA000000000000000000T1 /* cmuxTests */ = {
			isa = PBXNativeTarget;
			buildPhases = (
				AAAA000000000000000000S1 /* Sources */,
			);
			name = cmuxTests;
		};
/* End PBXNativeTarget section */

/* Begin PBXSourcesBuildPhase section */
		AAAA000000000000000000S1 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				BBBB000000000000000000B1 /* FakeKeptTests.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */
PBX

if "$LINT" --repo-root "$SANDBOX_E" >"$SANDBOX_E/out" 2>&1; then
  echo "test_ci_pbxproj_test_wiring: (e) lint should have failed on the pre-conversion (plain PBXGroup) layout" >&2
  cat "$SANDBOX_E/out" >&2
  exit 1
fi
if ! grep -q "not governed by a PBXFileSystemSynchronizedRootGroup" "$SANDBOX_E/out"; then
  echo "test_ci_pbxproj_test_wiring: (e) lint output missing synchronized-group diagnostic" >&2
  cat "$SANDBOX_E/out" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# (f) membershipExceptions excludes only non-Swift content. Excluding a
# fixture resource from the test bundle is legitimate and must pass.
SANDBOX_F="$SANDBOX_PARENT/f"
make_sandbox "$SANDBOX_F"
mkdir -p "$SANDBOX_F/cmuxTests/Fixtures"
echo '{}' > "$SANDBOX_F/cmuxTests/Fixtures/data.json"
write_sync_pbxproj "$SANDBOX_F/cmux.xcodeproj/project.pbxproj" '		AAAA00000000000000000E01 /* Exceptions for "cmuxTests" folder in "cmuxTests" target */ = {
			isa = PBXFileSystemSynchronizedBuildFileExceptionSet;
			membershipExceptions = (
				Fixtures/data.json,
			);
			target = AAAA000000000000000000T1 /* cmuxTests */;
		};' '				AAAA00000000000000000E01 /* Exceptions for "cmuxTests" folder in "cmuxTests" target */,'

if ! "$LINT" --repo-root "$SANDBOX_F" >"$SANDBOX_F/out" 2>&1; then
  echo "test_ci_pbxproj_test_wiring: (f) lint should have passed on a non-Swift membership exclusion" >&2
  cat "$SANDBOX_F/out" >&2
  exit 1
fi

echo "test_ci_pbxproj_test_wiring: ok"
