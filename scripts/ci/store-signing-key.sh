#!/usr/bin/env bash
# The App Store signing key for one build step (nightly.yml build-nightly-app "Build the web bundles
# (cmux-next)", release.yml build-sign-notarize "Provide the cmux-next web bundles").
#   start  write $STORE_SIGNING_KEY (secret CMUX_STORE_SIGNING_KEY, PEM ed25519) to
#          $RUNNER_TEMP/cmux-store-signing-key/key.pem, mode 0600, in a 0700 folder; no key, no file.
#   stop   delete that folder. The step runs it from an EXIT trap.
# The caller exports CMUX_STORE_SIGNING_KEY_FILE when the file is not empty; sync-app-runtime.sh --store
# then signs cmux's own store packages (store-package-sign.py). The key is never printed.
set -euo pipefail
dir="${RUNNER_TEMP:?RUNNER_TEMP is required}/cmux-store-signing-key"
case "${1:-}" in
  start)
    rm -rf "$dir"
    if [ -z "${STORE_SIGNING_KEY:-}" ]; then
      echo "store signing key: not set for this job; the store packages ship unsigned (Unverified)"
      exit 0
    fi
    (
      umask 077
      mkdir -p "$dir"
      printf '%s\n' "$STORE_SIGNING_KEY" > "$dir/key.pem"
    )
    chmod 600 "$dir/key.pem"
    echo "store signing key: written for this step (0600)"
    ;;
  stop)
    rm -rf "$dir"
    ;;
  *)
    echo "usage: store-signing-key.sh start|stop" >&2
    exit 2
    ;;
esac
