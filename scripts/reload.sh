#!/usr/bin/env bash
set -euo pipefail

APP_NAME="cmux DEV"
BUNDLE_ID="com.cmuxterm.app.debug"
BASE_APP_NAME="cmux DEV"
DERIVED_DATA=""
NAME_SET=0
BUNDLE_SET=0
DERIVED_SET=0
TAG=""
LAUNCH=0
CMUX_DEBUG_LOG=""
CMUX_DEV_PORT=""
CMUX_DEV_PORT_END=""
CMUX_DEV_PORT_RANGE=""
CMUX_DEV_ORIGIN=""
CLI_PATH=""
NO_GLOBAL_CLI_LINKS="${CMUX_RELOAD_NO_GLOBAL_CLI_LINKS:-0}"
# Matches CmuxStateDirectory (non-TCC ~/.local/state/cmux) where the app/CLI now
# read the last-socket-path markers (https://github.com/manaflow-ai/cmux/issues/5146).
# Resolve the real account home via getpwuid (the same syscall
# homeDirectoryForCurrentUser uses) rather than $HOME, which a shell can override.
# perl ships with macOS and returns the full home path even when it contains spaces;
# `dscl ... | awk` mis-parses such paths because dscl wraps a value with spaces onto
# a second line. `|| true` keeps the lookup from aborting the script under
# `set -euo pipefail`; an empty result falls back to $HOME.
_cmux_account_home="$(perl -e 'print((getpwuid($<))[7])' 2>/dev/null || true)"
LAST_SOCKET_PATH_DIR="${_cmux_account_home:-$HOME}/.local/state/cmux"
AUTO_SKIP_ZIG_BUILD_REASON=""
SWIFT_FRONTEND_WORKAROUND=0
XCODEBUILD_STARTED=0
XCODEBUILD_OUTPUT_VALID=0
XCODEBUILD_CLEANED_OUTPUTS=0

should_skip_ghostty_cli_helper_zig_build() {
  if [[ "${CMUX_SKIP_ZIG_BUILD:-}" == "1" ]]; then
    AUTO_SKIP_ZIG_BUILD_REASON="CMUX_SKIP_ZIG_BUILD=1"
    return 0
  fi

  AUTO_SKIP_ZIG_BUILD_REASON=""
  return 1
}

write_dev_cli_shim() {
  local target="$1"
  local fallback_bin="$2"
  mkdir -p "$(dirname "$target")"
  cat > "$target" <<EOF
#!/usr/bin/env bash
# cmux dev shim (managed by scripts/reload.sh)
set -euo pipefail

CLI_PATH_FILE="/tmp/cmux-last-cli-path"
SOCKET_ARG=""
EXPECT_SOCKET_VALUE=0
for arg in "\$@"; do
  if [[ "\$EXPECT_SOCKET_VALUE" == "1" ]]; then
    SOCKET_ARG="\$arg"
    EXPECT_SOCKET_VALUE=0
    continue
  fi
  case "\$arg" in
    --socket)
      EXPECT_SOCKET_VALUE=1
      ;;
    --socket=*)
      SOCKET_ARG="\${arg#--socket=}"
      ;;
  esac
done
if [[ -n "\$SOCKET_ARG" ]]; then
  SOCKET_NAME="\$(basename "\$SOCKET_ARG")"
  if [[ "\$SOCKET_NAME" == cmux-debug-*.sock ]]; then
    TAG="\${SOCKET_NAME#cmux-debug-}"
    TAG="\${TAG%.sock}"
    if [[ "\$TAG" =~ ^[A-Za-z0-9_-]+$ ]]; then
      TAG_CLI="\$HOME/Library/Developer/Xcode/DerivedData/cmux-\$TAG/Build/Products/Debug/cmux DEV \$TAG.app/Contents/Resources/bin/cmux"
      if [[ -x "\$TAG_CLI" ]] && [[ "\$TAG_CLI" != "\$0" ]]; then
        exec "\$TAG_CLI" "\$@"
      fi
    fi
  fi
fi
if [[ -n "\${CMUX_BUNDLED_CLI_PATH:-}" ]] && [[ -f "\$CMUX_BUNDLED_CLI_PATH" ]] && [[ -x "\$CMUX_BUNDLED_CLI_PATH" ]] && [[ "\$CMUX_BUNDLED_CLI_PATH" != "\$0" ]]; then
  exec "\$CMUX_BUNDLED_CLI_PATH" "\$@"
fi

CLI_PATH_OWNER="\$(stat -f '%u' "\$CLI_PATH_FILE" 2>/dev/null || stat -c '%u' "\$CLI_PATH_FILE" 2>/dev/null || echo -1)"
if [[ -r "\$CLI_PATH_FILE" ]] && [[ ! -L "\$CLI_PATH_FILE" ]] && [[ "\$CLI_PATH_OWNER" == "\$(id -u)" ]]; then
  CLI_PATH="\$(cat "\$CLI_PATH_FILE")"
  if [[ -x "\$CLI_PATH" ]]; then
    exec "\$CLI_PATH" "\$@"
  fi
fi

if [[ -x "$fallback_bin" ]]; then
  exec "$fallback_bin" "\$@"
fi

echo "error: no reload-selected dev cmux CLI found. Run ./scripts/reload.sh --tag <name> first." >&2
exit 1
EOF
  chmod +x "$target"
}

