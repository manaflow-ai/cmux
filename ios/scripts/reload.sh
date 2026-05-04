#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$IOS_DIR/.." && pwd)"
cd "$IOS_DIR"

run_with_timeout() {
    local timeout_seconds="$1"
    shift
    "$@" &
    local command_pid="$!"
    (
        sleep "$timeout_seconds"
        if kill -0 "$command_pid" >/dev/null 2>&1; then
            kill "$command_pid" >/dev/null 2>&1 || true
            sleep 1
            kill -9 "$command_pid" >/dev/null 2>&1 || true
        fi
    ) &
    local watchdog_pid="$!"
    set +e
    wait "$command_pid"
    local command_status="$?"
    set -e
    kill "$watchdog_pid" >/dev/null 2>&1 || true
    wait "$watchdog_pid" >/dev/null 2>&1 || true
    return "$command_status"
}

merge_status() {
    local current="$1"
    local next="$2"
    if [ "$current" = "unavailable" ]; then
        echo "$next"
    elif [ "$current" = "$next" ]; then
        echo "$current"
    elif [ "$current" = "failed" ] || [ "$next" = "failed" ]; then
        echo "failed"
    else
        echo "partial"
    fi
}

classify_device_reload_failure() {
    local log_path="$1"
    if grep -qiE "kAMDMobileImageMounterDeviceLocked|The device is locked|Ensure that the device is unlocked" "$log_path"; then
        echo "device locked while mounting the developer disk image"
    elif grep -qi "developer disk image could not be mounted" "$log_path"; then
        echo "developer disk image mount failed"
    elif grep -qi "No provider was found" "$log_path"; then
        echo "CoreDevice provider unavailable"
    elif grep -qi "Provisioning profile" "$log_path"; then
        echo "provisioning failed"
    else
        echo "see reload output above"
    fi
}

require_tag_value() {
    local value="${1:-}"
    if [ -z "$value" ] || [[ "$value" == -* ]]; then
        echo "error: --tag requires a non-empty value" >&2
        exit 1
    fi
}

TAG=""
SIMULATOR_ONLY=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --tag)
            TAG="${2:-}"
            require_tag_value "$TAG"
            shift 2
            continue
            ;;
        --tag=*)
            TAG="${1#--tag=}"
            require_tag_value "$TAG"
            ;;
        --simulator-only|--sim-only)
            SIMULATOR_ONLY=1
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
    shift
done

if [ -z "$TAG" ]; then
    echo "error: --tag is required (example: ios/scripts/reload.sh --tag ihome)" >&2
    exit 1
fi
TAG_SLUG="$(echo "$TAG" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\.+//; s/\.+$//; s/\.+/./g')"
if [ -z "$TAG_SLUG" ]; then
    echo "Tag must contain at least one letter or digit" >&2
    exit 1
fi

DERIVED_DATA_PATH="$HOME/Library/Developer/Xcode/DerivedData/cmux-ios-$TAG_SLUG"
BUNDLE_ID="dev.cmux.ios.$TAG_SLUG"
APP_NAME="$TAG_SLUG"
DISPLAY_NAME="$TAG"

"$REPO_ROOT/scripts/ensure-ghosttykit.sh"

if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate >/dev/null
fi

EXTRA_SETTINGS=(
    "PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID"
    "PRODUCT_NAME=$APP_NAME"
    "INFOPLIST_KEY_CFBundleDisplayName=$DISPLAY_NAME"
)

echo "Building simulator app..."
xcodebuild \
    -project cmux-ios.xcodeproj \
    -scheme cmux-ios \
    -sdk iphonesimulator \
    -configuration Debug \
    -destination "platform=iOS Simulator,name=iPhone 17 Pro" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    "${EXTRA_SETTINGS[@]}" \
    -quiet

SIM_APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug-iphonesimulator/$APP_NAME.app"
if ! xcrun simctl list devices booted | grep -q "iPhone 17 Pro"; then
    xcrun simctl boot "iPhone 17 Pro" >/dev/null 2>&1 || true
fi

