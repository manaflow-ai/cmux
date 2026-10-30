#!/usr/bin/env bash
# CMUX_NOTARIZE_COMPUTER_USE_HELPER_TOOL for the cmux NIGHTLY-identity copy of a
# cmux NEXT build (scripts/ci/nightly-next-legacy-identity.sh, cx-x7hwx).
#
# The copy keeps the Computer Use helper exactly as cmux NEXT shipped it:
# signed, notarized and stapled. It is not submitted again. A helper whose
# ticket does not validate returns 75, and notarize-nightly-dmg.sh then requires
# the DMG ticket to cover every helper slice before it staples anything.
#
# Usage (as notarize-nightly-dmg.sh calls it with CMUX_COMPUTER_USE_NOTARY_SUBMISSION_FILE
# set, so that a 75 is a warning there and not a failure):
#   --finish <unused-state-file> <host-app> <entitlements> <identity>
set -euo pipefail
if [[ "${1:-}" == --finish ]]; then
  shift 2
fi
helper="$1/Contents/Library/cmux Computer Use.app"
if xcrun stapler validate "$helper"; then
  echo "Computer Use helper keeps its own stapled ticket"
  exit 0
fi
echo "Computer Use helper has no valid stapled ticket; the DMG ticket must cover it" >&2
exit 75
