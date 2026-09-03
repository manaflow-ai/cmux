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
# The default root filesystem is an Alpine Linux 3.24 x86 image baked by
# scripts/bake-ish-rootfs.sh with the cmux tool set (bash, git, ssh, python3,
# vim, ...) and published as a release asset on manaflow-ai/ish. It is an i386
# userland for iSH's user-mode emulator, not an x86_64 image, and is converted
# to an iSH fakefs on the device at first launch. The URL and SHA-256 are
# pinned below. The archive is not tracked in Git: it is downloaded into the
# Swift package's resource directory and checked on every build. Licensing
# information stays with the vendored source and the package NOTICE; the
# manifest beside the archive records the exact source and package versions.
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

# cmux Alpine 3.24.1 x86 (i386) image. Both values are printed by
# scripts/bake-ish-rootfs.sh --publish; keep them together so changing the
# image requires an intentional review of the manifest beside it.
readonly DEFAULT_ROOTFS_URL="https://github.com/manaflow-ai/ish/releases/download/cmux-rootfs-2026.09.02/alpine-rootfs-3.24.1-x86-cmux-2026.09.02.tar.gz"
readonly DEFAULT_ROOTFS_SHA256="1b843033cda58c495469ad9d90f90a5ac3a930b6d2bbbaeaf094e00e0f2b8454"

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

LOCK_FILE="$BUILD_ROOT/.ish-ios-build.lock"
LOCK_FD_OPEN=0
WORK=""
XC_WORK=""
# The rootfs install uses a same-directory temporary file before its final
# rename. Keep its exact path so an interrupt or validation failure cannot
# leave a partial archive beside the package resource.
ROOTFS_PART=""

# Publishing is a small transaction. Keep the old trees in sibling backup
# directories until both new trees and the manifest are in place. The EXIT
# trap uses these markers to restore the old trees when a move or an
# interruption fails midway.
PUBLISH_ACTIVE=0
PUBLISH_OUT_BACKUP_DIR=""
PUBLISH_XC_BACKUP_DIR=""
PUBLISH_OUT_BACKUP=""
PUBLISH_XC_BACKUP=""
PUBLISH_OUT_OLD_ATTEMPTED=0
PUBLISH_XC_OLD_ATTEMPTED=0
PUBLISH_OUT_NEW_ATTEMPTED=0
PUBLISH_XC_NEW_ATTEMPTED=0

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

require_clean_ish_tree() {
    local status
    status="$(git -C "$ISH" status --porcelain=v1 --untracked-files=all --ignore-submodules=none 2>/dev/null)" \
        || die "cannot inspect vendor/ish working tree"
    if [[ -n "$status" ]]; then
        echo "$status" >&2
        die "vendor/ish has local changes; commit them before building a provenance-tracked artifact"
    fi
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

sha256_stream() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print tolower($1)}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print tolower($1)}'
    else
        die "missing shasum or sha256sum"
    fi
}

