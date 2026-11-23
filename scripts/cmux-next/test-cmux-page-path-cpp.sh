#!/usr/bin/env bash
# Compiles the shim's cmux-page:// path, MIME and id rules and its packed files
# (CEFShim/src/cmux_page_path.h and cmux_page_packed.h, no CEF needed; zlib) and runs them on a temporary
# directory tree with symlinks. Small: one clang++ call.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/cmux-page-path.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
"${cxx[@]}" -std=c++17 -Wall -Werror -O1 \
  -o "$work/test" "$root/Packages/macOS/CmuxNext/CEFShim/tests/cmux_page_path_test.cpp" -lz
"$work/test"
