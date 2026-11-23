#!/usr/bin/env bash
# The Share extension end to end on a fleet Mac with a console session (pluginkit and the Share
# menu are per logged-in user):
#   cmux-ci run --class exclusive --script scripts/measure/share-extension.sh --ref SHA --timeout 1200
# Runs scripts/cmux-next/tests/bundle-share-extension.test.sh: builds CmuxShare.appex with the Xcode
# phase's script into a stand-in app, registers it (pluginkit -a), performs its NSSharingService
# for a PNG from a script, and checks the app that carries it was opened with the PNG. It removes
# its registrations and files when it ends. Exit 0 only when every step passed.
set -euo pipefail
exec /bin/bash "$(cd "$(dirname "$0")/../.." && pwd)/scripts/cmux-next/tests/bundle-share-extension.test.sh"
