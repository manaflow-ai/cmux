#!/bin/bash
set -e

# Ensure bun and bunx are in PATH
export PATH="/usr/local/bin:$PATH"

# Skip DinD setup that might interfere - supervisor will handle Docker startup

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
        echo "Docker daemon is running"
        # Give it a bit more time to fully initialize
        sleep 2
        # Test if Docker is actually working
        if docker version >/dev/null 2>&1; then
            echo "Docker is ready!"
            docker version
        else
            echo "Docker daemon is running but not yet ready"
            sleep 3
        fi
    fi
}

wait_for_dockerd

# Create log directory
mkdir -p /var/log/cmux

# Log environment variables for debugging
echo "[Startup] Environment variables:" > /var/log/cmux/startup.log
env >> /var/log/cmux/startup.log

# Configure VS Code theme based on environment variable
if [ -n "$VSCODE_THEME" ]; then
    echo "[Startup] Configuring VS Code theme: $VSCODE_THEME" >> /var/log/cmux/startup.log
    
    # Determine the color theme based on the setting
    COLOR_THEME="Default Light Modern"
    if [ "$VSCODE_THEME" = "dark" ]; then
        COLOR_THEME="Default Dark Modern"
    elif [ "$VSCODE_THEME" = "system" ]; then
        # Default to dark for system (could be enhanced to detect system preference)
        COLOR_THEME="Default Dark Modern"
    fi
    
    # Update VS Code settings files with theme
    SETTINGS_JSON='{"workbench.startupEditor": "none", "workbench.colorTheme": "'$COLOR_THEME'"}'
    
    # Update all VS Code settings locations
    echo "$SETTINGS_JSON" > /root/.openvscode-server/data/User/settings.json
    echo "$SETTINGS_JSON" > /root/.openvscode-server/data/User/profiles/default-profile/settings.json
    echo "$SETTINGS_JSON" > /root/.openvscode-server/data/Machine/settings.json
    
    echo "[Startup] VS Code theme configured to: $COLOR_THEME" >> /var/log/cmux/startup.log
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

# Run post-startup script if available
if [ "$RUN_POST_STARTUP" = "true" ] && [ -f /root/post-startup.sh ]; then
    echo "[Startup] Running post-startup script..." >> /var/log/cmux/startup.log
    bash /root/post-startup.sh >> /var/log/cmux/startup.log 2>&1
fi

# Start the worker
export NODE_ENV=production
export WORKER_PORT=39377
# temporary hack to get around Claude's --dangerously-skip-permissions cannot be used with root/sudo privileges for security reasons
export IS_SANDBOX=true

rm -f /startup.sh

node /builtins/build/index.js > /var/log/cmux/worker-proc.log 2>&1