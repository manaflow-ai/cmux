#!/usr/bin/env bash
# Compiles the shim's suggestion rows (CEFShim/src/suggestion_rows.h, no CEF
# needed: the SUGGESTIONS event's JSON) and runs their
# cases. With CMUX_CEF_FORK=<manaflow-ai/cef checkout at API 31>, also checks
# the shim's copies of the fork's structs against its include/cef_cmux.h.
# Small: one clang++ call.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/shim-suggestion-rows.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
fork=()
if [[ -n "${CMUX_CEF_FORK:-}" ]]; then
  # cef_cmux.h needs only the build config header, which a checkout lacks.
  mkdir -p "$work/config/include"
  : > "$work/config/include/cef_config.h"
  fork=(-DCMUX_CHECK_FORK_HEADER -I "$CMUX_CEF_FORK" -I "$work/config")
fi
"${cxx[@]}" -std=c++20 -Wall -Wextra -Werror -O1 ${fork[@]+"${fork[@]}"} \
  -o "$work/test" "$root/Packages/macOS/CmuxNext/CEFShim/tests/suggestion_rows_test.cpp"
"$work/test"
