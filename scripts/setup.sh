#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "==> Initializing submodules..."
git submodule update --init --recursive

GHOSTTY_SHA="$(git -C ghostty rev-parse HEAD)"
CACHE_ROOT="${CMUX_GHOSTTYKIT_CACHE_DIR:-$HOME/.cache/cmux/ghosttykit}"
CACHE_DIR="$CACHE_ROOT/$GHOSTTY_SHA"
CACHE_XCFRAMEWORK="$CACHE_DIR/GhosttyKit.xcframework"
CHECKSUMS_FILE="$SCRIPT_DIR/ghosttykit-checksums.txt"
LOCAL_XCFRAMEWORK="$PROJECT_DIR/ghostty/macos/GhosttyKit.xcframework"
LOCAL_SHA_STAMP="$LOCAL_XCFRAMEWORK/.ghostty_sha"
LOCK_DIR="$CACHE_ROOT/$GHOSTTY_SHA.lock"
CACHE_SOURCE_STAMP="$CACHE_DIR/.cmux_ghosttykit_source"
CACHE_LAYOUT_STAMP="$CACHE_DIR/.cmux_ghosttykit_layout"
CACHE_LAYOUT_VERSION="2"
PREFER_PREBUILT="${CMUX_GHOSTTYKIT_PREFER_PREBUILT:-1}"

mkdir -p "$CACHE_ROOT"

echo "==> Ghostty submodule commit: $GHOSTTY_SHA"

require_zig() {
    echo "==> Checking for zig..."
    if ! command -v zig &> /dev/null; then
        echo "Error: zig is not installed."
        echo "Install via: brew install zig"
        exit 1
    fi
}

has_pinned_prebuilt() {
    [ -f "$CHECKSUMS_FILE" ] && awk -v sha="$GHOSTTY_SHA" '
        $1 == sha {
            found = 1
            exit
        }
        END {
            exit(found ? 0 : 1)
        }
    ' "$CHECKSUMS_FILE"
}

cache_source() {
    if [ -f "$CACHE_SOURCE_STAMP" ]; then
        cat "$CACHE_SOURCE_STAMP"
    fi
}

cache_layout() {
    if [ -f "$CACHE_LAYOUT_STAMP" ]; then
        cat "$CACHE_LAYOUT_STAMP"
    fi
}

write_cache_metadata() {
    local source="$1"
    printf '%s\n' "$source" > "$CACHE_SOURCE_STAMP"
    printf '%s\n' "$CACHE_LAYOUT_VERSION" > "$CACHE_LAYOUT_STAMP"
}

install_cache_from_dir() {
    local source_dir="$1"
    local source="$2"
    local tmp_dir

    if [ ! -d "$source_dir" ]; then
        echo "Error: GhosttyKit.xcframework not found at $source_dir"
        exit 1
    fi

    tmp_dir="$(mktemp -d "$CACHE_ROOT/.ghosttykit-tmp.XXXXXX")"
    mkdir -p "$CACHE_DIR"
    cp -R "$source_dir" "$tmp_dir/GhosttyKit.xcframework"
    rm -rf "$CACHE_XCFRAMEWORK"
    mv "$tmp_dir/GhosttyKit.xcframework" "$CACHE_XCFRAMEWORK"
    write_cache_metadata "$source"
    rmdir "$tmp_dir"
    echo "==> Cached GhosttyKit.xcframework at $CACHE_XCFRAMEWORK ($source)"
}

download_prebuilt_ghosttykit() {
    local tmp_dir

    tmp_dir="$(mktemp -d "$CACHE_ROOT/.ghosttykit-download.XXXXXX")"
    if ! (
        cd "$tmp_dir"
        GHOSTTY_SHA="$GHOSTTY_SHA" \
        GHOSTTYKIT_OUTPUT_DIR="GhosttyKit.xcframework" \
        "$SCRIPT_DIR/download-prebuilt-ghosttykit.sh"
    ); then
        rm -rf "$tmp_dir"
        return 1
    fi

    mkdir -p "$CACHE_DIR"
    rm -rf "$CACHE_XCFRAMEWORK"
    mv "$tmp_dir/GhosttyKit.xcframework" "$CACHE_XCFRAMEWORK"
    write_cache_metadata "download"
    rmdir "$tmp_dir"
    echo "==> Cached GhosttyKit.xcframework at $CACHE_XCFRAMEWORK (download)"
}

build_or_seed_local_ghosttykit() {
    local local_sha

    local_sha=""
    if [ -f "$LOCAL_SHA_STAMP" ]; then
        local_sha="$(cat "$LOCAL_SHA_STAMP")"
    fi

    if [ -d "$LOCAL_XCFRAMEWORK" ] && [ "$local_sha" = "$GHOSTTY_SHA" ]; then
        echo "==> Seeding cache from existing local GhosttyKit.xcframework (SHA matches)"
    else
        require_zig
        echo "==> Building GhosttyKit.xcframework (this may take a few minutes)..."
        (
            cd ghostty
            zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
        )
        printf '%s\n' "$GHOSTTY_SHA" > "$LOCAL_SHA_STAMP"
    fi

    install_cache_from_dir "$LOCAL_XCFRAMEWORK" "local-build"
}

LOCK_TIMEOUT=300
LOCK_START=$SECONDS
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if (( SECONDS - LOCK_START > LOCK_TIMEOUT )); then
        echo "==> Lock stale (>${LOCK_TIMEOUT}s), removing and retrying..."
        rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR"
        continue
    fi
    echo "==> Waiting for GhosttyKit cache lock for $GHOSTTY_SHA..."
    sleep 1
done
trap 'rmdir "$LOCK_DIR" >/dev/null 2>&1 || true' EXIT

DESIRED_SOURCE="local-build"
if [ "$PREFER_PREBUILT" != "0" ] && has_pinned_prebuilt; then
    DESIRED_SOURCE="download"
fi

CURRENT_SOURCE="$(cache_source)"
CURRENT_LAYOUT="$(cache_layout)"

if [ -d "$CACHE_XCFRAMEWORK" ] && [ "$CURRENT_LAYOUT" = "$CACHE_LAYOUT_VERSION" ] && [ "$CURRENT_SOURCE" = "$DESIRED_SOURCE" ]; then
    echo "==> Reusing cached GhosttyKit.xcframework ($CURRENT_SOURCE)"
else
    if [ -d "$CACHE_XCFRAMEWORK" ]; then
        LEGACY_SOURCE="$CURRENT_SOURCE"
        if [ -z "$LEGACY_SOURCE" ]; then
            LEGACY_SOURCE="legacy-unverified"
        fi
        echo "==> Refreshing GhosttyKit.xcframework cache ($LEGACY_SOURCE -> $DESIRED_SOURCE)"
    fi

    if [ "$DESIRED_SOURCE" = "download" ]; then
        echo "==> Downloading pinned GhosttyKit.xcframework..."
        if ! download_prebuilt_ghosttykit; then
            echo "==> Download failed, falling back to local GhosttyKit build"
            build_or_seed_local_ghosttykit
        fi
    else
        build_or_seed_local_ghosttykit
    fi
fi

echo "==> Creating symlink for GhosttyKit.xcframework..."
ln -sfn "$CACHE_XCFRAMEWORK" GhosttyKit.xcframework

echo "==> Setup complete!"
echo ""
echo "You can now build and run the app:"
echo "  ./scripts/reload.sh --tag first-run"
