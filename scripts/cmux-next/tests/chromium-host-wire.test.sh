#!/usr/bin/env bash
# Compiles the Chromium host wire (ChromiumHost/src/chromium_host_wire.h) and
# control channel (chromium_host_control.{h,cc}), no CEF needed, and checks
# each against the golden frame that the Swift side (ChromiumHostFrameTests,
# ChromiumHostControlChannelTests) checks too, then the one ordered input
# stream (chromium_host_order_test.cpp, task 092), the host's input queue
# (host_user_input_test.cpp) and its hang watch
# (host_hang_watcher_test.cpp). Small: five clang++ calls.
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
host="$root/Packages/macOS/CmuxNext/ChromiumHost"
"${cxx[@]}" -std=c++17 -Wall -Wextra -Werror -O1 -pthread \
  -o "$work/control-test" "$host/tests/chromium_host_control_test.cpp" "$host/src/chromium_host_control.cc"
"$work/control-test"
"${cxx[@]}" -std=c++17 -Wall -Wextra -Werror -O1 -pthread \
  -o "$work/order-test" "$host/tests/chromium_host_order_test.cpp" "$host/src/chromium_host_control.cc"
"$work/order-test"
# The host's input queue choice and event time scope (host_user_input.h).
"${cxx[@]}" -std=c++17 -Wall -Wextra -Werror -O1 \
  -o "$work/user-input-test" "$host/tests/host_user_input_test.cpp"
"$work/user-input-test"
# The host's hang watch and cmux's input ack count (host_hang_watcher.h).
"${cxx[@]}" -std=c++17 -Wall -Wextra -Werror -O1 -pthread \
  -o "$work/hang-watcher-test" "$host/tests/host_hang_watcher_test.cpp" "$host/src/chromium_host_control.cc"
"$work/hang-watcher-test"
