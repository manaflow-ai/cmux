#!/usr/bin/env bash
# The remote shim's mirror cache (task p01-process-016b), with no build:
#  1. client/remote_shim_mirror.h's MIRROR and ACK op ids equal the
#     generator's (gen-chromium-host-wire.py MIRROR_OP, ACK_OP), and so do
#     ChromiumHostMirror.swift's;
#  2. the cache through the generated client exports
#     (ChromiumHost/tests/remote_shim_mirror_test.cpp): remote_shim.inc is
#     written fresh into a temporary tree from the header and ops JSON, then
#     one C++ compiler call builds the test with chromium_host_control.cc.
# No CI job runs it (lead, 2026-10-23: no new CI tests); whoever changes the
# mirror cache, a mirror or pending_keys entry, or the generated client runs it.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
gen="$root/scripts/cmux-next/gen-chromium-host-wire.py"
host="$root/Packages/macOS/CmuxNext/ChromiumHost"
swift="$root/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/ChromiumHost/ChromiumHostMirror.swift"
shimh=Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim/cmux_cef_shim.h
ops=plans/cmux-next/chromium-host-ops.json
client_inc=Packages/macOS/CmuxNext/ChromiumHost/client/generated/remote_shim.inc
fail() { echo "FAIL: $*" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/remote-shim-mirror.XXXXXX")"
trap 'rm -rf "$work"' EXIT

ids="$(sed -nE 's/^EVENT_OP, REPLY_OP, MIRROR_OP, ACK_OP = 0x[0-9a-f]+, 0x[0-9a-f]+, (0x[0-9a-f]+), (0x[0-9a-f]+)$/\1 \2/p' "$gen")"
[[ -n "$ids" ]] || fail "no MIRROR_OP, ACK_OP line in $gen"
read -r mirror_op ack_op <<<"$ids"
grep -q "kMirrorOp = $mirror_op;" "$host/client/remote_shim_mirror.h" || fail "remote_shim_mirror.h kMirrorOp is not $mirror_op"
grep -q "kAckOp = $ack_op;" "$host/client/remote_shim_mirror.h" || fail "remote_shim_mirror.h kAckOp is not $ack_op"
grep -q "static let mirrorOp: UInt16 = $mirror_op" "$swift" || fail "ChromiumHostMirror.mirrorOp is not $mirror_op"
grep -q "static let ackOp: UInt16 = $ack_op" "$swift" || fail "ChromiumHostMirror.ackOp is not $ack_op"

mkdir -p "$work/tree/$(dirname "$shimh")" "$work/tree/$(dirname "$ops")"
cp "$root/$shimh" "$work/tree/$shimh"
cp "$root/$ops" "$work/tree/$ops"
python3 "$gen" --root "$work/tree" >/dev/null
[[ -s "$work/tree/$client_inc" ]] || fail "the generator wrote no $client_inc"

# shellcheck source=../lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
"${cxx[@]}" -std=c++17 -Wall -Wextra -Werror -O1 -pthread \
  -I"$root/$(dirname "$shimh")" -I"$host/src" -I"$work/tree/$(dirname "$client_inc")" \
  -o "$work/test" "$host/tests/remote_shim_mirror_test.cpp" "$host/src/chromium_host_control.cc"
"$work/test"
