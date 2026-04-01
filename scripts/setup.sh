#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "==> Initializing submodules..."
git submodule update --init --recursive

echo "==> Checking for zig..."
if ! command -v zig &> /dev/null; then
    echo "Error: zig is not installed."
    echo "Install via: brew install zig"
    exit 1
fi

GHOSTTY_SHA="$(git -C ghostty rev-parse HEAD)"
CACHE_ROOT="${CMUX_GHOSTTYKIT_CACHE_DIR:-$HOME/.cache/cmux/ghosttykit}"
CACHE_DIR="$CACHE_ROOT/$GHOSTTY_SHA"
CACHE_XCFRAMEWORK="$CACHE_DIR/GhosttyKit.xcframework"
LOCAL_XCFRAMEWORK="$PROJECT_DIR/ghostty/macos/GhosttyKit.xcframework"
LOCAL_SHA_STAMP="$LOCAL_XCFRAMEWORK/.ghostty_sha"
LOCK_DIR="$CACHE_ROOT/$GHOSTTY_SHA.lock"
CHECKSUMS_FILE="$SCRIPT_DIR/ghosttykit-checksums.txt"
PREFER_PREBUILT="${CMUX_GHOSTTYKIT_PREFER_PREBUILT:-1}"
TMP_ROOT=""

mkdir -p "$CACHE_ROOT"

echo "==> Ghostty submodule commit: $GHOSTTY_SHA"

has_pinned_prebuilt() {
    [ -f "$CHECKSUMS_FILE" ] || return 1
    awk -v sha="$GHOSTTY_SHA" '
        $1 == sha {
            found = 1
            exit 0
        }
        END {
            exit(found ? 0 : 1)
        }
    ' "$CHECKSUMS_FILE"
}

download_prebuilt_ghosttykit() {
    local download_dir="$1"
    echo "==> Downloading prebuilt GhosttyKit.xcframework for $GHOSTTY_SHA..."
    (
        cd "$download_dir"
        GHOSTTY_SHA="$GHOSTTY_SHA" "$SCRIPT_DIR/download-prebuilt-ghosttykit.sh"
    )
}

build_local_ghosttykit() {
    echo "==> Building GhosttyKit.xcframework locally (this may take a few minutes)..."
    (
        cd ghostty
        zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
    )
}

print_local_build_help() {
    cat <<'EOF'
Error: Failed to build GhosttyKit.xcframework locally.

If the error mentions a missing Metal Toolchain, install it once with:
  xcodebuild -downloadComponent MetalToolchain

Then rerun:
  ./scripts/setup.sh

If you want to avoid a local Ghostty build, try the pinned prebuilt bundle:
  ./scripts/download-prebuilt-ghosttykit.sh
EOF
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
trap 'rm -rf "$TMP_ROOT" >/dev/null 2>&1 || true; rmdir "$LOCK_DIR" >/dev/null 2>&1 || true' EXIT

if [ -d "$CACHE_XCFRAMEWORK" ]; then
    echo "==> Reusing cached GhosttyKit.xcframework"
else
    TMP_ROOT="$(mktemp -d "$CACHE_ROOT/.ghosttykit-tmp.XXXXXX")"
    DOWNLOAD_DIR="$TMP_ROOT/download"
    STAGE_DIR="$TMP_ROOT/stage"
    mkdir -p "$DOWNLOAD_DIR" "$STAGE_DIR"

    # Only reuse local xcframework if its SHA stamp matches the current ghostty commit.
    # Without this check, a stale build from a previous commit could be cached under
    # the wrong SHA, producing ABI mismatches.
    LOCAL_SHA=""
    if [ -f "$LOCAL_SHA_STAMP" ]; then
        LOCAL_SHA="$(cat "$LOCAL_SHA_STAMP")"
    fi

    SOURCE_XCFRAMEWORK=""
    if [ -d "$LOCAL_XCFRAMEWORK" ] && [ "$LOCAL_SHA" = "$GHOSTTY_SHA" ]; then
        echo "==> Seeding cache from existing local GhosttyKit.xcframework (SHA matches)"
        SOURCE_XCFRAMEWORK="$LOCAL_XCFRAMEWORK"
    else
        if [ "$PREFER_PREBUILT" != "0" ] && has_pinned_prebuilt; then
            if download_prebuilt_ghosttykit "$DOWNLOAD_DIR"; then
                SOURCE_XCFRAMEWORK="$DOWNLOAD_DIR/GhosttyKit.xcframework"
            else
                echo "==> Prebuilt GhosttyKit download failed; falling back to local build."
            fi
        else
            echo "==> No pinned prebuilt GhosttyKit for $GHOSTTY_SHA; building locally."
        fi

        if [ -z "$SOURCE_XCFRAMEWORK" ]; then
            if ! build_local_ghosttykit; then
                print_local_build_help
                exit 1
            fi
            # Stamp the build output with the SHA it was built from.
            echo "$GHOSTTY_SHA" > "$LOCAL_SHA_STAMP"
            SOURCE_XCFRAMEWORK="$LOCAL_XCFRAMEWORK"
        fi
    fi

    if [ ! -d "$SOURCE_XCFRAMEWORK" ]; then
        echo "Error: GhosttyKit.xcframework not found at $SOURCE_XCFRAMEWORK"
        exit 1
    fi

    mkdir -p "$CACHE_DIR"
    cp -R "$SOURCE_XCFRAMEWORK" "$STAGE_DIR/GhosttyKit.xcframework"
    rm -rf "$CACHE_XCFRAMEWORK"
    mv "$STAGE_DIR/GhosttyKit.xcframework" "$CACHE_XCFRAMEWORK"
    echo "==> Cached GhosttyKit.xcframework at $CACHE_XCFRAMEWORK"
fi

echo "==> Creating symlink for GhosttyKit.xcframework..."
ln -sfn "$CACHE_XCFRAMEWORK" GhosttyKit.xcframework

echo "==> Setup complete!"
echo ""
echo "You can now build and run the app:"
echo "  ./scripts/reload.sh --tag first-run"
