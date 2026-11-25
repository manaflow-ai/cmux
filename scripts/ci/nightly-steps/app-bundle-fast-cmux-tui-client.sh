#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Bundle the fast cmux-tui client". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# The fast arm64 build bundles the client it just compiled. Full builds
# take the published client in build-sign-notarize-nightly instead: the
# commit is resolved by resolve-nightly-cmux-tui-client while this job
# compiles, so the history deepen (1.5 to 11 minutes) is off this path.
set -euo pipefail
app="build-universal/Build/Products/Release/cmux.app"
local_client="$GITHUB_WORKSPACE/cmux-tui/target/aarch64-apple-darwin/release/cmux-tui"
test -x "$local_client"
CMUX_TUI_CLIENT_LOCAL="$local_client" \
  ./scripts/install-cmux-tui-client.sh "$app" \
  --require-capability wireguard-hub \
  --require-acpmux
./scripts/cmux-next/check-daemon-capabilities.sh --static-only --binary "$app/Contents/Resources/bin/cmux-tui"
