#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SCRIPT="$ROOT/scripts/cmux-next/capture-pr-surfaces.sh"
test -x "$SCRIPT"
bash -n "$SCRIPT"
help="$($SCRIPT --help 2>&1 || true)"
grep -q -- '--head-archive' <<<"$help"
grep -q -- '--base-archive' <<<"$help"
grep -q 'CAPTURE_HOST acquire' "$SCRIPT"
grep -q 'release "\$lease"' "$SCRIPT"
grep -q 'quit_owned' "$SCRIPT"
grep -q 'new-tab' "$SCRIPT"
grep -q 'terminal-workspace' "$SCRIPT"
grep -q 'agent-pane' "$SCRIPT"
grep -q '04-home' "$SCRIPT"
grep -q '05-settings' "$SCRIPT"
printf 'capture-pr-surfaces tests: ok\n'
