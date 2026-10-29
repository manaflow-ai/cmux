#!/usr/bin/env bash
# Compiles the Chromium Host's focus rule (CEFShim/src/embedder_focus_policy.h,
# no CEF needed) and runs its cases. Small: one clang++
# call. Not in CI (no new CI tests); run it when you change the rule.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/embedder-focus-policy.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
"${cxx[@]}" -std=c++17 -Wall -Wextra -Werror -O1 \
  -o "$work/test" "$root/Packages/macOS/CmuxNext/CEFShim/tests/embedder_focus_policy_test.cpp"
"$work/test"
