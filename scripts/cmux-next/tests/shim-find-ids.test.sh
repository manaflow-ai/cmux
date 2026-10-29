#!/usr/bin/env bash
# Compiles the shim's find id table (CEFShim/src/find_ids.h, no CEF needed) and
# runs its cases: FIND_RESULT carries the caller's find id.
# Small: one clang++ call.
#
# Not a scripts/cmux-next/test-*-cpp.sh, so cmux-next-shim-cpp.yml does not run
# it (lead, 2026-10-23: no new CI tests); agents that change the table run it.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/shim-find-ids.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=../lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
"${cxx[@]}" -std=c++17 -Wall -Wextra -Werror -O1 \
  -o "$work/test" "$root/Packages/macOS/CmuxNext/CEFShim/tests/find_ids_test.cpp"
"$work/test"
