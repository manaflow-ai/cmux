#!/usr/bin/env bash
# Compiles the shim's DevTools frontend-loaded signal
# (CEFShim/src/devtools_ready.h, no CEF needed: the frontend script
# and its console marker) and runs their cases.
# Small: one clang++ call.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/shim-devtools-ready.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
"${cxx[@]}" -std=c++17 -Wall -Werror -O1 \
  -o "$work/test" "$root/Packages/macOS/CmuxNext/CEFShim/tests/devtools_ready_test.cpp"
"$work/test"
