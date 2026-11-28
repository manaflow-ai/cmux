#!/usr/bin/env bash
# Compiles the shim's C++ local file handoff rule (CEFShim/src/local_file_handoff.h,
# no CEF needed) and runs it against the "cef" column of
# schemas/local-file-handoff/vectors.json, the vectors the Swift copy also
# passes. Small: one clang++ call. CXX overrides the compiler (Linux: c++).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/local-file-handoff.XXXXXX")"
trap 'rm -rf "$work"' EXIT
if [[ -n "${CXX:-}" ]]; then compile=("$CXX"); else compile=(xcrun clang++); fi
"${compile[@]}" -std=c++17 -Wall -Werror -O1 \
  -o "$work/test" "$root/Packages/macOS/CmuxNext/CEFShim/tests/local_file_handoff_test.cpp"
python3 - "$root/schemas/local-file-handoff/vectors.json" > "$work/cases" <<'PY'
import json, sys
for case in json.load(open(sys.argv[1]))["cases"]:
    print("1" if case["cef"] else "0", case["url"].encode("utf-8").hex() or "-")
PY
"$work/test" < "$work/cases"
