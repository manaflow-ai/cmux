#!/usr/bin/env bash
# Compiles the shim's host-mode key seq table (CEFShim/src/host_key_seqs.h,
# no CEF needed) and runs its cases. Small: one clang++ call.
#
# Not a scripts/cmux-next/test-*-cpp.sh, so cmux-next-shim-cpp.yml does not run
# it (lead, 2026-10-23: no new CI tests); agents that change the table run it.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/shim-host-key-seqs.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=../lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
"${cxx[@]}" -std=c++17 -Wall -Wextra -Werror -O1 \
  -o "$work/test" "$root/Packages/macOS/CmuxNext/CEFShim/tests/host_key_seqs_test.cpp"
"$work/test"
