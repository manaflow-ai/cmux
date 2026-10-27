#!/usr/bin/env bash
# verify-signed-nightly: scripts/ci/check-signed-app.sh on the signed app. A
# build commit older than that script has nothing to run.
set -euo pipefail
if [[ ! -f scripts/ci/check-signed-app.sh ]]; then
  echo "::notice title=Signed app checks::the build commit predates scripts/ci/check-signed-app.sh"
  exit 0
fi
./scripts/ci/check-signed-app.sh "$CHANNEL_APP_PATH" "$CHANNEL_ENTITLEMENTS"
