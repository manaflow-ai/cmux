#!/bin/bash
# aside-mcp.sh: Aside's computer-use MCP server (stdio), as AgentEnv starts it
export ASIDE_HOME=$HOME/aside/home ASIDE_CLI_UPDATE_CHECK=0 PATH=/usr/bin:/bin:/usr/sbin:/sbin
exec "$HOME/aside/bin/aside" mcp --computer-use "$@"
