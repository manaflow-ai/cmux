#!/usr/bin/env bash
# Compiles and runs every C++ policy test of the CEF shim
# (Packages/macOS/CmuxCEF/CEFShim/tests/*_test.cpp). Each test includes only
# pure headers from CEFShim/src, so no CEF artifact is needed and this runs on
# macOS or Linux (CXX overrides the compiler; default xcrun clang++ on macOS,
# else clang++ or c++). A test listed in VECTOR_TESTS reads cases from a
# shared vectors file on stdin, the same vectors the Swift copy passes.
#
# Usage: scripts/cef/test-shim-cpp.sh [--shim-dir DIR] [--schemas-dir DIR] [NAME...]
#   NAME selects tests by file stem (e.g. download_state_test); default: all.
# Exits nonzero when a test fails, when a vectors file is missing, or when the
# shim directory exists but holds no tests (a lost glob must not pass).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
shim_dir="$root/Packages/macOS/CmuxCEF/CEFShim"
schemas_dir="$root/schemas"
selected=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --shim-dir) shim_dir="$2"; shift 2 ;;
    --schemas-dir) schemas_dir="$2"; shift 2 ;;
    -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) echo "test-shim-cpp.sh: unknown option $1" >&2; exit 2 ;;
    *) selected+=("$1"); shift ;;
  esac
done

if [ ! -d "$shim_dir" ]; then
  echo "No CEF shim at $shim_dir; nothing to test."
  exit 0
fi

if [ -n "${CXX:-}" ]; then
  compile=("$CXX")
elif command -v xcrun >/dev/null 2>&1; then
  compile=(xcrun clang++)
elif command -v clang++ >/dev/null 2>&1; then
  compile=(clang++)
else
  compile=(c++)
fi

# stem -> "vectors path relative to schemas|python expression for the expected column"
vectors_for() {
  case "$1" in
    agent_url_policy_test) echo 'agent-url-policy/vectors.json|refused' ;;
    local_file_handoff_test) echo 'local-file-handoff/vectors.json|cef' ;;
    *) echo '' ;;
  esac
}

work="$(mktemp -d "${TMPDIR:-/tmp}/cef-shim-cpp.XXXXXX")"
trap 'rm -rf "$work"' EXIT

tests=()
if [ "${#selected[@]}" -gt 0 ]; then
  for name in "${selected[@]}"; do
    test_file="$shim_dir/tests/${name%.cpp}.cpp"
    [ -f "$test_file" ] || { echo "::error::no shim test $test_file" >&2; exit 1; }
    tests+=("$test_file")
  done
else
  for test_file in "$shim_dir"/tests/*_test.cpp; do
    [ -f "$test_file" ] && tests+=("$test_file")
  done
fi
if [ "${#tests[@]}" -eq 0 ]; then
  echo "::error::$shim_dir/tests has no *_test.cpp files" >&2
  exit 1
fi

failed=()
for test_file in "${tests[@]}"; do
  stem="$(basename "$test_file" .cpp)"
  binary="$work/$stem"
  echo "== $stem"
  if ! "${compile[@]}" -std=c++20 -Wall -Werror -O1 -o "$binary" "$test_file"; then
    failed+=("$stem (compile)")
    continue
  fi
  spec="$(vectors_for "$stem")"
  if [ -n "$spec" ]; then
    vectors="$schemas_dir/${spec%%|*}"
    column="${spec#*|}"
    if [ ! -f "$vectors" ]; then
      echo "::error::$stem reads $vectors, which is missing" >&2
      failed+=("$stem (vectors)")
      continue
    fi
    python3 - "$vectors" "$column" > "$work/$stem.cases" <<'PY'
import json, sys
column = sys.argv[2]
for case in json.load(open(sys.argv[1], encoding="utf-8"))["cases"]:
    print("1" if case[column] else "0", case["url"].encode("utf-8").hex() or "-")
PY
    "$binary" < "$work/$stem.cases" || failed+=("$stem")
  else
    "$binary" < /dev/null || failed+=("$stem")
  fi
done

if [ "${#failed[@]}" -gt 0 ]; then
  printf '::error::CEF shim C++ test failed: %s\n' "${failed[@]}" >&2
  exit 1
fi
echo "All ${#tests[@]} CEF shim C++ tests passed."
