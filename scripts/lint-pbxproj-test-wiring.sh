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
# The same check covers app source directories: `--target cmux --tests-dir
# Sources --recursive --allowlist scripts/pbxproj-sources-wiring-allowlist.txt`
# fails when a Sources/**/*.swift file is not compiled into the app target.
# That is how main stopped compiling on 2026-09-25: a merge dropped
# AgentChatProseStreamWakeDriver.swift from the cmux target while code on main
# still used its types.
#
# Usage:
#   ./scripts/lint-pbxproj-test-wiring.sh [--repo-root <path>]
#       [--target <name>] [--tests-dir <dir>] [--recursive]
#       [--allowlist <file>]
#
#   --recursive   check *.swift in every subdirectory, not just the top level.
#   --allowlist   file of repo-relative paths that are deliberately not target
#                 members, one per line, `#` comments allowed. An entry whose
#                 file is gone or is now wired fails, so the list cannot rot.
#
# Exit codes:
#   0 — all test files wired correctly (or no test files present)
#   1 — at least one test file is missing pbxproj wiring
#   2 — invocation error (e.g. project.pbxproj not found)

set -euo pipefail

REPO_ROOT=""
TARGET_NAME="cmuxTests"
TESTS_DIR_ARG=""
RECURSIVE=false
ALLOWLIST=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-root)
      REPO_ROOT="$2"
      shift 2
      ;;
    --target)
      TARGET_NAME="$2"
      shift 2
      ;;
    --tests-dir)
      TESTS_DIR_ARG="$2"
      shift 2
      ;;
    --recursive)
      RECURSIVE=true
      shift
      ;;
    --allowlist)
      ALLOWLIST="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '1,40p' "$0" | sed 's/^# *//'
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
TESTS_REL="${TESTS_DIR_ARG:-$TARGET_NAME}"
TESTS_DIR="$REPO_ROOT/$TESTS_REL"

if [ ! -f "$PBXPROJ" ]; then
  echo "lint-pbxproj-test-wiring: not found: $PBXPROJ" >&2
  echo "  (run from the cmux repo root or pass --repo-root)" >&2
  exit 2
fi
if [ ! -d "$TESTS_DIR" ]; then
  echo "lint-pbxproj-test-wiring: not found: $TESTS_DIR" >&2
  exit 2
fi

# Locate the cmuxTests PBXNativeTarget and resolve its Sources build phase
# UUID. We then slice out just that build phase block and look for files inside
# it — which is exactly the set of files Xcode compiles into cmuxTests.
#
# Targeting the cmuxTests Sources phase specifically (instead of the whole
# pbxproj) catches three failure modes:
#   1. File missing entirely (no `<file>.swift in Sources` anywhere).
#   2. File has a PBXFileReference + group child but no PBXBuildFile /
#      Sources phase entry (in the project tree but not a member of any
#      target).
#   3. File is a member of the wrong target (e.g. cmuxUITests or cmux). Its
#      `<file>.swift in Sources` lines exist in the pbxproj, so a global grep
#      would pass, but they are not inside the cmuxTests Sources block.
# `/* cmuxTests */ = {` appears twice in a typical pbxproj: once for the
# PBXGroup that holds the test files, and once for the PBXNativeTarget. We
# only care about the native-target block. Use awk to capture every
# `/* cmuxTests */ = { ... };` block and keep only the one whose `isa =
# PBXNativeTarget;` line is present.
tests_target_block="$(awk -v target="$TARGET_NAME" '
  $0 ~ "/\\* " target " \\*/ = \\{" { capture = 1; buf = "" }
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
  echo "lint-pbxproj-test-wiring: could not locate $TARGET_NAME PBXNativeTarget in $PBXPROJ" >&2
  exit 2
fi

# Xcode UUIDs are conventionally 24 uppercase hex chars, but hand-edited
# pbxprojs use other lengths too: the cmux app target's Sources phase is the
# 8-char A5001051. Accept any alphanumeric identifier.
tests_sources_uuid="$(printf '%s\n' "$tests_target_block" \
  | grep -oE '[A-Za-z0-9]+ /\* Sources \*/' \
  | head -n 1 \
  | awk '{print $1}')"

if [ -z "$tests_sources_uuid" ]; then
  echo "lint-pbxproj-test-wiring: $TARGET_NAME target has no Sources build phase reference" >&2
  exit 2
fi

# Slice the PBXSourcesBuildPhase block whose UUID matches the cmuxTests
# target's Sources phase reference. The block begins with the UUID/Sources
# header and ends at the next standalone "};" line.
tests_sources_block="$(awk -v uuid="$tests_sources_uuid" '
  $0 ~ "(^|[^A-Za-z0-9])" uuid " /\\* Sources \\*/ = \\{" { capture = 1 }
  capture { print }
  capture && /^[[:space:]]*\};[[:space:]]*$/ { exit }
' "$PBXPROJ")"

if [ -z "$tests_sources_block" ]; then
  echo "lint-pbxproj-test-wiring: could not slice $TARGET_NAME Sources build phase (uuid=$tests_sources_uuid)" >&2
  exit 2
fi

