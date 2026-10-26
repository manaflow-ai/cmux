#!/usr/bin/env bash
# Compiles the Chromium Host's mirror producers (ChromiumHost/src/host_mirror.mm,
# plain C++ in an .mm) with the control channel and runs host_mirror_test.cpp:
# which watched keys each refresh event names, the pref_get watches and the
# tab -> window map. No CEF needed; one clang++ call.
#
# Not in CI (p01-process section 4, rule 4): agents that change host_mirror or
# the mirror rows of plans/cmux-next/chromium-host-ops.json run it themselves.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/chromium-host-mirror.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=../lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
host="$root/Packages/macOS/CmuxNext/ChromiumHost"
shim="$root/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim"
"${cxx[@]}" -std=c++17 -Wall -Wextra -Werror -O1 -I "$shim" \
  -o "$work/test" "$host/tests/host_mirror_test.cpp" -x c++ "$host/src/host_mirror.mm" \
  -x none "$host/src/chromium_host_control.cc"
"$work/test"
