#!/usr/bin/env bash
# nightly.yml publish-nightly-reel: "Install ffmpeg". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
if ! command -v ffmpeg >/dev/null || ! command -v fc-match >/dev/null; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq --no-install-recommends ffmpeg fontconfig fonts-dejavu-core >/dev/null
fi
