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

echo "📲 Installing on simulator..."
xcrun simctl install booted "build/Build/Products/Debug-iphonesimulator/cmux DEV.app" 2>/dev/null || true
xcrun simctl launch booted dev.cmux.app.dev 2>/dev/null || true

if [ "$SIMULATOR_ONLY" -eq 1 ]; then
    echo "✅ Done! (simulator only)"
    exit 0
fi

# Check for connected device
DEVICE_ID=$(xcrun xctrace list devices 2>&1 | grep -E "iPhone.*\([0-9]+\.[0-9]+\)" | grep -v Simulator | head -1 | grep -oE '\([A-F0-9-]+\)' | tr -d '()')

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
    xcrun devicectl device process launch --device "$DEVICE_ID" dev.cmux.app.dev
else
    echo "ℹ️  No iPhone connected, skipping device install"
fi

echo "✅ Done!"
