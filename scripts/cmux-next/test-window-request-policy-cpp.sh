#!/usr/bin/env bash
# Compiles the shim's pushed window request decision
# (CEFShim/src/window_request_policy.h; no CEF needed)
# and runs its cases. Small: one clang++ call.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/window-request-policy.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
"${cxx[@]}" -std=c++20 -Wall -Wextra -Werror -O1 \
  -o "$work/test" "$root/Packages/macOS/CmuxNext/CEFShim/tests/window_request_policy_test.cpp"
"$work/test"
