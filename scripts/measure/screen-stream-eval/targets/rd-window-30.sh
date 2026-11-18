#!/usr/bin/env bash
# rd-window at 30 frames a second: the same window stream with the rate a live thumbnail can have.
set -euo pipefail
EVAL_RDWIN_FPS=30 exec bash "$(dirname "${BASH_SOURCE[0]}")/rd-window.sh" "$@"