select_cmux_shim_target() {
  local app_cli_dir="/Applications/cmux.app/Contents/Resources/bin"
  local marker="cmux dev shim (managed by scripts/reload.sh)"
  local target=""
  local path_entry=""
  local candidate=""

  IFS=':' read -r -a path_entries <<< "${PATH:-}"
  for path_entry in "${path_entries[@]}"; do
    [[ -z "$path_entry" ]] && continue
    if [[ "$path_entry" == "~/"* ]]; then
      path_entry="$HOME/${path_entry#~/}"
    fi
    if [[ "$path_entry" == "$app_cli_dir" ]]; then
      break
    fi
    [[ -d "$path_entry" && -w "$path_entry" ]] || continue
    candidate="$path_entry/cmux"
    if [[ ! -e "$candidate" ]]; then
      target="$candidate"
      break
    fi
    if [[ -f "$candidate" ]] && grep -q "$marker" "$candidate" 2>/dev/null; then
      target="$candidate"
      break
    fi
  done

  if [[ -n "$target" ]]; then
    echo "$target"
    return 0
  fi

  # Fallback for PATH layouts where app CLI isn't listed or no earlier entries were writable.
  for path_entry in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/bin"; do
    [[ -d "$path_entry" && -w "$path_entry" ]] || continue
    candidate="$path_entry/cmux"
    if [[ ! -e "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
    if [[ -f "$candidate" ]] && grep -q "$marker" "$candidate" 2>/dev/null; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

publish_reload_cli_path() {
  local cli_path="$1"
  if [[ ! -x "$cli_path" ]]; then
    return 0
  fi
  if [[ "$NO_GLOBAL_CLI_LINKS" == "1" ]]; then
    return 0
  fi

  (umask 077; printf '%s\n' "$cli_path" > /tmp/cmux-last-cli-path) || true
  ln -sfn "$cli_path" /tmp/cmux-cli || true

  # Stable shim that always follows the last reload-selected dev CLI.
  DEV_CLI_SHIM="$HOME/.local/bin/cmux-dev"
  write_dev_cli_shim "$DEV_CLI_SHIM" "/Applications/cmux.app/Contents/Resources/bin/cmux"

  CMUX_SHIM_TARGET="$(select_cmux_shim_target || true)"
  if [[ -n "${CMUX_SHIM_TARGET:-}" ]]; then
    write_dev_cli_shim "$CMUX_SHIM_TARGET" "/Applications/cmux.app/Contents/Resources/bin/cmux"
  fi
}

write_last_socket_path() {
  local socket_path="$1"
  local marker_name="dev-last-socket-path"
  local tmp_marker="/tmp/cmux-dev-last-socket-path"
  local bundle_id="${BUNDLE_ID:-}"
  local slug=""

  case "$bundle_id" in
    com.cmuxterm.app)
      marker_name="last-socket-path"
      tmp_marker="/tmp/cmux-last-socket-path"
      ;;
    com.cmuxterm.app.nightly)
      marker_name="nightly-last-socket-path"
      tmp_marker="/tmp/cmux-nightly-last-socket-path"
      ;;
    com.cmuxterm.app.nightly.*)
      slug="$(sanitize_path "${bundle_id#com.cmuxterm.app.nightly.}")"
      if [[ -n "$slug" ]]; then
        marker_name="nightly-${slug}-last-socket-path"
        tmp_marker="/tmp/cmux-nightly-${slug}-last-socket-path"
      else
        marker_name="nightly-last-socket-path"
        tmp_marker="/tmp/cmux-nightly-last-socket-path"
      fi
      ;;
    com.cmuxterm.app.staging)
      marker_name="staging-last-socket-path"
      tmp_marker="/tmp/cmux-staging-last-socket-path"
      ;;
    com.cmuxterm.app.staging.*)
      slug="$(sanitize_path "${bundle_id#com.cmuxterm.app.staging.}")"
      if [[ -n "$slug" ]]; then
        marker_name="staging-${slug}-last-socket-path"
        tmp_marker="/tmp/cmux-staging-${slug}-last-socket-path"
      else
        marker_name="staging-last-socket-path"
        tmp_marker="/tmp/cmux-staging-last-socket-path"
      fi
      ;;
    com.cmuxterm.app.debug)
      slug="${TAG_SLUG:-}"
      if [[ -n "$slug" ]]; then
        marker_name="dev-${slug}-last-socket-path"
        tmp_marker="/tmp/cmux-dev-${slug}-last-socket-path"
      fi
      ;;
    com.cmuxterm.app.debug.*)
      slug="$(sanitize_path "${bundle_id#com.cmuxterm.app.debug.}")"
      if [[ -n "$slug" ]]; then
        marker_name="dev-${slug}-last-socket-path"
        tmp_marker="/tmp/cmux-dev-${slug}-last-socket-path"
      fi
      ;;
    *)
      marker_name="last-socket-path"
      tmp_marker="/tmp/cmux-last-socket-path"
      ;;
  esac

  mkdir -p "$LAST_SOCKET_PATH_DIR"
  echo "$socket_path" > "${LAST_SOCKET_PATH_DIR}/${marker_name}" || true
  echo "$socket_path" > "$tmp_marker" || true
}

usage() {
  cat <<'EOF'
Usage: ./scripts/reload.sh --tag <name> [options]

Options:
  --tag <name>           Required. Short tag for parallel builds (e.g., feature-xyz-lol).
                         Sets app name, bundle id, and derived data path unless overridden.
                         After a successful build, terminates any running app with this tag
                         so macOS launches the freshly-built binary on cmd-click or --launch.
  --launch               Launch the app after building. Without this flag, the script
                         builds and prints the app path but does not open it.
  --name <app name>      Override app display/bundle name.
  --bundle-id <id>       Override bundle identifier.
  --derived-data <path>  Override derived data path.
  --no-global-cli-links  Do not update /tmp/cmux-cli, /tmp/cmux-last-cli-path,
                         or PATH cmux-dev shims. Useful for isolated dogfood.
  --swift-frontend-workaround
                         Work around Swift arm64 frontend spins for this reload
                         only by disabling batch mode, debug symbol emission,
                         and AArch64 GlobalISel. Also enabled by
                         CMUX_SWIFT_FRONTEND_WORKAROUND=1.
  --swift-disable-global-isel
                         Alias for --swift-frontend-workaround.
  -h, --help             Show this help.
EOF
}

sanitize_bundle() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\\.+//; s/\\.+$//; s/\\.+/./g')"
  if [[ -z "$cleaned" ]]; then
    cleaned="agent"
  fi
  echo "$cleaned"
}

sanitize_path() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  echo "$cleaned"
}

is_valid_port() {
  local port="${1:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  local numeric=$((10#$port))
  (( numeric >= 1 && numeric <= 65535 ))
}

