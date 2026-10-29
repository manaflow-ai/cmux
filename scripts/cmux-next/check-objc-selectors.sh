#!/usr/bin/env bash
# The unrecognized-selector check (check-objc-selectors.py) as a cmux-ci step on a fleet Mac:
#   cmux-ci run --class light --script scripts/cmux-next/check-objc-selectors.sh --ref SHA --key KEY \
#     --arg --probe --arg --write --artifact scripts/cmux-next/objc-selector-table.json
# The worker runs every step script with /bin/bash, so this wrapper is the step script and the
# controller pins it (hq build-fleet, ci_step.go: class light, no env, the table as the only
# artifact). Arguments: none (the table check), --probe (also ask this Mac's Objective-C runtime),
# or --probe --write (merge this Mac's answers into scripts/cmux-next/objc-selector-table.json).
# --probe needs macOS. It reads only this checkout: no --root or --source.
set -euo pipefail

case "$*" in
  "" | "--probe" | "--probe --write") ;;
  *)
    echo "check-objc-selectors.sh: arguments must be none, --probe, or --probe --write (got: $*)" >&2
    exit 2
    ;;
esac
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python=/usr/bin/python3
[[ -x "$python" ]] || python="$(command -v python3)"
exec "$python" -I "$here/check-objc-selectors.py" --root "$(cd "$here/../.." && pwd)" "$@"
