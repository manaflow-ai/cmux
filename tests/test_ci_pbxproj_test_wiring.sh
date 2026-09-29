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
#   (d) Test file is a member of a non-cmuxCLITests target (e.g. OtherTests).
#       Its "in Sources" lines exist in the pbxproj, but not inside the
#       cmuxCLITests Sources build phase; Xcode does not compile it into the
#       cmuxCLITests bundle.
#   (e) Test file's basename is a suffix of another file already wired into
#       the cmuxCLITests Sources phase. An unanchored grep would match the
#       longer name and falsely report the shorter one as wired.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LINT="$ROOT_DIR/scripts/lint-pbxproj-test-wiring.sh"
if [ ! -x "$LINT" ]; then
  echo "test_ci_pbxproj_test_wiring: lint not executable at $LINT" >&2
  exit 1
fi

# (a) Real repo must lint clean. cmuxCLITestSupport/ is compiled into the
# cmuxCLITests bundle as well. A checkout whose project has no cmuxCLITests
# target (verify-local's fixture repository) has nothing to check; one whose
# project names the target checks it even if a directory is missing, so a
# deleted directory still fails.
if [ -d "$ROOT_DIR/cmuxCLITests" ] \
  || grep -q 'cmuxCLITests' "$ROOT_DIR/cmux.xcodeproj/project.pbxproj"; then
  "$LINT" --repo-root "$ROOT_DIR"
  "$LINT" --repo-root "$ROOT_DIR" --target cmuxCLITests --tests-dir cmuxCLITestSupport
fi

# Shared sandbox cleanup.
SANDBOX_PARENT="$(mktemp -d)"
trap 'rm -rf "$SANDBOX_PARENT"' EXIT

