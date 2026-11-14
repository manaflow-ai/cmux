#!/bin/bash
# aside-daemon.sh: the Aside daemon, as AgentEnv's daemon service runs it
export ASIDE_HOME=$HOME/aside/home
exec "$HOME/aside/Aside Daemon.app/Contents/MacOS/aside-daemon"
