#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Build in-tree acpmux for the compilation cache". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
acpmux_bin="$RUNNER_TEMP/cmux-next-acpmux/acpmux"
if [[ -n "${CMUX_NEXT_ACPMUX_BIN:-}" && -x "$CMUX_NEXT_ACPMUX_BIN" ]]; then
  acpmux_bin="$CMUX_NEXT_ACPMUX_BIN"
  echo "Reusing the attested same-tree acpmux companion: $acpmux_bin"
else
  # As refresh-build-in-tree-acpmux.sh: libghostty-vt (ghostty-vt-sys) builds ghostty-next, whose Zig (0.17.0) is not the
  # host's default Zig (0.16.0 on the minis and ultras). ghostty-vt-sys runs ZIG first, so the vt Zig that "Install
  # compilation dependencies" published as CMUX_VT_ZIG goes there (an explicit ZIG stays).
  if [[ -z "${ZIG:-}" && -n "${CMUX_VT_ZIG:-}" ]]; then
    export ZIG="$CMUX_VT_ZIG"
  fi
  vt_zig="${ZIG:-${CMUX_ZIG:-zig}}"
  echo "libghostty-vt zig: $vt_zig ($("$vt_zig" version 2>/dev/null || echo unknown))"
  scripts/cmux-next/build-acpmux.sh --output "$acpmux_bin"
fi
echo "CMUX_NEXT_ACPMUX_BIN=$acpmux_bin" >> "$GITHUB_ENV"