is_positive_integer() {
  local value="${1:-}"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  local numeric=$((10#$value))
  (( numeric > 0 ))
}

choose_cmux_dev_port() {
  if is_valid_port "${CMUX_PORT:-}"; then
    echo "$CMUX_PORT"
    return 0
  fi
  if is_valid_port "${PORT:-}"; then
    echo "$PORT"
    return 0
  fi
  echo "3777"
}

choose_cmux_dev_port_range() {
  if is_positive_integer "${CMUX_PORT_RANGE:-}"; then
    echo "$CMUX_PORT_RANGE"
    return 0
  fi
  echo "1"
}

choose_cmux_dev_port_end() {
  local start="$1"
  local range="$2"
  if is_valid_port "${CMUX_PORT_END:-}"; then
    echo "$CMUX_PORT_END"
    return 0
  fi
  local start_num=$((10#$start))
  local range_num=$((10#$range))
  local end=$((start_num + range_num - 1))
  if (( end > 65535 )); then
    end="$start_num"
  fi
  echo "$end"
}

set_plist_env() {
  local plist="$1"
  local key="$2"
  local value="$3"
  /usr/libexec/PlistBuddy -c "Set :LSEnvironment:${key} \"${value}\"" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :LSEnvironment:${key} string \"${value}\"" "$plist"
}

set_plist_url_scheme() {
  local plist="$1"
  local scheme="$2"
  /usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:1:CFBundleURLSchemes:0 \"${scheme}\"" "$plist" 2>/dev/null \
    || true
}

tagged_derived_data_path() {
  local slug="$1"
  echo "$HOME/Library/Developer/Xcode/DerivedData/cmux-${slug}"
}

remove_app_bundle_output() {
  local path="${1:-}"
  if [[ -z "$path" || ! -e "$path" ]]; then
    return 0
  fi
  if [[ -z "${BUILD_PRODUCTS_DEBUG_DIR:-}" ]]; then
    echo "warning: refusing to remove app output without a build products directory: $path" >&2
    return 0
  fi
  case "$path" in
    "$BUILD_PRODUCTS_DEBUG_DIR"/*.app)
      rm -rf "$path"
      ;;
    *)
      echo "warning: refusing to remove unexpected app output: $path" >&2
      ;;
  esac
}

cleanup_incomplete_xcodebuild_outputs() {
  if [[ "$XCODEBUILD_CLEANED_OUTPUTS" -eq 1 ]]; then
    return 0
  fi
  XCODEBUILD_CLEANED_OUTPUTS=1
  remove_app_bundle_output "${XCODEBUILD_SOURCE_APP_PATH:-}"
  remove_app_bundle_output "${XCODEBUILD_TAG_APP_PATH:-}"
  remove_app_bundle_output "${TAG_APP_STAGING_PATH:-}"
}

validate_app_bundle() {
  local app_path="$1"
  local executable_name="$2"
  local executable_path="$app_path/Contents/MacOS/$executable_name"
  local info_plist="$app_path/Contents/Info.plist"

  if [[ ! -d "$app_path" ]]; then
    echo "error: app bundle not found after xcodebuild: $app_path" >&2
    return 1
  fi
  if [[ ! -f "$info_plist" ]]; then
    echo "error: app Info.plist not found after xcodebuild: $info_plist" >&2
    return 1
  fi
  if [[ ! -x "$executable_path" ]]; then
    echo "error: app executable not found after xcodebuild: $executable_path" >&2
    return 1
  fi
}

print_tag_cleanup_reminder() {
  local current_slug="$1"
  local path=""
  local tag=""
  local seen=" "
  local -a stale_tags=()

  while IFS= read -r -d '' path; do
    if [[ "$path" == /tmp/cmux-* ]]; then
      tag="${path#/tmp/cmux-}"
    elif [[ "$path" == "$HOME/Library/Developer/Xcode/DerivedData/cmux-"* ]]; then
      tag="${path#$HOME/Library/Developer/Xcode/DerivedData/cmux-}"
    else
      continue
    fi
    if [[ "$tag" == "$current_slug" ]]; then
      continue
    fi
    # Only surface stale debug tag builds.
    if [[ ! -d "$path/Build/Products/Debug" ]]; then
      continue
    fi
    if [[ "$seen" == *" $tag "* ]]; then
      continue
    fi
    seen="${seen}${tag} "
    stale_tags+=("$tag")
  done < <(
    find /tmp -maxdepth 1 -name 'cmux-*' -print0 2>/dev/null
    find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 1 -type d -name 'cmux-*' -print0 2>/dev/null
  )

  echo
  echo "Tag cleanup status:"
  echo "  current tag: ${current_slug} (keep this running until you verify)"
  if [[ "${#stale_tags[@]}" -eq 0 ]]; then
    echo "  stale tags: none"
    echo "  stale cleanup: not needed"
  else
    echo "  stale tags:"
    for tag in "${stale_tags[@]}"; do
      echo "    - ${tag}"
    done
    echo "Cleanup stale tags only:"
    for tag in "${stale_tags[@]}"; do
      echo "  pkill -f \"cmux DEV ${tag}.app/Contents/MacOS/cmux DEV\""
      echo "  rm -rf \"$(tagged_derived_data_path "$tag")\" \"/tmp/cmux-${tag}\" \"/tmp/cmux-debug-${tag}.sock\""
      echo "  rm -f \"/tmp/cmux-debug-${tag}.log\""
      echo "  rm -f \"$HOME/Library/Application Support/cmux/cmuxd-dev-${tag}.sock\""
    done
  fi
  echo "After you verify current tag, cleanup command:"
  echo "  pkill -f \"cmux DEV ${current_slug}.app/Contents/MacOS/cmux DEV\""
  echo "  rm -rf \"$(tagged_derived_data_path "$current_slug")\" \"/tmp/cmux-${current_slug}\" \"/tmp/cmux-debug-${current_slug}.sock\""
  echo "  rm -f \"/tmp/cmux-debug-${current_slug}.log\""
  echo "  rm -f \"$HOME/Library/Application Support/cmux/cmuxd-dev-${current_slug}.sock\""
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="${2:-}"
      if [[ -z "$TAG" ]]; then
        echo "error: --tag requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --name)
      APP_NAME="${2:-}"
      if [[ -z "$APP_NAME" ]]; then
        echo "error: --name requires a value" >&2
        exit 1
      fi
      NAME_SET=1
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="${2:-}"
      if [[ -z "$BUNDLE_ID" ]]; then
        echo "error: --bundle-id requires a value" >&2
        exit 1
      fi
      BUNDLE_SET=1
      shift 2
      ;;
    --launch)
      LAUNCH=1
      shift
      ;;
    --derived-data)
      DERIVED_DATA="${2:-}"
      if [[ -z "$DERIVED_DATA" ]]; then
        echo "error: --derived-data requires a value" >&2
        exit 1
      fi
      DERIVED_SET=1
      shift 2
      ;;
    --no-global-cli-links)
      NO_GLOBAL_CLI_LINKS=1
      shift
      ;;
    --swift-disable-global-isel)
      SWIFT_FRONTEND_WORKAROUND=1
      shift
      ;;
    --swift-frontend-workaround)
      SWIFT_FRONTEND_WORKAROUND=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$TAG" ]]; then
  echo "error: --tag is required (example: ./scripts/reload.sh --tag fix-sidebar-theme)" >&2
  usage
  exit 1
fi

if [[ -n "$TAG" ]]; then
  TAG_ID="$(sanitize_bundle "$TAG")"
  TAG_SLUG="$(sanitize_path "$TAG")"
  if [[ -z "$TAG_SLUG" ]]; then
    echo "error: --tag must contain at least one alphanumeric character" >&2
    exit 1
  fi
  if [[ "$NAME_SET" -eq 0 ]]; then
    APP_NAME="cmux DEV ${TAG_SLUG}"
  fi
  if [[ "$BUNDLE_SET" -eq 0 ]]; then
    BUNDLE_ID="com.cmuxterm.app.debug.${TAG_ID}"
  fi
  if [[ "$DERIVED_SET" -eq 0 ]]; then
    DERIVED_DATA="$(tagged_derived_data_path "$TAG_SLUG")"
  fi
fi

CMUX_DEV_PORT="$(choose_cmux_dev_port)"
CMUX_DEV_PORT_RANGE="$(choose_cmux_dev_port_range)"
CMUX_DEV_PORT_END="$(choose_cmux_dev_port_end "$CMUX_DEV_PORT" "$CMUX_DEV_PORT_RANGE")"
CMUX_DEV_ORIGIN="http://localhost:${CMUX_DEV_PORT}"

# Quiet logging: capture all noisy build output (xcodebuild, zig, codesign,
# plistbuddy, etc.) to a single log file. On success we print only a one-line
# summary plus the App/CLI paths. On failure we dump the log.
RELOAD_LOG="/tmp/cmux-reload-${TAG_SLUG}.log"
RELOAD_START_TIME="$(date +%s)"
: > "$RELOAD_LOG"

BUILD_PRODUCTS_DEBUG_DIR=""
XCODEBUILD_SOURCE_APP_NAME="$APP_NAME"
XCODEBUILD_SOURCE_APP_PATH=""
XCODEBUILD_TAG_APP_PATH=""
TAG_APP_FINAL_PATH=""
TAG_APP_STAGING_PATH=""
if [[ -n "$DERIVED_DATA" ]]; then
  BUILD_PRODUCTS_DEBUG_DIR="${DERIVED_DATA}/Build/Products/Debug"
  if [[ -n "$TAG" ]]; then
    XCODEBUILD_SOURCE_APP_NAME="$BASE_APP_NAME"
  fi
  XCODEBUILD_SOURCE_APP_PATH="${BUILD_PRODUCTS_DEBUG_DIR}/${XCODEBUILD_SOURCE_APP_NAME}.app"
  if [[ -n "$TAG" && "$APP_NAME" != "$XCODEBUILD_SOURCE_APP_NAME" ]]; then
    XCODEBUILD_TAG_APP_PATH="${BUILD_PRODUCTS_DEBUG_DIR}/${APP_NAME}.app"
  fi
fi

# Save the original stdout/stderr so the EXIT trap can write the user-facing
# summary after the body redirect, then redirect bulk output into the log.
exec 3>&1 4>&2
exec >>"$RELOAD_LOG" 2>&1

reload_finalize() {
  local rc=$?
  trap - EXIT
  exec 1>&3 2>&4
  local elapsed=$(( $(date +%s) - RELOAD_START_TIME ))
  if [[ "$rc" -ne 0 ]]; then
    if [[ "$XCODEBUILD_STARTED" -eq 1 && "$XCODEBUILD_OUTPUT_VALID" -ne 1 ]]; then
      cleanup_incomplete_xcodebuild_outputs
      echo "==> removed incomplete xcodebuild app outputs" >&2
    elif [[ -n "${TAG_APP_STAGING_PATH:-}" && -e "$TAG_APP_STAGING_PATH" ]]; then
      remove_app_bundle_output "$TAG_APP_STAGING_PATH"
      echo "==> removed incomplete staged tagged app" >&2
    fi
    if [[ -s "$RELOAD_LOG" ]]; then
      cat "$RELOAD_LOG" >&2
    fi
    echo "" >&2
    echo "==> reload FAILED (exit $rc) after ${elapsed}s" >&2
    echo "==> log: $RELOAD_LOG" >&2
    exit "$rc"
  fi
  echo "==> reload succeeded in ${elapsed}s"
  echo "==> log: $RELOAD_LOG"
  if [[ -n "${APP_PATH:-}" ]]; then
    echo
    echo "App path:"
    echo "  $APP_PATH"
  fi
  if [[ -n "${CMUX_DEV_ORIGIN:-}" ]]; then
    echo
    echo "Dev web origin:"
    echo "  $CMUX_DEV_ORIGIN"
    if [[ -n "${TAG_SLUG:-}" ]]; then
      echo "Dev web command:"
      echo "  cd web && CMUX_PORT=$CMUX_DEV_PORT CMUX_PORT_RANGE=$CMUX_DEV_PORT_RANGE CMUX_PORT_END=$CMUX_DEV_PORT_END CMUX_AUTH_CALLBACK_SCHEME=cmux-dev-$TAG_SLUG bun dev"
    fi
  fi
  if [[ -x "${CLI_PATH:-}" ]]; then
    echo
    echo "CLI path:"
    echo "  $CLI_PATH"
    echo "CLI helpers:"
    if [[ "$NO_GLOBAL_CLI_LINKS" == "1" ]]; then
      echo "  preserved existing global cmux CLI links (--no-global-cli-links)"
    else
      echo "  /tmp/cmux-cli ..."
      echo "  $HOME/.local/bin/cmux-dev ..."
      if [[ -n "${CMUX_SHIM_TARGET:-}" ]]; then
        echo "  $CMUX_SHIM_TARGET ..."
      fi
      echo "If your shell still resolves the old cmux, run: rehash"
    fi
  fi
  if [[ "${SWIFT_FRONTEND_WORKAROUND_EFFECTIVE:-0}" -eq 1 ]]; then
    echo
    echo "Swift workaround:"
    echo "  batch mode, debug symbols, and AArch64 GlobalISel disabled for this reload"
  fi
  if [[ "$LAUNCH" -eq 0 ]]; then
    echo
    echo "Build complete. Pass --launch to open the app, or cmd-click the path above."
  fi
}
trap reload_finalize EXIT

# Tell the user we're starting (visible even though body output is redirected).
echo "==> reload starting (tag: ${TAG}, log: ${RELOAD_LOG})" >&3

"$PWD/scripts/ensure-ghosttykit.sh"

if should_skip_ghostty_cli_helper_zig_build; then
  export CMUX_SKIP_ZIG_BUILD=1
fi

XCODEBUILD_ARGS=(
  -project cmux.xcodeproj
  -scheme cmux
  -configuration Debug
  -destination 'platform=macOS'
)
if [[ -n "$DERIVED_DATA" ]]; then
  XCODEBUILD_ARGS+=(-derivedDataPath "$DERIVED_DATA")
fi
if [[ -n "${CMUX_SOURCE_PACKAGES_DIR:-}" ]]; then
  mkdir -p "$CMUX_SOURCE_PACKAGES_DIR"
  XCODEBUILD_ARGS+=(-clonedSourcePackagesDirPath "$CMUX_SOURCE_PACKAGES_DIR")
fi
if [[ "${CMUX_DISABLE_AUTOMATIC_PACKAGE_RESOLUTION:-}" == "1" ]]; then
  XCODEBUILD_ARGS+=(-disableAutomaticPackageResolution)
fi
if [[ -z "$TAG" ]]; then
  XCODEBUILD_ARGS+=(
    INFOPLIST_KEY_CFBundleName="$APP_NAME"
    INFOPLIST_KEY_CFBundleDisplayName="$APP_NAME"
  )
fi
XCODEBUILD_ARGS+=(PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID")
# Scope the sidebar ExtensionKit point per build tag so concurrent dev builds (and
# their tagged sample extensions) don't share one point. The host bundle declares
# the point under Contents/Extensions, and Info.plist carries the same identifier.
if [[ -n "$TAG" ]]; then
  XCODEBUILD_ARGS+=(CMUX_SIDEBAR_EXTENSION_POINT_ID="${BUNDLE_ID}.cmux.sidebar")
fi
# Forward explicit CMUX_SKIP_ZIG_BUILD to xcodebuild run script phases.
if [[ "${CMUX_SKIP_ZIG_BUILD:-}" == "1" ]]; then
  XCODEBUILD_ARGS+=(CMUX_SKIP_ZIG_BUILD=1)
fi
if [[ "$SWIFT_FRONTEND_WORKAROUND" -eq 1 || "${CMUX_SWIFT_FRONTEND_WORKAROUND:-}" == "1" || "${CMUX_SWIFT_DISABLE_GLOBAL_ISEL:-}" == "1" ]]; then
  SWIFT_FRONTEND_WORKAROUND_EFFECTIVE=1
  echo "==> Swift frontend workaround enabled for this reload"
  XCODEBUILD_ARGS+=(SWIFT_ENABLE_BATCH_MODE=NO)
  XCODEBUILD_ARGS+=(DEBUG_INFORMATION_FORMAT=)
  XCODEBUILD_ARGS+=(GCC_GENERATE_DEBUGGING_SYMBOLS=NO)
  XCODEBUILD_ARGS+=('OTHER_SWIFT_FLAGS=$(inherited) -Xllvm -aarch64-enable-global-isel-at-O=-1')
else
  SWIFT_FRONTEND_WORKAROUND_EFFECTIVE=0
fi
XCODEBUILD_ARGS+=(build)

if [[ -n "$BUILD_PRODUCTS_DEBUG_DIR" ]]; then
  mkdir -p "$BUILD_PRODUCTS_DEBUG_DIR"
  cleanup_incomplete_xcodebuild_outputs
  XCODEBUILD_CLEANED_OUTPUTS=0
fi

XCODEBUILD_LOCK_DIR="${TMPDIR:-/tmp}/cmux-xcodebuild-$(id -u).locks"
XCODEBUILD_LOCK_CONCURRENCY="${CMUX_XCODEBUILD_LOCK_CONCURRENCY:-5}"
if ! is_positive_integer "$XCODEBUILD_LOCK_CONCURRENCY"; then
  echo "error: xcodebuild lock concurrency must be a positive integer" >&2
  exit 1
fi
XCODEBUILD_LOCK_WAIT_SECONDS="${CMUX_XCODEBUILD_LOCK_WAIT_SECONDS:-1800}"
if ! is_positive_integer "$XCODEBUILD_LOCK_WAIT_SECONDS"; then
  echo "error: xcodebuild lock wait timeout must be a positive integer" >&2
  exit 1
fi
# Xcode 26's SWBBuildService is a per-user singleton. Too many concurrent
# xcodebuild invocations can trample that daemon, so cap reload.sh builds at
# five per user while still allowing useful parallel tagged builds.
XCODEBUILD_STARTED=1
python3 -c '
import array
import fcntl
import os
import select
import signal
import socket
import sys

lock_dir = sys.argv[1]
concurrency = int(sys.argv[2])
wait_seconds = int(sys.argv[3])
command = sys.argv[4:]

try:
    os.makedirs(lock_dir, mode=0o700, exist_ok=True)
except OSError as exc:
    raise SystemExit(f"error: create lock dir: {exc}")

def open_slot(slot):
    lock_path = os.path.join(lock_dir, f"slot-{slot}.lock")
    try:
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    except OSError as exc:
        raise SystemExit(f"error: open lock slot: {exc}")

    try:
        os.set_inheritable(fd, True)
    except OSError as exc:
        os.close(fd)
        raise SystemExit(f"error: fcntl lock fd: {exc}")
    return fd, lock_path

def try_acquire_any_slot():
    for slot in range(1, concurrency + 1):
        fd, lock_path = open_slot(slot)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd, slot, lock_path
        except BlockingIOError:
            os.close(fd)
        except OSError as exc:
            os.close(fd)
            raise SystemExit(f"error: flock: {exc}")
    return None, None, None

def stop_waiters(children):
    for pid in children:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        except OSError:
            pass
    for pid in children:
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
        except OSError:
            pass

def wait_for_any_slot():
    parent_sock, child_sock = socket.socketpair()
    children = []
    try:
        for slot in range(1, concurrency + 1):
            pid = os.fork()
            if pid == 0:
                try:
                    parent_sock.close()
                    fd, _ = open_slot(slot)
                    fcntl.flock(fd, fcntl.LOCK_EX)
                    payload = array.array("i", [fd])
                    child_sock.sendmsg(
                        [f"{slot}".encode()],
                        [(socket.SOL_SOCKET, socket.SCM_RIGHTS, payload)],
                    )
                except BaseException:
                    os._exit(1)
                os._exit(0)
            children.append(pid)
        child_sock.close()

        ready, _, _ = select.select([parent_sock], [], [], wait_seconds)
        if not ready:
            raise SystemExit(
                f"error: timed out waiting for xcodebuild slot after {wait_seconds}s; "
                "check for stuck xcodebuild processes"
            )

        msg, ancdata, _, _ = parent_sock.recvmsg(
            16,
            socket.CMSG_LEN(array.array("i").itemsize),
        )
        received = array.array("i")
        for level, ctype, data in ancdata:
            if level == socket.SOL_SOCKET and ctype == socket.SCM_RIGHTS:
                received.frombytes(data[: array.array("i").itemsize])
        if not received:
            raise SystemExit("error: failed to receive xcodebuild lock slot")
        fd = received[0]
        os.set_inheritable(fd, True)
        try:
            slot = int(msg.decode())
        except ValueError:
            slot = 0
        lock_path = os.path.join(lock_dir, f"slot-{slot}.lock")
        return fd, slot, lock_path
    finally:
        stop_waiters(children)
        parent_sock.close()
        try:
            child_sock.close()
        except OSError:
            pass

fd, slot, lock_path = try_acquire_any_slot()
if fd is None:
    msg = (
        f"==> xcodebuild concurrency limit reached ({concurrency}); "
        "waiting for the next available slot...\n"
    )
    # reload.sh saves the original stderr on fd 4 before redirecting to the
    # log file. Surface the wait notice to the terminal so the user knows
    # they are queued, not hung. Fall back to stderr (the log) if fd 4 is
    # unavailable (e.g. when this script is run standalone).
    try:
        os.write(4, msg.encode())
    except OSError:
        sys.stderr.write(msg)
        sys.stderr.flush()
    fd, slot, lock_path = wait_for_any_slot()

try:
    os.execvp(command[0], command)
except OSError as exc:
    raise SystemExit(f"error: exec: {exc}")
' "$XCODEBUILD_LOCK_DIR" "$XCODEBUILD_LOCK_CONCURRENCY" "$XCODEBUILD_LOCK_WAIT_SECONDS" xcodebuild "${XCODEBUILD_ARGS[@]}"
sleep 0.2
if LC_ALL=C grep -q 'BUILD INTERRUPTED' "$RELOAD_LOG"; then
  echo "error: xcodebuild reported ** BUILD INTERRUPTED **; refusing to reuse DerivedData app artifacts" >&2
  exit 65
fi

FALLBACK_APP_NAME="$BASE_APP_NAME"
SEARCH_APP_NAME="$APP_NAME"
APP_EXECUTABLE_NAME="$SEARCH_APP_NAME"
if [[ -n "$TAG" ]]; then
  SEARCH_APP_NAME="$BASE_APP_NAME"
  APP_EXECUTABLE_NAME="$BASE_APP_NAME"
fi
if [[ -n "$DERIVED_DATA" ]]; then
  APP_PATH="${DERIVED_DATA}/Build/Products/Debug/${SEARCH_APP_NAME}.app"
  if [[ ! -d "${APP_PATH}" && "$SEARCH_APP_NAME" != "$FALLBACK_APP_NAME" ]]; then
    APP_PATH="${DERIVED_DATA}/Build/Products/Debug/${FALLBACK_APP_NAME}.app"
    APP_EXECUTABLE_NAME="$FALLBACK_APP_NAME"
  fi
else
  APP_BINARY="$(
    find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Debug/${SEARCH_APP_NAME}.app/Contents/MacOS/${SEARCH_APP_NAME}" -print0 \
    | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
    | sort -nr \
    | head -n 1 \
    | cut -d' ' -f2-
  )"
  if [[ -n "${APP_BINARY}" ]]; then
    APP_PATH="$(dirname "$(dirname "$(dirname "$APP_BINARY")")")"
  fi
  if [[ -z "${APP_PATH}" && "$SEARCH_APP_NAME" != "$FALLBACK_APP_NAME" ]]; then
    APP_BINARY="$(
      find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Debug/${FALLBACK_APP_NAME}.app/Contents/MacOS/${FALLBACK_APP_NAME}" -print0 \
      | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
      | sort -nr \
      | head -n 1 \
      | cut -d' ' -f2-
    )"
    if [[ -n "${APP_BINARY}" ]]; then
      APP_PATH="$(dirname "$(dirname "$(dirname "$APP_BINARY")")")"
      APP_EXECUTABLE_NAME="$FALLBACK_APP_NAME"
    fi
  fi
fi
if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}" ]]; then
  echo "${APP_NAME}.app not found in DerivedData" >&2
  exit 1
fi
validate_app_bundle "$APP_PATH" "$APP_EXECUTABLE_NAME"
XCODEBUILD_OUTPUT_VALID=1

if [[ -n "${TAG_SLUG:-}" ]]; then
  TMP_COMPAT_DERIVED_LINK="/tmp/cmux-${TAG_SLUG}"
  if [[ "$DERIVED_DATA" != "$TMP_COMPAT_DERIVED_LINK" ]]; then
    ABS_DERIVED_DATA="$(cd "$DERIVED_DATA" && pwd)"
    rm -rf "$TMP_COMPAT_DERIVED_LINK"
    ln -s "$ABS_DERIVED_DATA" "$TMP_COMPAT_DERIVED_LINK"
  fi
fi

if [[ -n "$TAG" && "$APP_NAME" != "$SEARCH_APP_NAME" ]]; then
  TAG_APP_FINAL_PATH="$(dirname "$APP_PATH")/${APP_NAME}.app"
  TAG_APP_STAGING_PATH="$(dirname "$APP_PATH")/.${APP_NAME}.reload-$$.app"
  rm -rf "$TAG_APP_STAGING_PATH"
  cp -R "$APP_PATH" "$TAG_APP_STAGING_PATH"
  INFO_PLIST="$TAG_APP_STAGING_PATH/Contents/Info.plist"
  if [[ -f "$INFO_PLIST" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$INFO_PLIST" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$INFO_PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$INFO_PLIST" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$INFO_PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$INFO_PLIST"
    if [[ -n "${TAG_SLUG:-}" ]]; then
      APP_SUPPORT_DIR="$HOME/Library/Application Support/cmux"
      CMUXD_SOCKET="${APP_SUPPORT_DIR}/cmuxd-dev-${TAG_SLUG}.sock"
      CMUX_SOCKET_PATH_VALUE="/tmp/cmux-debug-${TAG_SLUG}.sock"
      CMUX_DEBUG_LOG="/tmp/cmux-debug-${TAG_SLUG}.log"
      CMUX_AUTH_CALLBACK_SCHEME_VALUE="cmux-dev-${TAG_SLUG}"
      write_last_socket_path "$CMUX_SOCKET_PATH_VALUE"
      echo "$CMUX_DEBUG_LOG" > /tmp/cmux-last-debug-log-path || true
      /usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$INFO_PLIST" 2>/dev/null || true
      set_plist_url_scheme "$INFO_PLIST" "$CMUX_AUTH_CALLBACK_SCHEME_VALUE"
      set_plist_env "$INFO_PLIST" CMUX_BUNDLE_ID "$BUNDLE_ID"
      set_plist_env "$INFO_PLIST" CMUXD_UNIX_PATH "$CMUXD_SOCKET"
      set_plist_env "$INFO_PLIST" CMUX_SOCKET_PATH "$CMUX_SOCKET_PATH_VALUE"
      set_plist_env "$INFO_PLIST" CMUX_DEBUG_LOG "$CMUX_DEBUG_LOG"
      set_plist_env "$INFO_PLIST" CMUX_TAG "$TAG_SLUG"
      set_plist_env "$INFO_PLIST" CMUX_AUTH_CALLBACK_SCHEME "$CMUX_AUTH_CALLBACK_SCHEME_VALUE"
      set_plist_env "$INFO_PLIST" CMUX_SOCKET_ENABLE "1"
      set_plist_env "$INFO_PLIST" CMUX_SOCKET_MODE "allowAll"
      set_plist_env "$INFO_PLIST" CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD "1"
      set_plist_env "$INFO_PLIST" CMUXTERM_REPO_ROOT "$PWD"
      set_plist_env "$INFO_PLIST" CMUX_BUNDLED_CLI_PATH "$TAG_APP_FINAL_PATH/Contents/Resources/bin/cmux"
      set_plist_env "$INFO_PLIST" CMUX_SHELL_INTEGRATION_DIR "$TAG_APP_FINAL_PATH/Contents/Resources/shell-integration"
      set_plist_env "$INFO_PLIST" CMUX_PORT "$CMUX_DEV_PORT"
      set_plist_env "$INFO_PLIST" CMUX_PORT_END "$CMUX_DEV_PORT_END"
      set_plist_env "$INFO_PLIST" CMUX_PORT_RANGE "$CMUX_DEV_PORT_RANGE"
      set_plist_env "$INFO_PLIST" PORT "$CMUX_DEV_PORT"
      set_plist_env "$INFO_PLIST" CMUX_AUTH_WWW_ORIGIN "$CMUX_DEV_ORIGIN"
      set_plist_env "$INFO_PLIST" CMUX_API_BASE_URL "$CMUX_DEV_ORIGIN"
      set_plist_env "$INFO_PLIST" CMUX_VM_API_BASE_URL "$CMUX_DEV_ORIGIN"
      if [[ -S "$CMUXD_SOCKET" ]]; then
        for PID in $(lsof -t "$CMUXD_SOCKET" 2>/dev/null); do
          kill "$PID" 2>/dev/null || true
        done
        rm -f "$CMUXD_SOCKET"
      fi
      if [[ -S "$CMUX_SOCKET_PATH_VALUE" ]]; then
        rm -f "$CMUX_SOCKET_PATH_VALUE"
      fi
    fi
  fi
  APP_PATH="$TAG_APP_STAGING_PATH"
fi

CLI_PATH="$(dirname "$APP_PATH")/cmux"
publish_reload_cli_path "$CLI_PATH"

# Build cmuxd and ensure helper binaries are present (needed for both launch and no-launch).
CMUXD_SRC="$PWD/cmuxd/zig-out/bin/cmuxd"
if [[ -d "$PWD/cmuxd" ]]; then
  (cd "$PWD/cmuxd" && zig build -Doptimize=ReleaseFast)
fi
if [[ -d "$PWD/ghostty" ]]; then
  BIN_DIR="$APP_PATH/Contents/Resources/bin"
  GHOSTTY_HELPER_DEST="$BIN_DIR/ghostty"
  if [[ -x "$GHOSTTY_HELPER_DEST" ]]; then
    echo "Preserving Xcode-built ghostty CLI helper at $GHOSTTY_HELPER_DEST"
  elif [[ "${CMUX_SKIP_ZIG_BUILD:-}" == "1" ]]; then
    echo "Skipping direct ghostty CLI helper zig build (CMUX_SKIP_ZIG_BUILD=1)"
  else
    mkdir -p "$BIN_DIR"
    "$PWD/scripts/build-ghostty-cli-helper.sh" --output "$GHOSTTY_HELPER_DEST"
  fi
fi
BIN_DIR="$APP_PATH/Contents/Resources/bin"
CU_PROVIDER_DEST="$BIN_DIR/cmux-computer-use-provider"
if [[ -x "$CU_PROVIDER_DEST" ]]; then
  echo "Preserving Xcode-built cmux computer-use provider at $CU_PROVIDER_DEST"
else
  mkdir -p "$BIN_DIR"
  "$PWD/scripts/build-computer-use-provider.sh" --output "$CU_PROVIDER_DEST"
fi
if [[ -x "$CMUXD_SRC" ]]; then
  BIN_DIR="$APP_PATH/Contents/Resources/bin"
  mkdir -p "$BIN_DIR"
  cp "$CMUXD_SRC" "$BIN_DIR/cmuxd"
  chmod +x "$BIN_DIR/cmuxd"
fi
if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$APP_PATH" || true
fi
if ! /usr/bin/codesign --force --sign - --timestamp=none --generate-entitlement-der "$APP_PATH" >/dev/null 2>&1; then
  if [[ "${CMUX_ALLOW_UNSIGNED_DEV_APP:-}" == "1" ]]; then
    echo "warning: codesign failed for $APP_PATH; continuing because CMUX_ALLOW_UNSIGNED_DEV_APP=1" >&2
  else
    echo "error: codesign failed for $APP_PATH" >&2
    exit 1
  fi
fi
if [[ -n "${TAG_APP_FINAL_PATH:-}" && -n "${TAG_APP_STAGING_PATH:-}" ]]; then
  rm -rf "$TAG_APP_FINAL_PATH"
  mv "$TAG_APP_STAGING_PATH" "$TAG_APP_FINAL_PATH"
  APP_PATH="$TAG_APP_FINAL_PATH"
fi
CLI_PATH="$APP_PATH/Contents/Resources/bin/cmux"
publish_reload_cli_path "$CLI_PATH"

# Tag mode: always terminate the existing same-tag instance after a successful build,
# even without --launch. A stale tagged app pinned to this bundle id would otherwise
# keep running against freshly-overwritten resources, and macOS would foreground it
# instead of launching the newly built binary when the user cmd-clicks the .app.
if [[ -n "$TAG" ]]; then
  /usr/bin/osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
  sleep 0.3
  pkill -f "${APP_NAME}.app/Contents/MacOS/${BASE_APP_NAME}" || true
  sleep 0.3
fi

if [[ "$LAUNCH" -eq 1 ]]; then
  if [[ -z "$TAG" ]]; then
    # Non-tag mode: kill any running instance (across any DerivedData path) to avoid socket conflicts.
    /usr/bin/osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
    sleep 0.3
    pkill -f "/${BASE_APP_NAME}.app/Contents/MacOS/${BASE_APP_NAME}" || true
    sleep 0.3
  fi

  # Avoid inheriting cmux/ghostty environment variables from the terminal that
  # runs this script (often inside another cmux instance), which can cause
  # socket and resource-path conflicts.
  OPEN_CLEAN_ENV=(
    env
    -u CMUX_SOCKET
    -u CMUX_SOCKET_PASSWORD
    -u CMUX_SOCKET_PATH
    -u CMUX_WORKSPACE_ID
    -u CMUX_SURFACE_ID
    -u CMUX_TAB_ID
    -u CMUX_PANEL_ID
    -u CMUXD_UNIX_PATH
    -u CMUX_TAG
    -u CMUX_DEBUG_LOG
    -u CMUX_BUNDLE_ID
    -u CMUX_BUNDLED_CLI_PATH
    -u CMUX_SHELL_INTEGRATION
    -u CMUX_SHELL_INTEGRATION_DIR
    -u CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION
    -u GHOSTTY_BIN_DIR
    -u GHOSTTY_RESOURCES_DIR
    -u GHOSTTY_SHELL_FEATURES
    -u GHOSTTY_SURFACE_ID
    # Dev shells (including CI/Codex) often force-disable paging by exporting these.
    # Don't leak that into cmux, otherwise `git diff` won't page even with PAGER=less.
    -u GIT_PAGER
    -u GH_PAGER
    -u TERMINFO
    -u XDG_DATA_DIRS
  )

  # DEBUG dogfood auto-sign-in needs no env injection here: the in-app resolver
  # reads ~/.secrets/cmuxterm-dev.env (then ~/.secrets/cmux.env) directly on
  # launch, which fires for every launch method including Finder / the CMUX Tag
  # Opener that this script's TAG_LAUNCH_ENV never reaches. Exporting the Stack
  # password into the long-lived GUI process environment would leak it to every
  # child terminal/CLI it spawns, for zero added coverage, so we deliberately do
  # not set CMUX_UITEST_STACK_* here.
  LAUNCH_AUTH_CALLBACK_SCHEME="cmux-dev"
  if [[ -n "${TAG_SLUG:-}" ]]; then
    LAUNCH_AUTH_CALLBACK_SCHEME="cmux-dev-${TAG_SLUG}"
  fi
  TAG_LAUNCH_ENV=(
    CMUX_TAG="${TAG_SLUG:-}"
    CMUX_BUNDLE_ID="$BUNDLE_ID"
    CMUX_AUTH_CALLBACK_SCHEME="$LAUNCH_AUTH_CALLBACK_SCHEME"
    CMUX_SOCKET_ENABLE=1
    CMUX_SOCKET_MODE=allowAll
    CMUX_DEBUG_LOG="$CMUX_DEBUG_LOG"
    CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1
    CMUXTERM_REPO_ROOT="$PWD"
    CMUX_BUNDLED_CLI_PATH="$CLI_PATH"
    CMUX_SHELL_INTEGRATION_DIR="$APP_PATH/Contents/Resources/shell-integration"
    CMUX_PORT="$CMUX_DEV_PORT"
    CMUX_PORT_END="$CMUX_DEV_PORT_END"
    CMUX_PORT_RANGE="$CMUX_DEV_PORT_RANGE"
    PORT="$CMUX_DEV_PORT"
    CMUX_AUTH_WWW_ORIGIN="$CMUX_DEV_ORIGIN"
    CMUX_API_BASE_URL="$CMUX_DEV_ORIGIN"
    CMUX_VM_API_BASE_URL="$CMUX_DEV_ORIGIN"
  )

  LAUNCH_CMD=()
  LAUNCH_RETRY_CMD=()
  if [[ -n "${TAG_SLUG:-}" ]]; then
    # Launch tagged apps directly so LaunchServices cannot reuse a stale
    # LSEnvironment for the tag's bundle id.
    APP_EXECUTABLE="$APP_PATH/Contents/MacOS/${BASE_APP_NAME}"
    if [[ ! -x "$APP_EXECUTABLE" ]]; then
      echo "error: tagged app executable not found: $APP_EXECUTABLE" >&2
      exit 1
    fi
    TAG_LAUNCH_LOG="/tmp/cmux-launch-${TAG_SLUG}.out"
    if [[ -n "${CMUX_SOCKET_PATH_VALUE:-}" ]]; then
      nohup "${OPEN_CLEAN_ENV[@]}" "${TAG_LAUNCH_ENV[@]}" CMUX_SOCKET_PATH="$CMUX_SOCKET_PATH_VALUE" CMUXD_UNIX_PATH="$CMUXD_SOCKET" "$APP_EXECUTABLE" >"$TAG_LAUNCH_LOG" 2>&1 &
    else
      nohup "${OPEN_CLEAN_ENV[@]}" "${TAG_LAUNCH_ENV[@]}" "$APP_EXECUTABLE" >"$TAG_LAUNCH_LOG" 2>&1 &
    fi
  else
    echo "/tmp/cmux-debug.sock" > /tmp/cmux-last-socket-path || true
    echo "/tmp/cmux-debug.log" > /tmp/cmux-last-debug-log-path || true
    if [[ -n "${CMUX_SOCKET_PATH_VALUE:-}" ]]; then
      # Ensure explicit socket paths win even if the caller has CMUX_* overrides.
      LAUNCH_CMD=("${OPEN_CLEAN_ENV[@]}" "${TAG_LAUNCH_ENV[@]}" CMUX_SOCKET_PATH="$CMUX_SOCKET_PATH_VALUE" CMUXD_UNIX_PATH="$CMUXD_SOCKET" open -g "$APP_PATH")
      LAUNCH_RETRY_CMD=("${OPEN_CLEAN_ENV[@]}" "${TAG_LAUNCH_ENV[@]}" CMUX_SOCKET_PATH="$CMUX_SOCKET_PATH_VALUE" CMUXD_UNIX_PATH="$CMUXD_SOCKET" open -n -g "$APP_PATH")
    else
      LAUNCH_CMD=("${OPEN_CLEAN_ENV[@]}" "${TAG_LAUNCH_ENV[@]}" open -g "$APP_PATH")
      LAUNCH_RETRY_CMD=("${OPEN_CLEAN_ENV[@]}" "${TAG_LAUNCH_ENV[@]}" open -n -g "$APP_PATH")
    fi
  fi

  if [[ "${#LAUNCH_CMD[@]}" -gt 0 ]] && ! "${LAUNCH_CMD[@]}"; then
    echo "warning: open -g failed; retrying launch with open -n -g" >&2
    "${LAUNCH_RETRY_CMD[@]}"
  fi

  # Safety: ensure only one instance is running.
  sleep 0.2
  PIDS=($(pgrep -f "${APP_PATH}/Contents/MacOS/" || true))
  if [[ -n "${TAG_SLUG:-}" && "${#PIDS[@]}" -eq 0 ]]; then
    echo "error: tagged app exited immediately after launch" >&2
    if [[ -n "${TAG_LAUNCH_LOG:-}" && -f "$TAG_LAUNCH_LOG" ]]; then
      echo "Launch log: $TAG_LAUNCH_LOG" >&2
      tail -n 80 "$TAG_LAUNCH_LOG" >&2 || true
    fi
    exit 1
  fi
  if [[ "${#PIDS[@]}" -gt 1 ]]; then
    NEWEST_PID=""
    NEWEST_AGE=999999
    for PID in "${PIDS[@]}"; do
      AGE="$(ps -o etimes= -p "$PID" | tr -d ' ')"
      if [[ -n "$AGE" && "$AGE" -lt "$NEWEST_AGE" ]]; then
        NEWEST_AGE="$AGE"
        NEWEST_PID="$PID"
      fi
    done
    for PID in "${PIDS[@]}"; do
      if [[ "$PID" != "$NEWEST_PID" ]]; then
        kill "$PID" 2>/dev/null || true
      fi
    done
  fi
  if [[ -n "${TAG_SLUG:-}" && -n "${CMUX_SOCKET_PATH_VALUE:-}" ]]; then
    SOCKET_READY=0
    for _ in {1..80}; do
      if [[ -S "$CMUX_SOCKET_PATH_VALUE" ]]; then
        SOCKET_READY=1
        break
      fi
      if ! pgrep -f "${APP_PATH}/Contents/MacOS/" >/dev/null 2>&1; then
        break
      fi
      sleep 0.1
    done
    if [[ "$SOCKET_READY" -ne 1 ]]; then
      echo "error: tagged app did not create socket: $CMUX_SOCKET_PATH_VALUE" >&2
      if [[ -n "${TAG_LAUNCH_LOG:-}" && -f "$TAG_LAUNCH_LOG" ]]; then
        echo "Launch log: $TAG_LAUNCH_LOG" >&2
        tail -n 80 "$TAG_LAUNCH_LOG" >&2 || true
      fi
      exit 1
    fi
  fi
fi

# The user-facing summary (success line, App path, CLI path/helpers, rehash
# hint, "pass --launch") is printed by the reload_finalize EXIT trap. The
# tag-cleanup reminder still runs here, but its output goes to $RELOAD_LOG
# (visible by tail -f or by inspecting the log path printed in the summary).
if [[ -n "${TAG_SLUG:-}" ]]; then
  print_tag_cleanup_reminder "$TAG_SLUG"
fi
