#!/bin/bash
# Build and install to simulators and connected iPhone/iPad devices when available.
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR/ios"

SIMULATOR_ONLY=0
TAG=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --simulator-only|--sim-only)
            SIMULATOR_ONLY=1
            ;;
        --tag)
            TAG="$2"
            shift
            ;;
        --tag=*)
            TAG="${1#--tag=}"
            ;;
    esac
    shift
done

DERIVED_DATA_PATH="build"
if [ -n "$TAG" ]; then
    DERIVED_DATA_PATH="$HOME/Library/Developer/Xcode/DerivedData/cmux-$TAG"
fi

# Tagged build identity. The home-screen label is just the tag (e.g. "mvios")
# because iOS truncates long names; the "cmux DEV" prefix wastes the width
# that every tagged build would otherwise share. Untagged builds keep the
# full "cmux DEV" label for discoverability.
BUNDLE_ID="dev.cmux.app.dev"
APP_NAME="cmux DEV"
if [ -n "$TAG" ]; then
    SANITIZED_TAG=$(echo "$TAG" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\.+//; s/\.+$//; s/\.+/./g')
    BUNDLE_ID="dev.cmux.app.dev.${SANITIZED_TAG}"
    APP_NAME="${TAG}"
fi

# Discover the active wsPort from the matching macOS daemon's .wsport file.
# Tagged iOS builds embed this as the authoritative default endpoint for the
# main sidebar; the in-app Find Servers sheet remains the broad scanner.
WS_PORT=""
if [ -n "$TAG" ]; then
    TAG_SLUG=$(echo "$TAG" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')
    WSPORT_FILE="/tmp/cmux-debug-${TAG_SLUG}.wsport"
    if [ -f "$WSPORT_FILE" ]; then
        WS_PORT=$(cat "$WSPORT_FILE")
        # Sanity-check the hint against a live daemon so we don't embed a
        # stale port. If no daemon is answering on that port, drop the hint
        # and let the runtime scan handle it.
        if ! nc -z 127.0.0.1 "$WS_PORT" 2>/dev/null; then
            echo "⚠️  wsport hint $WS_PORT is stale (no daemon listening); will rely on runtime scan"
            WS_PORT=""
        else
            echo "🔗 Found macOS daemon wsPort: $WS_PORT (from $WSPORT_FILE)"
        fi
    else
        echo "⚠️  No wsport hint at $WSPORT_FILE — runtime port scan will handle discovery."
        echo "    (Tip: run ./scripts/reload.sh --tag $TAG first if you want an exact match.)"
    fi
fi

LOCAL_CONFIG_SOURCE="$PROJECT_DIR/ios/Sources/Config/LocalConfig.plist"

source "$SCRIPT_DIR/common.sh"

ensure_ghosttykit() {
    local ghostty_dir="$PROJECT_DIR/ghostty"
    local local_xcframework="$ghostty_dir/macos/GhosttyKit.xcframework"
    local local_sha_stamp="$local_xcframework/.ghostty_sha"
    local cache_root="${CMUX_GHOSTTYKIT_CACHE_DIR:-$HOME/.cache/cmux/ghosttykit}"
    local ghostty_sha
    ghostty_sha="$(git -C "$ghostty_dir" rev-parse HEAD)"
    local ghostty_short_sha
    ghostty_short_sha="$(git -C "$ghostty_dir" rev-parse --short HEAD)"
    local ghostty_base_version
    ghostty_base_version="$(awk -F'\"' '/.version = / { print $2; exit }' "$ghostty_dir/build.zig.zon")"
    local ghostty_version_string="${ghostty_base_version}+${ghostty_short_sha}"
    local cache_dir="$cache_root/$ghostty_sha"
    local cache_xcframework="$cache_dir/GhosttyKit.xcframework"
    local link_path="$PROJECT_DIR/GhosttyKit.xcframework"

    mkdir -p "$cache_root"

    if [ ! -d "$cache_xcframework" ]; then
        local local_sha=""
        if [ -f "$local_sha_stamp" ]; then
            local_sha="$(cat "$local_sha_stamp")"
        fi

        if [ ! -d "$local_xcframework" ] || [ "$local_sha" != "$ghostty_sha" ]; then
            echo "🔧 Building GhosttyKit.xcframework for ghostty $ghostty_sha..."
            (
                cd "$ghostty_dir"
                zig build \
                    -Demit-xcframework=true \
                    -Doptimize=ReleaseFast \
                    -Dversion-string="$ghostty_version_string"
            )
            echo "$ghostty_sha" > "$local_sha_stamp"
        else
            echo "🔧 Reusing local GhosttyKit.xcframework for ghostty $ghostty_sha..."
        fi

        if [ ! -d "$local_xcframework" ]; then
            echo "GhosttyKit.xcframework missing at $local_xcframework" >&2
            exit 1
        fi

        local tmp_dir
        tmp_dir="$(mktemp -d "$cache_root/.ghosttykit-tmp.XXXXXX")"
        mkdir -p "$cache_dir"
        cp -R "$local_xcframework" "$tmp_dir/GhosttyKit.xcframework"
        rm -rf "$cache_xcframework"
        mv "$tmp_dir/GhosttyKit.xcframework" "$cache_xcframework"
        rmdir "$tmp_dir"
        echo "🔧 Cached GhosttyKit.xcframework at $cache_xcframework"
    fi

    if [ "$(readlink "$link_path" 2>/dev/null || true)" != "$cache_xcframework" ]; then
        echo "🔧 Linking GhosttyKit.xcframework -> $cache_xcframework"
        ln -sfn "$cache_xcframework" "$link_path"
    fi
}

ensure_ghosttykit

xcodegen generate

# Build for simulator
echo "🖥️  Building for simulator..."
EXTRA_SETTINGS=()
if [ "$BUNDLE_ID" != "dev.cmux.app.dev" ]; then
    EXTRA_SETTINGS+=("PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID")
    EXTRA_SETTINGS+=("INFOPLIST_KEY_CFBundleDisplayName=$APP_NAME")
fi
xcodebuild -scheme cmux -sdk iphonesimulator -configuration Debug \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    "${EXTRA_SETTINGS[@]}" \
    -quiet

SIM_APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug-iphonesimulator/cmux DEV.app"
copy_local_config_if_present "$SIM_APP_PATH" "$LOCAL_CONFIG_SOURCE"

# Embed wsPort if discovered
if [ -n "$WS_PORT" ] && [ -d "$SIM_APP_PATH" ]; then
    printf '%s' "$WS_PORT" > "$SIM_APP_PATH/debug-ws-port"
fi
if [ -n "$TAG" ] && [ -d "$SIM_APP_PATH" ]; then
    printf 'cmuxd-dev-%s' "$TAG_SLUG" > "$SIM_APP_PATH/debug-ws-instance"
fi

echo "📲 Installing on simulator(s)..."
# Install and launch on ALL booted simulators
BOOTED_SIMS=$(xcrun simctl list devices | grep "Booted" | grep -oE '[A-F0-9-]{36}')
if [ -n "$BOOTED_SIMS" ]; then
    for SIM_ID in $BOOTED_SIMS; do
        SIM_NAME=$(xcrun simctl list devices | grep "$SIM_ID" | sed 's/ (.*//')
        echo "  → $SIM_NAME"
        xcrun simctl terminate "$SIM_ID" "$BUNDLE_ID" 2>/dev/null || true
        xcrun simctl install "$SIM_ID" "$SIM_APP_PATH" 2>/dev/null || true
        xcrun simctl launch "$SIM_ID" "$BUNDLE_ID" 2>/dev/null || true
    done
else
    echo "  ⚠️  No booted simulators found"
fi

if [ "$SIMULATOR_ONLY" -eq 1 ]; then
    echo "✅ Done! (simulator only)"
    exit 0
fi

IOS_DEVICES="$(connected_ios_device_lines)"
MIN_IOS_VERSION="$(ios_deployment_target)"
INSTALLED_DEVICE_COUNT=0
if [ -n "$IOS_DEVICES" ]; then
    echo "📱 Building and installing on connected iPhone/iPad device(s)..."
    while IFS=$'\t' read -r DEVICE_NAME DEVICE_ID DEVICE_OS_VERSION; do
        [ -n "$DEVICE_ID" ] || continue
        if [ -n "$DEVICE_OS_VERSION" ] && [ -n "$MIN_IOS_VERSION" ] && ! ios_version_at_least "$DEVICE_OS_VERSION" "$MIN_IOS_VERSION"; then
            echo "  ⚠️  Skipping $DEVICE_NAME (iOS/iPadOS $DEVICE_OS_VERSION). cmux requires iOS/iPadOS $MIN_IOS_VERSION or newer."
            continue
        fi

        echo "  → Building for $DEVICE_NAME..."

        xcodebuild -scheme cmux -configuration Debug \
            -destination "id=$DEVICE_ID" \
            -derivedDataPath "$DERIVED_DATA_PATH" \
            "${EXTRA_SETTINGS[@]}" \
            -allowProvisioningUpdates \
            -allowProvisioningDeviceRegistration \
            -quiet

        DEVICE_APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug-iphoneos/cmux DEV.app"
        copy_local_config_if_present "$DEVICE_APP_PATH" "$LOCAL_CONFIG_SOURCE"
        rewrite_localhost_for_device "$DEVICE_APP_PATH/LocalConfig.plist"
        embed_debug_relay_for_device "$DEVICE_APP_PATH"

        # Embed wsPort if discovered
        if [ -n "$WS_PORT" ] && [ -d "$DEVICE_APP_PATH" ]; then
            printf '%s' "$WS_PORT" > "$DEVICE_APP_PATH/debug-ws-port"
        fi
        if [ -n "$TAG" ] && [ -d "$DEVICE_APP_PATH" ]; then
            printf 'cmuxd-dev-%s' "$TAG_SLUG" > "$DEVICE_APP_PATH/debug-ws-instance"
        fi

        echo "  → Installing on $DEVICE_NAME..."
        xcrun devicectl device install app --device "$DEVICE_ID" "$DEVICE_APP_PATH"

        echo "  → Launching on $DEVICE_NAME..."
        if ! xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"; then
            echo "  ⚠️  Could not launch on $DEVICE_NAME. If the device is locked, unlock it and open cmux manually."
        fi
        INSTALLED_DEVICE_COUNT=$((INSTALLED_DEVICE_COUNT + 1))
    done <<< "$IOS_DEVICES"
fi

OFFLINE_DEVICES="$(offline_ios_device_lines)"
if [ -n "$OFFLINE_DEVICES" ]; then
    while IFS=$'\t' read -r OFFLINE_DEVICE_NAME OFFLINE_DEVICE_ID OFFLINE_DEVICE_OS_VERSION; do
        [ -n "$OFFLINE_DEVICE_ID" ] || continue
        if [ -n "$OFFLINE_DEVICE_OS_VERSION" ]; then
            echo "⚠️  Found $OFFLINE_DEVICE_NAME (iOS/iPadOS $OFFLINE_DEVICE_OS_VERSION), but it is currently unavailable/offline."
        else
            echo "⚠️  Found $OFFLINE_DEVICE_NAME, but it is currently unavailable/offline."
        fi
        echo "   Unlock the device and make sure it is trusted, then re-run this script."
    done <<< "$OFFLINE_DEVICES"
fi

if [ -z "$IOS_DEVICES" ]; then
    echo "ℹ️  No iPhone or iPad connected, skipping physical device install"
elif [ "$INSTALLED_DEVICE_COUNT" -eq 0 ]; then
    echo "ℹ️  No compatible connected iPhone or iPad was reloaded"
fi

echo "✅ Done!"
