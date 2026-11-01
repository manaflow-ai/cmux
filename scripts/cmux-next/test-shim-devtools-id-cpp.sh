#!/usr/bin/env bash
# Compiles the shim's DevTools message helpers
# (CEFShim/src/devtools_message_id.h, no CEF needed: the id scanner and the
# message of cmux_shim_devtools_call) and runs their cases.
# Small: one clang++ call.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/shim-devtools-id.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
"${cxx[@]}" -std=c++17 -Wall -Werror -O1 \
  -o "$work/test" "$root/Packages/macOS/CmuxNext/CEFShim/tests/devtools_message_id_test.cpp"
"$work/test"
