#!/bin/bash
# Build and install to connected iPhone
set -e
cd "$(dirname "$0")/.."

# Find connected device
DEVICE_ID=$(xcrun xctrace list devices 2>&1 | grep -E "iPhone.*\([0-9]+\.[0-9]+(\.[0-9]+)?\)" | grep -v Simulator | head -1 | grep -oE '\([A-F0-9-]+\)' | tr -d '()')

if [ -z "$DEVICE_ID" ]; then
    echo "❌ No iPhone connected"
    exit 1
fi

DEVICE_NAME=$(xcrun xctrace list devices 2>&1 | grep "$DEVICE_ID" | sed 's/ ([0-9].*//')
echo "📱 Building for $DEVICE_NAME..."

xcodegen generate
xcodebuild -scheme cmux -configuration Debug \
    -destination "id=$DEVICE_ID" \
    -derivedDataPath build \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    -quiet

echo "📲 Installing..."
xcrun devicectl device install app --device "$DEVICE_ID" "build/Build/Products/Debug-iphoneos/cmux DEV.app"

echo "🚀 Launching..."
if ! xcrun devicectl device process launch --device "$DEVICE_ID" dev.cmux.app.dev; then
    echo "⚠️  Could not launch app. If the device is locked, unlock it and open cmux manually."
fi

echo "✅ Done!"
