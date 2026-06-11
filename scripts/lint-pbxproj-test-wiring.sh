#!/usr/bin/env bash
# Lint: cmuxTests/ must be governed by a PBXFileSystemSynchronizedRootGroup
# that the cmuxTests target owns, and no membershipExceptions entry may
# exclude a *.swift test file from that target.
#
# History: before the project moved to Xcode's filesystem-synchronized format
# (objectVersion 70), every cmuxTests/<file>.swift needed explicit per-file
# wiring (PBXFileReference + PBXBuildFile + Sources build phase entry). A file
# missing that wiring was silently ignored by Xcode: both bot reviews and
# `xcodebuild test -only-testing:cmuxTests/<TestClass>` passed with
# "Executed 0 tests", so a missing wire was indistinguishable from a passing
# regression test (surfaced during the
# https://github.com/manaflow-ai/cmux/issues/4529 investigation, where
# SessionIndexJSONLStreamTests.swift on
# https://github.com/manaflow-ai/cmux/pull/4536 never actually ran on CI).
#
# Synchronized groups eliminate that failure mode: every on-disk .swift under
# cmuxTests/ compiles into the cmuxTests target automatically, with no
# per-file wiring to forget. The remaining ways a test can silently drop out
# of CI are exactly what this lint now guards:
#   1. cmuxTests/ stops being a synchronized group (someone de-converts it
#      back to a plain PBXGroup, reintroducing per-file wiring).
#   2. The cmuxTests target stops owning the synchronized group via
#      fileSystemSynchronizedGroups.
#   3. A PBXFileSystemSynchronizedBuildFileExceptionSet on the group (with
#      target = cmuxTests) lists a .swift file in membershipExceptions —
#      Xcode writes this when target membership is unticked, and the excluded
#      test never compiles or runs while everything still looks green.
#
# Usage:
#   ./scripts/lint-pbxproj-test-wiring.sh [--repo-root <path>]
#
# Exit codes:
#   0 — invariant holds (synchronized + owned, no .swift membership exclusion)
#   1 — invariant violated (a test file can silently skip CI)
#   2 — invocation error (e.g. project.pbxproj not found)

set -euo pipefail

REPO_ROOT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-root)
      REPO_ROOT="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '1,36p' "$0" | sed 's/^# *//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
fi

PBXPROJ="$REPO_ROOT/cmux.xcodeproj/project.pbxproj"
TESTS_DIR="$REPO_ROOT/cmuxTests"

if [ ! -f "$PBXPROJ" ]; then
  echo "lint-pbxproj-test-wiring: not found: $PBXPROJ" >&2
  echo "  (run from the cmux repo root or pass --repo-root)" >&2
  exit 2
fi
if [ ! -d "$TESTS_DIR" ]; then
  echo "lint-pbxproj-test-wiring: not found: $TESTS_DIR" >&2
  exit 2
fi

# Locate the cmuxTests PBXNativeTarget. `/* cmuxTests */ = {` appears more
# than once in the pbxproj (the synchronized root group and the native
# target share the comment), so capture every such block and keep the one
# whose `isa = PBXNativeTarget;` line is present.
tests_target_block="$(awk '
  /\/\* cmuxTests \*\/ = \{/ { capture = 1; buf = "" }
  capture { buf = buf $0 "\n" }
  capture && /^[[:space:]]*\};[[:space:]]*$/ {
    if (buf ~ /isa = PBXNativeTarget;/) {
      print buf
      exit
    }
    capture = 0
    buf = ""
  }
' "$PBXPROJ")"

if [ -z "$tests_target_block" ]; then
  echo "lint-pbxproj-test-wiring: could not locate cmuxTests PBXNativeTarget in $PBXPROJ" >&2
  exit 2
fi

tests_target_uuid="$(printf '%s\n' "$tests_target_block" | head -n 1 | awk '{print $1}')"

