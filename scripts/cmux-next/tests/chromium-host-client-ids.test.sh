#!/usr/bin/env bash
# Compiles the Chromium Host's client id map (ChromiumHost/src/host_client_ids.{h,cc},
# task 019 of plans/cmux-next/chrome-parity/p01-process.md) and runs
# ChromiumHost/tests/host_client_ids_test.cpp. No CEF; runs on Linux and macOS.
#
# Not in CI (lead, 2026-10-23: no new CI tests); run it when you change the id
# map or the mint ranges (chromium_host_mint.h).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/chromium-host-client-ids.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=../lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
host="$root/Packages/macOS/CmuxNext/ChromiumHost"
shim_header="$root/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim"
"${cxx[@]}" -std=c++20 -Wall -Wextra -Wshadow -Werror -O1 -I"$host/src" -I"$shim_header" \
  -o "$work/test" "$host/tests/host_client_ids_test.cpp" "$host/src/host_client_ids.cc"
"$work/test"
