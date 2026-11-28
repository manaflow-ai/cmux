#!/usr/bin/env bash
# Reproduces the Chromium allocator zone race that crashed cmux-next with
# "[FATAL:allocator_shim_apple.cc(61)] ... No zone found" and checks the fix
# (plans/cmux-next/browser-isolation.md, "Allocator zone race").
#
# Four threads malloc/free while the main thread dlopens the Chromium
# framework (as CEFRuntime.loadLibrary does off the main thread).
#   late:  no early zone; PartitionAlloc's constructor briefly unregisters the
#          system zone and a concurrent free() finds no owner (expected crashes)
#   early: CmuxNextMallocZone installed first (what CmuxNextApp.main does)
#
# Usage: run.sh [runs] [framework binary]   (default: the pinned cached CEF)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
runs="${1:-30}"
version="$(/usr/bin/plutil -extract version raw -o - "$root/scripts/cmux-next/cef-manifest.json")"
framework="${2:-$HOME/Library/Caches/cmux/cef/$version/Chromium Embedded Framework.framework/Chromium Embedded Framework}"
[[ -f "$framework" ]] || { echo "skip: no CEF framework at $framework (run scripts/cmux-next/ensure-cef.sh)"; exit 0; }
zone="$root/Packages/macOS/CmuxNext/Sources/CmuxNextMallocZone"
bin="$(mktemp -d)/repro"
clang -O2 -I"$zone/include" "$here/repro.c" "$zone/early_zone.c" -o "$bin"
late=0; early=0
for _ in $(seq 1 "$runs"); do
  ("$bin" late "$framework") >/dev/null 2>&1 || late=$((late + 1))
  ("$bin" early "$framework") >/dev/null 2>&1 || early=$((early + 1))
done
rm -rf "$(dirname "$bin")"
echo "without early zone: $late/$runs crashed; with early zone: $early/$runs crashed"
[[ "$early" -eq 0 ]]
