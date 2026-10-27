#!/usr/bin/env bash
# The Chromium Host's framework read (ChromiumHost/src/host_framework_prefetch.h,
# task p01-process-101): builds ChromiumHost/tests/host_framework_prefetch_test.cpp
# with -Werror and the host's -fno-exceptions -fno-rtti (build-chromium-host.sh)
# and runs it on a fake framework folder. No CEF; runs on Linux and macOS.
#
# Not in CI (lead, 2026-10-23: no new CI tests); run it when you change
# host_framework_prefetch.h.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/chromium-host-prefetch.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=../lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
host="$root/Packages/macOS/CmuxNext/ChromiumHost"
flags=(-std=c++20 -Wall -Wextra -Werror -fno-exceptions -fno-rtti -I"$host/src")
"${cxx[@]}" "${flags[@]}" -o "$work/prefetch_test" "$host/tests/host_framework_prefetch_test.cpp"
mkdir -p "$work/scratch"
"$work/prefetch_test" "$work/scratch"
echo "chromium-host-prefetch: ok"
