#!/bin/bash
set -e

# Ensure bun, node, and our shims are in PATH
export PATH="/usr/local/bin:$PATH"

# Create log dir early
mkdir -p /var/log/cmux || true
mkdir -p /root/.openvscode-server || true

BOOTSTRAP_SENTINEL="/root/.openvscode-server/.cmux_bootstrapped"
FIRST_RUN=false
FIRST_RUN_LOG=""
if [ ! -f "$BOOTSTRAP_SENTINEL" ]; then
    FIRST_RUN=true
    FIRST_RUN_LOG="[Startup] Detected first run; priming OpenVSCode data volume"
    if [ -d "/opt/cmux/openvscode-defaults" ]; then
        cp -a /opt/cmux/openvscode-defaults/. /root/.openvscode-server/
    fi
else
    FIRST_RUN_LOG="[Startup] Resuming existing OpenVSCode session"
fi

# Start supervisor to manage dockerd (in background, but with -n for proper signal handling)
/usr/bin/supervisord -n >> /dev/null 2>&1 &

# Wait for Docker daemon to be ready
# Based on https://github.com/cruizba/ubuntu-dind/blob/master/start-docker.sh
wait_for_dockerd() {
    local max_time_wait=120
    local waited_sec=0
    echo "Waiting for Docker daemon to start..."
    
    while ! pgrep "dockerd" >/dev/null && [ $waited_sec -lt $max_time_wait ]; do
        if [ $((waited_sec % 10)) -eq 0 ]; then
            echo "Docker daemon is not running yet. Waited $waited_sec seconds of $max_time_wait seconds"
        fi
        sleep 1
        waited_sec=$((waited_sec + 1))
    done
    
    if [ $waited_sec -ge $max_time_wait ]; then
        echo "ERROR: dockerd is not running after $max_time_wait seconds"
        echo "Docker daemon logs:"
        tail -50 /var/log/dockerd.err.log
        return 1
    else
        echo "Docker daemon process is running, verifying it's ready..."
        
        # Wait for Docker to be actually ready to accept connections
        local docker_ready_wait=30
        local docker_waited=0
        while [ $docker_waited -lt $docker_ready_wait ]; do
            if docker version >/dev/null 2>&1; then
                echo "Docker is ready!"
                docker version
                # Additional check: ensure docker-proxy can be spawned
                docker network ls >/dev/null 2>&1
                return 0
            fi
            echo "Waiting for Docker API to be ready... ($docker_waited/$docker_ready_wait)"
            sleep 1
            docker_waited=$((docker_waited + 1))
        done
        
        echo "ERROR: Docker daemon is running but API is not ready after $docker_ready_wait seconds"
        return 1
    fi
}

# Function to start devcontainer if present
start_devcontainer() {
    echo "[Startup] Checking for devcontainer configuration..." >> /var/log/cmux/startup.log
    
    # Wait for Docker to be ready first
    wait_for_dockerd
    
    # Clean up any stale Docker resources
    echo "[Startup] Cleaning up stale Docker resources..." >> /var/log/cmux/startup.log
    docker system prune -f >/dev/null 2>&1 || true
    # Kill any defunct docker-proxy processes
    pkill -9 docker-proxy 2>/dev/null || true
    
    # Check if devcontainer.json exists in the workspace
    if [ -f "/root/workspace/.devcontainer/devcontainer.json" ]; then
        echo "[Startup] Found .devcontainer/devcontainer.json, starting devcontainer..." >> /var/log/cmux/startup.log
        
        # Start the devcontainer in the background using @devcontainers/cli
        # Use a subshell to ensure errors don't propagate
        (
            cd /root/workspace
            
            # First, start the devcontainer
            bunx @devcontainers/cli up --workspace-folder . >> /var/log/cmux/devcontainer.log 2>&1 || {
                echo "[Startup] Devcontainer startup failed (non-fatal), check logs at /var/log/cmux/devcontainer.log" >> /var/log/cmux/startup.log
                echo "[Startup] Devcontainer error (non-fatal): $(tail -5 /var/log/cmux/devcontainer.log)" >> /var/log/cmux/startup.log
                exit 0  # Exit subshell but don't fail
            }
            
            echo "[Startup] Devcontainer started successfully" >> /var/log/cmux/startup.log
            
            # If devcontainer started successfully and dev.sh exists, run it
            if [ -f "/root/workspace/scripts/dev.sh" ]; then
                echo "[Startup] Running ./scripts/dev.sh in devcontainer..." >> /var/log/cmux/startup.log
                
                # Get the container name/id from the devcontainer CLI output
                CONTAINER_ID=$(bunx @devcontainers/cli read-configuration --workspace-folder . 2>/dev/null | grep -o '"containerId":"[^"]*"' | cut -d'"' -f4)
                
                if [ -n "$CONTAINER_ID" ]; then
                    # Execute dev.sh inside the devcontainer
                    docker exec -d "$CONTAINER_ID" bash -c "cd /root/workspace && ./scripts/dev.sh" >> /var/log/cmux/devcontainer-dev.log 2>&1 || {
                        echo "[Startup] Failed to run dev.sh in devcontainer (non-fatal)" >> /var/log/cmux/startup.log
                    }
                    echo "[Startup] Started dev.sh in devcontainer (logs at /var/log/cmux/devcontainer-dev.log)" >> /var/log/cmux/startup.log
                else
                    # Fallback: try to run it directly if we can't get container ID
                    bunx @devcontainers/cli exec --workspace-folder . bash -c "./scripts/dev.sh" >> /var/log/cmux/devcontainer-dev.log 2>&1 &
                    echo "[Startup] Attempted to run dev.sh via devcontainer CLI (logs at /var/log/cmux/devcontainer-dev.log)" >> /var/log/cmux/startup.log
                fi
            else
                echo "[Startup] No scripts/dev.sh found in workspace, skipping dev script" >> /var/log/cmux/startup.log
            fi
        ) &
        
        echo "[Startup] Devcontainer startup initiated in background (logs at /var/log/cmux/devcontainer.log)" >> /var/log/cmux/startup.log
    else
        echo "[Startup] No .devcontainer/devcontainer.json found, skipping devcontainer startup" >> /var/log/cmux/startup.log
    fi
}

