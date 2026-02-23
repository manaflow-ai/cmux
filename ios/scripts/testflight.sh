#!/bin/bash
# TestFlight upload script with auto-incrementing build number
set -e

cd "$(dirname "$0")/.."

# Get current build number from project.yml
CURRENT_BUILD=$(grep 'CURRENT_PROJECT_VERSION:' project.yml | head -1 | sed 's/.*: *"\([0-9]*\)".*/\1/')
NEW_BUILD=$((CURRENT_BUILD + 1))

echo "📱 Bumping build number: $CURRENT_BUILD → $NEW_BUILD"

# Update build number in project.yml
sed -i '' "s/CURRENT_PROJECT_VERSION: \"$CURRENT_BUILD\"/CURRENT_PROJECT_VERSION: \"$NEW_BUILD\"/" project.yml

# Regenerate Xcode project
echo "⚙️  Regenerating Xcode project..."
xcodegen generate

# Archive
echo "📦 Archiving..."
xcodebuild -scheme cmux -configuration Beta \
  -archivePath build/cmux.xcarchive archive \
  -quiet

# Try to attach Sentry dSYM if available
SENTRY_BINARY="build/cmux.xcarchive/Products/Applications/cmux Beta.app/Frameworks/Sentry.framework/Sentry"
if [ -f "$SENTRY_BINARY" ]; then
  SENTRY_UUID=$(dwarfdump --uuid "$SENTRY_BINARY" | awk '{print $2}' | head -1)
  if [ -n "$SENTRY_UUID" ]; then
    python3 - <<'PY' "$SENTRY_UUID" "$HOME/Library/Developer/Xcode/DerivedData" "build/cmux.xcarchive/dSYMs"
import pathlib
import shutil
import subprocess
import sys

needle = sys.argv[1].strip()
root = pathlib.Path(sys.argv[2])
dest_root = pathlib.Path(sys.argv[3])
matched = None

for path in root.rglob("Sentry.framework.dSYM"):
    try:
        out = subprocess.check_output(["dwarfdump", "--uuid", str(path)], stderr=subprocess.STDOUT, text=True)
    except subprocess.CalledProcessError:
        continue
    if needle in out:
        matched = path
        break

if matched:
    dest = dest_root / "Sentry.framework.dSYM"
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(matched, dest)
    print(f"✅ Attached Sentry dSYM: {matched}")
else:
    print(f"⚠️  Sentry dSYM not found for UUID {needle}")
PY
  fi
fi

# Export options
EXPORT_PLIST="build/ExportOptions.plist"
cat <<'EOF' > "$EXPORT_PLIST"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>upload</string>
  <key>method</key>
  <string>app-store-connect</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>teamID</key>
  <string>7WLXT3NR37</string>
  <key>uploadSymbols</key>
  <true/>
</dict>
</plist>
EOF

# Export and upload
echo "🚀 Uploading to TestFlight..."
xcodebuild -exportArchive \
  -archivePath build/cmux.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration

echo "✅ Build $NEW_BUILD uploaded to TestFlight!"
