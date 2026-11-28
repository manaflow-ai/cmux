#!/usr/bin/env bash
# Compiles the shim's download and popup bookkeeping
# (CEFShim/src/download_state.h, no CEF needed) and runs its cases.
# Small: one clang++ call.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/shim-downloads.XXXXXX")"
trap 'rm -rf "$work"' EXIT
xcrun clang++ -std=c++20 -Wall -Werror -O1 \
  -o "$work/test" "$root/Packages/macOS/CmuxNext/CEFShim/tests/download_state_test.cpp"
"$work/test"
