#!/usr/bin/env bash
# Compiles the Chromium Host's client id map (ChromiumHost/src/host_client_ids.{h,cc},
# task 019 of plans/cmux-next/chrome-parity/p01-process.md) and runs
# ChromiumHost/tests/host_client_ids_test.cpp, then generates the host cases of
# ChromiumHost/tests/fixtures/client_ids with gen-chromium-host-wire.py and runs them end to end
# through the map (ChromiumHost/tests/host_client_ids_dispatch_test.cpp). No CEF; runs on Linux
# and macOS.
#
# Not in CI (lead, 2026-10-23: no new CI tests); run it when you change the id
# map, the mint ranges (chromium_host_mint.h) or the generator's mint cases.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/chromium-host-client-ids.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=../lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
host="$root/Packages/macOS/CmuxNext/ChromiumHost"
shim_header="$root/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim"
flags=(-std=c++20 -Wall -Wextra -Wshadow -Werror -O1)

"${cxx[@]}" "${flags[@]}" -I"$host/src" -I"$shim_header" \
  -o "$work/test" "$host/tests/host_client_ids_test.cpp" "$host/src/host_client_ids.cc"
"$work/test"

# The fixture tree: its header stands in for cmux_cef_shim.h, its ops JSON for chromium-host-ops.json.
fixture="$host/tests/fixtures/client_ids"
tree="$work/tree"
mkdir -p "$tree/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim" "$tree/plans/cmux-next"
cp "$fixture/cmux_cef_shim.h" "$tree/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim/"
cp "$fixture/chromium-host-ops.json" "$tree/plans/cmux-next/"
python3 "$root/scripts/cmux-next/gen-chromium-host-wire.py" --root "$tree" >/dev/null
# The map against the real header, the test against the fixture's (the same event values).
"${cxx[@]}" "${flags[@]}" -I"$host/src" -I"$shim_header" -c -o "$work/host_client_ids.o" \
  "$host/src/host_client_ids.cc"
# A tree with no mirror leaves ProduceMirror's parameters unused.
"${cxx[@]}" "${flags[@]}" -Wno-unused-parameter -include cstdint -I"$host/src" -I"$fixture" \
  -I"$tree/Packages/macOS/CmuxNext/ChromiumHost/src/generated" \
  -pthread -o "$work/dispatch" "$host/tests/host_client_ids_dispatch_test.cpp" "$work/host_client_ids.o" \
  "$host/src/chromium_host_control.cc"
"$work/dispatch"
