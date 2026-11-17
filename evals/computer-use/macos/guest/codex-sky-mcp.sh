#!/bin/bash
# codex-sky-mcp.sh: Codex Computer Use's MCP client, configured as the Codex app configures it. `exec` keeps the
# agent's codex as the parent process (the service accepts only an OpenAI-signed parent).
sky="$HOME/.codex/computer-use/Codex Computer Use.app"
export SKY_CUA_SERVICE_PATH="$sky" CODEX_CLI_PATH="$HOME/.local/bin/codex" CODEX_HOME="$HOME/.codex"
cd "$HOME/.codex/computer-use" || exit 1
exec "$sky/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient" mcp "$@"
