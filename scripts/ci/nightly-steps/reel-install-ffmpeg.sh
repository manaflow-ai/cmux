#!/usr/bin/env bash
# nightly.yml publish-nightly-reel: "Install ffmpeg". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
# On the nightly mini ffmpeg and fontconfig (fc-match) come from Homebrew; on a fork's hosted Ubuntu from apt.
set -euo pipefail
if command -v ffmpeg >/dev/null && command -v fc-match >/dev/null; then
  exit 0
fi
if [ "$(uname -s)" = Darwin ]; then
  # Homebrew's bin may be off the runner's PATH: use what it already has there, install only what it lacks,
  # and put that bin on PATH for the reel step, which runs ffmpeg and fc-match by name.
  prefix="${HOMEBREW_PREFIX:-/opt/homebrew}"
  missing=()
  [ -x "$prefix/bin/ffmpeg" ] || missing+=(ffmpeg)
  [ -x "$prefix/bin/fc-match" ] || missing+=(fontconfig)
  if [ "${#missing[@]}" -gt 0 ]; then
    brew=$(command -v brew || echo "$prefix/bin/brew")
    HOMEBREW_NO_AUTO_UPDATE=1 "$brew" install "${missing[@]}" >/dev/null
  fi
  if [ -n "${GITHUB_PATH:-}" ]; then
    echo "$prefix/bin" >> "$GITHUB_PATH"
  fi
else
  # A slow mirror timed the step out at 6 min (run 42033609306); retry each request instead of hanging on it.
  sudo apt-get update -qq -o Acquire::Retries=3 -o Acquire::http::Timeout=30
  sudo apt-get install -y -qq --no-install-recommends -o Acquire::Retries=3 -o Acquire::http::Timeout=30 \
    ffmpeg fontconfig fonts-dejavu-core >/dev/null
fi
