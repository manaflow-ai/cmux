#!/usr/bin/env bash
# cmux-next.yml cmux-scheme-compile: "Look up the DEV Release app compiled on the same inputs".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
set -euo pipefail
key="$(python3 -I scripts/ci/job_input_fingerprint.py dev-release-product \
  --extra "xcode=$(xcodebuild -version | tr '\n' ' ')" \
  --extra "sdk=$(xcrun --sdk macosx --show-sdk-version) $(xcrun --sdk macosx --show-sdk-build-version)" \
  --extra "arch=$(uname -m)" \
  --extra "recipe=$(python3 -I -c 'import sys; sys.path.insert(0, "scripts/ci"); import dev_release_product_reuse as r; print(r.RECIPE)') swift_mode=$SWIFT_COMPILATION_MODE" \
  --extra "tui_tree=${CMUX_TUI_TREE_KEY:-own}" | sed -n 's/^fingerprint=//p')"
echo "key=$key" >> "$GITHUB_OUTPUT"
python3 -I scripts/ci/dev_release_product_reuse.py lookup --key "$key" --skip "$SKIP_REASON" \
  --out "$RUNNER_TEMP/cmux-next-dev-product" --timeout 180 >> "$GITHUB_OUTPUT"
