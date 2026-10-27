#!/usr/bin/env bash
# Compiles the C ring v1 writer (CEFShim/src/cmux_trace.h, no CEF needed) as C11 and checks it
# against the golden ring the Rust and Swift writers check too, and its crash-key slots against
# CrashKeySlot.swift, its crash-key header against CrashKeys.swift and the shared crash-key fixture. Also compiles the header as C++20, the shim's language. Small: three compiler calls.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/cmux-trace-c.XXXXXX")"
trap 'rm -rf "$work"' EXIT
src="$root/Packages/macOS/CmuxNext/CEFShim/src"
if [[ -n "${CC:-}" ]]; then
  cc=("$CC")
elif command -v xcrun >/dev/null 2>&1; then
  cc=(xcrun clang)
else
  cc=(cc)
fi
# shellcheck source-path=SCRIPTDIR source=lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
"${cc[@]}" -std=c11 -Wall -Wextra -Werror -O2 -pthread -o "$work/test" "$src/cmux_trace_test.c"
printf '#include "cmux_trace.h"\nint main(void) { return 0; }\n' >"$work/cxx.cc"
"${cxx[@]}" -std=c++20 -Wall -Wextra -Werror -fsyntax-only -I"$src" "$work/cxx.cc"
"$work/test" \
  "$root/Packages/macOS/CmuxNext/Tests/CmuxNextTraceTests/Fixtures/ring-v1-golden.cmxtrace" \
  "$root/Packages/macOS/CmuxNext/Sources/CmuxNextTrace/CrashKeySlot.swift" \
  "$root/Packages/macOS/CmuxNext/Sources/CmuxNextTrace/CrashKeys.swift" \
  "$root/Packages/macOS/CmuxNext/Tests/CmuxNextTraceTests/Fixtures/crash-keys-v1-golden.crashkeys"
