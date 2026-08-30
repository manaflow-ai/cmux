#!/bin/bash
set -euo pipefail

CMUX_CUA_REPO_URL="${CMUX_CUA_REPO_URL:-https://github.com/manaflow-ai/cmux-cua.git}"
CMUX_CUA_PINNED_SHA="7a57a7c79522ece017a3ae4ef7884a24d7eec270"
CMUX_CUA_SOURCE_OWNER_FILE=".cmux-cua-managed-source"
CMUX_CUA_SOURCE_OWNER_VALUE="cmux-cua-cache-v2 $CMUX_CUA_PINNED_SHA"
CMUX_CUA_HELPER_OWNER_FILE=".cmux-cua-managed-helper"
CMUX_CUA_HELPER_OWNER_VALUE="cmux-cua-helper-v2"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

OUTPUT=""
ARCHS_RAW=""
PRINT_HELPER_ID=""
CACHE_DIR="${CMUX_CUA_CACHE_DIR:-${HOME:-/tmp}/Library/Caches/cmux/cmux-cua}"

helper_bundle_id_for_host() {
  # cmux-cua owns one stable TCC identity. Tag isolation comes from the
  # installed path, socket, credential, and state scope—not from minting a new
  # permission row for every host bundle.
  echo "com.cmuxterm.cua"
}

validate_replaceable_helper_bundle() {
  local helper_app="$1"
  local expected_id="$2"
  local expected_executable="$3"
  local owner_value
  local existing_id
  local existing_executable

  if [[ ! -e "$helper_app" && ! -L "$helper_app" ]]; then
    return 0
  fi
  if [[ -L "$helper_app" || ! -d "$helper_app" ]]; then
    echo "error: refusing to replace non-directory or symlinked helper bundle: $helper_app" >&2
    exit 1
  fi

  owner_value="$(cat "$helper_app/Contents/Resources/$CMUX_CUA_HELPER_OWNER_FILE" 2>/dev/null || true)"
  if [[ "$owner_value" == "$CMUX_CUA_HELPER_OWNER_VALUE" ]]; then
    return 0
  fi

  # Adopt helper bundles produced before the ownership marker existed only
  # when their exact TCC identity and executable prove they are our generated
  # build output. Never remove an arbitrary directory merely because it lives
  # at the computed output path.
  existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$helper_app/Contents/Info.plist" 2>/dev/null || true)"
  existing_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$helper_app/Contents/Info.plist" 2>/dev/null || true)"
  local legacy_id=false
  case "$existing_id" in
    com.cmuxterm.*.computer-use|com.cmuxterm.app.computer-use)
      legacy_id=true
      ;;
  esac
  if [[ ("$existing_id" == "$expected_id" || "$legacy_id" == true) \
        && ("$existing_executable" == "$expected_executable" \
            || "$existing_executable" == "cmux Computer Use") ]]; then
    return 0
  fi

  echo "error: refusing to replace unmanaged helper bundle: $helper_app" >&2
  echo "  move it aside or remove it manually, then rerun the build" >&2
  exit 1
}

usage() {
  cat <<'USAGE' >&2
usage: scripts/build-cmux-cua.sh --output <path> [options]

Options:
  --archs "<archs>"     architectures to build (default: "arm64 x86_64")
  --cache-dir <path>    clone/build cache dir (default: ~/Library/Caches/cmux/cmux-cua)
  --print-helper-id <host-bundle-id>
                         Print the TCC-facing helper identity and exit
  -h, --help            show this help

Environment:
  CMUX_CUA_SRC          existing cmux-cua checkout to read instead of cloning/fetching
  CMUX_CUA_CACHE_DIR    default cache dir override
  CMUX_CUA_REPO_URL     repo URL override, defaults to manaflow-ai/cmux-cua
USAGE
}

while (($#)); do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      OUTPUT="$2"
      shift 2
      ;;
    --archs)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      ARCHS_RAW="$2"
      shift 2
      ;;
    --cache-dir)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      CACHE_DIR="$2"
      shift 2
      ;;
    --print-helper-id)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      PRINT_HELPER_ID="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -n "$PRINT_HELPER_ID" ]]; then
  helper_bundle_id_for_host "$PRINT_HELPER_ID"
  exit 0
