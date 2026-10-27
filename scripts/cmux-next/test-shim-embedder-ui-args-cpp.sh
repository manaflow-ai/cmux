#!/usr/bin/env bash
# Compiles the shim's fork API 31 types and argument conversions
# (CEFShim/src/embedder_ui_args.h, no CEF needed) and runs their cases.
# With CMUX_CEF_FORK=<manaflow-ai/cef checkout at API 31>, also checks the
# shim's copies of the fork's structs against its include/cef_cmux.h.
# Small: one clang++ call.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/shim-embedder-ui-args.XXXXXX")"
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
"${cxx[@]}" -std=c++20 -Wall -Wextra -Werror -O1 \
  -I "$root/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim" ${fork[@]+"${fork[@]}"} \
  -o "$work/test" "$root/Packages/macOS/CmuxNext/CEFShim/tests/embedder_ui_args_test.cpp"
"$work/test"
