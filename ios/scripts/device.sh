#!/bin/bash
# Build and install to connected iPhone/iPad devices.
set -e
cd "$(dirname "$0")/.."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_CONFIG_SOURCE="$(cd "$SCRIPT_DIR/.." && pwd)/Sources/Config/LocalConfig.plist"

source "$SCRIPT_DIR/common.sh"

IOS_DEVICES="$(connected_ios_device_lines)"
MIN_IOS_VERSION="$(ios_deployment_target)"

if [ -z "$IOS_DEVICES" ]; then
    echo "❌ No iPhone or iPad connected"
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
    exit 1
fi

xcodegen generate

INSTALLED_DEVICE_COUNT=0
while IFS=$'\t' read -r DEVICE_NAME DEVICE_ID DEVICE_OS_VERSION; do
    [ -n "$DEVICE_ID" ] || continue
    if [ -n "$DEVICE_OS_VERSION" ] && [ -n "$MIN_IOS_VERSION" ] && ! ios_version_at_least "$DEVICE_OS_VERSION" "$MIN_IOS_VERSION"; then
        echo "⚠️  Skipping $DEVICE_NAME (iOS/iPadOS $DEVICE_OS_VERSION). cmux requires iOS/iPadOS $MIN_IOS_VERSION or newer."
        continue
    fi

    echo "📱 Building for $DEVICE_NAME..."

    xcodebuild -scheme cmux -configuration Debug \
        -destination "id=$DEVICE_ID" \
        -derivedDataPath build \
        -allowProvisioningUpdates \
        -allowProvisioningDeviceRegistration \
        -quiet

    DEVICE_APP_PATH="build/Build/Products/Debug-iphoneos/cmux DEV.app"
    copy_local_config_if_present "$DEVICE_APP_PATH" "$LOCAL_CONFIG_SOURCE"
    rewrite_localhost_for_device "$DEVICE_APP_PATH/LocalConfig.plist"
    embed_debug_relay_for_device "$DEVICE_APP_PATH"

    echo "📲 Installing on $DEVICE_NAME..."
    xcrun devicectl device install app --device "$DEVICE_ID" "$DEVICE_APP_PATH"

    echo "🚀 Launching on $DEVICE_NAME..."
    if ! xcrun devicectl device process launch --device "$DEVICE_ID" dev.cmux.app.dev; then
        echo "⚠️  Could not launch on $DEVICE_NAME. If the device is locked, unlock it and open cmux manually."
    fi
    INSTALLED_DEVICE_COUNT=$((INSTALLED_DEVICE_COUNT + 1))
done <<< "$IOS_DEVICES"

if [ "$INSTALLED_DEVICE_COUNT" -eq 0 ]; then
    echo "❌ No compatible connected iPhone or iPad was reloaded"
    exit 1
fi

echo "✅ Done!"
