#!/usr/bin/env bash
# Compiles the Chromium host input ring (ChromiumHost/src/chromium_host_input_ring.h),
# no CEF needed, and runs its test: the golden bytes the
# Swift side (ChromiumHostInputRingTests) checks too, full and broken rings,
# the park protocol, how the reader ends, the host reader's back-pressure
# handshake over 1,000,000 frames and a 1,000,000-frame process pair (the Mach
# doorbell on macOS, a pipe elsewhere) and the host's input acks (AckBatch,
# host_input.h). It also compiles the reader child the
# Swift test spawns (chromium_host_input_ring_reader.cpp). Not a CI test
# (lead, 2026-10-23): whoever changes either side of the ring runs this and
# the Swift test.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/chromium-host-input-ring.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=../lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
"${cxx[@]}" -std=c++20 -fno-exceptions -Wall -Wextra -Werror -O2 \
  -o "$work/test" "$root/Packages/macOS/CmuxNext/ChromiumHost/tests/chromium_host_input_ring_test.cpp" \
  "$root/Packages/macOS/CmuxNext/ChromiumHost/src/chromium_host_control.cc"
"${cxx[@]}" -std=c++20 -fno-exceptions -Wall -Wextra -Werror -O2 \
  -o "$work/reader" "$root/Packages/macOS/CmuxNext/ChromiumHost/tests/chromium_host_input_ring_reader.cpp"
"$work/test"
