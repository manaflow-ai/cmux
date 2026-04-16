#!/usr/bin/env zsh

set -e  # Exit on error

# ─── Configuration ───────────────────────────────────────────────────────────

SRCROOT="${SRCROOT:-.}"
FRAMEWORKS_DIR="$SRCROOT/Frameworks"

# ─── Helper Functions ────────────────────────────────────────────────────────

# Find the CEF binary directory
find_cef_dir() {
    local cef_dir=$(find -L "$SRCROOT/CEF" -maxdepth 1 -type d -name "cef_binary_*" | head -1)
    if [ -z "$cef_dir" ]; then
        echo "❌ Error: Could not find CEF binary directory in $SRCROOT/CEF"
        exit 1
    fi
    echo "$cef_dir"
}

# Build the C++ DLL wrapper from source
build_cef_wrapper() {
    local cef_dir="$1"
    echo "🔨 Building CEF C++ wrapper..."

    (
        cd "$cef_dir"
        cmake -G "Xcode" -DPROJECT_ARCH="arm64" .
        xcodebuild -configuration Release
    )

    echo "✓ CEF C++ wrapper built"
}

# Restructure framework from flat to versioned macOS layout
restructure_framework() {
    local fw="$1"
    local fw_name="Chromium Embedded Framework"

    echo "  ↳ Restructuring to macOS versioned layout..."

    # Create versioned directory structure
    mkdir -p "$fw/Versions/A"

    # Move binary to Versions/A
    mv "$fw/$fw_name" "$fw/Versions/A/"

    # Move Resources to Versions/A
    mv "$fw/Resources" "$fw/Versions/A/"

    # Move Libraries to Versions/A if it exists
    if [ -d "$fw/Libraries" ]; then
        mv "$fw/Libraries" "$fw/Versions/A/"
    fi

    # Create Current symlink (Versions/Current -> A)
    ln -s "A" "$fw/Versions/Current"

    # Create root-level symlinks pointing to Versions/Current
    ln -s "Versions/Current/$fw_name" "$fw/$fw_name"
    ln -s "Versions/Current/Resources" "$fw/Resources"
    if [ -d "$fw/Versions/A/Libraries" ]; then
        ln -s "Versions/Current/Libraries" "$fw/Libraries"
    fi

    # Update the binary's install name to the versioned path using @rpath.
    # Xcode strips the root-level binary symlink during code signing, so dyld must
    # resolve the binary directly via Versions/A/. @rpath is resolved using the
    # app's LD_RUNPATH_SEARCH_PATHS (@executable_path/../Frameworks).
    local versioned_id="@rpath/$fw_name.framework/Versions/A/$fw_name"
    install_name_tool -id "$versioned_id" "$fw/Versions/A/$fw_name"
}

# Copy static library and headers to Frameworks
copy_static_artifacts() {
    local cef_dir="$1"
    echo "📦 Copying static library and headers..."

    mkdir -p "$FRAMEWORKS_DIR/include"
    cp "$cef_dir/libcef_dll_wrapper/Release/libcef_dll_wrapper.a" "$FRAMEWORKS_DIR/"
    cp -R "$cef_dir/include/" "$FRAMEWORKS_DIR/include/"

    echo "✓ Copied libcef_dll_wrapper.a and headers"
}

# Copy dynamic framework and helper apps
copy_dynamic_framework() {
    local cef_dir="$1"
    echo "📚 Copying dynamic Chromium Embedded Framework..."

    mkdir -p "$FRAMEWORKS_DIR"

    # Copy Chromium Embedded Framework from CEF Release directory
    local cef_framework="$cef_dir/Release/Chromium Embedded Framework.framework"
    if [ -d "$cef_framework" ]; then
        rm -rf "$FRAMEWORKS_DIR/Chromium Embedded Framework.framework"
        cp -R "$cef_framework" "$FRAMEWORKS_DIR/"

        # CEF ships the framework as a flat bundle, but macOS requires versioned layout.
        # Restructure Versions/A/Resources/Info.plist for Xcode code signing.
        local fw_dest="$FRAMEWORKS_DIR/Chromium Embedded Framework.framework"
        restructure_framework "$fw_dest"

        # Remove pre-existing signature from CEF's team so Xcode can re-sign with our team cert
        echo "  🔓 Removing CEF's pre-existing signature..."
        codesign --remove-signature "$fw_dest/Versions/A/Chromium Embedded Framework" 2>/dev/null || true

        echo "✓ Copied Chromium Embedded Framework to Frameworks/"
    else
        echo "⚠️  Warning: Could not find Chromium Embedded Framework at $cef_framework"
        return 1
    fi

    # Copy CEF helper apps if they exist (optional; normally in unpacked dirs)
    setopt nullglob  # Make glob expansion return empty list instead of error when no matches
    local helper_count=0
    for helper in "$cef_dir/Release/"*.app; do
        [ -d "$helper" ] || continue
        local bundle_name=$(basename "$helper")
        rm -rf "$FRAMEWORKS_DIR/$bundle_name"
        cp -R "$helper" "$FRAMEWORKS_DIR/"
        echo "✓ Copied $bundle_name to Frameworks/"
        helper_count=$((helper_count + 1))
    done
    unsetopt nullglob

    if [ $helper_count -eq 0 ]; then
        echo "ℹ️  No helper apps found in Release directory (this is normal)"
    fi
}

# ─── Main Build Flow ────────────────────────────────────────────────────────

echo "🚀 Building CEFWebView CEF dependencies..."
echo ""

# Find CEF directory
cef_dir=$(find_cef_dir)
echo "📍 Found CEF at: $cef_dir"
echo ""

# Build the C++ wrapper
build_cef_wrapper "$cef_dir"
echo ""

# Copy artifacts to Frameworks
copy_static_artifacts "$cef_dir"
echo ""

copy_dynamic_framework "$cef_dir"
echo ""

echo "✅ Build complete! Frameworks/ is ready for Xcode."
