#!/bin/bash
# aside-env.sh CMD...: run CMD with the env AgentEnv's driver gives the Aside CLI
export ASIDE_HOME=$HOME/aside/home ASIDE_CLI_UPDATE_CHECK=0
exec "$@"
