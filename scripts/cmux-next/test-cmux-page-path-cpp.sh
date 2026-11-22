#!/usr/bin/env bash
# Compiles the shim's cmux-page:// path, MIME and id rules
# (CEFShim/src/cmux_page_path.h, no CEF needed) and runs them on a temporary
# directory tree with symlinks. Small: one clang++ call.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/cmux-page-path.XXXXXX")"
trap 'rm -rf "$work"' EXIT
xcrun clang++ -std=c++17 -Wall -Werror -O1 \
  -o "$work/test" "$root/Packages/macOS/CmuxNext/CEFShim/tests/cmux_page_path_test.cpp"
"$work/test"
