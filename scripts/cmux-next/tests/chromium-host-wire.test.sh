#!/usr/bin/env bash
# Compiles the Chromium host wire (ChromiumHost/src/chromium_host_wire.h, no
# CEF needed) and checks it against the golden frame that the Swift side
# (ChromiumHostFrameTests) checks too. Small: one clang++ call.
#
# The host is a Debug-only prototype, not part of the CEF shim, so this is not
# one of the shim's scripts/cmux-next/test-*-cpp.sh that cmux-next-shim-cpp.yml
# runs. Agents that change either side of the wire run this and the Swift
# test themselves (lead, 2026-10-23: no new CI tests).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/chromium-host-wire.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=../lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
"${cxx[@]}" -std=c++17 -Wall -Werror -O1 \
  -o "$work/test" "$root/Packages/macOS/CmuxNext/ChromiumHost/tests/chromium_host_wire_test.cpp"
"$work/test"
