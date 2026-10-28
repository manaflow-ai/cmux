#!/usr/bin/env bash
# The remote shim's mirror cache, with no build:
#  1. the generated host dispatch refreshes go_back's pending keys between
#     the call and its ACK, the order the C++ test's fixture host sends;
#  2. the cache through the generated client exports
#     (ChromiumHost/tests/remote_shim_mirror_test.cpp): the outputs are
#     written fresh into a temporary tree from the header and ops JSON, then
#     one C++ compiler call builds the test with chromium_host_control.cc.
# No CI job runs it (lead, 2026-10-23: no new CI tests); whoever changes the
# mirror cache, a mirror or pending_keys entry, or the generated client runs it.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
gen="$root/scripts/cmux-next/gen-chromium-host-wire.py"
host="$root/Packages/macOS/CmuxNext/ChromiumHost"
shimh=Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim/cmux_cef_shim.h
ops=plans/cmux-next/chromium-host-ops.json
client_inc=Packages/macOS/CmuxNext/ChromiumHost/client/generated/remote_shim.inc
host_inc=Packages/macOS/CmuxNext/ChromiumHost/src/generated/host_dispatch.inc
fail() { echo "FAIL: $*" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/remote-shim-mirror.XXXXXX")"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/tree/$(dirname "$shimh")" "$work/tree/$(dirname "$ops")"
cp "$root/$shimh" "$work/tree/$shimh"
cp "$root/$ops" "$work/tree/$ops"
python3 "$gen" --root "$work/tree" >/dev/null
[[ -s "$work/tree/$client_inc" ]] || fail "the generator wrote no $client_inc"
back="$(awk '/case kOpGoBack: \{/ { on = 1 } on { print } on && /^    }$/ { exit }' "$work/tree/$host_inc" |
  sed -n '/cmux_shim_go_back(/,/ctx.Ack(wire_token);/p' | grep -oE 'cmux_shim_go_back|RefreshMirror\(kOp[A-Za-z]+|ctx.Ack' | tr '\n' ' ')"
[[ "$back" == "cmux_shim_go_back RefreshMirror(kOpTabNavigationEntries RefreshMirror(kOpTabNavigationState ctx.Ack " ]] ||
  fail "host_dispatch.inc's go_back is not call, RefreshMirror of its pending keys, ACK: $back"

# shellcheck source=../lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
"${cxx[@]}" -std=c++20 -Wall -Wextra -Werror -O1 -pthread \
  -I"$root/$(dirname "$shimh")" -I"$host/src" -I"$host/client" -I"$work/tree/$(dirname "$client_inc")" \
  -o "$work/test" "$host/tests/remote_shim_mirror_test.cpp" "$host/src/chromium_host_control.cc"
"$work/test"
