#!/usr/bin/env bash
# Compiles which DevTools frontend a shim DevTools call names
# (CEFShim/src/devtools_call_target.h, no CEF needed: a docked frontend's own
# id reaches it) and runs its cases.
# Small: one clang++ call.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/shim-devtools-call-target.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
"${cxx[@]}" -std=c++17 -Wall -Werror -O1 \
  -o "$work/test" "$root/Packages/macOS/CmuxNext/CEFShim/tests/devtools_call_target_test.cpp"
"$work/test"
