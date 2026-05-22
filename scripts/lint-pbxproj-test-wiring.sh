#!/usr/bin/env bash
# Lint: every Swift file under cmuxTests/ must be wired into
# cmux.xcodeproj/project.pbxproj.
#
# A test file added to the worktree but not registered as a PBXFileReference +
# PBXSourcesBuildPhase entry in project.pbxproj is silently ignored by Xcode and
# never compiles or runs on CI. Both bot reviews and
# `xcodebuild test -only-testing:cmuxTests/<TestClass>` pass with
# "Executed 0 tests" — so missing wiring is indistinguishable from a passing
# regression test until a real user hits the bug the test was supposed to catch.
#
# Originally surfaced during the https://github.com/manaflow-ai/cmux/issues/4529
# investigation, where SessionIndexJSONLStreamTests.swift on
# https://github.com/manaflow-ai/cmux/pull/4536 looked like a clean two-commit
# red/green test fix but never actually ran on CI.
#
# Usage:
#   ./scripts/lint-pbxproj-test-wiring.sh [--repo-root <path>]
#
# Exit codes:
#   0 — all test files wired correctly (or no test files present)
#   1 — at least one test file is missing pbxproj wiring
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
      sed -n '1,25p' "$0" | sed 's/^# *//'
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

missing=()
checked=0

while IFS= read -r -d '' file; do
  base="$(basename "$file")"
  checked=$((checked + 1))
  # Target membership is what determines whether Xcode actually compiles/runs
  # the file. Only two pbxproj entries prove target membership, and both carry
  # the literal `<basename> in Sources` suffix:
  #   1. PBXBuildFile:           "<UUID> /* <base> in Sources */ = { ... };"
  #   2. PBXSourcesBuildPhase:   "<UUID> /* <base> in Sources */," (inside the
  #                              cmuxTests target's Sources build phase)
  # The bare filename also appears in PBXFileReference + group children, but
  # those entries are present even when the file is in the project tree but
  # NOT a member of the cmuxTests target — which is the silently-skipped case
  # that prompted this lint. Counting only `in Sources` lines guarantees we
  # catch missing target membership.
  hits="$(grep -c -- "$base in Sources" "$PBXPROJ" || true)"
  if [ "$hits" -lt 2 ]; then
    missing+=("$base (in-Sources hits=$hits)")
  fi
done < <(find "$TESTS_DIR" -maxdepth 1 -type f -name '*.swift' -print0)

if [ "${#missing[@]}" -eq 0 ]; then
  echo "lint-pbxproj-test-wiring: ok (checked $checked test files)"
  exit 0
fi

echo "lint-pbxproj-test-wiring: ${#missing[@]} test file(s) not a member of the cmuxTests target in cmux.xcodeproj/project.pbxproj"
for entry in "${missing[@]}"; do
  echo "  - $entry"
done
echo ""
echo "Each cmuxTests/<file>.swift must appear in cmux.xcodeproj/project.pbxproj as:"
echo "  1. a PBXBuildFile entry (line ends with '<file>.swift in Sources */ = { ... };')"
echo "  2. a PBXFileReference entry"
echo "  3. an entry in the cmuxTests group children list"
echo "  4. an entry in the cmuxTests target's PBXSourcesBuildPhase files"
echo "     (line ends with '<file>.swift in Sources */,')"
echo ""
echo "Entries 1 and 4 are the target-membership lines this lint counts."
echo ""
echo "Add via Xcode (drag the file into the cmuxTests target) or hand-edit"
echo "the four blocks (see any wired sibling test as a template)."
exit 1
