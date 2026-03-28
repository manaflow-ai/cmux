#!/usr/bin/env bash
set -euo pipefail

# Build the CEF bridge library.
# If CEF distribution is available (cached or downloaded), builds with
# real CEF support. Otherwise builds stubs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CEF_BRIDGE_DIR="$PROJECT_DIR/vendor/cef-bridge"

# CEF version pinned for this release
CEF_VERSION="146.0.6+g68649e2+chromium-146.0.7680.154"
CEF_PLATFORM="macosarm64"
CEF_DIST_NAME="cef_binary_${CEF_VERSION}_${CEF_PLATFORM}_minimal"
CEF_CACHE_DIR="${CMUX_CEF_CACHE_DIR:-$HOME/.cache/cmux/cef}"
CEF_EXTRACT_DIR="$CEF_CACHE_DIR/extracted/$CEF_DIST_NAME"
CEF_DOWNLOAD_URL="https://cef-builds.spotifycdn.com/cef_binary_$(echo "$CEF_VERSION" | sed 's/+/%2B/g')_${CEF_PLATFORM}_minimal.tar.bz2"

download_cef() {
    local archive="$CEF_CACHE_DIR/$(basename "$CEF_DOWNLOAD_URL")"
    mkdir -p "$CEF_CACHE_DIR"

    if [ ! -f "$archive" ]; then
        echo "==> Downloading CEF minimal distribution..."
        curl -L -o "$archive" "$CEF_DOWNLOAD_URL" --progress-bar
    fi

    if [ ! -d "$CEF_EXTRACT_DIR" ]; then
        echo "==> Extracting CEF..."
        mkdir -p "$CEF_CACHE_DIR/extracted"
        tar -xjf "$archive" -C "$CEF_CACHE_DIR/extracted"
    fi
}

build_wrapper() {
    local build_dir="$CEF_EXTRACT_DIR/build"
    local wrapper_lib="$build_dir/libcef_dll_wrapper/libcef_dll_wrapper.a"

    if [ -f "$wrapper_lib" ]; then
        echo "==> Reusing cached libcef_dll_wrapper.a"
        return
    fi

    echo "==> Building libcef_dll_wrapper..."
    mkdir -p "$build_dir"
    (
        cd "$build_dir"
        cmake -G "Ninja" \
            -DPROJECT_ARCH="arm64" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_OSX_ARCHITECTURES=arm64 \
            ..
        ninja libcef_dll_wrapper
    )
}

build_bridge() {
    local target_archs="${ARCHS:-arm64}"
    local wrapper_lib="$CEF_EXTRACT_DIR/build/libcef_dll_wrapper/libcef_dll_wrapper.a"
    local needs_stub=0

    case " $target_archs " in
        *" x86_64 "*)
            echo "==> x86_64 build requested, using stub bridge"
            needs_stub=1
            ;;
    esac

    if [ ! -d "$CEF_EXTRACT_DIR" ]; then
        needs_stub=1
    elif [ ! -f "$wrapper_lib" ]; then
        echo "==> CEF extract found but wrapper library is missing, using stub bridge"
        needs_stub=1
    fi

    if [ "$needs_stub" -eq 0 ]; then
        echo "==> Building CEF bridge with real CEF support..."
        make -C "$CEF_BRIDGE_DIR" clean all \
            ARCHS="$target_archs" \
            CEF_ROOT="$CEF_EXTRACT_DIR"
        # Copy the wrapper library alongside the bridge for separate linking
        cp "$wrapper_lib" "$CEF_BRIDGE_DIR/libcef_dll_wrapper.a"
    else
        echo "==> Building CEF bridge (stub mode, no CEF framework)..."
        make -C "$CEF_BRIDGE_DIR" clean all ARCHS="$target_archs"
        # Remove stale wrapper if present
        rm -f "$CEF_BRIDGE_DIR/libcef_dll_wrapper.a"
    fi
    # Always use the stub framework for Xcode linking. The real CEF framework
    # has a flat bundle structure that Xcode's validator rejects. The real
    # framework is embedded at runtime via embed-cef.sh.
    build_stub_framework "$target_archs"
}

# Symlink the CEF framework for Xcode to find at runtime
link_framework() {
    local fw_src="$CEF_EXTRACT_DIR/Release/Chromium Embedded Framework.framework"
    local fw_dst="$PROJECT_DIR/vendor/cef-bridge/Chromium Embedded Framework.framework"
    if [ -d "$fw_src" ]; then
        rm -rf "$fw_dst"
        ln -sfn "$fw_src" "$fw_dst"
        echo "==> Linked CEF framework at $fw_dst"
    fi
}

build_stub_framework() {
    local target_archs="${1:-arm64}"
    local framework_dir="$CEF_BRIDGE_DIR/Chromium Embedded Framework.framework"
    local framework_versions_dir="$framework_dir/Versions"
    local framework_current_dir="$framework_versions_dir/Current"
    local framework_version_dir="$framework_versions_dir/A"
    local framework_resources_dir="$framework_version_dir/Resources"
    local framework_bin="$framework_version_dir/Chromium Embedded Framework"
    local arch_flags=()

    for arch in $target_archs; do
        arch_flags+=("-arch" "$arch")
    done

    rm -rf "$framework_dir"
    mkdir -p "$framework_resources_dir"
    printf 'void cmux_cef_framework_stub(void) {}\n' | \
        clang -dynamiclib "${arch_flags[@]}" -mmacosx-version-min=13.0 \
            -install_name "@rpath/Chromium Embedded Framework.framework/Chromium Embedded Framework" \
            -compatibility_version 1460.0.6 -current_version 1460.0.6 \
            -x c - -o "$framework_bin"
    ln -sfn "A" "$framework_current_dir"
    ln -sfn "Versions/Current/Chromium Embedded Framework" "$framework_dir/Chromium Embedded Framework"
    ln -sfn "Versions/Current/Resources" "$framework_dir/Resources"
    cat > "$framework_resources_dir/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Chromium Embedded Framework</string>
    <key>CFBundleIdentifier</key>
    <string>app.cmux.stub-cef-framework</string>
    <key>CFBundleName</key>
    <string>Chromium Embedded Framework</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
</dict>
</plist>
EOF
    echo "==> Built stub Chromium Embedded Framework at $framework_dir"
}

# Main
case "${1:-full}" in
    download)
        download_cef
        ;;
    wrapper)
        download_cef
        build_wrapper
        ;;
    bridge)
        build_bridge
        ;;
    stub)
        echo "==> Building CEF bridge (stub mode)..."
        make -C "$CEF_BRIDGE_DIR" clean all
        build_stub_framework "${ARCHS:-arm64}"
        ;;
    full)
        download_cef
        build_wrapper
        build_bridge
        ;;
    *)
        echo "Usage: $0 [download|wrapper|bridge|stub|full]"
        exit 1
        ;;
esac

echo "==> CEF bridge build complete."
