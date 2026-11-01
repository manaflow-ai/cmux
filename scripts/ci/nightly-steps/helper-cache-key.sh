#!/usr/bin/env bash
# nightly.yml build-nightly-ghostty-cli-helper: "Key the Ghostty CLI helper cache". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# The helper is a function of the inputs its own cache manifest names
# (ghostty_cache_metadata in scripts/build-ghostty-cli-helper.sh):
# Ghostty's commit, the script, the Zig binary, the target, the SDK and
# the macOS version. A hosted runner starts with an empty cache, so the
# script's cache directory is kept across runs under a key of those
# same inputs. The script still installs an entry only when its manifest
# equals this build's and the binary's sha256 equals the manifest's;
# anything else builds. tests/test_nightly_ghostty_helper_cache.py.
set -euo pipefail
{
  echo "ghostty=$(git -C ghostty rev-parse HEAD)"
  shasum -a 256 scripts/build-ghostty-cli-helper.sh scripts/ghostty-zig-version.sh
  path_zig="$(command -v zig)" || path_zig=""
  for zig in /opt/homebrew/bin/zig "$path_zig" /usr/local/bin/zig; do
    if [[ -x "$zig" ]]; then
      zig_version="$("$zig" version)"
      zig_sha="$(shasum -a 256 "$zig" | cut -d' ' -f1)"
      echo "zig $zig_version $zig_sha"
    fi
  done | sort -u
  echo "sdk=$(xcrun --sdk macosx --show-sdk-version)"
  echo "macos=$(sw_vers -productVersion) $(uname -m)"
  echo "archs=$NIGHTLY_COMPILE_ARCHS"
} > "$RUNNER_TEMP/ghostty-helper-inputs.txt"
cat "$RUNNER_TEMP/ghostty-helper-inputs.txt"
echo "key=ghostty-cli-helper-v1-$(shasum -a 256 < "$RUNNER_TEMP/ghostty-helper-inputs.txt" | cut -d' ' -f1)" >> "$GITHUB_OUTPUT"
