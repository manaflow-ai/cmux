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
# A runner with no zlib.h gets zlib from ci/steps.toml's `zlib` tool, under "$CI_TOOLS/zlib".
zlib_include=()
zlib_lib=(-lz)
if [[ -n "${CI_TOOLS:-}" && -f "$CI_TOOLS/zlib/include/zlib.h" ]]; then
  zlib_include=(-isystem "$CI_TOOLS/zlib/include")
  zlib_lib=("$CI_TOOLS/zlib/lib/libz.a")
fi
"${cxx[@]}" -std=c++17 -Wall -Werror -O1 "${zlib_include[@]}" \
  -o "$work/test" "$root/Packages/macOS/CmuxNext/CEFShim/tests/cmux_page_path_test.cpp" "${zlib_lib[@]}"
"$work/test"
