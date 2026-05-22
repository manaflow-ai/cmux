#!/usr/bin/env bash
# CI guard for ./scripts/lint-pbxproj-test-wiring.sh.
#
# Verifies the lint script reports "ok" on the real cmux repo and correctly
# fails on every silent-skip failure mode the lint is meant to catch. The
# negative cases are what prevent the lint itself from rotting into a no-op.
#
# Cases:
#   (a) Real cmux repo lints clean.
#   (b) Test file has no pbxproj references at all (hits=0).
#   (c) Test file has PBXFileReference + group child but is not a member of
#       any target (Xcode silently skips it).
#   (d) Test file is a member of a non-cmuxTests target (e.g. cmuxUITests).
#       Its "in Sources" lines exist in the pbxproj, but not inside the
#       cmuxTests Sources build phase; Xcode does not compile it into the
#       cmuxTests bundle.

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

# Helper: write a minimal pbxproj that contains a cmuxTests PBXNativeTarget with
# a Sources build phase. Each fixture appends its own orphan/wrong-target entries
# outside the Sources block. The block is intentionally small enough to read by
# eye; the lint only cares about the `cmuxTests` target marker, the Sources
# phase UUID lookup inside it, and the contents of the matching
# PBXSourcesBuildPhase block.
write_base_pbxproj() {
  local pbxproj="$1"
  local extra_after_sources="${2:-}"

  cat > "$pbxproj" <<PBX
// Minimal synthetic project for lint testing.
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
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */
${extra_after_sources}
PBX
}

# ---------------------------------------------------------------------------
# (b) File has no references at all in pbxproj.
SANDBOX_B="$SANDBOX_PARENT/b"
mkdir -p "$SANDBOX_B/cmuxTests" "$SANDBOX_B/cmux.xcodeproj"
cat > "$SANDBOX_B/cmuxTests/FakeOrphanTests.swift" <<'SWIFT'
import XCTest
final class FakeOrphanTests: XCTestCase { func testNoop() { XCTAssert(true) } }
SWIFT
write_base_pbxproj "$SANDBOX_B/cmux.xcodeproj/project.pbxproj"

if "$LINT" --repo-root "$SANDBOX_B" >"$SANDBOX_B/out" 2>&1; then
  echo "test_ci_pbxproj_test_wiring: (b) lint should have failed on the no-reference orphan" >&2
  cat "$SANDBOX_B/out" >&2
  exit 1
fi
if ! grep -q "FakeOrphanTests.swift" "$SANDBOX_B/out"; then
  echo "test_ci_pbxproj_test_wiring: (b) lint output missing FakeOrphanTests.swift" >&2
  cat "$SANDBOX_B/out" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# (c) File has PBXFileReference + group child only — not a target member.
SANDBOX_C="$SANDBOX_PARENT/c"
mkdir -p "$SANDBOX_C/cmuxTests" "$SANDBOX_C/cmux.xcodeproj"
cat > "$SANDBOX_C/cmuxTests/FakeGroupOnlyTests.swift" <<'SWIFT'
import XCTest
final class FakeGroupOnlyTests: XCTestCase { func testNoop() { XCTAssert(true) } }
SWIFT
write_base_pbxproj "$SANDBOX_C/cmux.xcodeproj/project.pbxproj" "
/* Begin PBXFileReference section */
		BBBB000000000000000000F1 /* FakeGroupOnlyTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = FakeGroupOnlyTests.swift; sourceTree = \"<group>\"; };
/* End PBXFileReference section */

/* Begin PBXGroup section */
		BBBB000000000000000000G1 /* cmuxTests */ = {
			isa = PBXGroup;
			children = (
				BBBB000000000000000000F1 /* FakeGroupOnlyTests.swift */,
			);
		};
/* End PBXGroup section */
"

if "$LINT" --repo-root "$SANDBOX_C" >"$SANDBOX_C/out" 2>&1; then
  echo "test_ci_pbxproj_test_wiring: (c) lint should have failed on group-only file" >&2
  cat "$SANDBOX_C/out" >&2
  exit 1
fi
if ! grep -q "FakeGroupOnlyTests.swift" "$SANDBOX_C/out"; then
  echo "test_ci_pbxproj_test_wiring: (c) lint output missing FakeGroupOnlyTests.swift" >&2
  cat "$SANDBOX_C/out" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# (d) File is in cmuxUITests target's Sources phase, NOT in cmuxTests.
SANDBOX_D="$SANDBOX_PARENT/d"
mkdir -p "$SANDBOX_D/cmuxTests" "$SANDBOX_D/cmux.xcodeproj"
cat > "$SANDBOX_D/cmuxTests/FakeWrongTargetTests.swift" <<'SWIFT'
import XCTest
final class FakeWrongTargetTests: XCTestCase { func testNoop() { XCTAssert(true) } }
SWIFT

# Write a pbxproj that contains BOTH a cmuxTests target (with empty Sources
# phase) AND a separate cmuxUITests target whose Sources phase wires
# FakeWrongTargetTests.swift. The file therefore appears in two `in Sources`
# lines (PBXBuildFile + cmuxUITests Sources phase), satisfying a naive global
# grep, but it is NOT a member of the cmuxTests Sources phase.
cat > "$SANDBOX_D/cmux.xcodeproj/project.pbxproj" <<'PBX'
// Minimal synthetic project for lint testing — wrong-target case.
/* Begin PBXBuildFile section */
		CCCC000000000000000000B1 /* FakeWrongTargetTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = CCCC000000000000000000F1 /* FakeWrongTargetTests.swift */; };
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		CCCC000000000000000000F1 /* FakeWrongTargetTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = FakeWrongTargetTests.swift; sourceTree = "<group>"; };
/* End PBXFileReference section */

/* Begin PBXNativeTarget section */
		AAAA000000000000000000T1 /* cmuxTests */ = {
			isa = PBXNativeTarget;
			buildPhases = (
				AAAA000000000000000000S1 /* Sources */,
			);
			name = cmuxTests;
		};
		CCCC000000000000000000T1 /* cmuxUITests */ = {
			isa = PBXNativeTarget;
			buildPhases = (
				CCCC000000000000000000S1 /* Sources */,
			);
			name = cmuxUITests;
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
		CCCC000000000000000000S1 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				CCCC000000000000000000B1 /* FakeWrongTargetTests.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */
PBX

if "$LINT" --repo-root "$SANDBOX_D" >"$SANDBOX_D/out" 2>&1; then
  echo "test_ci_pbxproj_test_wiring: (d) lint should have failed on file wired to wrong target (cmuxUITests instead of cmuxTests)" >&2
  cat "$SANDBOX_D/out" >&2
  exit 1
fi
if ! grep -q "FakeWrongTargetTests.swift" "$SANDBOX_D/out"; then
  echo "test_ci_pbxproj_test_wiring: (d) lint output missing FakeWrongTargetTests.swift" >&2
  cat "$SANDBOX_D/out" >&2
  exit 1
fi
if ! grep -q "cmuxTests target's Sources build phase" "$SANDBOX_D/out"; then
  echo "test_ci_pbxproj_test_wiring: (d) lint output missing cmuxTests-target diagnostic" >&2
  cat "$SANDBOX_D/out" >&2
  exit 1
fi

echo "test_ci_pbxproj_test_wiring: ok"
