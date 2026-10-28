#!/usr/bin/env bash
# Compiles the shim's frame renderer reports (CEFShim/src/frame_renderers.h, no
# CEF needed) and runs its cases: FRAME_RENDERERS goes out once
# per burst of frame changes, and only for a new set of renderers.
# Small: one clang++ call.
#
# Not a scripts/cmux-next/test-*-cpp.sh, so cmux-next-shim-cpp.yml does not run
# it (lead, 2026-10-23: no new CI tests); agents that change the reports run it.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/shim-frame-renderers.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=../lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
"${cxx[@]}" -std=c++17 -Wall -Wextra -Werror -O1 \
  -o "$work/test" "$root/Packages/macOS/CmuxNext/CEFShim/tests/frame_renderers_test.cpp"
"$work/test"
