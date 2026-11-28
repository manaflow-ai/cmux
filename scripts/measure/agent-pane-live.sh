#!/usr/bin/env bash
# Allowlisted fleet entry for the real agent-pane flow. The Python harness owns the tagged app
# lifecycle and fetches the exact cmux build named by --job.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
exec python3 scripts/cmux-next/agent-pane-live.py "$@"
