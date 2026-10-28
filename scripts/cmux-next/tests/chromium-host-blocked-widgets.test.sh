#!/usr/bin/env bash
# Compiles the Chromium Host's blocked widget handler
# (ChromiumHost/src/host_blocked_widgets.h; no CEF, no
# AppKit) with -Werror and runs its test (ChromiumHost/tests/
# host_blocked_widgets_test.cpp): one dismissal and one BLOCKED_WIDGET line per
# shown widget, a widget that hid first logged as gone, a refused close kept,
# a permission prompt held and never closed,
# owners by class, and the window backstop's line. Runs on Linux and macOS.
# Not a CI test (lead, 2026-10-23): whoever changes the header runs it.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/chromium-host-blocked-widgets.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=../lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
host="$root/Packages/macOS/CmuxNext/ChromiumHost"
"${cxx[@]}" -std=c++20 -fno-exceptions -Wall -Wextra -Werror -O1 -I "$host/src" \
  -o "$work/test" "$host/tests/host_blocked_widgets_test.cpp"
"$work/test"