SIMULATOR_STATUS="unavailable"
BOOTED_SIMS="$(xcrun simctl list devices booted | grep -oE '[A-F0-9-]{36}' || true)"
if [ -n "$BOOTED_SIMS" ]; then
    SIMULATOR_STATUS="succeeded"
    while IFS= read -r SIM_ID; do
        [ -n "$SIM_ID" ] || continue
        run_with_timeout 8 xcrun simctl terminate "$SIM_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
        if ! run_with_timeout 30 xcrun simctl install "$SIM_ID" "$SIM_APP_PATH"; then
            echo "Simulator install failed for $SIM_ID" >&2
            SIMULATOR_STATUS="failed"
            continue
        fi
        if ! run_with_timeout 15 xcrun simctl launch "$SIM_ID" "$BUNDLE_ID" >/dev/null; then
            echo "Simulator launch failed for $SIM_ID" >&2
            SIMULATOR_STATUS="failed"
        fi
    done <<< "$BOOTED_SIMS"
fi

IPHONE_STATUS="unavailable"
OTHER_IOS_STATUS="unavailable"
DEVICE_RELOAD_DETAILS=()
if [ "$SIMULATOR_ONLY" -eq 0 ]; then
    if command -v jq >/dev/null 2>&1; then
        if ! IOS_DEVICES="$(xcrun xcdevice list --timeout 2 | jq -r '.[] | select(.simulator == false and .platform == "com.apple.platform.iphoneos" and .available == true) | [.name, .identifier] | @tsv')"; then
            IOS_DEVICES=""
        fi
    else
        IOS_DEVICES=""
    fi

    if [ -n "$IOS_DEVICES" ]; then
        while IFS=$'\t' read -r DEVICE_NAME DEVICE_ID; do
            [ -n "$DEVICE_ID" ] || continue
            echo "Building device app for $DEVICE_NAME..."
            DEVICE_STATUS="succeeded"
            DEVICE_LOG="$(mktemp "${TMPDIR:-/tmp}/cmux-ios-reload-device.XXXXXX.log")"
            if ! xcodebuild \
                -project cmux-ios.xcodeproj \
                -scheme cmux-ios \
                -configuration Debug \
                -destination "id=$DEVICE_ID" \
                -derivedDataPath "$DERIVED_DATA_PATH" \
                "${EXTRA_SETTINGS[@]}" \
                -allowProvisioningUpdates \
                -allowProvisioningDeviceRegistration \
                -quiet 2>&1 | tee "$DEVICE_LOG"; then
                DEVICE_STATUS="failed"
                DEVICE_RELOAD_DETAILS+=("$DEVICE_NAME reload reason: $(classify_device_reload_failure "$DEVICE_LOG")")
            else
                DEVICE_APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug-iphoneos/$APP_NAME.app"
                if ! xcrun devicectl device install app --device "$DEVICE_ID" "$DEVICE_APP_PATH" 2>&1 | tee "$DEVICE_LOG"; then
                    DEVICE_STATUS="failed"
                    DEVICE_RELOAD_DETAILS+=("$DEVICE_NAME reload reason: $(classify_device_reload_failure "$DEVICE_LOG")")
                elif ! xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" 2>&1 | tee "$DEVICE_LOG"; then
                    DEVICE_STATUS="installed_launch_failed"
                    DEVICE_RELOAD_DETAILS+=("$DEVICE_NAME reload reason: launch failed")
                fi
            fi
            rm -f "$DEVICE_LOG"

            if echo "$DEVICE_NAME" | grep -qi "iphone"; then
                IPHONE_STATUS="$(merge_status "$IPHONE_STATUS" "$DEVICE_STATUS")"
            else
                OTHER_IOS_STATUS="$(merge_status "$OTHER_IOS_STATUS" "$DEVICE_STATUS")"
            fi
        done <<< "$IOS_DEVICES"
    fi
fi

echo "iOS tag: $TAG"
echo "Simulator reload: $SIMULATOR_STATUS"
echo "iPhone reload: $IPHONE_STATUS"
if [ "$OTHER_IOS_STATUS" != "unavailable" ]; then
    echo "Other iOS device reload: $OTHER_IOS_STATUS"
fi
for DETAIL in "${DEVICE_RELOAD_DETAILS[@]}"; do
    echo "$DETAIL"
done
