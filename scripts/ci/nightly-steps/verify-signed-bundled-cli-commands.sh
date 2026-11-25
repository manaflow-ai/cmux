#!/usr/bin/env bash
# nightly.yml verify-signed-nightly: "Verify bundled CLI commands run from the bundle alone". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# Every CLI command that must work from the bundle alone runs from the
# signed app on this Mac (a subcommand once exec'd a cmux-vm binary no
# bundle shipped). A slice this Mac cannot run is checked by the
# variant that can.
set -euo pipefail
archs="$(lipo -archs "$CHANNEL_APP_PATH/Contents/Resources/bin/cmux")"
if [[ " $archs " == *" $(uname -m) "* ]]; then
  ./scripts/cmux-next/check-bundled-cli-commands.sh "$CHANNEL_APP_PATH"
else
  echo "bin/cmux is $archs; this runner is $(uname -m): the matching variant checks it"
fi
