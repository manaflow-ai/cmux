#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Bundle the fast cmux-tui client". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
app="build-universal/Build/Products/Release/cmux.app"
local_client="$GITHUB_WORKSPACE/cmux-tui/target/aarch64-apple-darwin/release/cmux-tui"
test -x "$local_client"
CMUX_TUI_CLIENT_LOCAL="$local_client" \
  ./scripts/install-cmux-tui-client.sh "$app" \
  --require-capability wireguard-hub \
  --require-acpmux
./scripts/cmux-next/check-daemon-capabilities.sh --static-only --binary "$app/Contents/Resources/bin/cmux-tui"
