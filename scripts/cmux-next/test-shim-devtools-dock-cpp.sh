#!/usr/bin/env bash
# Compiles the shim's DevTools dock-side values
# (CEFShim/src/devtools_dock_state.h, no CEF needed: the frontend setting
# value of each host dock side) and runs its cases.
# Small: one clang++ call.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/shim-devtools-dock.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
"${cxx[@]}" -std=c++17 -Wall -Werror -O1 \
  -o "$work/test" "$root/Packages/macOS/CmuxNext/CEFShim/tests/devtools_dock_state_test.cpp"
"$work/test"
