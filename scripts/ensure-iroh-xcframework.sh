#!/usr/bin/env bash
# Materializes IrohFFI.xcframework at the repo root from the pinned upstream
# n0-computer/iroh-ffi release, rewrapping each flat static-library slice as a
# static Iroh.framework.
#
# Why the rewrap: upstream's IrohLib.xcframework ships library slices whose
# Headers/module.modulemap Xcode copies into the shared Products/include
# directory, where it collides with GhosttyKit.xcframework's identically
# named module map ("Multiple commands produce .../include/module.modulemap").
# Framework-scoped slices keep Headers/ and Modules/ inside Iroh.framework,
# so nothing lands in the shared include directory. The binaries are
# upstream's, byte for byte; only the bundle layout changes. The Swift
# bindings for the same tag are vendored at
# Packages/Shared/CmuxPeerTransport/Sources/IrohLib/.
#
# Updating to a new upstream release: bump IROH_FFI_VERSION + IROH_FFI_SHA256
# (from the release's Package.swift releaseChecksum), re-vendor
# IrohLib/Sources/IrohLib/IrohLib.swift from the tag, delete
# IrohFFI.xcframework, and rerun this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

IROH_FFI_VERSION="v1.1.0"
IROH_FFI_SHA256="ad46dadf09f9224157512992923562931ed60f252414230d50893a4d515c5776"
IROH_FFI_URL="https://github.com/n0-computer/iroh-ffi/releases/download/${IROH_FFI_VERSION}/IrohLib.xcframework.zip"

OUTPUT_DIR="$PROJECT_DIR/IrohFFI.xcframework"
STAMP_FILE="$OUTPUT_DIR/.cmux-source-checksum"

if [[ -d "$OUTPUT_DIR" && -f "$STAMP_FILE" ]] \
    && [[ "$(cat "$STAMP_FILE")" == "$IROH_FFI_SHA256" ]]; then
    echo "IrohFFI.xcframework up to date (${IROH_FFI_VERSION})"
    exit 0
fi

hash_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

WORK_DIR="$(mktemp -d /tmp/iroh-xcframework.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

ZIP_PATH="$WORK_DIR/IrohLib.xcframework.zip"
echo "Downloading ${IROH_FFI_URL}"
curl -fsSL --retry 3 -o "$ZIP_PATH" "$IROH_FFI_URL"

ACTUAL_SHA="$(hash_file "$ZIP_PATH")"
if [[ "$ACTUAL_SHA" != "$IROH_FFI_SHA256" ]]; then
    echo "error: IrohLib.xcframework.zip checksum mismatch" >&2
    echo "  expected: $IROH_FFI_SHA256" >&2
    echo "  actual:   $ACTUAL_SHA" >&2
    exit 1
fi

unzip -q "$ZIP_PATH" -d "$WORK_DIR"
SOURCE_XCF="$WORK_DIR/Iroh.xcframework"
if [[ ! -d "$SOURCE_XCF" ]]; then
    SOURCE_XCF="$(find "$WORK_DIR" -maxdepth 2 -name '*.xcframework' -type d | head -1)"
fi
[[ -d "$SOURCE_XCF" ]] || { echo "error: no xcframework in release zip" >&2; exit 1; }

FRAMEWORK_NAME="Iroh"
STAGED="$WORK_DIR/IrohFFI.xcframework"
mkdir -p "$STAGED"

# Per-slice Info.plist inside the framework bundle.
write_bundle_plist() {
    local path="$1" min_os_key="$2" min_os_value="$3"
    cat > "$path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${FRAMEWORK_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>computer.iroh.${FRAMEWORK_NAME}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${FRAMEWORK_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>${min_os_key}</key>
    <string>${min_os_value}</string>
</dict>
</plist>
PLIST
}

MODULEMAP_CONTENT="framework module ${FRAMEWORK_NAME} {
    umbrella header \"Export.h\"
    export *
    module * { export * }
}"

# The outer xcframework Info.plist is assembled by hand (xcodebuild is
# guarded on agent machines); the schema is the stable AvailableLibraries
# list Xcode has consumed for years.
LIBRARIES_XML=""

