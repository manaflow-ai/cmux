#!/usr/bin/env bash
# Compiles the shim's permission prompt rule (CEFShim/src/permission_prompt_policy.h,
# no CEF needed) and runs its cases. Small: one clang++ call.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/permission-prompt-policy.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
"${cxx[@]}" -std=c++17 -Wall -Werror -O1 \
  -o "$work/test" "$root/Packages/macOS/CmuxNext/CEFShim/tests/permission_prompt_policy_test.cpp"
"$work/test"
