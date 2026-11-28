#!/usr/bin/env bash
# Compiles the shim's C++ agent URL rule (CEFShim/src/agent_url_policy.h,
# no CEF needed) and runs it against schemas/agent-url-policy/vectors.json,
# the vectors the Swift and Rust copies also pass. Small: one clang++ call.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/agent-url-policy.XXXXXX")"
trap 'rm -rf "$work"' EXIT
xcrun clang++ -std=c++17 -Wall -Werror -O1 \
  -o "$work/test" "$root/Packages/macOS/CmuxNext/CEFShim/tests/agent_url_policy_test.cpp"
python3 - "$root/schemas/agent-url-policy/vectors.json" > "$work/cases" <<'PY'
import json, sys
for case in json.load(open(sys.argv[1]))["cases"]:
    print("1" if case["refused"] else "0", case["url"].encode("utf-8").hex() or "-")
PY
"$work/test" < "$work/cases"
