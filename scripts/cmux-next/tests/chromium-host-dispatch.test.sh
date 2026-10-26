#!/usr/bin/env bash
# Compiles the Chromium Host's dispatcher (ChromiumHost/src/host_dispatch.mm,
# no AppKit in it, so as C++) and its mirror producers (host_mirror.mm) with
# a subset of the generated host_dispatch.inc, rendered from the current
# cmux_cef_shim.h and plans/cmux-next/chromium-host-ops.json as the test runs
# (chromium-host-dispatch-subset.py: real op ids, case bodies and refresh
# rows), and a recording fake of the shim, then runs
# ChromiumHost/tests/host_dispatch_test.cpp and host_mirror_test.cpp. No CEF;
# runs on Linux and macOS.
#
# Not in CI (lead, 2026-10-23: no new CI tests); run it when you change
# host_dispatch.{h,mm}, host_mirror.{h,mm}, the mirror rows of the ops JSON
# or the shape of the generated host cases.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/chromium-host-dispatch.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=../lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
host="$root/Packages/macOS/CmuxNext/ChromiumHost"
shim_header="$root/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim"
# The dispatcher includes generated/host_dispatch.inc next to itself: a copy
# of src with the subset in that place.
mkdir -p "$work/src/generated"
cp "$host/src/host_dispatch.mm" "$host/src/host_dispatch.h" "$host/src/host_mirror.mm" "$host/src/host_mirror.h" \
  "$host/src/chromium_host_tlv.h" \
  "$host/src/chromium_host_control.h" "$host/src/chromium_host_control.cc" "$work/src/"
python3 "$root/scripts/cmux-next/tests/chromium-host-dispatch-subset.py" "$work/src/generated/host_dispatch.inc"
# host_mirror.h's kExtActionIconPixels is CEFExtensionAction.iconPixels:
# OmnibarStyle.buttonSize * 2.
button="$(sed -n 's/.*static var buttonSize: CGFloat { \([0-9.]*\) }.*/\1/p' \
  "$root/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/UI/OmnibarStyle.swift")"
grep -q 'iconPixels: Int32 { Int32((OmnibarStyle.buttonSize \* 2).rounded()) }' \
  "$root/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFExtensionAction.swift" ||
  { echo "FAIL: CEFExtensionAction.iconPixels is no longer OmnibarStyle.buttonSize * 2" >&2; exit 1; }
pixels="$(python3 -c 'import sys; print(round(float(sys.argv[1]) * 2))' "$button")"
grep -q "kExtActionIconPixels = $pixels;" "$host/src/host_mirror.h" ||
  { echo "FAIL: kExtActionIconPixels is not CEFExtensionAction.iconPixels ($pixels)" >&2; exit 1; }
for test in host_dispatch_test host_mirror_test; do
  "${cxx[@]}" -std=c++20 -Wall -Wextra -Werror -O1 -pthread -I"$work/src" -I"$shim_header" \
    -o "$work/$test" "$host/tests/$test.cpp" -x c++ "$work/src/host_dispatch.mm" "$work/src/host_mirror.mm" \
    "$work/src/chromium_host_control.cc"
  "$work/$test"
done
