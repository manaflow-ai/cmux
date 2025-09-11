#!/bin/bash
set -e

# Ensure bun, node, and our shims are in PATH
export PATH="/usr/local/bin:$PATH"

# Create log dir early
mkdir -p /var/log/cmux || true

# Start envd (per-user env daemon) in background and wait for socket
start_envd() {
  local runtime_dir="${XDG_RUNTIME_DIR:-/tmp}"
  local sock_dir="$runtime_dir/cmux-envd"
  local sock_path="$sock_dir/envd.sock"
  mkdir -p "$sock_dir" || true
  if ! pgrep -f "node .*envd/dist/index.js" >/dev/null 2>&1; then
    echo "[Startup] Starting envd daemon..." >> /var/log/cmux/startup.log
    (XDG_RUNTIME_DIR="$runtime_dir" nohup envd >/var/log/cmux/envd.log 2>&1 &)
  fi
  # Wait briefly for the socket to appear
  for i in $(seq 1 100); do
    [ -S "$sock_path" ] && break
    sleep 0.05
  done
  if [ ! -S "$sock_path" ]; then
    echo "[Startup] Warning: envd socket not found at $sock_path" >> /var/log/cmux/startup.log
  else
    echo "[Startup] envd ready at $sock_path" >> /var/log/cmux/startup.log
  fi
}

# Skip DinD setup that might interfere - supervisor will handle Docker startup

# Start supervisor to manage dockerd (in background, but with -n for proper signal handling)
/usr/bin/supervisord -n >> /dev/null 2>&1 &

# Bring up env daemon immediately
start_envd

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

CMUX_USED_HOST_VSCODE_SETTINGS=0

# If a host VS Code settings directory is provided, copy it into OpenVSCode's data
copy_host_vscode_settings() {
    if [ -n "${HOST_VSCODE_USER_DIR:-}" ] && [ -d "$HOST_VSCODE_USER_DIR" ]; then
        echo "[Startup] Found host VS Code settings at: $HOST_VSCODE_USER_DIR" >> /var/log/cmux/startup.log
        mkdir -p /root/.openvscode-server/data/User /root/.openvscode-server/data/User/profiles/default-profile /root/.openvscode-server/data/Machine

        # Copy the entire User directory contents (best effort), excluding heavy caches
        # Excludes: workspaceStorage, History, logs
        if command -v tar >/dev/null 2>&1; then
          (cd "$HOST_VSCODE_USER_DIR" && tar --exclude 'workspaceStorage' --exclude 'History' --exclude 'logs' -cf - .) \
            | (cd /root/.openvscode-server/data/User && tar -xpf -) || true
        else
          # Fallback: cp -a (may include caches)
          cp -a "$HOST_VSCODE_USER_DIR/." /root/.openvscode-server/data/User/ || true
        fi

        # Mirror key settings into default-profile so the active profile matches host theme/keybindings
        if [ -f "/root/.openvscode-server/data/User/settings.json" ]; then
          cp /root/.openvscode-server/data/User/settings.json /root/.openvscode-server/data/User/profiles/default-profile/settings.json || true
        fi
        if [ -f "/root/.openvscode-server/data/User/keybindings.json" ]; then
          cp /root/.openvscode-server/data/User/keybindings.json /root/.openvscode-server/data/User/profiles/default-profile/keybindings.json || true
        fi

        CMUX_USED_HOST_VSCODE_SETTINGS=1
    fi
}

copy_host_vscode_settings