# Create log and lifecycle directories
mkdir -p /var/log/cmux /root/lifecycle

# Log environment variables for debugging
echo "[Startup] Environment variables:" > /var/log/cmux/startup.log
env >> /var/log/cmux/startup.log
if [ -n "$FIRST_RUN_LOG" ]; then
    echo "$FIRST_RUN_LOG" >> /var/log/cmux/startup.log
fi

if [ "$FIRST_RUN" = "true" ]; then
    # Configure VS Code theme based on environment variable
    if [ -n "$VSCODE_THEME" ]; then
        echo "[Startup] Configuring VS Code theme: $VSCODE_THEME" >> /var/log/cmux/startup.log
        
        # Determine the color theme based on the setting
        COLOR_THEME="Default Light Modern"
        if [ "$VSCODE_THEME" = "dark" ]; then
            COLOR_THEME="Default Dark Modern"
        elif [ "$VSCODE_THEME" = "system" ]; then
            COLOR_THEME="Default Dark Modern"
        fi
        
        SETTINGS_JSON='{"workbench.startupEditor": "none", "terminal.integrated.shellIntegration.enabled": false, "terminal.integrated.macOptionClickForcesSelection": true, "terminal.integrated.shell.linux": "bash", "terminal.integrated.shellArgs.linux": ["-l"], "workbench.colorTheme": "'$COLOR_THEME'", "git.openDiffOnClick": true, "scm.defaultViewMode": "tree", "git.showPushSuccessNotification": true, "git.autorefresh": true, "git.branchCompareWith": "main"}'
    else
        echo "[Startup] Configuring default VS Code git settings" >> /var/log/cmux/startup.log
        SETTINGS_JSON='{"workbench.startupEditor": "none", "terminal.integrated.shellIntegration.enabled": false, "terminal.integrated.macOptionClickForcesSelection": true, "terminal.integrated.shell.linux": "bash", "terminal.integrated.shellArgs.linux": ["-l"], "git.openDiffOnClick": true, "scm.defaultViewMode": "tree", "git.showPushSuccessNotification": true, "git.autorefresh": true, "git.branchCompareWith": "main"}'
    fi

    echo "$SETTINGS_JSON" > /root/.openvscode-server/data/User/settings.json
    echo "$SETTINGS_JSON" > /root/.openvscode-server/data/User/profiles/default-profile/settings.json
    echo "$SETTINGS_JSON" > /root/.openvscode-server/data/Machine/settings.json
else
    echo "[Startup] Skipping VS Code settings bootstrap (resume)" >> /var/log/cmux/startup.log
fi

# Start OpenVSCode server on port 39378 without authentication
echo "[Startup] Starting OpenVSCode server..." >> /var/log/cmux/startup.log
/app/openvscode-server/bin/openvscode-server \
  --host 0.0.0.0 \
  --port 39378 \
  --without-connection-token \
  --disable-workspace-trust \
  --disable-telemetry \
  --disable-updates \
  --profile default-profile \
  --verbose \
  /root/workspace \
  > /var/log/cmux/server.log 2>&1 &

echo "[Startup] OpenVSCode server started, logs available at /var/log/cmux/server.log" >> /var/log/cmux/startup.log

# Wait for OpenVSCode server to be ready
echo "[Startup] Waiting for OpenVSCode server to be ready..." >> /var/log/cmux/startup.log
MAX_RETRIES=30
RETRY_DELAY=1
retry_count=0

while [ $retry_count -lt $MAX_RETRIES ]; do
    if curl -s -f "http://localhost:39378/?folder=/root/workspace" > /dev/null 2>&1; then
        echo "[Startup] Successfully connected to OpenVSCode server" >> /var/log/cmux/startup.log
        break
    fi
    
    retry_count=$((retry_count + 1))
    echo "[Startup] Waiting for OpenVSCode server... (attempt $retry_count/$MAX_RETRIES)" >> /var/log/cmux/startup.log
    sleep $RETRY_DELAY
done

if [ $retry_count -eq $MAX_RETRIES ]; then
    echo "[Startup] Warning: Failed to connect to OpenVSCode server after $MAX_RETRIES attempts" >> /var/log/cmux/startup.log
fi

# Start the worker
export NODE_ENV=production
export WORKER_PORT=39377
# temporary hack to get around Claude's --dangerously-skip-permissions cannot be used with root/sudo privileges for security reasons
export IS_SANDBOX=true

# Start Docker readiness check and devcontainer in background
# start_devcontainer &

# Start default empty tmux session for cmux that the agent will be spawned in
# (cd /root/workspace && tmux new-session -d -s cmux)

rm -f /startup.sh

if [ "$FIRST_RUN" = "true" ]; then
    touch "$BOOTSTRAP_SENTINEL"
fi

exec node /builtins/build/index.js