allowed=()
if [ -n "$ALLOWLIST" ]; then
  allowlist_path="$ALLOWLIST"
  case "$allowlist_path" in /*) ;; *) allowlist_path="$REPO_ROOT/$allowlist_path" ;; esac
  if [ ! -f "$allowlist_path" ]; then
    echo "lint-pbxproj-test-wiring: allowlist not found: $allowlist_path" >&2
    exit 2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$line" ] && allowed+=("$line")
  done < "$allowlist_path"
fi

is_allowed() {
  local entry
  for entry in ${allowed[@]+"${allowed[@]}"}; do
    [ "$entry" = "$1" ] && return 0
  done
  return 1
}

find_depth=(-maxdepth 1)
if [ "$RECURSIVE" = true ]; then
  find_depth=()
fi

# Names compiled by this target, one per line, from each
# `/* <base> in Sources */` entry in its Sources phase. grep -o, not a
# per-line sed: merges have left two entries on one line. Comparing whole
# names (not a substring grep) keeps `SearchIndexTests.swift` from matching
# the wired `SettingsSearchIndexTests.swift`.
wired_names="$(grep -oE '/\* [^*]+ in Sources \*/' <<<"$tests_sources_block" \
  | sed -e 's#^/\* ##' -e 's# in Sources \*/$##' || true)"

# Repo-relative paths of the Swift files to check. Plain command substitutions
# so set -e and pipefail stop the lint if find or awk fails, instead of an
# empty list reading as "all wired".
all_files="$(find "$TESTS_DIR" ${find_depth[@]+"${find_depth[@]}"} -type f -name '*.swift' \
  | ROOT_PREFIX="$REPO_ROOT/" awk '{ print substr($0, length(ENVIRON["ROOT_PREFIX"]) + 1) }' \
  | LC_ALL=C sort)"
checked=0
[ -n "$all_files" ] && checked="$(printf '%s\n' "$all_files" | wc -l | tr -d ' ')"

# Membership is by file name, which is exact only while names are unique: an
# unwired Sources/B/Foo.swift would otherwise pass on a wired Sources/A/Foo.swift.
duplicates="$(printf '%s\n' "$all_files" | awk -F/ 'NF { print $NF }' | LC_ALL=C sort | uniq -d)"
if [ -n "$duplicates" ]; then
  echo "lint-pbxproj-test-wiring: Swift file names under $TESTS_REL/ must be unique; target membership is checked by name:"
  printf '%s\n' "$duplicates" | while IFS= read -r name; do
    printf '%s\n' "$all_files" | awk -F/ -v n="$name" '$NF == n { print "  - " $0 }'
  done
  exit 1
fi

unwired="$(printf '%s\n' "$all_files" | awk '
  NR == FNR { if ($0 != "") wired[$0] = 1; next }
  $0 != "" { base = $0; sub(/.*\//, "", base); if (!(base in wired)) print }
' <(printf '%s\n' "$wired_names") -)"

missing=()
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  if is_allowed "$rel"; then
    continue
  fi
  if [ "$RECURSIVE" = true ]; then
    missing+=("$rel")
  else
    missing+=("${rel##*/}")
  fi
done <<<"$unwired"

is_wired() {
  grep -qxF -- "$1" <<<"$wired_names"
}

stale=()
for entry in ${allowed[@]+"${allowed[@]}"}; do
  if [ ! -f "$REPO_ROOT/$entry" ]; then
    stale+=("$entry (file does not exist)")
  elif is_wired "${entry##*/}"; then
    stale+=("$entry (now a member of $TARGET_NAME)")
  fi
done
if [ "${#stale[@]}" -gt 0 ]; then
  echo "lint-pbxproj-test-wiring: ${#stale[@]} stale allowlist entr(y/ies) in $ALLOWLIST; remove them:"
  for entry in "${stale[@]}"; do
    echo "  - $entry"
  done
  exit 1
fi

if [ "${#missing[@]}" -eq 0 ]; then
  echo "lint-pbxproj-test-wiring: ok (checked $checked Swift files)"
  exit 0
fi

echo "lint-pbxproj-test-wiring: ${#missing[@]} Swift file(s) not a member of the $TARGET_NAME target's Sources build phase (uuid=$tests_sources_uuid) in cmux.xcodeproj/project.pbxproj"
for entry in "${missing[@]}"; do
  echo "  - $entry"
done
echo ""
echo "Each $TESTS_REL/<file>.swift must be wired into cmux.xcodeproj/project.pbxproj"
echo "as a full target member of $TARGET_NAME:"
echo "  1. a PBXBuildFile entry (line ends with '<file>.swift in Sources */ = { ... };')"
echo "  2. a PBXFileReference entry"
echo "  3. an entry in the $TARGET_NAME group children list"
echo "  4. an entry in the $TARGET_NAME target's PBXSourcesBuildPhase files"
echo "     (line ends with '<file>.swift in Sources */,')"
echo ""
echo "This lint slices the $TARGET_NAME Sources phase and looks for entry 4 there."
echo "Files wired only into cmuxUITests, cmux, or the project tree (without"
echo "$TARGET_NAME target membership) are silently skipped by Xcode and will be"
echo "flagged here."
echo ""
if [ "$TARGET_NAME" = "cmuxTests" ] && [ "$TESTS_REL" = "cmuxTests" ]; then
  echo "Run ./scripts/sync-test-wiring to reconcile direct $TESTS_REL/*.swift files."
  echo "Use ./scripts/sync-test-wiring --check for a read-only authoring/CI check."
else
  # sync-test-wiring only reconciles cmuxTests. Other targets are wired by hand.
  echo "sync-test-wiring only reconciles cmuxTests; add the four $TARGET_NAME"
  echo "entries above by hand (or in Xcode) for $TESTS_REL/*.swift."
fi
echo "This lint remains the defensive $TARGET_NAME Sources-phase guard."
exit 1
