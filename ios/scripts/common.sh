#!/bin/bash
# Shared helpers for iOS build scripts

ios_device_lines_for_section() {
    local section="$1"
    xcrun xctrace list devices 2>&1 | awk -v section="$section" '
        $0 == section { in_section = 1; next }
        /^==/ { in_section = 0 }
        in_section && $0 ~ /(iPhone|iPad)/ && $0 ~ /\([0-9]+\.[0-9]/ { print }
    ' | while IFS= read -r line; do
        local device_id
        device_id="$(echo "$line" | grep -oE '\([A-Fa-f0-9-]{20,}\)' | tail -1 | tr -d '()')"
        [ -n "$device_id" ] || continue

        local device_os_version
        device_os_version="$(echo "$line" | grep -oE '\([0-9]+\.[0-9]+(\.[0-9]+)?[^)]*\)' | head -1 | sed -E 's/[()]//g; s/[^0-9.].*$//')"

        local device_name
        device_name="$(echo "$line" | sed -E 's/[[:space:]]*\([0-9]+(\.[0-9]+)*[^)]*\)[[:space:]]*\([A-Fa-f0-9-]{20,}\).*$//')"
        [ -n "$device_name" ] || device_name="iOS device"

        printf '%s\t%s\t%s\n' "$device_name" "$device_id" "$device_os_version"
    done
}

connected_ios_device_lines() {
    ios_device_lines_for_section "== Devices =="
}

offline_ios_device_lines() {
    ios_device_lines_for_section "== Devices Offline =="
}

ios_deployment_target() {
    awk -F'"' '/^[[:space:]]*iOS:[[:space:]]*"/ { print $2; exit }' project.yml
}

ios_version_at_least() {
    local version="$1"
    local minimum="$2"
    awk -v version="$version" -v minimum="$minimum" '
        function component(value, idx, parts) {
            split(value, parts, ".")
            return parts[idx] == "" ? 0 : parts[idx] + 0
        }
        BEGIN {
            for (i = 1; i <= 3; i++) {
                current = component(version, i)
                required = component(minimum, i)
                if (current > required) exit 0
                if (current < required) exit 1
            }
            exit 0
        }
    '
}

copy_local_config_if_present() {
    local app_path="$1"
    local config_source="$2"
    if [ -f "$config_source" ] && [ -d "$app_path" ]; then
        cp "$config_source" "$app_path/LocalConfig.plist"
    fi
}

get_mac_reachable_ip() {
    # Prefer Tailscale IP (required for iPhone connectivity)
    local ts_ip
    ts_ip=$(/Applications/Tailscale.app/Contents/MacOS/Tailscale ip -4 2>/dev/null || tailscale ip -4 2>/dev/null)
    if [ -n "$ts_ip" ]; then
        echo "$ts_ip"
        return
    fi
    # Fallback: scan utun interfaces for Tailscale 100.x range
    for i in $(seq 0 15); do
        local ip
        ip=$(ifconfig utun$i 2>/dev/null | grep "inet " | awk '{print $2}')
        if [ -n "$ip" ] && [[ "$ip" == 100.* ]]; then
            echo "$ip"
            return
        fi
    done
    # Last resort: LAN IP
    ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null
}

rewrite_localhost_for_device() {
    local plist_path="$1"
    local mac_ip
    mac_ip="$(get_mac_reachable_ip)"
    if [ -n "$mac_ip" ] && [ -f "$plist_path" ]; then
        local ip_source="LAN"
        if [[ "$mac_ip" == 100.* ]]; then
            ip_source="Tailscale"
        fi
        sed -i '' "s|localhost|$mac_ip|g; s|127\.0\.0\.1|$mac_ip|g" "$plist_path"
        echo "  → Rewrote localhost → $mac_ip ($ip_source) in $(basename "$plist_path")"
    fi
}

# Copy WebSocket debug relay files into the device app bundle so the iOS app
# can connect to the desktop cmux daemon via WebSocket over Tailscale.
embed_debug_relay_for_device() {
    local app_path="$1"
    [ -d "$app_path" ] || return

    # Copy ws-secret from Mac into app bundle
    local ws_secret_src="$HOME/Library/Application Support/cmux/mobile-ws-secret"
    if [ -f "$ws_secret_src" ]; then
        cp "$ws_secret_src" "$app_path/mobile-ws-secret"
        echo "  → Embedded mobile-ws-secret in app bundle"
    else
        echo "  ⚠️  No mobile-ws-secret found at $ws_secret_src"
    fi

    # Write the Mac's reachable IP so the app knows where to connect
    local mac_ip
    mac_ip="$(get_mac_reachable_ip)"
    if [ -n "$mac_ip" ]; then
        printf '%s' "$mac_ip" > "$app_path/debug-relay-host"
        echo "  → Embedded debug-relay-host ($mac_ip) in app bundle"
    fi
}
