#!/usr/bin/env bash
# Compiles and runs the Chromium Host's black box, crash keys, metrics file and
# pump watch test (ChromiumHost/tests/host_black_box_test.cpp, task
# p09-observability-104) with the C ring writer (CEFShim/src/cmux_trace.h, task
# 094). No CEF; runs on Linux and macOS. First, the host's catalog ids are
# checked against SignpostName.swift.
#
# Not in CI (lead, 2026-10-23: no new CI tests); run it when you change
# host_black_box.h, host_pump_metrics.h, host_pump_watch.h or cmux_trace.h.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/chromium-host-black-box.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=../lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
host="$root/Packages/macOS/CmuxNext/ChromiumHost"
signposts="$root/Packages/macOS/CmuxNext/Sources/CmuxNextSignposts/SignpostName.swift"

for pair in cefPump:kTraceCefPump cefCreateBrowser:kTraceCefCreateBrowser cefHostInput:kTraceCefHostInput \
  hangThreadHung:kTraceHangThreadHung; do
  swift_name="${pair%%:*}"
  c_name="${pair##*:}"
  id="$(sed -n "s/^ *case $swift_name = \([0-9]*\)$/\1/p" "$signposts")"
  [[ -n "$id" ]] || { echo "FAIL: SignpostName has no $swift_name" >&2; exit 1; }
  grep -q "inline constexpr uint16_t $c_name = $id;" "$host/src/host_black_box.h" ||
    { echo "FAIL: $c_name is not SignpostName.$swift_name ($id)" >&2; exit 1; }
done

"${cxx[@]}" -std=c++20 -Wall -Wextra -Werror -O1 -pthread -D_GNU_SOURCE \
  -I"$host/src" -I"$root/Packages/macOS/CmuxNext/CEFShim/src" \
  -o "$work/test" "$host/tests/host_black_box_test.cpp"
"$work/test" "$root/cmux-tui/crates/cmux-trace/tests/fixtures/metrics-log-linear-golden.txt"
