#!/bin/bash
# cuenv3.sh CMD... : cuenv2.sh plus the three-way arms: Aside (aside-mcp.sh) and Codex Computer Use (codex-sky-mcp.sh)
export CUEVAL_ASIDE_COMMAND="[\"$HOME/cu/aside-mcp.sh\"]"
export CUEVAL_CODEX_CU_COMMAND="[\"$HOME/cu/codex-sky-mcp.sh\"]"
export CODEX_BIN="$HOME/.local/bin/codex"
exec "$HOME/cu/cuenv2.sh" "$@"