# Helper: write a minimal pbxproj that contains a cmuxCLITests PBXNativeTarget with
# a Sources build phase. Each fixture appends its own orphan/wrong-target entries
# outside the Sources block. The block is intentionally small enough to read by
# eye; the lint only cares about the `cmuxCLITests` target marker, the Sources
# phase UUID lookup inside it, and the contents of the matching
# PBXSourcesBuildPhase block.
write_base_pbxproj() {
  local pbxproj="$1"
  local extra_after_sources="${2:-}"

  cat > "$pbxproj" <<PBX
// Minimal synthetic project for lint testing.
/* Begin PBXNativeTarget section */
		AAAA000000000000000000T1 /* cmuxCLITests */ = {
			isa = PBXNativeTarget;
			buildPhases = (
				AAAA000000000000000000S1 /* Sources */,
			);
			name = cmuxCLITests;
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
mkdir -p "$SANDBOX_B/cmuxCLITests" "$SANDBOX_B/cmux.xcodeproj"
cat > "$SANDBOX_B/cmuxCLITests/FakeOrphanTests.swift" <<'SWIFT'
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
mkdir -p "$SANDBOX_C/cmuxCLITests" "$SANDBOX_C/cmux.xcodeproj"
cat > "$SANDBOX_C/cmuxCLITests/FakeGroupOnlyTests.swift" <<'SWIFT'
import XCTest
final class FakeGroupOnlyTests: XCTestCase { func testNoop() { XCTAssert(true) } }
SWIFT
write_base_pbxproj "$SANDBOX_C/cmux.xcodeproj/project.pbxproj" "
/* Begin PBXFileReference section */
		BBBB000000000000000000F1 /* FakeGroupOnlyTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = FakeGroupOnlyTests.swift; sourceTree = \"<group>\"; };
/* End PBXFileReference section */

/* Begin PBXGroup section */
		BBBB000000000000000000G1 /* cmuxCLITests */ = {
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
# (d) File is in OtherTests target's Sources phase, NOT in cmuxCLITests.
SANDBOX_D="$SANDBOX_PARENT/d"
mkdir -p "$SANDBOX_D/cmuxCLITests" "$SANDBOX_D/cmux.xcodeproj"
cat > "$SANDBOX_D/cmuxCLITests/FakeWrongTargetTests.swift" <<'SWIFT'
import XCTest
final class FakeWrongTargetTests: XCTestCase { func testNoop() { XCTAssert(true) } }
SWIFT

# Write a pbxproj that contains BOTH a cmuxCLITests target (with empty Sources
# phase) AND a separate OtherTests target whose Sources phase wires
# FakeWrongTargetTests.swift. The file therefore appears in two `in Sources`
# lines (PBXBuildFile + OtherTests Sources phase), satisfying a naive global
# grep, but it is NOT a member of the cmuxCLITests Sources phase.
cat > "$SANDBOX_D/cmux.xcodeproj/project.pbxproj" <<'PBX'
// Minimal synthetic project for lint testing — wrong-target case.
/* Begin PBXBuildFile section */
		CCCC000000000000000000B1 /* FakeWrongTargetTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = CCCC000000000000000000F1 /* FakeWrongTargetTests.swift */; };
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		CCCC000000000000000000F1 /* FakeWrongTargetTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = FakeWrongTargetTests.swift; sourceTree = "<group>"; };
/* End PBXFileReference section */

/* Begin PBXNativeTarget section */
		AAAA000000000000000000T1 /* cmuxCLITests */ = {
			isa = PBXNativeTarget;
			buildPhases = (
				AAAA000000000000000000S1 /* Sources */,
			);
			name = cmuxCLITests;
		};
		CCCC000000000000000000T1 /* OtherTests */ = {
			isa = PBXNativeTarget;
			buildPhases = (
				CCCC000000000000000000S1 /* Sources */,
			);
			name = OtherTests;
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
  echo "test_ci_pbxproj_test_wiring: (d) lint should have failed on file wired to wrong target (OtherTests instead of cmuxCLITests)" >&2
  cat "$SANDBOX_D/out" >&2
  exit 1
fi
if ! grep -q "FakeWrongTargetTests.swift" "$SANDBOX_D/out"; then
  echo "test_ci_pbxproj_test_wiring: (d) lint output missing FakeWrongTargetTests.swift" >&2
  cat "$SANDBOX_D/out" >&2
  exit 1
fi
if ! grep -q "cmuxCLITests target's Sources build phase" "$SANDBOX_D/out"; then
  echo "test_ci_pbxproj_test_wiring: (d) lint output missing cmuxCLITests-target diagnostic" >&2
  cat "$SANDBOX_D/out" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# (e) Filename-suffix overlap. Two files share a suffix: only the longer one
# is wired into the cmuxCLITests Sources phase. The shorter file should be
# flagged. Without anchoring the grep, an unanchored substring match against
# the longer wired entry would falsely report the shorter file as wired.
SANDBOX_E="$SANDBOX_PARENT/e"
mkdir -p "$SANDBOX_E/cmuxCLITests" "$SANDBOX_E/cmux.xcodeproj"
cat > "$SANDBOX_E/cmuxCLITests/FooTests.swift" <<'SWIFT'
import XCTest
final class FooTests: XCTestCase { func testNoop() { XCTAssert(true) } }
SWIFT
cat > "$SANDBOX_E/cmuxCLITests/PrefixFooTests.swift" <<'SWIFT'
import XCTest
final class PrefixFooTests: XCTestCase { func testNoop() { XCTAssert(true) } }
SWIFT

# pbxproj: cmuxCLITests target's Sources phase only wires PrefixFooTests.swift.
# FooTests.swift has no entries; it should be flagged.
cat > "$SANDBOX_E/cmux.xcodeproj/project.pbxproj" <<'PBX'
// Minimal synthetic project for lint testing — suffix-overlap case.
/* Begin PBXBuildFile section */
		DDDD000000000000000000B1 /* PrefixFooTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = DDDD000000000000000000F1 /* PrefixFooTests.swift */; };
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		DDDD000000000000000000F1 /* PrefixFooTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PrefixFooTests.swift; sourceTree = "<group>"; };
/* End PBXFileReference section */

/* Begin PBXNativeTarget section */
		AAAA000000000000000000T1 /* cmuxCLITests */ = {
			isa = PBXNativeTarget;
			buildPhases = (
				AAAA000000000000000000S1 /* Sources */,
			);
			name = cmuxCLITests;
		};
/* End PBXNativeTarget section */

/* Begin PBXSourcesBuildPhase section */
		AAAA000000000000000000S1 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				DDDD000000000000000000B1 /* PrefixFooTests.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */
PBX

if "$LINT" --repo-root "$SANDBOX_E" >"$SANDBOX_E/out" 2>&1; then
  echo "test_ci_pbxproj_test_wiring: (e) lint should have failed on FooTests.swift (suffix-overlap false negative)" >&2
  cat "$SANDBOX_E/out" >&2
  exit 1
fi
if ! grep -q "FooTests.swift" "$SANDBOX_E/out"; then
  echo "test_ci_pbxproj_test_wiring: (e) lint output missing FooTests.swift" >&2
  cat "$SANDBOX_E/out" >&2
  exit 1
fi
# Confirm the lint only flagged the suffix-orphan, not the wired prefix file.
if grep -q "  - PrefixFooTests.swift" "$SANDBOX_E/out"; then
  echo "test_ci_pbxproj_test_wiring: (e) lint should NOT flag PrefixFooTests.swift (it is wired)" >&2
  cat "$SANDBOX_E/out" >&2
  exit 1
fi

echo "test_ci_pbxproj_test_wiring: ok"
