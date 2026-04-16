#!/bin/bash
# Fix CEF framework symlink structure after Xcode embedding
# Xcode's Embed Frameworks phase expands symlinks to directories — this restores the correct structure

FRAMEWORK_PATH="${BUILT_PRODUCTS_DIR}/${EXECUTABLE_FOLDER_PATH}/../Frameworks/Chromium Embedded Framework.framework"

if [ ! -d "$FRAMEWORK_PATH" ]; then
    echo "⚠️  Framework not found at $FRAMEWORK_PATH"
    exit 0
fi

echo "🔧 Fixing CEF framework symlinks at: $FRAMEWORK_PATH"

# Remove mis-embedded root files (should be symlinks, not copies)
rm -f "$FRAMEWORK_PATH/Chromium Embedded Framework"
rm -f "$FRAMEWORK_PATH/Resources"
rm -f "$FRAMEWORK_PATH/Libraries"

# Create proper root-level symlinks to Versions/Current
cd "$FRAMEWORK_PATH"
ln -sf "Versions/Current/Chromium Embedded Framework" "Chromium Embedded Framework"
ln -sf "Versions/Current/Resources" "Resources"

if [ -d "Versions/A/Libraries" ]; then
    ln -sf "Versions/Current/Libraries" "Libraries"
fi

# Fix Versions/Current — should be symlink to A, not a directory
if [ -d "Versions/Current" ] && [ ! -L "Versions/Current" ]; then
    rm -rf "Versions/Current"
    ln -s "A" "Versions/Current"
fi

echo "✓ CEF framework structure fixed"
