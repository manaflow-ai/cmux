#!/usr/bin/env bash
# Build the iSH kernel and cmux shim as an iOS xcframework.
#
# The vendored iSH project uses an Xcode legacy target to configure Meson and
# then runs Ninja. Building the `libish` target is sufficient: its
# NINJA_TARGETS setting emits libish.a, libish_emu.a, and libfakefs.a in the
# Meson directory. The old implementation built all three Xcode targets
# separately. That needlessly re-entered the Meson external target and was
# racy on recent Xcode versions ("never received target ended message").
#
# The default root filesystem is the Alpine Linux 3.24.1 x86 minirootfs.
# It is an i386 userland for iSH's user-mode emulator, not an x86_64 image.
# The URL and SHA-256 are pinned below. The archive is copied into the Swift
# package's resource directory and is checked on every build. iSH and Alpine
# licensing information stays with the vendored source and the package
# NOTICE; the generated manifest records the exact source and revisions.
set -euo pipefail

# Keep the normal space-first separator so `${array[*]}` is readable while
# retaining safe tab/newline splitting for any unquoted expansion.
IFS=$' \t\n'
export LC_ALL=C
export TZ=UTC

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ISH="$ROOT/vendor/ish"
SHIM="$ROOT/Packages/iOS/CmuxLocalLinux/ShimSource"
BUILD_ROOT="$ROOT/build"
OUT="$BUILD_ROOT/ish-kernel"
ROOTFS_DEST="$ROOT/Packages/iOS/CmuxLocalLinux/Sources/CmuxLocalLinux/Resources/alpine-rootfs.tar.gz"
ROOTFS_PROVENANCE="$ROOT/Packages/iOS/CmuxLocalLinux/Sources/CmuxLocalLinux/Resources/alpine-rootfs.json"

# Alpine 3.24.1 x86 (i386) minirootfs. The checksum is the value published
# beside the archive by dl-cdn.alpinelinux.org. Keep both values together so
# changing the image requires an intentional review of the provenance.
readonly DEFAULT_ROOTFS_URL="https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86/alpine-minirootfs-3.24.1-x86.tar.gz"
readonly DEFAULT_ROOTFS_SHA256="634355e2245c9d56186d1b86fb6e034453eb303aea15b573ca250b343376fffd"

ROOTFS_URL="${CMUX_ISH_ROOTFS_URL:-$DEFAULT_ROOTFS_URL}"
ROOTFS_SHA256="${CMUX_ISH_ROOTFS_SHA256:-$DEFAULT_ROOTFS_SHA256}"
ROOTFS_INPUT="${CMUX_ISH_ROOTFS_PATH:-}"
CONFIGURATION="${CMUX_ISH_CONFIGURATION:-Release}"
DEPLOYMENT_TARGET="${CMUX_ISH_IOS_DEPLOYMENT_TARGET:-18.0}"
XCODE_JOBS="${CMUX_ISH_XCODE_JOBS:-1}"
LOCK_WAIT_SECONDS="${CMUX_ISH_LOCK_WAIT_SECONDS:-1800}"
KEEP_BUILD="${CMUX_ISH_KEEP_BUILD:-0}"
DEVICE_ONLY="${CMUX_ISH_DEVICE_ONLY:-0}"

# Bash 3.2 (the system shell on older macOS releases) has no `${value,,}`
# expansion. Normalize once with POSIX tr instead.
ROOTFS_SHA256="$(printf '%s' "$ROOTFS_SHA256" | tr '[:upper:]' '[:lower:]')"

LOCK_DIR="$BUILD_ROOT/.ish-ios-build.lock"
LOCK_HELD=0
WORK=""
XC_WORK=""

die() {
    echo "build-ish-ios: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: scripts/build-ish-ios.sh [options]

Builds IshKernel.xcframework with arm64 iphoneos and iphonesimulator slices,
and installs the pinned Alpine i386 rootfs resource when it is missing.

Options:
  --device-only  Build only the iphoneos slice.
  --check        Validate tools, submodules, and the rootfs, without building.
  --help         Show this help.

Environment:
  CMUX_ISH_ROOTFS_PATH       Use a local tar.gz instead of downloading.
  CMUX_ISH_ROOTFS_URL        Override the download URL (also set the SHA).
  CMUX_ISH_ROOTFS_SHA256     Expected SHA-256 for the selected archive.
  CMUX_ISH_XCODE_JOBS        Xcode job limit, defaults to 1 for Meson safety.
  CMUX_ISH_DEVICE_ONLY=1     Same as --device-only.
EOF
}