# If host settings are mounted, optionally keep them in sync (one-way: host -> container)
maybe_start_host_vscode_watch() {
    if [ "$CMUX_USED_HOST_VSCODE_SETTINGS" = "1" ]; then
        MODE="${HOST_VSCODE_SYNC_MODE:-watch}"
        INTERVAL="${HOST_VSCODE_SYNC_INTERVAL:-2}"
        if [ "$MODE" = "watch" ]; then
            echo "[Startup] Starting VS Code settings sync loop (every ${INTERVAL}s)" >> /var/log/cmux/startup.log
            (
              while true; do
                if [ -d "$HOST_VSCODE_USER_DIR" ]; then
                  # Sync only if host settings changed (hash compare)
                  host_settings="$HOST_VSCODE_USER_DIR/settings.json"
                  container_user_dir="/root/.openvscode-server/data/User"
                  profile_settings="$container_user_dir/profiles/default-profile/settings.json"
                  user_settings="$container_user_dir/settings.json"

                  if [ -f "$host_settings" ]; then
                    host_sha=$(sha256sum "$host_settings" 2>/dev/null | awk '{print $1}')
                  else
                    host_sha=""
                  fi
                  last_sha_file="$CMUX_STATE_DIR/host_settings.sha"
                  last_sha=""
                  [ -f "$last_sha_file" ] && last_sha=$(cat "$last_sha_file" 2>/dev/null || echo "")

                  if [ "$host_sha" != "$last_sha" ]; then
                    echo "[Startup] Host settings changed; syncing (sha: ${host_sha})" >> /var/log/cmux/startup.log
                    # Sync host -> container, excluding heavy caches
                    tar -C "$HOST_VSCODE_USER_DIR" \
                      --exclude 'workspaceStorage' \
                      --exclude 'History' \
                      --exclude 'logs' \
                      -cf - . 2>/dev/null | tar -C "$container_user_dir" -xpf - 2>/dev/null || true

                    # Merge into profile: preserve existing profile theme/icon if host didn't specify them
                    if command -v jq >/dev/null 2>&1 && [ -f "$user_settings" ]; then
                      tmp_profile=$(mktemp)
                      # Read host user and current profile
                      if [ -f "$profile_settings" ]; then
                        # Compute merged profile
                        jq -s 'def haskey(o;k): (o|type)=="object" and (o|has(k));
                               def keepTheme(u,p): if haskey(u;"workbench.colorTheme") then u["workbench.colorTheme"] 
                                 else (p["workbench.colorTheme"] // empty) end;
                               def keepIcon(u,p): if haskey(u;"workbench.iconTheme") then u["workbench.iconTheme"] 
                                 else (p["workbench.iconTheme"] // empty) end;
                               . as $a | ($a[0] * $a[1])
                               | (if ($a[0]|has("workbench.colorTheme")) then . else (if ($a[1]|has("workbench.colorTheme")) then .+{"workbench.colorTheme":$a[1]["workbench.colorTheme"]} else . end) end)
                               | (if ($a[0]|has("workbench.iconTheme")) then . else (if ($a[1]|has("workbench.iconTheme")) then .+{"workbench.iconTheme":$a[1]["workbench.iconTheme"]} else . end) end)' \
                           "$user_settings" "$profile_settings" > "$tmp_profile" 2>/dev/null || cp "$user_settings" "$tmp_profile"
                      else
                        cp "$user_settings" "$tmp_profile"
                      fi
                      mv "$tmp_profile" "$profile_settings"
                    else
                      # Fallback: copy user -> profile
                      [ -f "$user_settings" ] && cp "$user_settings" "$profile_settings" || true
                    fi

                    # If we still lack an explicit colorTheme, try to derive and set one in profile
                    if command -v jq >/dev/null 2>&1; then
                      current_theme=$(jq -r '."workbench.colorTheme" // empty' "$profile_settings" 2>/dev/null || true)
                      if [ -z "$current_theme" ]; then
                        # derive from preferredDark/Light + VSCODE_THEME
                        pref_dark=""; pref_light=""
                        pref_dark=$(jq -r '."workbench.preferredDarkColorTheme" // empty' "$user_settings" 2>/dev/null || true)
                        pref_light=$(jq -r '."workbench.preferredLightColorTheme" // empty' "$user_settings" 2>/dev/null || true)
                        choose="$pref_dark"
                        if [ "${VSCODE_THEME:-dark}" = "light" ] && [ -n "$pref_light" ]; then choose="$pref_light"; fi
                        if [ -n "$choose" ]; then
                          tmp=$(mktemp); jq --arg th "$choose" '. + {"workbench.colorTheme": $th}' "$profile_settings" > "$tmp" && mv "$tmp" "$profile_settings"
                        fi
                      fi
                    fi

                    # Copy matching theme/icon extensions if necessary
                    copy_required_theme_extensions || true

                    echo -n "$host_sha" > "$last_sha_file" 2>/dev/null || true
                  fi
                fi
                sleep "$INTERVAL"
              done
            ) &
        fi
    fi
}

maybe_start_host_vscode_watch

# Copy required theme/icon extensions from host (if available)
copy_required_theme_extensions() {
    # Require host extensions dir
    if [ -z "${HOST_VSCODE_EXT_DIR:-}" ] || [ ! -d "$HOST_VSCODE_EXT_DIR" ]; then
        return 0
    fi
    local user_settings="/root/.openvscode-server/data/User/settings.json"
    local profile_settings="/root/.openvscode-server/data/User/profiles/default-profile/settings.json"
    # Extract selected themes from profile first (active), then fallback to user
    if command -v jq >/dev/null 2>&1; then
        local color_theme icon_theme
        if [ -f "$profile_settings" ]; then
          color_theme=$(jq -r '."workbench.colorTheme" // empty' "$profile_settings" 2>/dev/null || true)
          icon_theme=$(jq -r '."workbench.iconTheme" // empty' "$profile_settings" 2>/dev/null || true)
        fi
        if [ -z "$color_theme" ] && [ -f "$user_settings" ]; then
          color_theme=$(jq -r '."workbench.colorTheme" // empty' "$user_settings" 2>/dev/null || true)
        fi
        if [ -z "$icon_theme" ] && [ -f "$user_settings" ]; then
          icon_theme=$(jq -r '."workbench.iconTheme" // empty' "$user_settings" 2>/dev/null || true)
        fi

        # helper to see if an extension dir provides a theme/icon by label or id
        provides_theme() {
            local pkg="$1/package.json"; local label="$2"; local kind="$3" # kind: themes|iconThemes
            [ -f "$pkg" ] || return 1
            jq -e --arg label "$label" --arg kind "$kind" '(.contributes[$kind] // []) | any(.label == $label or (.id? // "") == $label)' "$pkg" >/dev/null 2>&1
        }

        mkdir -p /root/.openvscode-server/extensions

        # Search host extensions for matching color theme
        if [ -n "$color_theme" ]; then
            for d in "$HOST_VSCODE_EXT_DIR"/*; do
                [ -d "$d" ] || continue
                if provides_theme "$d" "$color_theme" themes; then
                    base=$(basename "$d")
                    if [ ! -d "/root/.openvscode-server/extensions/$base" ]; then
                        echo "[Startup] Copying color theme extension: $base" >> /var/log/cmux/startup.log
                        cp -R "$d" "/root/.openvscode-server/extensions/$base" || true
                    fi
                    break
                fi
            done
        fi

        # Search host extensions for matching icon theme
        if [ -n "$icon_theme" ]; then
            for d in "$HOST_VSCODE_EXT_DIR"/*; do
                [ -d "$d" ] || continue
                if provides_theme "$d" "$icon_theme" iconThemes; then
                    base=$(basename "$d")
                    if [ ! -d "/root/.openvscode-server/extensions/$base" ]; then
                        echo "[Startup] Copying icon theme extension: $base" >> /var/log/cmux/startup.log
                        cp -R "$d" "/root/.openvscode-server/extensions/$base" || true
                    fi
                    break
                fi
            done
        fi
    fi
}

# Ensure theme/icon extensions exist before starting server
copy_required_theme_extensions

# Ensure workbench.colorTheme is explicit when host settings use auto-detect
ensure_explicit_color_theme() {
    local user_settings="/root/.openvscode-server/data/User/settings.json"
    [ -f "$user_settings" ] || return 0
    if ! command -v jq >/dev/null 2>&1; then
      return 0
    fi
    local current theme pref_dark pref_light autodetect
    current=$(jq -r '."workbench.colorTheme" // empty' "$user_settings")
    if [ -n "$current" ]; then
      return 0
    fi
    pref_dark=$(jq -r '."workbench.preferredDarkColorTheme" // empty' "$user_settings")
    pref_light=$(jq -r '."workbench.preferredLightColorTheme" // empty' "$user_settings")
    autodetect=$(jq -r '."window.autoDetectColorScheme" // empty' "$user_settings")
    # Choose based on VSCODE_THEME if provided, else prefer dark when autodetect
    if [ -n "$VSCODE_THEME" ]; then
      if [ "$VSCODE_THEME" = "dark" ] && [ -n "$pref_dark" ]; then theme="$pref_dark"; fi
      if [ "$VSCODE_THEME" = "light" ] && [ -n "$pref_light" ]; then theme="$pref_light"; fi
    fi
    if [ -z "$theme" ] && [ "$autodetect" = "true" ]; then
      if [ -n "$pref_dark" ]; then theme="$pref_dark"; fi
    fi
    if [ -z "$theme" ]; then
      if [ -n "$pref_dark" ]; then theme="$pref_dark"; fi
      if [ -z "$theme" ] && [ -n "$pref_light" ]; then theme="$pref_light"; fi
    fi
    if [ -n "$theme" ]; then
      echo "[Startup] Setting explicit colorTheme to: $theme" >> /var/log/cmux/startup.log
      tmp=$(mktemp)
      jq --arg theme "$theme" '. + {"workbench.colorTheme": $theme}' "$user_settings" > "$tmp" && mv "$tmp" "$user_settings"
      # Keep profile in sync
      cp "$user_settings" /root/.openvscode-server/data/User/profiles/default-profile/settings.json || true
    fi
}

ensure_explicit_color_theme

# State dir for incremental sync
CMUX_STATE_DIR="/root/.openvscode-server/data/.cmux"
mkdir -p "$CMUX_STATE_DIR"

# Configure VS Code settings
if [ "$CMUX_USED_HOST_VSCODE_SETTINGS" = "1" ]; then
    # When host settings are provided, don't override them. Optionally ensure some sane defaults exist.
    echo "[Startup] Using host VS Code settings; skipping theme override" >> /var/log/cmux/startup.log
    # Ensure terminal defaults exist without clobbering existing file
    if [ -f /root/.openvscode-server/data/User/settings.json ]; then
      # Append minimal defaults if keys missing using jq if available
      if command -v jq >/dev/null 2>&1; then
        tmp=$(mktemp)
        jq '."terminal.integrated.defaultProfile.linux" //= "bash" | ."terminal.integrated.profiles.linux" //= {"bash": {"path": "/bin/bash", "args": ["-l"]}}' \
           /root/.openvscode-server/data/User/settings.json > "$tmp" && mv "$tmp" /root/.openvscode-server/data/User/settings.json || true
        cp /root/.openvscode-server/data/User/settings.json /root/.openvscode-server/data/User/profiles/default-profile/settings.json || true
      fi
    fi
else
    # No host settings; fall back to app-provided defaults and optional theme
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
        # Update VS Code settings files with theme and git configuration
        SETTINGS_JSON='{"workbench.startupEditor": "none", "terminal.integrated.macOptionClickForcesSelection": true, "terminal.integrated.defaultProfile.linux": "bash", "terminal.integrated.profiles.linux": {"bash": {"path": "/bin/bash", "args": ["-l"]}}, "workbench.colorTheme": "'$COLOR_THEME'", "git.openDiffOnClick": true, "scm.defaultViewMode": "tree", "git.showPushSuccessNotification": true, "git.autorefresh": true, "git.branchCompareWith": "main"}'
        # Update all VS Code settings locations
        mkdir -p /root/.openvscode-server/data/User /root/.openvscode-server/data/User/profiles/default-profile /root/.openvscode-server/data/Machine
        echo "$SETTINGS_JSON" > /root/.openvscode-server/data/User/settings.json
        echo "$SETTINGS_JSON" > /root/.openvscode-server/data/User/profiles/default-profile/settings.json
        echo "$SETTINGS_JSON" > /root/.openvscode-server/data/Machine/settings.json
        echo "[Startup] VS Code theme configured to: $COLOR_THEME" >> /var/log/cmux/startup.log
    else
        # Even if no theme is specified, configure defaults for git and terminal
        echo "[Startup] Applying default VS Code settings" >> /var/log/cmux/startup.log
        SETTINGS_JSON='{"workbench.startupEditor": "none", "terminal.integrated.macOptionClickForcesSelection": true, "terminal.integrated.defaultProfile.linux": "bash", "terminal.integrated.profiles.linux": {"bash": {"path": "/bin/bash", "args": ["-l"]}}, "git.openDiffOnClick": true, "scm.defaultViewMode": "tree", "git.showPushSuccessNotification": true, "git.autorefresh": true, "git.branchCompareWith": "main"}'
        mkdir -p /root/.openvscode-server/data/User /root/.openvscode-server/data/User/profiles/default-profile /root/.openvscode-server/data/Machine
        echo "$SETTINGS_JSON" > /root/.openvscode-server/data/User/settings.json
        echo "$SETTINGS_JSON" > /root/.openvscode-server/data/User/profiles/default-profile/settings.json
        echo "$SETTINGS_JSON" > /root/.openvscode-server/data/Machine/settings.json
        echo "[Startup] Default VS Code settings applied" >> /var/log/cmux/startup.log
    fi
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

exec node /builtins/build/index.js
