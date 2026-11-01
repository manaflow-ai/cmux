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

# Exact argument lists, compared one argument at a time (one argument "--probe --write" is refused).
allowed=0
case "$#" in
  0) allowed=1 ;;
  1) [[ "$1" == "--probe" ]] && allowed=1 ;;
  2) [[ "$1" == "--probe" && "$2" == "--write" ]] && allowed=1 ;;
esac
if [[ "$allowed" != 1 ]]; then
  echo "check-objc-selectors.sh: arguments must be none, --probe, or --probe --write (got $# argument(s): $*)" >&2
  exit 2
fi
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python=/usr/bin/python3
if [[ ! -x "$python" ]]; then
  python="$(command -v python3 || true)"
  if [[ -z "$python" ]]; then
    echo "check-objc-selectors.sh: no python3 (neither /usr/bin/python3 nor one on PATH)" >&2
    exit 127
  fi
fi
exec "$python" -I "$here/check-objc-selectors.py" --root "$(cd "$here/../.." && pwd)" "$@"