# Locate the PBXFileSystemSynchronizedRootGroup whose path is cmuxTests.
# Blocks can nest braces (e.g. `explicitFileTypes = { };`), so track depth
# instead of stopping at the first `};` line.
tests_sync_group_uuid="$(awk '
  !capture && /^[[:space:]]*[A-Z0-9]+ \/\* cmuxTests \*\/ = \{$/ { capture = 1; depth = 0; buf = ""; uuid = $1 }
  capture {
    buf = buf $0 "\n"
    depth += gsub(/\{/, "{") - gsub(/\}/, "}")
    if (depth == 0) {
      if (buf ~ /isa = PBXFileSystemSynchronizedRootGroup;/ && buf ~ /path = cmuxTests;/) {
        print uuid
        exit
      }
      capture = 0
    }
  }
' "$PBXPROJ")"

if [ -z "$tests_sync_group_uuid" ]; then
  echo "lint-pbxproj-test-wiring: cmuxTests is not governed by a PBXFileSystemSynchronizedRootGroup in cmux.xcodeproj/project.pbxproj" >&2
  echo >&2
  echo "The project uses Xcode's filesystem-synchronized format (objectVersion 70):" >&2
  echo "cmuxTests/ must be a synchronized root group owned by the cmuxTests target" >&2
  echo "so every on-disk test file compiles automatically. De-converting it to a" >&2
  echo "plain PBXGroup reintroduces per-file wiring that can silently skip tests" >&2
  echo "on CI (https://github.com/manaflow-ai/cmux/issues/4529)." >&2
  exit 1
fi

# The synchronized group only feeds the cmuxTests target if the target lists
# it under fileSystemSynchronizedGroups.
if ! printf '%s\n' "$tests_target_block" | grep -qF "$tests_sync_group_uuid"; then
  echo "lint-pbxproj-test-wiring: cmuxTests is a filesystem-synchronized group ($tests_sync_group_uuid) but the cmuxTests target does not own it via fileSystemSynchronizedGroups" >&2
  echo >&2
  echo "Without that ownership entry no file under cmuxTests/ compiles into the" >&2
  echo "cmuxTests target, so the whole suite silently skips on CI." >&2
  exit 1
fi

# Slice the synchronized group's block so we only consider exception sets
# attached to it (exception sets on other synchronized groups that name the
# cmuxTests target ADD files to cmuxTests; only sets on this group with
# target = cmuxTests REMOVE membership).
tests_sync_group_block="$(awk -v needle="$tests_sync_group_uuid /* cmuxTests */ = {" '
  !capture && index($0, needle) { capture = 1; depth = 0 }
  capture {
    print
    depth += gsub(/\{/, "{") - gsub(/\}/, "}")
    if (depth == 0) exit
  }
' "$PBXPROJ")"

excluded=()
exc_uuids="$(printf '%s\n' "$tests_sync_group_block" \
  | sed -n 's,^[[:space:]]*\([A-Z0-9][A-Z0-9]*\) /\* Exceptions for.*,\1,p')"
for exc_uuid in $exc_uuids; do
  exc_block="$(awk -v needle="$exc_uuid /* " '
    !capture && index($0, needle) && /= \{$/ { capture = 1; depth = 0 }
    capture {
      print
      depth += gsub(/\{/, "{") - gsub(/\}/, "}")
      if (depth == 0) exit
    }
  ' "$PBXPROJ")"
  # Only exception sets targeting cmuxTests itself remove membership; sets
  # for other targets add the listed files to those targets instead.
  printf '%s\n' "$exc_block" | grep -qE "target = $tests_target_uuid( |;)" || continue
  while IFS= read -r f; do
    [ -n "$f" ] && excluded+=("$f")
  done < <(printf '%s\n' "$exc_block" \
    | sed -n '/membershipExceptions = (/,/);/p' \
    | grep -oE '[A-Za-z0-9_+./"-]+\.swift' | tr -d '"')
done

if [ "${#excluded[@]}" -gt 0 ]; then
  echo "lint-pbxproj-test-wiring: ${#excluded[@]} test file(s) excluded from the cmuxTests target via membershipExceptions on the synchronized cmuxTests group in cmux.xcodeproj/project.pbxproj" >&2
  for f in "${excluded[@]}"; do
    echo "  - $f" >&2
  done
  echo >&2
  echo "Files under cmuxTests/ compile automatically; an excluded file never" >&2
  echo "compiles or runs on CI while everything still looks green. Remove the" >&2
  echo "membershipExceptions entry (Xcode: tick the cmuxTests target membership" >&2
  echo "for the file) so the test actually runs." >&2
  exit 1
fi

checked="$(find "$TESTS_DIR" -type f -name '*.swift' | wc -l | tr -d '[:space:]')"
echo "lint-pbxproj-test-wiring: OK (cmuxTests is a filesystem-synchronized group owned by the cmuxTests target; $checked on-disk test file(s) compile automatically, no membership exclusions)"
exit 0
