#!/usr/bin/env bash
# nightly.yml publish-nightly-reel: "Install ffmpeg". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
# On our Mac minis ffmpeg and fontconfig (fc-match) come from Homebrew; on hosted Ubuntu (until glaeda gives
# this job the whole mini) from apt.
set -euo pipefail
if command -v ffmpeg >/dev/null && command -v fc-match >/dev/null; then
  exit 0
fi
if [ "$(uname -s)" = Darwin ]; then
  brew=$(command -v brew || echo /opt/homebrew/bin/brew)
  HOMEBREW_NO_AUTO_UPDATE=1 "$brew" install ffmpeg fontconfig >/dev/null
else
  sudo apt-get update -qq
  sudo apt-get install -y -qq --no-install-recommends ffmpeg fontconfig fonts-dejavu-core >/dev/null
fi
