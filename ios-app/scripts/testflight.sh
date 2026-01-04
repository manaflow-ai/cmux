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

# Export and upload
echo "🚀 Uploading to TestFlight..."
xcodebuild -exportArchive \
  -archivePath build/cmux.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist build/ExportOptions.plist

echo "✅ Build $NEW_BUILD uploaded to TestFlight!"