CHECK_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --device-only)
            DEVICE_ONLY=1
            ;;
        --check)
            CHECK_ONLY=1
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown option: $1"
            ;;
    esac
    shift
done

[[ "$DEVICE_ONLY" == 0 || "$DEVICE_ONLY" == 1 ]] || die "CMUX_ISH_DEVICE_ONLY must be 0 or 1"
[[ "$KEEP_BUILD" == 0 || "$KEEP_BUILD" == 1 ]] || die "CMUX_ISH_KEEP_BUILD must be 0 or 1"
[[ "$ROOTFS_SHA256" =~ ^[[:xdigit:]]{64}$ ]] || die "CMUX_ISH_ROOTFS_SHA256 must be 64 hexadecimal characters"
[[ "$DEPLOYMENT_TARGET" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "invalid iOS deployment target: $DEPLOYMENT_TARGET"
[[ "$XCODE_JOBS" =~ ^[1-9][0-9]*$ ]] || die "CMUX_ISH_XCODE_JOBS must be a positive integer"
[[ "$LOCK_WAIT_SECONDS" =~ ^[0-9]+$ ]] || die "CMUX_ISH_LOCK_WAIT_SECONDS must be a non-negative integer"

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command '$1'"
}

sha256_file() {
    local path="$1"
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$path" | awk '{print tolower($1)}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$path" | awk '{print tolower($1)}'
    else
        die "missing shasum or sha256sum"
    fi
}

validate_tree() {
    require_command xcodebuild
    require_command xcrun
    require_command libtool
    require_command curl
    require_command meson
    require_command ninja
    require_command python3
    require_command tar
    if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
        die "missing shasum or sha256sum"
    fi

    [[ -f "$ISH/meson.build" ]] || die "vendor/ish is not initialized; run 'git submodule update --init --recursive vendor/ish'"
    [[ -f "$ISH/iSH.xcodeproj/project.pbxproj" ]] || die "vendor/ish/iSH.xcodeproj is missing"
    [[ -x "$ISH/app/xcode-meson.sh" ]] || die "vendor/ish/app/xcode-meson.sh is missing or not executable"
    [[ -x "$ISH/app/xcode-ninja.sh" ]] || die "vendor/ish/app/xcode-ninja.sh is missing or not executable"
    [[ -f "$ISH/deps/libarchive.xcodeproj/project.pbxproj" ]] || die "iSH libarchive submodule is not initialized"
    [[ -f "$ISH/deps/libarchive/libarchive/archive.h" ]] || die "iSH libarchive headers are missing; run 'git -C vendor/ish submodule update --init deps/libarchive'"
    [[ -f "$SHIM/cmux_ish.c" && -f "$SHIM/cmux_ish.h" ]] || die "cmux iSH shim sources are missing"
    [[ ! -L "$ROOTFS_DEST" ]] || die "rootfs destination is a symlink, refusing to overwrite it"
    [[ ! -L "$ROOTFS_PROVENANCE" ]] || die "rootfs provenance is a symlink: $ROOTFS_PROVENANCE"
}

rootfs_entries=""
validate_rootfs() {
    local archive="$1"
    [[ -f "$archive" ]] || die "rootfs archive does not exist: $archive"
    [[ ! -L "$archive" ]] || die "rootfs archive must not be a symlink: $archive"
    [[ -s "$archive" ]] || die "rootfs archive is empty: $archive"

    local actual_sha
    actual_sha="$(sha256_file "$archive")"
    if [[ "$actual_sha" != "$ROOTFS_SHA256" ]]; then
        die "rootfs SHA-256 mismatch for $archive (expected $ROOTFS_SHA256, got $actual_sha)"
    fi

    # Validate the archive before putting it into the app bundle. Keep the
    # complete listing in memory to avoid a tar|grep SIGPIPE under pipefail.
    if ! rootfs_entries="$(tar -tzf "$archive" 2>/dev/null)"; then
        die "rootfs is not a readable gzip-compressed tar archive: $archive"
    fi
    grep -Eq '(^|/)(\./)?bin/sh$' <<<"$rootfs_entries" || die "rootfs has no /bin/sh: $archive"
    grep -Eq '(^|/)(\./)?etc/alpine-release$' <<<"$rootfs_entries" || die "rootfs has no /etc/alpine-release: $archive"
    grep -Eq '(^|/)(\./)?lib/apk/db/installed$' <<<"$rootfs_entries" || die "rootfs has no Alpine package database: $archive"
}

validate_rootfs_provenance() {
    # Local override archives are useful for development. Their metadata is
    # maintained by the caller, so validate only the checked-in pinned image.
    if [[ -n "$ROOTFS_INPUT" || "$ROOTFS_URL" != "$DEFAULT_ROOTFS_URL" || "$ROOTFS_SHA256" != "$DEFAULT_ROOTFS_SHA256" ]]; then
        return
    fi
    [[ -f "$ROOTFS_PROVENANCE" ]] || die "missing rootfs provenance: $ROOTFS_PROVENANCE"

    local ish_revision
    ish_revision="$(git -C "$ISH" rev-parse HEAD 2>/dev/null)" || die "cannot read vendor/ish revision"
    python3 - "$ROOTFS_PROVENANCE" "$(basename "$ROOTFS_DEST")" \
        "$ROOTFS_SHA256" "$DEFAULT_ROOTFS_URL" "$ish_revision" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
archive, digest, source, ish_revision = sys.argv[2:]
try:
    metadata = json.loads(path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"build-ish-ios: invalid rootfs provenance {path}: {error}") from error

expected = {
    "archive": archive,
    "sha256": digest,
    "source": source,
    "ish_revision": ish_revision,
}
for key, value in expected.items():
    if metadata.get(key) != value:
        raise SystemExit(
            f"build-ish-ios: rootfs provenance {key!r} mismatch "
            f"(expected {value!r}, got {metadata.get(key)!r})"
        )
packages = metadata.get("packages")
if not isinstance(packages, list) or not packages:
    raise SystemExit("build-ish-ios: rootfs provenance has no package manifest")
PY
}

install_rootfs() {
    mkdir -p "$(dirname "$ROOTFS_DEST")"

    if [[ -n "$ROOTFS_INPUT" ]]; then
        validate_rootfs "$ROOTFS_INPUT"
        if [[ "$ROOTFS_INPUT" != "$ROOTFS_DEST" ]]; then
            local copied
            copied="$(mktemp "$ROOTFS_DEST.part.XXXXXX")"
            cp "$ROOTFS_INPUT" "$copied"
            mv -f "$copied" "$ROOTFS_DEST"
        fi
    elif [[ -f "$ROOTFS_DEST" ]]; then
        validate_rootfs "$ROOTFS_DEST"
    else
        echo "rootfs missing, downloading pinned Alpine archive"
        local downloaded
        downloaded="$(mktemp "$ROOTFS_DEST.part.XXXXXX")"
        if ! curl -fL --connect-timeout 20 --max-time 300 --retry 3 --retry-delay 2 \
            -o "$downloaded" "$ROOTFS_URL"; then
            rm -f "$downloaded"
            die "could not download rootfs; provide CMUX_ISH_ROOTFS_PATH for an offline build"
        fi
        if ! validate_rootfs "$downloaded"; then
            rm -f "$downloaded"
            exit 1
        fi
        mv -f "$downloaded" "$ROOTFS_DEST"
    fi

    echo "rootfs: $ROOTFS_DEST"
    echo "rootfs sha256: $(sha256_file "$ROOTFS_DEST")"
    validate_rootfs_provenance
}

acquire_lock() {
    mkdir -p "$BUILD_ROOT"
    local waited=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        local owner=""
        if [[ -f "$LOCK_DIR/pid" ]]; then
            owner="$(<"$LOCK_DIR/pid")"
        fi
        if [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null; then
            if (( waited >= LOCK_WAIT_SECONDS )); then
                die "another iSH build (pid $owner) is still running after ${LOCK_WAIT_SECONDS}s"
            fi
            if (( waited == 0 || waited % 30 == 0 )); then
                echo "waiting for another iSH build (pid $owner)"
            fi
            waited=$((waited + 1))
            sleep 1
        else
            # A killed process can leave the mkdir lock behind. Remove it
            # only when its recorded owner is absent or no longer alive.
            rm -f "$LOCK_DIR/pid"
            if ! rmdir "$LOCK_DIR" 2>/dev/null; then
                # Do not spin if an interrupted writer left another entry in
                # the lock directory, or if a concurrent owner is finishing
                # its PID write. Apply the same bounded wait as the live-owner
                # path and fail with a useful error when the lock cannot be
                # removed.
                if (( waited >= LOCK_WAIT_SECONDS )); then
                    die "cannot clear stale iSH build lock: $LOCK_DIR"
                fi
                waited=$((waited + 1))
                sleep 1
            fi
        fi
    done
    printf '%s\n' "$$" >"$LOCK_DIR/pid"
    LOCK_HELD=1
}

cleanup() {
    local status=$?
    if [[ "$KEEP_BUILD" != 1 && -n "$WORK" && -d "$WORK" ]]; then
        rm -rf "$WORK"
    fi
    if [[ "$KEEP_BUILD" != 1 && -n "$XC_WORK" && -d "$XC_WORK" ]]; then
        rm -rf "$XC_WORK"
    fi
    if [[ "$LOCK_HELD" == 1 ]]; then
        rm -f "$LOCK_DIR/pid"
        rmdir "$LOCK_DIR" 2>/dev/null || true
        LOCK_HELD=0
    fi
    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT TERM

# Keep direct invocations reproducible too. The verifier passes a private bin
# directory when it starts a missing-artifact build, but callers often invoke
# this script directly from a fresh checkout. Reusing the helper here keeps
# Meson/Ninja on PATH for the current process and for iSH's Xcode scripts.
ISH_TOOLS_HELPER="$ROOT/scripts/ensure-ish-build-tools.sh"
if [[ ! -f "$ISH_TOOLS_HELPER" || ! -x "$ISH_TOOLS_HELPER" ]]; then
    die "missing $ISH_TOOLS_HELPER; install Meson and Ninja with 'brew install meson ninja'"
fi
ISH_TOOLS_BIN="$("$ISH_TOOLS_HELPER" --bin-dir)"
[[ -d "$ISH_TOOLS_BIN" ]] || die "iSH tool helper returned an invalid bin directory: $ISH_TOOLS_BIN"
PATH="$ISH_TOOLS_BIN:$PATH"
export PATH

validate_tree

if [[ "$CHECK_ONLY" == 1 ]]; then
    install_rootfs
    echo "iSH build prerequisites are valid"
    exit 0
fi

# Serialize before touching the shared resource or build output. The iSH
# Meson target is not safe to run concurrently, even with distinct Xcode
# products, because its helper scripts inspect shared source state.
acquire_lock
install_rootfs

SLICES=(iphoneos)
if [[ "$DEVICE_ONLY" != 1 ]]; then
    SLICES+=(iphonesimulator)
fi

mkdir -p "$BUILD_ROOT"
WORK="$(mktemp -d "$BUILD_ROOT/.ish-kernel.XXXXXX")"
mkdir -p "$WORK/logs"

sdk_path_for() {
    local sdk="$1"
    local path
    path="$(xcrun --sdk "$sdk" --show-sdk-path 2>/dev/null)" || die "Xcode SDK '$sdk' is not installed"
    [[ -d "$path" ]] || die "Xcode SDK path does not exist for '$sdk': $path"
    printf '%s' "$path"
}

run_xcodebuild() {
    local project="$1"
    local target="$2"
    local sdk="$3"
    local symroot="$4"
    local log="$5"
    shift 5

    echo "== $target ($sdk)"
    if xcodebuild \
        -project "$project" \
        -target "$target" \
        -sdk "$sdk" \
        -configuration "$CONFIGURATION" \
        -jobs "$XCODE_JOBS" \
        -hideShellScriptEnvironment \
        ARCHS=arm64 \
        ONLY_ACTIVE_ARCH=NO \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        IPHONEOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        ZERO_AR_DATE=YES \
        SYMROOT="$symroot" \
        OBJROOT="$symroot/obj" \
        "$@" \
        build >"$log" 2>&1; then
        :
    else
        local status=$?
        echo "xcodebuild failed for $target ($sdk), log: $log" >&2
        tail -80 "$log" >&2 || true
        return "$status"
    fi
}

archive_for() {
    local path="$1"
    [[ -f "$path" ]] || die "expected static archive was not produced: $path"
    local archs
    archs="$(xcrun lipo -archs "$path" 2>/dev/null)" || die "cannot inspect architecture of $path"
    [[ "$archs" == arm64 ]] || die "expected arm64-only archive, got '$archs' for $path"
}

normalise_archive() {
    local archive="$1"
    local normalised="${archive}.normalised"
    # Meson emits DWARF with the temporary build directory in every object.
    # Strip that debug payload before publishing, then regenerate the archive
    # index with deterministic member dates. Public symbols are retained.
    xcrun strip -S -o "$normalised" "$archive" \
        || die "could not strip debug information from $archive"
    mv -f "$normalised" "$archive"
    xcrun ranlib -D "$archive" \
        || die "could not write a deterministic archive index for $archive"
}

replace_uname_object() {
    local archive="$1"
    local object="$2"
    local source="$3"
    local sdk="$4"
    local sdkpath="$5"
    local triple="$6"
    local meson_dir="$7"

    # iSH's uname implementation embeds __DATE__ and __TIME__. Compile that
    # one translation unit from the pinned iSH commit timestamp, then replace
    # the archive member. This preserves a useful version string while making
    # repeated builds byte-identical.
    local uname_date
    local uname_time
    uname_date="$(git -C "$ISH" show -s --date=format:'%b %e %Y' --format='%cd' HEAD)" \
        || die "cannot read iSH commit date"
    uname_time="$(git -C "$ISH" show -s --date=format:'%H:%M:%S' --format='%cd' HEAD)" \
        || die "cannot read iSH commit time"
    xcrun --sdk "$sdk" clang -c "$source" \
        -target "$triple" \
        -arch arm64 \
        -isysroot "$sdkpath" \
        -O2 \
        -g \
        -std=gnu11 \
        -I"$ISH" \
        -I"$meson_dir" \
        -Wno-builtin-macro-redefined \
        -DLOG_HANDLER_NSLOG=1 \
        -DENGINE_ASBESTOS=1 \
        "-D__DATE__=\"$uname_date\"" \
        "-D__TIME__=\"$uname_time\"" \
        -o "$object"

    xcrun ar -d "$archive" kernel_uname.c.o \
        || die "iSH archive has no kernel_uname.c.o member: $archive"
    ZERO_AR_DATE=1 xcrun ar -r "$archive" "$object" \
        || die "could not install deterministic uname object in $archive"
    xcrun ranlib -D "$archive" \
        || die "could not index iSH archive after uname replacement"
}

for sdk in "${SLICES[@]}"; do
    sdk_path_for "$sdk" >/dev/null
    ISH_SYM="$WORK/sym-$sdk/ish"
    ARCHIVE_SYM="$WORK/sym-$sdk/libarchive"
    ISH_PRODUCTS="$ISH_SYM/$CONFIGURATION-$sdk"
    ARCHIVE_PRODUCTS="$ARCHIVE_SYM/$CONFIGURATION-$sdk"
    mkdir -p "$ISH_SYM" "$ARCHIVE_SYM"

    # libish's dependency graph invokes Meson once and emits all three iSH
    # static libraries. Keeping this to one invocation avoids the flaky
    # external-target re-entry that affected the old three-target loop.
    run_xcodebuild "$ISH/iSH.xcodeproj" libish "$sdk" "$ISH_SYM" \
        "$WORK/logs/$sdk-libish.log" \
        ISH_KERNEL=ish \
        NINJA_TARGETS="libish.a libish_emu.a libfakefs.a"

    ISH_MESON="$ISH_PRODUCTS/meson"
    LIBISH="$ISH_MESON/libish.a"
    LIBISH_EMU="$ISH_MESON/libish_emu.a"
    LIBFAKEFS="$ISH_MESON/libfakefs.a"
    [[ -f "$LIBISH" && -f "$LIBISH_EMU" && -f "$LIBFAKEFS" ]] || die "Meson did not produce all iSH archives for $sdk"
    archive_for "$LIBISH"
    archive_for "$LIBISH_EMU"
    archive_for "$LIBFAKEFS"

    run_xcodebuild "$ISH/deps/libarchive.xcodeproj" libarchive "$sdk" "$ARCHIVE_SYM" \
        "$WORK/logs/$sdk-libarchive.log"
    LIBARCHIVE="$ARCHIVE_PRODUCTS/libarchive.a"
    archive_for "$LIBARCHIVE"

    SDKPATH="$(sdk_path_for "$sdk")"
    case "$sdk" in
        iphoneos) TRIPLE="arm64-apple-ios${DEPLOYMENT_TARGET}" ;;
        iphonesimulator) TRIPLE="arm64-apple-ios${DEPLOYMENT_TARGET}-simulator" ;;
        *) die "unsupported SDK: $sdk" ;;
    esac

    SLICE="$WORK/$sdk"
    mkdir -p "$SLICE"
    # Keep the original member name so archive diagnostics and symbol maps do
    # not change merely because reproducibility is enabled.
    FIXED_UNAME="$SLICE/kernel_uname.c.o"
    replace_uname_object "$LIBISH" "$FIXED_UNAME" "$ISH/kernel/uname.c" \
        "$sdk" "$SDKPATH" "$TRIPLE" "$ISH_MESON"
    archive_for "$LIBISH"
    SHIM_OBJECTS=()
    # Bash globbing is sorted under LC_ALL=C. There is currently one cmux
    # shim source, but keeping this as a glob makes adding another shim safe.
    SHIM_SOURCES=("$SHIM"/*.c)
    [[ -f "${SHIM_SOURCES[0]}" ]] || die "no shim C sources found in $SHIM"
    for src in "${SHIM_SOURCES[@]}"; do
        object="$SLICE/$(basename "${src%.c}").o"
        echo "== shim $(basename "$src") ($sdk)"
        xcrun --sdk "$sdk" clang -c "$src" \
            -target "$TRIPLE" \
            -isysroot "$SDKPATH" \
            -O2 \
            -I"$ISH" \
            -I"$SHIM" \
            -I"$ISH/deps/libarchive" \
            -I"$ISH/deps/libarchive/libarchive" \
            -o "$object"
        SHIM_OBJECTS+=("$object")
    done

    FAKEFS_OBJECT="$SLICE/fakefs.o"
    echo "== iSH fakefs importer ($sdk)"
    xcrun --sdk "$sdk" clang -c "$ISH/tools/fakefs.c" \
        -target "$TRIPLE" \
        -isysroot "$SDKPATH" \
        -O2 \
        -I"$ISH" \
        -I"$SHIM" \
        -I"$ISH/deps/libarchive" \
        -I"$ISH/deps/libarchive/libarchive" \
        -o "$FAKEFS_OBJECT"

    ARCHIVE="$SLICE/IshKernel.a"
    # -D makes the archive reproducible by zeroing member mtimes. Pass
    # archives in a fixed order so filesystem enumeration cannot alter the
    # resulting symbol table.
    libtool -static -D -no_warning_for_no_symbols -o "$ARCHIVE" \
        "$LIBISH" "$LIBISH_EMU" "$LIBFAKEFS" "$LIBARCHIVE" \
        "${SHIM_OBJECTS[@]}" "$FAKEFS_OBJECT"
    normalise_archive "$ARCHIVE"
    archive_for "$ARCHIVE"
    symbols="$(xcrun nm -gU "$ARCHIVE" 2>/dev/null)" || die "cannot inspect symbols in $ARCHIVE"
    grep -q '_cmux_ish_boot' <<<"$symbols" || die "cmux_ish_boot is missing from $ARCHIVE"

    # A static framework keeps its module map below Modules/. Packaging the
    # archive directly with `-headers` puts every binary target's module map
    # at include/module.modulemap during ProcessXCFramework. That path also
    # belongs to GhosttyKit, so Xcode reports duplicate output files.
    FRAMEWORK="$SLICE/IshKernel.framework"
    mkdir -p "$FRAMEWORK/Headers" "$FRAMEWORK/Modules"
    cp "$ARCHIVE" "$FRAMEWORK/IshKernel"
    cp "$SHIM/cmux_ish.h" "$FRAMEWORK/Headers/"
    printf '%s\n' \
        'framework module IshKernel {' \
        '    umbrella header "cmux_ish.h"' \
        '    export *' \
        '}' >"$FRAMEWORK/Modules/module.modulemap"
    printf '%s\n' \
        '<?xml version="1.0" encoding="UTF-8"?>' \
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
        '<plist version="1.0">' \
        '<dict>' \
        '    <key>CFBundleExecutable</key>' \
        '    <string>IshKernel</string>' \
        '    <key>CFBundleIdentifier</key>' \
        '    <string>com.manaflow.cmux.IshKernel</string>' \
        '    <key>CFBundleName</key>' \
        '    <string>IshKernel</string>' \
        '    <key>CFBundlePackageType</key>' \
        '    <string>FMWK</string>' \
        '    <key>CFBundleShortVersionString</key>' \
        '    <string>1.0</string>' \
        '    <key>CFBundleVersion</key>' \
        '    <string>1</string>' \
        '</dict>' \
        '</plist>' >"$FRAMEWORK/Info.plist"
done

XC_WORK="$(mktemp -d "$ROOT/.ish-xcframework.XXXXXX")"
XC_TMP="$XC_WORK/IshKernel.xcframework"
FRAMEWORK_ARGS=()
for sdk in "${SLICES[@]}"; do
    FRAMEWORK_ARGS+=(-framework "$WORK/$sdk/IshKernel.framework")
done
echo "== xcframework (${SLICES[*]})"
xcodebuild -create-xcframework "${FRAMEWORK_ARGS[@]}" -output "$XC_TMP" \
    >"$XC_WORK/create.log" 2>&1 || {
        status=$?
        tail -80 "$XC_WORK/create.log" >&2 || true
        exit "$status"
    }

for sdk in "${SLICES[@]}"; do
    case "$sdk" in
        iphoneos) identifier=ios-arm64 ;;
        iphonesimulator) identifier=ios-arm64-simulator ;;
    esac
    packaged_framework="$XC_TMP/$identifier/IshKernel.framework"
    [[ -f "$packaged_framework/IshKernel" ]] || die "xcframework is missing the $identifier binary"
    [[ -f "$packaged_framework/Headers/cmux_ish.h" ]] || die "xcframework is missing headers for $identifier"
    [[ -f "$packaged_framework/Modules/module.modulemap" ]] || die "xcframework is missing the module map for $identifier"
    # `xcodebuild -create-xcframework` rewrites the archive index with the
    # current clock, even when the input archive was built with `ranlib -D`.
    # Restore the reproducible index after packaging and before validation.
    xcrun ranlib -D "$packaged_framework/IshKernel" \
        || die "could not normalize the packaged archive index for $identifier"
    archive_for "$packaged_framework/IshKernel"
done

# Publish only after every slice has passed validation. The lock prevents a
# second build from observing a half-published directory, while keeping the
# previous artifact available if compilation fails.
rm -rf "$OUT"
mv "$WORK" "$OUT"
WORK=""
rm -rf "$ROOT/IshKernel.xcframework"
mv "$XC_TMP" "$ROOT/IshKernel.xcframework"
if [[ "$KEEP_BUILD" != 1 ]]; then
    # xcodebuild leaves create.log beside the output directory, so rmdir is
    # not sufficient here. This path was created by mktemp above and is safe
    # to remove as one exact temporary directory.
    rm -rf "$XC_WORK"
    XC_WORK=""
fi

# A stable, reviewable manifest makes binary provenance auditable without
# putting generated libraries into Git. It intentionally contains no clock
# value, so identical inputs produce identical text.
ISH_COMMIT="$(git -C "$ISH" rev-parse HEAD 2>/dev/null || echo unknown)"
ROOTFS_DIGEST="$(sha256_file "$ROOTFS_DEST")"
printf '%s\n' \
    '{' \
    "  \"ishCommit\": \"$ISH_COMMIT\"," \
    "  \"rootfsURL\": \"$ROOTFS_URL\"," \
    "  \"rootfsSHA256\": \"$ROOTFS_DIGEST\"," \
    "  \"deploymentTarget\": \"$DEPLOYMENT_TARGET\"," \
    '  "architecture": "arm64",' \
    "  \"slices\": [$(printf '\"%s\",' "${SLICES[@]}" | sed 's/,$//')]" \
    '}' >"$OUT/manifest.json"

echo "Built $ROOT/IshKernel.xcframework (slices: ${SLICES[*]}, architecture: arm64)"
echo "Rootfs source: $ROOTFS_URL"
echo "Rootfs SHA-256: $ROOTFS_DIGEST"
