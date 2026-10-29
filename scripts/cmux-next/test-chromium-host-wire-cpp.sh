#!/usr/bin/env bash
# Compiles the Chromium host wire (CEFShim/src/chromium_host_wire.h, no CEF
# needed) and checks it against the golden frame the Swift side checks too.
# Small: one clang++ call.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/chromium-host-wire.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
"${cxx[@]}" -std=c++17 -Wall -Werror -O1 \
  -o "$work/test" "$root/Packages/macOS/CmuxNext/CEFShim/tests/chromium_host_wire_test.cpp"
"$work/test"