shim_digest() {
    local shim_source
    local digest_lines=""
    local shim_sources=("$SHIM"/*.c "$SHIM"/*.h)
    for shim_source in "${shim_sources[@]}"; do
        [[ -f "$shim_source" ]] || continue
        digest_lines+="$(sha256_file "$shim_source")  $(basename "$shim_source")\n"
    done
    [[ -n "$digest_lines" ]] || die "no shim sources found in $SHIM"
    printf '%b' "$digest_lines" | sha256_stream
}

validate_tree() {
    require_command xcodebuild
    require_command xcrun
    require_command libtool
    require_command curl
    require_command meson
    require_command ninja
    require_command lockf
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
    require_clean_ish_tree
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

    # The image is independent of the iSH revision; the kernel's own
    # provenance sidecar records that. Only the archive identity is checked.
    python3 - "$ROOTFS_PROVENANCE" "$(basename "$ROOTFS_DEST")" \
        "$ROOTFS_SHA256" "$DEFAULT_ROOTFS_URL" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
archive, digest, source = sys.argv[2:]
try:
    metadata = json.loads(path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"build-ish-ios: invalid rootfs provenance {path}: {error}") from error

expected = {
    "archive": archive,
    "sha256": digest,
    "source": source,
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
            ROOTFS_PART="$copied"
            cp "$ROOTFS_INPUT" "$copied"
            mv -f "$copied" "$ROOTFS_DEST"
            ROOTFS_PART=""
        fi
    elif [[ -f "$ROOTFS_DEST" ]]; then
        validate_rootfs "$ROOTFS_DEST"
    else
        echo "rootfs missing, downloading pinned cmux Alpine image"
        local downloaded
        downloaded="$(mktemp "$ROOTFS_DEST.part.XXXXXX")"
        ROOTFS_PART="$downloaded"
        if ! curl -fL --connect-timeout 20 --max-time 300 --retry 3 \
            -o "$downloaded" "$ROOTFS_URL"; then
            rm -f "$downloaded"
            ROOTFS_PART=""
            die "could not download rootfs; provide CMUX_ISH_ROOTFS_PATH for an offline build"
        fi
        if ! validate_rootfs "$downloaded"; then
            rm -f "$downloaded"
            ROOTFS_PART=""
            exit 1
        fi
        mv -f "$downloaded" "$ROOTFS_DEST"
        ROOTFS_PART=""
    fi

    echo "rootfs: $ROOTFS_DEST"
    echo "rootfs sha256: $(sha256_file "$ROOTFS_DEST")"
    validate_rootfs_provenance
}

prepare_lock_path() {
    # Older revisions used a directory containing pid. Do not pass that
    # directory to lockf, and never delete an ownerless directory because its
    # creator may still be between mkdir and pid initialization.
    if [[ -L "$LOCK_FILE" ]]; then
        die "iSH build lock is a symlink, refusing to follow it: $LOCK_FILE"
    fi
    if [[ -d "$LOCK_FILE" ]]; then
        local legacy_owner=""
        if [[ -f "$LOCK_FILE/pid" ]]; then
            legacy_owner="$(<"$LOCK_FILE/pid")"
        fi
        if [[ -z "$legacy_owner" ]]; then
            die "legacy iSH build lock has no owner; refusing to remove it: $LOCK_FILE"
        fi
        if [[ ! "$legacy_owner" =~ ^[0-9]+$ ]]; then
            die "legacy iSH build lock has an invalid owner; refusing to remove it: $LOCK_FILE"
        fi
        if kill -0 "$legacy_owner" 2>/dev/null; then
            die "legacy iSH build lock (pid $legacy_owner) is still active: $LOCK_FILE"
        fi
        # Remove only the protocol's pid file. rmdir then refuses any
        # unexpected entry, so a foreign directory cannot be deleted.
        rm -f "$LOCK_FILE/pid"
        if ! rmdir "$LOCK_FILE" 2>/dev/null; then
            die "legacy iSH build lock contains unexpected entries; refusing to remove it: $LOCK_FILE"
        fi
    elif [[ -e "$LOCK_FILE" && ! -f "$LOCK_FILE" ]]; then
        die "iSH build lock is not a regular file: $LOCK_FILE"
    fi
}

acquire_lock() {
    mkdir -p "$BUILD_ROOT"
    prepare_lock_path
    # BSD lockf locks the inode, not the pathname. Keep this file forever:
    # unlinking it while another process waits would let a later process lock
    # a new inode and run concurrently. Opening in append mode also avoids
    # truncating metadata while a different process owns the lock.
    if ! exec 9>>"$LOCK_FILE"; then
        die "could not open iSH build lock: $LOCK_FILE"
    fi
    LOCK_FD_OPEN=1
    if ! lockf -s -t "$LOCK_WAIT_SECONDS" 9; then
        exec 9>&-
        LOCK_FD_OPEN=0
        die "another iSH build is still running after ${LOCK_WAIT_SECONDS}s"
    fi
}

publish_path_exists() {
    [[ -e "$1" || -L "$1" ]]
}

# Roll back a partially completed publish. The caller disables `errexit`, so
# every move is checked explicitly. Backup directories are left in place when
# a restore itself fails, giving the caller a recoverable copy of the prior
# artifact instead of deleting it.
rollback_publish() {
    local rollback_failed=0
    local quarantine=""

    [[ "$PUBLISH_ACTIVE" == 1 ]] || return 0

    # First move any newly published tree aside. This makes the old backup
    # path available for an ordinary rename back to its original location.
    if [[ "$PUBLISH_OUT_NEW_ATTEMPTED" == 1 ]] && publish_path_exists "$OUT"; then
        if [[ -z "$PUBLISH_OUT_BACKUP_DIR" ]]; then
            echo "build-ish-ios: rollback has no output backup directory" >&2
            rollback_failed=1
        else
            quarantine="$PUBLISH_OUT_BACKUP_DIR/new"
            if ! mv "$OUT" "$quarantine"; then
                echo "build-ish-ios: rollback could not move new output aside: $OUT" >&2
                rollback_failed=1
            fi
        fi
    fi
    if [[ "$PUBLISH_XC_NEW_ATTEMPTED" == 1 ]] && publish_path_exists "$ROOT/IshKernel.xcframework"; then
        if [[ -z "$PUBLISH_XC_BACKUP_DIR" ]]; then
            echo "build-ish-ios: rollback has no xcframework backup directory" >&2
            rollback_failed=1
        else
            quarantine="$PUBLISH_XC_BACKUP_DIR/new"
            if ! mv "$ROOT/IshKernel.xcframework" "$quarantine"; then
                echo "build-ish-ios: rollback could not move new xcframework aside: $ROOT/IshKernel.xcframework" >&2
                rollback_failed=1
            fi
        fi
    fi

    # Restore each old tree only when its backup rename succeeded. If the old
    # rename failed, the original path is still the old tree and is left alone.
    if [[ "$PUBLISH_OUT_OLD_ATTEMPTED" == 1 ]]; then
        if publish_path_exists "$PUBLISH_OUT_BACKUP"; then
            if publish_path_exists "$OUT"; then
                echo "build-ish-ios: rollback output target is still occupied: $OUT" >&2
                rollback_failed=1
            elif ! mv "$PUBLISH_OUT_BACKUP" "$OUT"; then
                echo "build-ish-ios: rollback could not restore output: $OUT" >&2
                rollback_failed=1
            fi
        elif ! publish_path_exists "$OUT"; then
            echo "build-ish-ios: rollback lost the previous output: $OUT" >&2
            rollback_failed=1
        fi
    fi
    if [[ "$PUBLISH_XC_OLD_ATTEMPTED" == 1 ]]; then
        if publish_path_exists "$PUBLISH_XC_BACKUP"; then
            if publish_path_exists "$ROOT/IshKernel.xcframework"; then
                echo "build-ish-ios: rollback xcframework target is still occupied: $ROOT/IshKernel.xcframework" >&2
                rollback_failed=1
            elif ! mv "$PUBLISH_XC_BACKUP" "$ROOT/IshKernel.xcframework"; then
                echo "build-ish-ios: rollback could not restore xcframework: $ROOT/IshKernel.xcframework" >&2
                rollback_failed=1
            fi
        elif ! publish_path_exists "$ROOT/IshKernel.xcframework"; then
            echo "build-ish-ios: rollback lost the previous xcframework: $ROOT/IshKernel.xcframework" >&2
            rollback_failed=1
        fi
    fi

    if [[ "$rollback_failed" == 0 ]]; then
        if [[ -n "$PUBLISH_OUT_BACKUP_DIR" && -d "$PUBLISH_OUT_BACKUP_DIR" ]]; then
            rm -rf "$PUBLISH_OUT_BACKUP_DIR"
        fi
        if [[ -n "$PUBLISH_XC_BACKUP_DIR" && -d "$PUBLISH_XC_BACKUP_DIR" ]]; then
            rm -rf "$PUBLISH_XC_BACKUP_DIR"
        fi
        PUBLISH_ACTIVE=0
        echo "build-ish-ios: restored previous artifacts after interrupted publish" >&2
    else
        echo "build-ish-ios: rollback incomplete; backup directories kept:" >&2
        [[ -n "$PUBLISH_OUT_BACKUP_DIR" ]] && echo "  $PUBLISH_OUT_BACKUP_DIR" >&2
        [[ -n "$PUBLISH_XC_BACKUP_DIR" ]] && echo "  $PUBLISH_XC_BACKUP_DIR" >&2
    fi
    return "$rollback_failed"
}

publish_outputs() {
    # Each backup directory is created beside its target. This keeps every
    # rename on the target filesystem, so a successful rename is atomic and
    # cannot leave a half-copied directory.
    PUBLISH_ACTIVE=1
    PUBLISH_OUT_BACKUP_DIR="$(mktemp -d "$BUILD_ROOT/.ish-publish-out.XXXXXX")" \
        || die "could not create an output backup directory"
    PUBLISH_XC_BACKUP_DIR="$(mktemp -d "$ROOT/.ish-publish-xc.XXXXXX")" \
        || die "could not create an xcframework backup directory"
    PUBLISH_OUT_BACKUP="$PUBLISH_OUT_BACKUP_DIR/previous"
    PUBLISH_XC_BACKUP="$PUBLISH_XC_BACKUP_DIR/previous"

    if publish_path_exists "$OUT"; then
        PUBLISH_OUT_OLD_ATTEMPTED=1
        mv "$OUT" "$PUBLISH_OUT_BACKUP" \
            || die "could not move the previous output aside: $OUT"
    fi
    if publish_path_exists "$ROOT/IshKernel.xcframework"; then
        PUBLISH_XC_OLD_ATTEMPTED=1
        mv "$ROOT/IshKernel.xcframework" "$PUBLISH_XC_BACKUP" \
            || die "could not move the previous xcframework aside: $ROOT/IshKernel.xcframework"
    fi

    # The build lock protects this check from other invocations. Refuse an
    # unexpected target rather than allowing `mv` to nest the new tree inside
    # a directory created by another process.
    if publish_path_exists "$OUT"; then
        die "output publish target appeared unexpectedly: $OUT"
    fi
    PUBLISH_OUT_NEW_ATTEMPTED=1
    mv "$WORK" "$OUT" || die "could not publish output: $OUT"
    WORK=""

    if publish_path_exists "$ROOT/IshKernel.xcframework"; then
        die "xcframework publish target appeared unexpectedly: $ROOT/IshKernel.xcframework"
    fi
    PUBLISH_XC_NEW_ATTEMPTED=1
    mv "$XC_TMP" "$ROOT/IshKernel.xcframework" \
        || die "could not publish xcframework: $ROOT/IshKernel.xcframework"
    XC_TMP=""
}

cleanup() {
    local exit_status=$?
    set +e
    if [[ "$PUBLISH_ACTIVE" == 1 ]]; then
        if ! rollback_publish; then
            [[ "$exit_status" -eq 0 ]] && exit_status=1
        fi
    fi
    if [[ "$KEEP_BUILD" != 1 && -n "$WORK" && -d "$WORK" ]]; then
        rm -rf "$WORK"
    fi
    if [[ "$KEEP_BUILD" != 1 && -n "$XC_WORK" && -d "$XC_WORK" ]]; then
        rm -rf "$XC_WORK"
    fi
    if [[ -n "$ROOTFS_PART" && ( -e "$ROOTFS_PART" || -L "$ROOTFS_PART" ) ]]; then
        # The path is created by mktemp in the package resource directory and
        # is cleared after a successful rename. Remove it only while this
        # invocation still owns the tracked path.
        rm -f "$ROOTFS_PART"
        ROOTFS_PART=""
    fi
    if [[ "$LOCK_FD_OPEN" == 1 ]]; then
        # Closing the descriptor releases the advisory lock. Never unlink the
        # persistent lock file, because a waiter may already have it open.
        exec 9>&-
        LOCK_FD_OPEN=0
    fi
    set -e
    exit "$exit_status"
}

trap cleanup EXIT
trap 'exit 130' INT TERM

# Serialize every mode before touching shared rootfs resources or asking the
# tool helper to mutate its cache. `--check` also validates and may install the
# archive, so leaving it outside this lock would let two checks race a partial
# copy while a build is publishing the same resource.
acquire_lock

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
install_rootfs

# Capture the exact inputs before compiling. These values are embedded in each
# framework so a stale local XCFramework cannot pass verification after the
# vendored iSH or cmux shim changes.
ISH_COMMIT="$(git -C "$ISH" rev-parse HEAD 2>/dev/null)" \
    || die "cannot read vendor/ish revision"
ROOTFS_DIGEST="$(sha256_file "$ROOTFS_DEST")"
SHIM_DIGEST="$(shim_digest)"

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
        # cmux_ish_module.c is a header-only SwiftPM bridge anchor. Compile it
        # in that target, not into the binary archive, so the archive contains
        # only the implementation that must be linked once.
        [[ "$(basename "$src")" == "cmux_ish_module.c" ]] && continue
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

    ARCHIVE="$SLICE/libIshKernel.a"
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

    # Keep the archive as a library slice. The C declarations live in the
    # normal CmuxIshBridge SwiftPM target below; omitting binary-target headers
    # prevents Xcode from copying a second module map to the shared
    # include/module.modulemap path used by GhosttyKit.
    # Keep provenance beside the archive in each slice and copy it into the
    # final XCFramework below.
    printf '%s\n' \
        '{' \
        '    "format": "cmux-ish-provenance-v1",' \
        "    \"ishCommit\": \"$ISH_COMMIT\"," \
        "    \"rootfsSHA256\": \"$ROOTFS_DIGEST\"," \
        "    \"shimSHA256\": \"$SHIM_DIGEST\"," \
        "    \"deploymentTarget\": \"$DEPLOYMENT_TARGET\"," \
        "    \"slice\": \"$sdk\"," \
        '    "architecture": "arm64"' \
        '}' >"$SLICE/cmux-ish-provenance.json"
done

XC_WORK="$(mktemp -d "$ROOT/.ish-xcframework.XXXXXX")"
XC_TMP="$XC_WORK/IshKernel.xcframework"
LIBRARY_ARGS=()
for sdk in "${SLICES[@]}"; do
    LIBRARY_ARGS+=(-library "$WORK/$sdk/libIshKernel.a")
done
echo "== xcframework (${SLICES[*]})"
xcodebuild -create-xcframework "${LIBRARY_ARGS[@]}" -output "$XC_TMP" \
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
    slice_dir="$XC_TMP/$identifier"
    packaged_archive="$slice_dir/libIshKernel.a"
    [[ -f "$packaged_archive" ]] || die "xcframework is missing the $identifier archive"
    cp "$WORK/$sdk/cmux-ish-provenance.json" "$slice_dir/cmux-ish-provenance.json"
    [[ -f "$slice_dir/cmux-ish-provenance.json" ]] || die "xcframework is missing provenance for $identifier"
    # `xcodebuild -create-xcframework` rewrites the archive index with the
    # current clock, even when the input archive was built with `ranlib -D`.
    # Restore the reproducible index after packaging and before validation.
    xcrun ranlib -D "$packaged_archive" \
        || die "could not normalize the packaged archive index for $identifier"
    archive_for "$packaged_archive"
done

# Publish only after every slice has passed validation. The lock prevents a
# second build from observing a half-published directory. `publish_outputs`
# first renames old trees into sibling backups, then atomically renames both
# staged trees into place. The EXIT trap restores those backups on failure.
publish_outputs

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

# The manifest write is part of the publish transaction. Once it succeeds, the
# new trees are complete and it is safe to discard the old backups.
PUBLISH_ACTIVE=0
if [[ "$KEEP_BUILD" != 1 && -n "$XC_WORK" && -d "$XC_WORK" ]]; then
    rm -rf "$XC_WORK" || echo "build-ish-ios: warning: could not remove temporary directory $XC_WORK" >&2
    XC_WORK=""
fi
if [[ -n "$PUBLISH_OUT_BACKUP_DIR" && -d "$PUBLISH_OUT_BACKUP_DIR" ]]; then
    rm -rf "$PUBLISH_OUT_BACKUP_DIR" \
        || echo "build-ish-ios: warning: could not remove old output backup $PUBLISH_OUT_BACKUP_DIR" >&2
fi
if [[ -n "$PUBLISH_XC_BACKUP_DIR" && -d "$PUBLISH_XC_BACKUP_DIR" ]]; then
    rm -rf "$PUBLISH_XC_BACKUP_DIR" \
        || echo "build-ish-ios: warning: could not remove old xcframework backup $PUBLISH_XC_BACKUP_DIR" >&2
fi

echo "Built $ROOT/IshKernel.xcframework (slices: ${SLICES[*]}, architecture: arm64)"
echo "Rootfs source: $ROOTFS_URL"
echo "Rootfs SHA-256: $ROOTFS_DIGEST"
