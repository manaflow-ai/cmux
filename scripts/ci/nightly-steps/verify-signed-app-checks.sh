#!/usr/bin/env bash
# verify-signed-nightly: scripts/ci/check-signed-app.sh on the signed app. The
# step runs only when the build commit has this script (hashFiles).
set -euo pipefail
./scripts/ci/check-signed-app.sh "$CHANNEL_APP_PATH" "$CHANNEL_ENTITLEMENTS"
