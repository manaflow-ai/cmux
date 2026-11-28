#!/usr/bin/env bash
# cmux-next.yml dev-landing-compile: "Record the DEV Release app under its input key".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
python3 -I scripts/ci/dev_release_product_reuse.py record --key "$KEY" --sha "$GITHUB_SHA" --archive "$ARCHIVE" \
  --reused-from-run "$REUSED_FROM_RUN" --reused-from-sha "$REUSED_FROM_SHA" --compiled-run "$COMPILED_RUN" \
  --swift-mode "$SWIFT_MODE" --swift-mode-requested "$SWIFT_MODE_REQUESTED" \
  --out "$RUNNER_TEMP/cmux-next-dev-product-record/manifest.json" >> "$GITHUB_OUTPUT"
