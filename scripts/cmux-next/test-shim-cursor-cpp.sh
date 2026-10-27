#!/usr/bin/env bash
# Compiles the shim's cursor event numbers
# (CEFShim/src/cursor_event.h, no CEF needed) and runs its cases.
# Small: one clang++ call.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/shim-cursor.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
"${cxx[@]}" -std=c++20 -Wall -Werror -O1 \
  -o "$work/test" "$root/Packages/macOS/CmuxNext/CEFShim/tests/cursor_event_test.cpp"
"$work/test"
