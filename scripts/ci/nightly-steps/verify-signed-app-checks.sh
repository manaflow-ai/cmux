#!/usr/bin/env bash
# verify-signed-nightly: scripts/ci/check-signed-app.sh on the signed app. The
# step runs only when the build commit has this script (hashFiles).
# REQUIRE_HELPER_TICKET=true: an app whose signer stapled the Computer Use
# helper before the handoff (CMUX_SIGN_MODE=helper-first) must carry its ticket.
set -euo pipefail
flags=()
if [[ "${REQUIRE_HELPER_TICKET:-false}" == true ]]; then flags+=(--require-helper-ticket); fi
./scripts/ci/check-signed-app.sh "$CHANNEL_APP_PATH" "$CHANNEL_ENTITLEMENTS" ${flags[@]+"${flags[@]}"}
