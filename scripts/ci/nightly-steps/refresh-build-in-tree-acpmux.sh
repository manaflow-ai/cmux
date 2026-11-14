#!/usr/bin/env bash
# nightly.yml refresh-compilation-cache: "Build in-tree acpmux for the compilation cache". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
# acpmux's libghostty-vt (ghostty-vt-sys) builds ghostty-next, whose Zig can differ from the classic ghostty Zig in CMUX_ZIG
# and PATH. ghostty-vt-sys runs ZIG first, so the vt Zig that "Install compilation dependencies" published as CMUX_VT_ZIG
# goes there (an explicit ZIG stays).
if [[ -z "${ZIG:-}" && -n "${CMUX_VT_ZIG:-}" ]]; then
  export ZIG="$CMUX_VT_ZIG"
fi
vt_zig="${ZIG:-${CMUX_ZIG:-zig}}"
echo "libghostty-vt zig: $vt_zig ($("$vt_zig" version 2>/dev/null || echo unknown))"
acpmux_bin="$RUNNER_TEMP/cmux-next-acpmux/acpmux"
scripts/cmux-next/build-acpmux.sh --output "$acpmux_bin"
echo "CMUX_NEXT_ACPMUX_BIN=$acpmux_bin" >> "$GITHUB_ENV"
