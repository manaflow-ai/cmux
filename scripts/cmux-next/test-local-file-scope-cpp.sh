#!/usr/bin/env bash
# Compiles the shim's C++ local file scope rule (CEFShim/src/local_file_scope.h,
# no CEF needed) and runs it against schemas/local-file-scope/vectors.json.
# Small: one clang++ call.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/local-file-scope.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
"${cxx[@]}" -std=c++17 -Wall -Werror -O1 \
  -o "$work/test" "$root/Packages/macOS/CmuxNext/CEFShim/tests/local_file_scope_test.cpp"
python3 - "$root/schemas/local-file-scope/vectors.json" > "$work/cases" <<'PY'
import json, sys
for case in json.load(open(sys.argv[1]))["cases"]:
    print("1" if case["allowed"] else "0",
          case["document"].encode("utf-8").hex() or "-",
          case["request"].encode("utf-8").hex() or "-")
PY
"$work/test" < "$work/cases"
