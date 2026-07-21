#!/usr/bin/env bash
set -euo pipefail

CMUX_CUA_REPO_URL="${CMUX_CUA_REPO_URL:-https://github.com/manaflow-ai/cmux-cua.git}"
CMUX_CUA_PINNED_SHA="e7baba3ef2083c0692b67d977766a278896aeee6"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

OUTPUT=""
ARCHS_RAW=""
CACHE_DIR="${CMUX_CUA_CACHE_DIR:-${HOME:-/tmp}/Library/Caches/cmux/cua-driver}"

usage() {
  cat <<'USAGE' >&2
usage: scripts/build-cua-driver.sh --output <path> [options]

Options:
  --archs "<archs>"     architectures to build (default: "arm64 x86_64")
  --cache-dir <path>    clone/build cache dir (default: ~/Library/Caches/cmux/cua-driver)
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
  echo "error: cargo is required to build the bundled cua-driver" >&2
  echo "  local dev: install Rust via rustup (https://rustup.rs or \`brew install rustup && rustup-init\`)" >&2
  echo "  CI: run scripts/install-rust-ci.sh" >&2
  exit 1
}

mkdir -p "$CACHE_DIR"

# One trap handles both the source lock (released early, before compile) and
# the scratch build dir.
SRC_LOCK_DIR=""
TMPDIR_BUILD=""
cleanup() {
  [[ -n "$TMPDIR_BUILD" ]] && rm -rf "$TMPDIR_BUILD"
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
      echo "error: timed out waiting for cua-driver source lock at $lock_dir" >&2
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
    rm -rf "$SRC_ROOT"
    git clone "$CMUX_CUA_REPO_URL" "$SRC_ROOT"
  fi
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
  # pinned contents and `clean -fdx` drops untracked/ignored files, keeping
  # only cmux's own metadata: the usage stamp and the per-revision Cargo
  # target dir (build OUTPUT, never compiled source).
  git -C "$SRC_ROOT" checkout --quiet --force --detach "$CMUX_CUA_PINNED_SHA"
  git -C "$SRC_ROOT" clean -qfdx -e .cmux-last-used -e .cmux-cargo-target
  # Bound the cache: each pin bump creates a new src-<sha> dir, so prune
  # sibling revisions (sources plus their embedded Cargo targets) that have
  # been idle for 7+ days. The stamp is refreshed on every build of a
  # revision, and a concurrent build of another pin is protected twice over:
  # its fresh stamp fails the idle check, and pruning requires acquiring that
  # revision's own lock.
  touch "$SRC_ROOT/.cmux-last-used"
  for old_src in "$CACHE_DIR"/src-*; do
    [[ -d "$old_src" ]] || continue
    [[ "$old_src" == "$SRC_ROOT" || "$old_src" == *.lock ]] && continue
    # Only delete directories cmux itself created: the stamp is written by
    # this script on every build. CACHE_DIR is caller-controlled
    # (--cache-dir / CMUX_CUA_CACHE_DIR), so an unmarked src-* dir may be an
    # unrelated source tree and must never be pruned automatically.
    stamp="$old_src/.cmux-last-used"
    [[ -e "$stamp" ]] || continue
    [[ -n "$(find "$stamp" -maxdepth 0 -mtime +7 2>/dev/null)" ]] || continue
    if mkdir "$old_src.lock" 2>/dev/null; then
      rm -rf "$old_src"
      rm -rf "$old_src.lock"
    fi
  done
fi

ACTUAL_SHA="$(git -C "$SRC_ROOT" rev-parse HEAD)"
if [[ "$ACTUAL_SHA" != "$CMUX_CUA_PINNED_SHA" ]]; then
  echo "error: cmux-cua checkout is at $ACTUAL_SHA, expected $CMUX_CUA_PINNED_SHA" >&2
  exit 1
fi
release_src_lock

CARGO_ROOT="$SRC_ROOT/libs/cua-driver/rust"
if [[ ! -f "$CARGO_ROOT/Cargo.toml" ]]; then
  echo "error: cua-driver Cargo workspace not found at $CARGO_ROOT" >&2
  exit 1
fi

TMPDIR_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/cmux-cua-driver.XXXXXX")"

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
  # paths: `$target/release/cua-driver` is a single uplift destination, and
  # with a shared dir a "fresh" build of pin A can leave pin B's (or a dirty
  # CMUX_CUA_SRC checkout's) binary in place, defeating the SHA gate. Keying
  # by source dir also lets the idle-revision pruning above bound target
  # growth. Concurrent builds of one revision serialize on Cargo's own lock.
  target_dir="$SRC_ROOT/.cmux-cargo-target"
  CARGO_TARGET_DIR="$target_dir" \
    cargo build --manifest-path "$CARGO_ROOT/Cargo.toml" --locked -p cua-driver --release --target "$target"
  arch_output="$TMPDIR_BUILD/cmux-cua-driver-$arch"
  cp "$target_dir/$target/release/cua-driver" "$arch_output"
  BUILT+=("$arch_output")
done

if ((${#BUILT[@]} == 1)); then
  cp "${BUILT[0]}" "$OUTPUT"
else
  /usr/bin/lipo -create "${BUILT[@]}" -output "$OUTPUT"
fi
chmod 0755 "$OUTPUT"

# Strip debug and local symbols before signing: the release cua-driver is
# ~12MB with ~29k symbols unstripped, which otherwise ships in the DMG and
# the installed app for no runtime benefit.
/usr/bin/strip -Sx "$OUTPUT"
/usr/bin/codesign --force --sign - --timestamp=none "$OUTPUT"
/usr/bin/codesign --verify --strict "$OUTPUT"

# Package the driver into a branded helper with its own bundle identifier and
# TCC identity. The helper is copied out of the host bundle before launch; that
# top-level copy is what macOS shows in Accessibility and Screen Recording.
_cua_bin_dir="$(cd "$(dirname "$OUTPUT")" && pwd)"
_cua_contents="$(cd "$_cua_bin_dir/../.." 2>/dev/null && pwd || true)"
if [ -n "${_cua_contents:-}" ] && [ "$(basename "$_cua_contents")" = "Contents" ]; then
  HELPER_APP="$_cua_contents/Library/cmux Computer Use.app"
  rm -rf "$HELPER_APP"
  mkdir -p \
    "$HELPER_APP/Contents/MacOS" \
    "$HELPER_APP/Contents/Resources/en.lproj" \
    "$HELPER_APP/Contents/Resources/ja.lproj"
  cp "$OUTPUT" "$HELPER_APP/Contents/MacOS/cmux-cua-driver"
  chmod 0755 "$HELPER_APP/Contents/MacOS/cmux-cua-driver"

  _helper_icon="$REPO_ROOT/Resources/ComputerUseHelperIcon.icns"
  if [ -f "$_helper_icon" ]; then
    cp "$_helper_icon" "$HELPER_APP/Contents/Resources/AppIcon.icns"
  elif [ -f "$_cua_contents/Resources/AppIcon.icns" ]; then
    cp "$_cua_contents/Resources/AppIcon.icns" "$HELPER_APP/Contents/Resources/AppIcon.icns"
  elif [ -f "$_cua_contents/Resources/AppIcon-Debug.icns" ]; then
    cp "$_cua_contents/Resources/AppIcon-Debug.icns" "$HELPER_APP/Contents/Resources/AppIcon.icns"
  fi

  # This build phase runs before Xcode writes the processed host Info.plist.
  # Prefer exported build settings; reading a missing plist makes PlistBuddy
  # print "File Doesn't Exist, Will Create" on stdout and corrupts the helper
  # identity with that message.
  _host_id="${PRODUCT_BUNDLE_IDENTIFIER:-}"
  if [ -z "$_host_id" ] && [ -f "$_cua_contents/Info.plist" ]; then
    _host_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$_cua_contents/Info.plist" 2>/dev/null || true)"
  fi
  _host_name="${PRODUCT_NAME:-}"
  if [ -z "$_host_name" ] && [ -f "$_cua_contents/Info.plist" ]; then
    _host_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$_cua_contents/Info.plist" 2>/dev/null || true)"
  fi
  [ -n "$_host_id" ] || _host_id="com.cmuxterm.app"
  [ -n "$_host_name" ] || _host_name="cmux"
  HELPER_ID="${_host_id}.computer-use"
  HELPER_DISPLAY="${CMUX_CUA_HELPER_DISPLAY_NAME:-${_host_name} Computer Use}"
  cat > "$HELPER_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${HELPER_DISPLAY}</string>
  <key>CFBundleDisplayName</key><string>${HELPER_DISPLAY}</string>
  <key>CFBundleIdentifier</key><string>${HELPER_ID}</string>
  <key>CFBundleExecutable</key><string>cmux-cua-driver</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSEnvironment</key>
  <dict>
    <key>CUA_DRIVER_RS_PERMISSIONS_GATE</key><string>0</string>
    <key>CUA_DRIVER_RS_EXTERNAL_PERMISSION_FLOW</key><string>1</string>
    <key>CUA_DRIVER_RS_TELEMETRY_ENABLED</key><string>false</string>
    <key>CUA_DRIVER_RS_UPDATE_CHECK</key><string>false</string>
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
# LaunchAgent plist and remove the hard-coded /usr/local/bin/cua-driver-update,
# which a temporary HOME does not redirect), so running it here would let an
# ordinary app build silently modify the developer's machine. Deeper MCP
# verification lives in tests/test_cua_driver_mcp_smoke.py.
"$OUTPUT" --version >/dev/null
