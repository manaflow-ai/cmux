#!/usr/bin/env bash
# Compiles the values codec of the Chromium Host's generated ops
# (ChromiumHost/src/chromium_host_tlv.h) with the control channel it rides
# on (chromium_host_control.{h,cc}), no CEF needed, and runs its test. One
# clang++ call; runs on Linux and macOS.
#
# Not in CI (lead, 2026-10-23: no new CI tests); run it when you change
# chromium_host_tlv.h or the generator's wire types.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/chromium-host-tlv.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=../lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
host="$root/Packages/macOS/CmuxNext/ChromiumHost"
"${cxx[@]}" -std=c++17 -Wall -Wextra -Werror -O1 -pthread \
  -o "$work/test" "$host/tests/chromium_host_tlv_test.cpp" "$host/src/chromium_host_control.cc"
"$work/test"
