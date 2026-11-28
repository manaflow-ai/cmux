#!/usr/bin/env bash
# cmux-next.yml cmux-scheme-compile: "Build in-tree acpmux for the app bundle".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
set -euo pipefail
acpmux_bin="$(scripts/cmux-next/pin-cmux-tui.sh acpmux-path)"
# Why: note-499
if [[ -x "$acpmux_bin" && ( -z "${CMUX_TUI_TREE_KEY:-}" ||
      "$CMUX_TUI_TREE_KEY" == "$(scripts/cmux-next/pin-cmux-tui.sh key --rev HEAD)" ) ]]; then
  printf 'commit=%s\nsource=same-tree\n' "$(git rev-parse HEAD)" > "$acpmux_bin.ref"
  echo "same-tree acpmux: $acpmux_bin"
else
  acpmux_bin="$RUNNER_TEMP/cmux-next-acpmux/acpmux"
  scripts/cmux-next/build-acpmux.sh --output "$acpmux_bin"
fi
echo "CMUX_NEXT_ACPMUX_BIN=$acpmux_bin" >> "$GITHUB_ENV"
