#!/usr/bin/env bash
# Compiles the CEF helpers' quit-signal rule (CEFShim/src/helper_signal_policy.h,
# no CEF needed) and runs its cases with real processes. Small: one clang++ call.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/shim-helper-signals.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
"${cxx[@]}" -std=c++17 -Wall -Werror -O2 \
  -o "$work/test" "$root/Packages/macOS/CmuxNext/CEFShim/tests/helper_signal_policy_test.cpp"
"$work/test"