for slice_dir in "$SOURCE_XCF"/*/; do
    slice="$(basename "$slice_dir")"
    [[ "$slice" == "Info.plist" ]] && continue
    [[ -f "$slice_dir"/libiroh_ffi.a ]] || continue

    platform="macos"
    variant=""
    min_key="LSMinimumSystemVersion"
    min_val="14.5"
    case "$slice" in
        ios-*-simulator) platform="ios"; variant="simulator"; min_key="MinimumOSVersion"; min_val="17.5" ;;
        ios-*-maccatalyst) platform="ios"; variant="maccatalyst"; min_key="MinimumOSVersion"; min_val="17.5" ;;
        ios-*) platform="ios"; min_key="MinimumOSVersion"; min_val="17.5" ;;
        macos-*) platform="macos" ;;
    esac

    out_slice="$STAGED/$slice"
    fw="$out_slice/${FRAMEWORK_NAME}.framework"
    mkdir -p "$out_slice"

    if [[ "$platform" == "macos" ]]; then
        # Versioned (deep) layout required for macOS frameworks.
        mkdir -p "$fw/Versions/A/Headers" "$fw/Versions/A/Modules" "$fw/Versions/A/Resources"
        cp "$slice_dir/libiroh_ffi.a" "$fw/Versions/A/${FRAMEWORK_NAME}"
        cp "$slice_dir/Headers/Export.h" "$slice_dir/Headers/iroh_ffiFFI.h" "$fw/Versions/A/Headers/"
        printf '%s\n' "$MODULEMAP_CONTENT" > "$fw/Versions/A/Modules/module.modulemap"
        write_bundle_plist "$fw/Versions/A/Resources/Info.plist" "$min_key" "$min_val"
        (
            cd "$fw/Versions" && ln -s A Current
            cd .. && ln -s "Versions/Current/${FRAMEWORK_NAME}" "${FRAMEWORK_NAME}"
            ln -s Versions/Current/Headers Headers
            ln -s Versions/Current/Modules Modules
            ln -s Versions/Current/Resources Resources
        )
    else
        # Shallow layout for iOS-family slices.
        mkdir -p "$fw/Headers" "$fw/Modules"
        cp "$slice_dir/libiroh_ffi.a" "$fw/${FRAMEWORK_NAME}"
        cp "$slice_dir/Headers/Export.h" "$slice_dir/Headers/iroh_ffiFFI.h" "$fw/Headers/"
        printf '%s\n' "$MODULEMAP_CONTENT" > "$fw/Modules/module.modulemap"
        write_bundle_plist "$fw/Info.plist" "$min_key" "$min_val"
    fi

    # Supported architectures from the slice directory name convention
    # (e.g. ios-arm64_x86_64-simulator -> arm64, x86_64).
    arch_part="${slice#*-}"
    arch_part="${arch_part%%-*}"
    arch_xml=""
    IFS='_' read -ra ARCHS <<< "$arch_part"
    for arch in "${ARCHS[@]}"; do
        arch_xml="${arch_xml}
                <string>${arch}</string>"
    done

    variant_xml=""
    if [[ -n "$variant" ]]; then
        variant_xml="
            <key>SupportedPlatformVariant</key>
            <string>${variant}</string>"
    fi

    LIBRARIES_XML="${LIBRARIES_XML}
        <dict>
            <key>BinaryPath</key>
            <string>${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}</string>
            <key>LibraryIdentifier</key>
            <string>${slice}</string>
            <key>LibraryPath</key>
            <string>${FRAMEWORK_NAME}.framework</string>
            <key>SupportedArchitectures</key>
            <array>${arch_xml}
            </array>
            <key>SupportedPlatform</key>
            <string>${platform}</string>${variant_xml}
        </dict>"
done

cat > "$STAGED/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AvailableLibraries</key>
    <array>${LIBRARIES_XML}
    </array>
    <key>CFBundlePackageType</key>
    <string>XFWK</string>
    <key>XCFrameworkFormatVersion</key>
    <string>1.0</string>
</dict>
</plist>
PLIST

printf '%s' "$IROH_FFI_SHA256" > "$STAGED/.cmux-source-checksum"

rm -rf "$OUTPUT_DIR"
mv "$STAGED" "$OUTPUT_DIR"
echo "IrohFFI.xcframework ready (${IROH_FFI_VERSION})"