fi

if [[ -z "$OUTPUT" ]]; then
  echo "error: --output is required" >&2
  usage
  exit 2
fi

if [[ -z "$ARCHS_RAW" ]]; then
  ARCHS_RAW="arm64 x86_64"
fi

read -r -a ARCHS <<<"$ARCHS_RAW"
if ((${#ARCHS[@]} == 0)); then
  echo "error: no architectures requested" >&2
  exit 1
fi

command -v git >/dev/null 2>&1 || { echo "error: git is required" >&2; exit 1; }
command -v cargo >/dev/null 2>&1 || {
  echo "error: cargo is required to build the bundled cmux-cua" >&2
  echo "  local dev: install Rust via rustup (https://rustup.rs or \`brew install rustup && rustup-init\`)" >&2
  echo "  CI: run scripts/install-rust-ci.sh" >&2
  exit 1
}

mkdir -p "$CACHE_DIR"

# One trap handles both the source lock (released early, before compile) and
# the scratch build dir.
SRC_LOCK_DIR=""
TMPDIR_BUILD=""
TMPDIR_CLONE=""
cleanup() {
  [[ -n "$TMPDIR_BUILD" ]] && rm -rf "$TMPDIR_BUILD"
  [[ -n "$TMPDIR_CLONE" ]] && rm -rf "$TMPDIR_CLONE"
  [[ -n "$SRC_LOCK_DIR" ]] && rm -rf "$SRC_LOCK_DIR"
  # The src lock is released (SRC_LOCK_DIR="") before compiling, so the test
  # above normally fails last; without an explicit success status the EXIT
  # trap propagates 1 under set -e and fails the Xcode phase script even
  # though the build succeeded.
  return 0
}
trap cleanup EXIT

# Serialize source materialization across parallel builds (concurrent tagged
# reloads build simultaneously). mkdir is atomic; the pid file lets a waiter
# reclaim a lock whose owner died. The lock only needs to cover git mutation:
# the source dir is keyed by the pinned SHA, so once materialized its contents
# are stable per key, and concurrent cargo builds already serialize on Cargo's
# own target-dir lock.
acquire_src_lock() {
  local lock_dir="$1"
  local waited=0
  until mkdir "$lock_dir" 2>/dev/null; do
    local owner
    owner="$(cat "$lock_dir/pid" 2>/dev/null || true)"
    if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then
      # Reclaim a dead owner's lock ATOMICALLY: rename first, then delete.
      # Only one waiter can win the rename, so a second waiter acting on the
      # same stale observation cannot delete the lock a new owner has since
      # created (an rm -rf here raced exactly that way). A microscopic
      # window remains (dead-observe -> full steal+reacquire by another
      # waiter -> our rename), but the fallout is bounded: both builds
      # materialize the same pinned tree, so the worst case is one build
      # failing loudly on git index contention.
      if /bin/mv "$lock_dir" "$lock_dir.stale.$$" 2>/dev/null; then
        rm -rf "$lock_dir.stale.$$"
      fi
      continue
    fi
    if (( waited >= 300 )); then
      echo "error: timed out waiting for cmux-cua source lock at $lock_dir" >&2
      echo "  if no other build is running, remove it manually: rm -rf '$lock_dir'" >&2
      exit 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  SRC_LOCK_DIR="$lock_dir"
  echo "$$" > "$lock_dir/pid"
}

release_src_lock() {
  [[ -n "$SRC_LOCK_DIR" ]] && rm -rf "$SRC_LOCK_DIR"
  SRC_LOCK_DIR=""
}

validate_managed_source_cache() {
  local expected_name="src-$CMUX_CUA_PINNED_SHA"
  local resolved_cache
  local resolved_source
  local owner_value

  if [[ -L "$SRC_ROOT" ]]; then
    echo "error: refusing symlinked cmux-cua source cache: $SRC_ROOT" >&2
    exit 1
  fi
  resolved_cache="$(cd "$CACHE_DIR" && pwd -P)"
  resolved_source="$(cd "$SRC_ROOT" && pwd -P)"
  if [[ "$(dirname "$resolved_source")" != "$resolved_cache" || "$(basename "$resolved_source")" != "$expected_name" ]]; then
    echo "error: refusing cmux-cua source outside its exact cache slot: $SRC_ROOT" >&2
    exit 1
  fi

  owner_value="$(cat "$SRC_ROOT/$CMUX_CUA_SOURCE_OWNER_FILE" 2>/dev/null || true)"
  if [[ "$owner_value" != "$CMUX_CUA_SOURCE_OWNER_VALUE" ]]; then
    echo "error: refusing unmanaged cmux-cua source cache: $SRC_ROOT" >&2
    echo "  move it aside or remove it manually, then rerun the build" >&2
    exit 1
  fi
}

adopt_legacy_source_cache() {
  local actual_sha
  local origin_url
  local unexpected_changes

  # Older versions stamped their own source caches but did not write the
  # stronger ownership marker. Adopt only an exact, clean legacy checkout;
  # otherwise fail without changing it so a caller-controlled cache path can
  # never turn an unrelated repository into destructive build scratch space.
  [[ -e "$SRC_ROOT/.cmux-last-used" ]] || return 1
  actual_sha="$(git -C "$SRC_ROOT" rev-parse HEAD 2>/dev/null || true)"
  origin_url="$(git -C "$SRC_ROOT" remote get-url origin 2>/dev/null || true)"
  [[ "$actual_sha" == "$CMUX_CUA_PINNED_SHA" ]] || return 1
  [[ "$origin_url" == "$CMUX_CUA_REPO_URL" ]] || return 1
  unexpected_changes="$(
    git -C "$SRC_ROOT" status --porcelain --untracked-files=all -- \
      . \
      ':(exclude).cmux-last-used' \
      ':(exclude).cmux-cargo-target' \
      2>/dev/null
  )"
  [[ -z "$unexpected_changes" ]] || return 1

  printf '%s\n' "$CMUX_CUA_SOURCE_OWNER_VALUE" > "$SRC_ROOT/$CMUX_CUA_SOURCE_OWNER_FILE"
}

if [[ -n "${CMUX_CUA_SRC:-}" ]]; then
  SRC_ROOT="$(cd "$CMUX_CUA_SRC" && pwd)"
  # rev-parse instead of testing .git's file type: linked git worktrees store
  # .git as a FILE with a gitdir: pointer, and they are a normal way to hold a
  # local cmux-cua checkout.
  if ! git -C "$SRC_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error: CMUX_CUA_SRC is not a git checkout: $SRC_ROOT" >&2
    exit 1
  fi
else
  # Key the source dir by the pinned SHA so checkouts pinning different
  # commits never mutate each other's verified sources, and a tree that passed
  # the SHA gate below cannot change underneath another invocation's compile.
  SRC_ROOT="$CACHE_DIR/src-$CMUX_CUA_PINNED_SHA"
  acquire_src_lock "$SRC_ROOT.lock"
  if [[ ! -d "$SRC_ROOT/.git" ]]; then
    if [[ -e "$SRC_ROOT" || -L "$SRC_ROOT" ]]; then
      echo "error: refusing to replace existing cmux-cua cache path: $SRC_ROOT" >&2
      echo "  move it aside or remove it manually, then rerun the build" >&2
      exit 1
    fi
    TMPDIR_CLONE="$(mktemp -d "$CACHE_DIR/.cmux-cua-clone.XXXXXX")"
    git clone "$CMUX_CUA_REPO_URL" "$TMPDIR_CLONE"
    printf '%s\n' "$CMUX_CUA_SOURCE_OWNER_VALUE" > "$TMPDIR_CLONE/$CMUX_CUA_SOURCE_OWNER_FILE"
    /bin/mv "$TMPDIR_CLONE" "$SRC_ROOT"
    TMPDIR_CLONE=""
  elif [[ ! -f "$SRC_ROOT/$CMUX_CUA_SOURCE_OWNER_FILE" ]]; then
    adopt_legacy_source_cache || {
      echo "error: refusing unmanaged cmux-cua source cache: $SRC_ROOT" >&2
      echo "  move it aside or remove it manually, then rerun the build" >&2
      exit 1
    }
  fi
  validate_managed_source_cache
  # Fetch only when the pinned commit is missing locally so incremental app
  # builds keep working offline (or through GitHub outages) after the first
  # successful build.
  if ! git -C "$SRC_ROOT" cat-file -e "$CMUX_CUA_PINNED_SHA^{commit}" 2>/dev/null; then
    git -C "$SRC_ROOT" fetch --quiet origin "$CMUX_CUA_PINNED_SHA"
  fi
  # Materialize the exact pinned tree. A plain `checkout --detach` at the
  # already-checked-out commit silently keeps modified tracked files, so a
  # tampered cache would still pass the rev-parse check below while its edits
  # get compiled, signed, and bundled. `--force` restores tracked files to the
  # pinned contents and `clean -fdx` drops untracked/ignored files. This is
  # safe only after the ownership and exact-path checks above. Keep cmux's
  # ownership metadata, usage stamp, and per-revision Cargo target dir (build
  # OUTPUT, never compiled source).
  git -C "$SRC_ROOT" checkout --quiet --force --detach "$CMUX_CUA_PINNED_SHA"
  git -C "$SRC_ROOT" clean -qfdx \
    -e "$CMUX_CUA_SOURCE_OWNER_FILE" \
    -e .cmux-last-used \
    -e .cmux-cargo-target
  touch "$SRC_ROOT/.cmux-last-used"
fi

ACTUAL_SHA="$(git -C "$SRC_ROOT" rev-parse HEAD)"
if [[ "$ACTUAL_SHA" != "$CMUX_CUA_PINNED_SHA" ]]; then
  echo "error: cmux-cua checkout is at $ACTUAL_SHA, expected $CMUX_CUA_PINNED_SHA" >&2
  exit 1
fi
release_src_lock

CARGO_ROOT="$SRC_ROOT/libs/cmux-cua/rust"
if [[ ! -f "$CARGO_ROOT/Cargo.toml" ]]; then
  echo "error: cmux-cua Cargo workspace not found at $CARGO_ROOT" >&2
  exit 1
fi

TMPDIR_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/cmux-cua-build.XXXXXX")"

mkdir -p "$(dirname "$OUTPUT")"

ensure_rust_target() {
  local target="$1"
  if command -v rustup >/dev/null 2>&1; then
    if ! rustup target list --installed | grep -qx "$target"; then
      rustup target add "$target"
    fi
  fi
}

BUILT=()
for arch in "${ARCHS[@]}"; do
  case "$arch" in
    arm64|aarch64)
      arch="arm64"
      target="aarch64-apple-darwin"
      ;;
    x86_64|amd64)
      arch="x86_64"
      target="x86_64-apple-darwin"
      ;;
    *)
      echo "error: unsupported architecture: $arch" >&2
      exit 1
      ;;
  esac

  ensure_rust_target "$target"
  # The Cargo target dir lives INSIDE the per-revision source dir (excluded
  # from `git clean`), never in a slot shared across revisions or source
  # paths: `$target/release/cmux-cua` is a single uplift destination, and
  # with a shared dir a "fresh" build of pin A can leave pin B's (or a dirty
  # CMUX_CUA_SRC checkout's) binary in place, defeating the SHA gate. Keying
  # by source dir prevents cross-revision reuse. Concurrent builds of one
  # revision serialize on Cargo's own lock.
  target_dir="$SRC_ROOT/.cmux-cargo-target"
  CARGO_TARGET_DIR="$target_dir" \
    cargo build --manifest-path "$CARGO_ROOT/Cargo.toml" --locked -p cmux-cua --release --target "$target"
  arch_output="$TMPDIR_BUILD/cmux-cua-$arch"
  cp "$target_dir/$target/release/cmux-cua" "$arch_output"
  BUILT+=("$arch_output")
