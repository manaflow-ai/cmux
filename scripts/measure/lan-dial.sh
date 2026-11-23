#!/usr/bin/env bash
# lan-dial on a fleet Mac: direct vs relay to a LAN HTTP service, from a fleet step (a background job under the
# worker). Arguments: HOST PORT [PATH] [ROUNDS]. scripts/lan-dial/demo.sh does the work; README.md there says why.
#   cmux-ci run --class exclusive --script scripts/measure/lan-dial.sh --ref SHA --arg HOST --arg PORT --arg /PATH
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lan-dial" && pwd)/demo.sh" "$@"
