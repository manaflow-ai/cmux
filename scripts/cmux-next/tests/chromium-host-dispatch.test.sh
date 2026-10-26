#!/usr/bin/env bash
# Compiles the Chromium Host's dispatcher (ChromiumHost/src/host_dispatch.mm,
# no AppKit in it, so as C++) with a fixture subset of its generated cases
# (ChromiumHost/tests/fixtures/host_dispatch_subset.inc) and a recording fake
# of the shim, and runs ChromiumHost/tests/host_dispatch_test.cpp. No CEF;
# runs on Linux and macOS.
#
# Not in CI (lead, 2026-10-23: no new CI tests); run it when you change
# host_dispatch.{h,mm} or the shape of the generated host cases.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/chromium-host-dispatch.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=../lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
host="$root/Packages/macOS/CmuxNext/ChromiumHost"
shim_header="$root/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim"
# The dispatcher includes generated/host_dispatch.inc next to itself: a copy
# of src with the fixture in that place.
mkdir -p "$work/src/generated"
cp "$host/src/host_dispatch.mm" "$host/src/host_dispatch.h" "$host/src/chromium_host_tlv.h" \
  "$host/src/chromium_host_control.h" "$host/src/chromium_host_control.cc" "$work/src/"
cp "$host/tests/fixtures/host_dispatch_subset.inc" "$work/src/generated/host_dispatch.inc"
"${cxx[@]}" -std=c++20 -Wall -Wextra -Werror -O1 -pthread -I"$work/src" -I"$shim_header" \
  -o "$work/test" "$host/tests/host_dispatch_test.cpp" -x c++ "$work/src/host_dispatch.mm" \
  "$work/src/chromium_host_control.cc"
"$work/test"