done

if ((${#BUILT[@]} == 1)); then
  cp "${BUILT[0]}" "$OUTPUT"
else
  /usr/bin/lipo -create "${BUILT[@]}" -output "$OUTPUT"
fi
chmod 0755 "$OUTPUT"

# Strip debug and local symbols before signing: the release cmux-cua is
# ~12MB with ~29k symbols unstripped, which otherwise ships in the DMG and
# the installed app for no runtime benefit.
/usr/bin/strip -Sx "$OUTPUT"
/usr/bin/codesign --force --sign - --timestamp=none "$OUTPUT"
/usr/bin/codesign --verify --strict "$OUTPUT"

# MIT compliance: the upstream license and copyright notice must accompany
# every redistributed copy of the cmux-cua engine. Take it from the pinned checkout so
# the shipped notice always matches the code it covers, and fail loudly if it
# ever disappears upstream rather than shipping unattributed.
CUA_LICENSE_SRC="$SRC_ROOT/LICENSE.md"
if [[ ! -f "$CUA_LICENSE_SRC" ]]; then
  echo "error: cmux-cua LICENSE.md not found at $CUA_LICENSE_SRC" >&2
  echo "  the bundled cmux-cua cannot ship without its MIT notice" >&2
  exit 1
fi
cp "$CUA_LICENSE_SRC" "$(dirname "$OUTPUT")/cmux-cua-LICENSE.md"

# Package the cmux-cua engine into a branded helper with its own bundle identifier and
# TCC identity. The helper is copied out of the host bundle before launch; that
# top-level copy is what macOS shows in Accessibility and Screen Recording.
_cua_bin_dir="$(cd "$(dirname "$OUTPUT")" && pwd -P)"
_cua_contents="$(cd "$_cua_bin_dir/../.." 2>/dev/null && pwd -P || true)"
if [ -n "${_cua_contents:-}" ] && [ "$(basename "$_cua_contents")" = "Contents" ]; then
  HELPER_APP="$_cua_contents/Library/cmux Computer Use.app"
  HELPER_EXECUTABLE="cmux-cua"
  # This build phase runs before Xcode writes the processed host Info.plist.
  # Prefer exported build settings; reading a missing plist makes PlistBuddy
  # print "File Doesn't Exist, Will Create" on stdout and corrupts the helper
  # identity with that message.
  _host_id="${PRODUCT_BUNDLE_IDENTIFIER:-}"
  if [ -z "$_host_id" ] && [ -f "$_cua_contents/Info.plist" ]; then
    _host_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$_cua_contents/Info.plist" 2>/dev/null || true)"
  fi
  [ -n "$_host_id" ] || _host_id="com.cmuxterm.app"
  HELPER_ID="$(helper_bundle_id_for_host "$_host_id")"
  # Keep the TCC-facing product name stable across release, tests, and tagged
  # dogfood builds. Runtime isolation comes from the tag-scoped install path,
  # socket, credential, and state directory.
  HELPER_DISPLAY="${CMUX_CUA_HELPER_DISPLAY_NAME:-cmux Computer Use}"
  validate_replaceable_helper_bundle "$HELPER_APP" "$HELPER_ID" "$HELPER_EXECUTABLE"
  /bin/rm -rf -- "$HELPER_APP"
  mkdir -p \
    "$HELPER_APP/Contents/MacOS" \
    "$HELPER_APP/Contents/Resources/en.lproj" \
    "$HELPER_APP/Contents/Resources/ja.lproj"
  printf '%s\n' "$CMUX_CUA_HELPER_OWNER_VALUE" > "$HELPER_APP/Contents/Resources/$CMUX_CUA_HELPER_OWNER_FILE"
  cp "$OUTPUT" "$HELPER_APP/Contents/MacOS/$HELPER_EXECUTABLE"
  chmod 0755 "$HELPER_APP/Contents/MacOS/$HELPER_EXECUTABLE"
  # The helper bundle is copied out of the host app before launch, so it must
  # carry its own copy of the upstream MIT notice.
  cp "$CUA_LICENSE_SRC" "$HELPER_APP/Contents/Resources/LICENSE.md"

  _helper_icon="$REPO_ROOT/Resources/ComputerUseHelperIcon.icns"
  if [ -f "$_helper_icon" ]; then
    cp "$_helper_icon" "$HELPER_APP/Contents/Resources/AppIcon.icns"
  elif [ -f "$_cua_contents/Resources/AppIcon.icns" ]; then
    cp "$_cua_contents/Resources/AppIcon.icns" "$HELPER_APP/Contents/Resources/AppIcon.icns"
  elif [ -f "$_cua_contents/Resources/AppIcon-Debug.icns" ]; then
    cp "$_cua_contents/Resources/AppIcon-Debug.icns" "$HELPER_APP/Contents/Resources/AppIcon.icns"
  fi

  cat > "$HELPER_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${HELPER_DISPLAY}</string>
  <key>CFBundleDisplayName</key><string>${HELPER_DISPLAY}</string>
  <key>CFBundleIdentifier</key><string>${HELPER_ID}</string>
  <key>CFBundleExecutable</key><string>${HELPER_EXECUTABLE}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSEnvironment</key>
  <dict>
    <key>CMUX_CUA_PERMISSIONS_GATE</key><string>0</string>
    <key>CMUX_CUA_EXTERNAL_PERMISSION_FLOW</key><string>1</string>
    <key>CMUX_CUA_TELEMETRY_ENABLED</key><string>false</string>
    <key>CMUX_CUA_UPDATE_CHECK</key><string>false</string>
  </dict>
  <key>NSAccessibilityUsageDescription</key><string>${HELPER_DISPLAY} controls apps only when you ask an agent to use Computer Use.</string>
  <key>NSScreenCaptureUsageDescription</key><string>${HELPER_DISPLAY} sees app windows only when you ask an agent to use Computer Use.</string>
</dict>
</plist>
PLIST
  cat > "$HELPER_APP/Contents/Resources/en.lproj/InfoPlist.strings" <<STRINGS
"CFBundleDisplayName" = "${HELPER_DISPLAY}";
"NSAccessibilityUsageDescription" = "${HELPER_DISPLAY} controls apps only when you ask an agent to use Computer Use.";
"NSScreenCaptureUsageDescription" = "${HELPER_DISPLAY} sees app windows only when you ask an agent to use Computer Use.";
STRINGS
  cat > "$HELPER_APP/Contents/Resources/ja.lproj/InfoPlist.strings" <<STRINGS
"CFBundleDisplayName" = "${HELPER_DISPLAY}";
"NSAccessibilityUsageDescription" = "${HELPER_DISPLAY}は、エージェントにComputer Useの使用を依頼した場合にのみアプリを操作します。";
"NSScreenCaptureUsageDescription" = "${HELPER_DISPLAY}は、エージェントにComputer Useの使用を依頼した場合にのみアプリのウインドウを表示します。";
STRINGS
  /usr/bin/plutil -lint "$HELPER_APP/Contents/Info.plist" >/dev/null
  # An ad-hoc signature without an explicit designated requirement collapses
  # to a CDHash-only identity. Privacy & Security records that entry but cannot
  # resolve it back to the dragged app after the helper is copied, so the row
  # stays invisible. Give tagged dev helpers a stable bundle-id requirement;
  # release signing replaces this with its stronger Developer ID requirement.
  _helper_requirement="=designated => identifier \"${HELPER_ID}\""
  /usr/bin/codesign \
    --force \
    --sign - \
    --timestamp=none \
    --identifier "$HELPER_ID" \
    --requirements "$_helper_requirement" \
    "$HELPER_APP"
  /usr/bin/codesign --verify --deep --strict "$HELPER_APP"
  echo "$HELPER_DISPLAY.app assembled at: $HELPER_APP (id $HELPER_ID)"
fi

# Launchability probe. Deliberately NOT `doctor --json`: doctor's macOS
# platform probes are mutating (they `launchctl unload` + delete a legacy
# LaunchAgent plist and remove the hard-coded /usr/local/bin/cmux-cua-update,
# which a temporary HOME does not redirect), so running it here would let an
# ordinary app build silently modify the developer's machine. Deeper MCP
# verification lives in tests/test_cmux_cua_mcp_smoke.py.
"$OUTPUT" --version >/dev/null
