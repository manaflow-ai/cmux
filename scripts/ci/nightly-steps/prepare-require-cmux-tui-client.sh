#!/usr/bin/env bash
# nightly.yml prepare-nightly-variant-primary: "Require the cmux-tui client build-nightly-app bundled". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# build-nightly-app installed, stripped and probed the client (the one
# commit resolve-nightly-cmux-tui-client chose); an unsigned app saved
# before that move has none, and is refused here.
set -euo pipefail
version="build-universal/Build/Products/Release/cmux.app/Contents/Resources/bin/cmux-tui.version"
[ -f "$version" ] || { echo "the unsigned app has no bundled cmux-tui client (saved before build-nightly-app installed it)" >&2; exit 1; }
grep -Fxq "commit=$CMUX_TUI_CLIENT_COMMIT" "$version" || { echo "bundled cmux-tui is not $CMUX_TUI_CLIENT_COMMIT:" >&2; cat "$version" >&2; exit 1; }
