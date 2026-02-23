#!/bin/bash
# Build and install to both simulator and connected iPhone (if available)
set -e
cd "$(dirname "$0")/.."

SIMULATOR_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --simulator-only|--sim-only)
            SIMULATOR_ONLY=1
            ;;
    esac
done

xcodegen generate

# Build for simulator
echo "🖥️  Building for simulator..."
xcodebuild -scheme cmux -sdk iphonesimulator -configuration Debug \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    -derivedDataPath build \
    -quiet

echo "📲 Installing on simulator(s)..."
# Install and launch on ALL booted simulators
BOOTED_SIMS=$(xcrun simctl list devices | grep "Booted" | grep -oE '[A-F0-9-]{36}')
if [ -n "$BOOTED_SIMS" ]; then
    for SIM_ID in $BOOTED_SIMS; do
        SIM_NAME=$(xcrun simctl list devices | grep "$SIM_ID" | sed 's/ (.*//')
        echo "  → $SIM_NAME"
        xcrun simctl install "$SIM_ID" "build/Build/Products/Debug-iphonesimulator/cmux DEV.app" 2>/dev/null || true
        xcrun simctl launch "$SIM_ID" dev.cmux.app.dev 2>/dev/null || true
    done
else
    echo "  ⚠️  No booted simulators found"
fi

if [ "$SIMULATOR_ONLY" -eq 1 ]; then
    echo "✅ Done! (simulator only)"
    exit 0
fi

# Check for connected device (may appear as "offline" if the phone is locked/untrusted).
DEVICE_ID=$(xcrun xctrace list devices 2>&1 | awk '
    /^== Devices ==/ { in_devices = 1; next }
    /^==/ { in_devices = 0 }
    in_devices { print }
' | grep -E "iPhone.*\\([0-9]+\\.[0-9]+(\\.[0-9]+)?\\)" | head -1 | grep -oE '\([A-F0-9-]+\)' | tr -d '()')

if [ -n "$DEVICE_ID" ]; then
    DEVICE_NAME=$(xcrun xctrace list devices 2>&1 | grep "$DEVICE_ID" | sed 's/ ([0-9].*//')
    echo "📱 Building for $DEVICE_NAME..."

    xcodebuild -scheme cmux -configuration Debug \
        -destination "id=$DEVICE_ID" \
        -derivedDataPath build \
        -allowProvisioningUpdates \
        -allowProvisioningDeviceRegistration \
        -quiet

    echo "📲 Installing on device..."
    xcrun devicectl device install app --device "$DEVICE_ID" "build/Build/Products/Debug-iphoneos/cmux DEV.app"

    echo "🚀 Launching on device..."
    if ! xcrun devicectl device process launch --device "$DEVICE_ID" dev.cmux.app.dev; then
        echo "⚠️  Could not launch app. If the device is locked, unlock it and open cmux manually."
    fi
else
    OFFLINE_DEVICE_ID=$(xcrun xctrace list devices 2>&1 | awk '
        /^== Devices Offline ==/ { in_devices = 1; next }
        /^==/ { in_devices = 0 }
        in_devices { print }
    ' | grep -E "iPhone.*\\([0-9]+\\.[0-9]+(\\.[0-9]+)?\\)" | head -1 | grep -oE '\([A-F0-9-]+\)' | tr -d '()')

    if [ -n "$OFFLINE_DEVICE_ID" ]; then
        OFFLINE_DEVICE_NAME=$(xcrun xctrace list devices 2>&1 | grep "$OFFLINE_DEVICE_ID" | sed 's/ ([0-9].*//')
        echo "⚠️  Found $OFFLINE_DEVICE_NAME, but it is currently unavailable/offline."
        echo "   Unlock the device and make sure it is trusted, then re-run this script."
    else
        echo "ℹ️  No iPhone connected, skipping device install"
    fi
fi

echo "✅ Done!"
