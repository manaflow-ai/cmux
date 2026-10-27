#!/usr/bin/env bash
# Compiles the shim's unsafe-buffer helpers (CEFShim/src/unsafe_buffers.h, no
# CEF needed) and runs their cases. Under clang the test builds with
# -Werror=unsafe-buffer-usage, as build-cef-shim.sh builds the shim, so the
# helpers themselves stay inside the rule. Small: one clang++ call.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/shim-unsafe-buffers.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
rule=()
if "${cxx[@]}" --version 2>/dev/null | grep -q clang; then
  rule=(-Wunsafe-buffer-usage -Werror=unsafe-buffer-usage)
fi
"${cxx[@]}" -std=c++20 -Wall -Wextra -Werror -O1 ${rule[@]+"${rule[@]}"} \
  -o "$work/test" "$root/Packages/macOS/CmuxNext/CEFShim/tests/unsafe_buffers_test.cpp"
"$work/test"
