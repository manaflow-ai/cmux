#!/bin/bash

# Port cleanup helper. Can be sourced and called as a function, or executed.
# Usage (sourced):
#   source scripts/_port-clean.sh
#   clean_ports 9775 9777 9778
# Usage (exec):
#   scripts/_port-clean.sh 9775 9777 9778

clean_ports() {
  # Colors (optional; no-op if not set by caller)
  local BLUE=${BLUE:-}
  local YELLOW=${YELLOW:-}
  local GREEN=${GREEN:-}
  local NC=${NC:-}

  # Ports passed as args, or default set
  local ports
  if [ "$#" -gt 0 ]; then
    ports=("$@")
  else
    local default_convex=${CONVEX_PORT:-9777}
    ports=(9775 "$default_convex" 9777 9778)
  fi

  echo -e "${BLUE}Checking ports and cleaning up processes...${NC}"

  for port in "${ports[@]}"; do
    # Get PIDs of processes listening on the port, excluding Google Chrome and OrbStack
    # Be resilient to set -euo pipefail in callers: lsof returns non-zero when no matches
    local pids
    pids=$({ lsof -ti :"$port" 2>/dev/null || true; } | while read -r pid; do
      local proc
      proc=$(ps -p "$pid" -o comm= 2>/dev/null || echo "")
      if [[ ! "$proc" =~ (Google|Chrome|OrbStack) ]]; then
        echo "$pid"
      fi
    done)

    if [ -n "$pids" ]; then
      echo -e "${YELLOW}Killing processes on port $port (excluding Chrome/OrbStack)...${NC}"
      for pid in $pids; do
        kill -9 "$pid" 2>/dev/null && echo -e "${GREEN}Killed process $pid on port $port${NC}"
      done
    fi
  done
}

# If executed directly, run with given args
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  clean_ports "$@"
fi
