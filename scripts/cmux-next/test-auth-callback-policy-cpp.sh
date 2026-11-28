#!/usr/bin/env bash
# Compiles the shim's sign-in callback rule (CEFShim/src/auth_callback_policy.h,
# no CEF needed) and runs its cases. Small: one clang++ call.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/auth-callback-policy.XXXXXX")"
trap 'rm -rf "$work"' EXIT
xcrun clang++ -std=c++17 -Wall -Werror -O1 \
  -o "$work/test" "$root/Packages/macOS/CmuxNext/CEFShim/tests/auth_callback_policy_test.cpp"
"$work/test"
