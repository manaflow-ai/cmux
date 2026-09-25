#!/bin/bash
set -euo pipefail
DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
GHOSTTY_DEST="${DEST}/ghostty"
TERMINFO_DEST="${DEST}/terminfo"
CMUX_SHELL_DEST="${DEST}/shell-integration"
BIN_DEST="${DEST}/bin"
LIBEXEC_DEST="${DEST}/libexec"
SRC_SHARE="${SRCROOT}/ghostty/zig-out/share"
GHOSTTY_SRC="${SRC_SHARE}/ghostty"
TERMINFO_SRC="${SRC_SHARE}/terminfo"
FALLBACK_GHOSTTY="${SRCROOT}/Resources/ghostty"
FALLBACK_TERMINFO="${SRCROOT}/Resources/ghostty/terminfo"
TERMINFO_OVERLAY="${SRCROOT}/Resources/terminfo-overlay"
CMUX_SHELL_SRC="${SRCROOT}/Resources/shell-integration"
GHOSTTY_SHELL_SRC="${SRCROOT}/ghostty/src/shell-integration"
CMUX_GHOSTTY_ZSH_SRC="${SRCROOT}/ghostty/src/shell-integration/zsh/ghostty-integration"
BUILD_GHOSTTY_HELPER="${SRCROOT}/scripts/build-ghostty-cli-helper.sh"
GHOSTTY_HELPER_DEST="${BIN_DEST}/ghostty"
BUILD_CMUX_CUA="${SRCROOT}/scripts/build-cmux-cua.sh"
CMUX_CUA_DEST="${BIN_DEST}/cmux-cua"
CMUX_CUA_LICENSE_DEST="${BIN_DEST}/cmux-cua-LICENSE.md"
CMUX_CUA_HELPER_APP="${DEST}/../Library/cmux Computer Use.app"
CMUX_CUA_HELPER_OWNER_MARKER="${CMUX_CUA_HELPER_APP}/Contents/Resources/.cmux-cua-managed-helper"
CMUX_CUA_HELPER_EXEC="${CMUX_CUA_HELPER_APP}/Contents/MacOS/cmux-cua"
INFO_PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"

run_git() (
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
  command git "$@"
)

update_commit() {
  local commit
  commit="$(run_git -C "${SRCROOT}" rev-parse --short=9 HEAD 2>/dev/null || true)"
  if [ -n "$commit" ] && [ -f "$INFO_PLIST" ]; then
    /usr/libexec/PlistBuddy -c "Set :CMUXCommit $commit" "$INFO_PLIST" >/dev/null 2>&1 || /usr/libexec/PlistBuddy -c "Add :CMUXCommit string $commit" "$INFO_PLIST" >/dev/null 2>&1 || true
  fi
}

fingerprint_tool() {
  local label="$1"
  shift
  local version
  version="$("$@" 2>/dev/null || true)"
  printf '%s=%s\n' "$label" "$version"
}

fingerprint_toolchain() {
  local zig_path
  if [ -n "${CMUX_ZIG:-}" ]; then
    zig_path="$CMUX_ZIG"
    printf 'zig-path=%s\n' "$zig_path"
    if [ -x "$zig_path" ]; then
      fingerprint_tool zig-version "$zig_path" version
    else
      printf 'zig-version=missing\n'
    fi
  else
    for zig_path in /opt/homebrew/bin/zig /usr/local/bin/zig "$(command -v zig 2>/dev/null || true)"; do
      [ -n "$zig_path" ] || continue
      if [ -x "$zig_path" ]; then
        printf 'zig-path=%s\n' "$zig_path"
        fingerprint_tool zig-version "$zig_path" version
      fi
    done
  fi
  fingerprint_tool rustc-version rustc --version
  fingerprint_tool cargo-version cargo --version
  for variable in \
    RUSTFLAGS CARGO_BUILD_RUSTFLAGS CARGO_ENCODED_RUSTFLAGS \
    RUSTUP_TOOLCHAIN RUSTC RUSTC_WRAPPER \
    CARGO_PROFILE_RELEASE_OPT_LEVEL CARGO_PROFILE_RELEASE_LTO \
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS \
    CARGO_TARGET_AARCH64_APPLE_DARWIN_RUSTFLAGS \
    CARGO_TARGET_X86_64_APPLE_DARWIN_RUSTFLAGS; do
    printf 'env-%s=%s\n' "$variable" "${!variable-}"
  done
}

STAMP="${DERIVED_FILE_DIR}/cmux-bundled-resources.stamp"
OUTPUT_MANIFEST="${DERIVED_FILE_DIR}/cmux-bundled-resources.outputs"

# This phase also runs when Xcode's dependency graph is conservative. Keep the
# expensive helper builds incremental inside the phase by keying the output to
# every source that the phase copies or compiles, plus the build architecture.
hash_tree() {
  local path="$1"
  if [ -L "$path" ]; then
    printf 'symlink:%s -> %s\n' "$path" "$(readlink "$path")"
    if [ -f "$path" ]; then
      shasum "$path"
    fi
  elif [ -d "$path" ]; then
    printf 'dir:%s\n' "$path"
    # One shasum per batch, not per file: this runs on every build, and a process
    # per file costs more than the helper rebuilds the stamp exists to skip.
    # Symlinks are rare, so they keep their own readlink line.
    find -P "$path" -type f -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 shasum
    find -P "$path" -type l -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r file; do
      printf 'symlink:%s -> %s\n' "$file" "$(readlink "$file")"
    done
  elif [ -f "$path" ]; then
    printf 'file:%s\n' "$path"
    shasum "$path"
  else
    printf 'missing:%s\n' "$path"
  fi
}

hash_git_worktree() {
  local repo="$1"
  if [ ! -d "$repo" ]; then
    printf 'missing-git:%s\n' "$repo"
    return
  fi
  # HEAD identifies every clean tracked file, so only the differences from it need
  # content hashing. Hashing each tracked file instead took ~45 s per build for the
  # ~5,900 files in the Ghostty submodule.
  printf 'head=%s\n' "$(run_git -C "$repo" rev-parse HEAD 2>/dev/null || echo unknown)"
  run_git -C "$repo" diff --binary HEAD 2>/dev/null || true
  (cd "$repo" && run_git ls-files --others --exclude-standard -z 2>/dev/null | xargs -0 shasum) || true
}

output_fingerprint() {
  {
    hash_swiftpm_resource_bundles "$DEST"
    hash_swiftpm_resource_bundles "$BIN_DEST"
    hash_tree "$GHOSTTY_DEST"
    hash_tree "$TERMINFO_DEST"
    hash_tree "$CMUX_SHELL_DEST"
    hash_tree "$GHOSTTY_HELPER_DEST"
    hash_tree "$CMUX_CUA_DEST"
    hash_tree "$CMUX_CUA_LICENSE_DEST"
    if [ -d "$CMUX_CUA_HELPER_APP" ]; then
      hash_tree "$CMUX_CUA_HELPER_APP"
    else
      printf 'missing:%s\n' "$CMUX_CUA_HELPER_APP"
    fi
  } | shasum | awk '{print $1}'
}

# SwiftPM places a package's processed resource bundle beside the app's other
# resources. The bundled CLI lives one directory deeper in Resources/bin, and
# Bundle.module resolves relative to that executable's resource directory.
# Keep a real copy beside the CLI so package resources work when the CLI is
# invoked directly from the app bundle. This is intentionally generic: adding
# resources to another package must not require another packaging allowlist.
hash_swiftpm_resource_bundles() {
  local directory="$1" bundle
  [ -d "$directory" ] || return 0
  for bundle in "$directory"/*.bundle; do
    [ -d "$bundle" ] || continue
    hash_tree "$bundle"
  done
}

sync_swiftpm_resource_bundles() {
  local source name destination
  mkdir -p "$BIN_DEST"
  for source in "$DEST"/*.bundle; do
    [ -d "$source" ] || continue
    name="${source##*/}"
    destination="$BIN_DEST/$name"
    mkdir -p "$destination"
    rsync -a --delete "$source/" "$destination/"
  done

  # Remove copies of package bundles that disappeared from the app resource
  # directory, while leaving unrelated helper directories in Resources/bin.
  for destination in "$BIN_DEST"/*.bundle; do
    [ -d "$destination" ] || continue
    name="${destination##*/}"
    [ -d "$DEST/$name" ] || rm -rf "$destination"
  done
}

fingerprint="$({
  printf 'archs=%s\n' "${ARCHS:-}"
  printf 'configuration=%s\n' "${CONFIGURATION:-}"
  printf 'sdk=%s\n' "${SDKROOT:-}"
  printf 'deployment=%s\n' "${MACOSX_DEPLOYMENT_TARGET:-}"
  printf 'cmux-cua-src=%s\n' "${CMUX_CUA_SRC:-}"
  printf 'cmux-cua-repo=%s\n' "${CMUX_CUA_REPO_URL:-}"
  printf 'skip-zig=%s\n' "${CMUX_SKIP_ZIG_BUILD:-}"
  printf 'cmux-zig=%s\n' "${CMUX_ZIG:-}"
  printf 'zig-required=%s\n' "${ZIG_REQUIRED:-}"
  fingerprint_toolchain
  printf 'helper-display=%s\n' "${CMUX_CUA_HELPER_DISPLAY_NAME:-}"
  printf 'bundle-id=%s\n' "${PRODUCT_BUNDLE_IDENTIFIER:-}"
  hash_git_worktree "${SRCROOT}/ghostty"
  hash_swiftpm_resource_bundles "$DEST"
  if [ -n "${CMUX_CUA_SRC:-}" ]; then
    hash_git_worktree "${CMUX_CUA_SRC}"
  fi
  hash_tree "${SRCROOT}/scripts/build-app-bundled-resources.sh"
  hash_tree "$BUILD_GHOSTTY_HELPER"
  hash_tree "$BUILD_CMUX_CUA"
  hash_tree "$GHOSTTY_SRC"
  hash_tree "$FALLBACK_GHOSTTY"
  hash_tree "$TERMINFO_SRC"
  hash_tree "$FALLBACK_TERMINFO"
  hash_tree "$TERMINFO_OVERLAY"
  hash_tree "$CMUX_SHELL_SRC"
  hash_tree "$GHOSTTY_SHELL_SRC"
  hash_tree "$CMUX_GHOSTTY_ZSH_SRC"
  hash_tree "${SRCROOT}/Resources/ComputerUseHelperIcon.icns"
  hash_tree "${SRCROOT}/Resources/AppIcon.icns"
  hash_tree "${SRCROOT}/Resources/AppIcon-Debug.icns"
} | shasum | awk '{print $1}')"
output_fingerprint_value="$(output_fingerprint)"

helper_output_ok=true
if [[ "$DEST" == *.app/Contents/Resources ]] && {
  [ ! -d "$CMUX_CUA_HELPER_APP" ] ||
  [ ! -f "$CMUX_CUA_HELPER_APP/Contents/Info.plist" ] ||
  [ ! -f "$CMUX_CUA_HELPER_OWNER_MARKER" ] ||
  [ ! -x "$CMUX_CUA_HELPER_EXEC" ]
}; then
  helper_output_ok=false
fi
if [ -f "$STAMP" ] && [ -x "$GHOSTTY_HELPER_DEST" ] && [ -x "$CMUX_CUA_DEST" ] \
  && [ "$helper_output_ok" = true ] && [ -f "$CMUX_CUA_LICENSE_DEST" ] \
  && [ -d "$GHOSTTY_DEST" ] && [ -d "$TERMINFO_DEST" ] \
  && [ -d "$CMUX_SHELL_DEST" ] && [ -f "$INFO_PLIST" ] \
  && [ -f "$OUTPUT_MANIFEST" ] \
  && [ "$(cat "$STAMP")" = "$fingerprint" ] \
  && [ "$(cat "$OUTPUT_MANIFEST")" = "$output_fingerprint_value" ]; then
  update_commit
  echo "Bundled resources unchanged; skipping helper rebuilds"
  exit 0
fi
mkdir -p "$BIN_DEST" "$LIBEXEC_DEST"
sync_swiftpm_resource_bundles
if [ -d "$GHOSTTY_SRC" ]; then
  mkdir -p "$GHOSTTY_DEST"
  rsync -a --delete "$GHOSTTY_SRC/" "$GHOSTTY_DEST/"
elif [ -d "$FALLBACK_GHOSTTY" ]; then
  mkdir -p "$GHOSTTY_DEST"
  rsync -a --delete "$FALLBACK_GHOSTTY/" "$GHOSTTY_DEST/"
else
  rm -rf "$GHOSTTY_DEST"
fi
if [ ! -d "$GHOSTTY_SHELL_SRC" ]; then
  echo "error: missing Ghostty shell integration resources at $GHOSTTY_SHELL_SRC" >&2
  exit 1
fi
mkdir -p "$GHOSTTY_DEST/shell-integration"
rsync -a --delete "$GHOSTTY_SHELL_SRC/" "$GHOSTTY_DEST/shell-integration/"
if [ -d "$TERMINFO_SRC" ]; then
  mkdir -p "$TERMINFO_DEST"
  rsync -a --delete "$TERMINFO_SRC/" "$TERMINFO_DEST/"
elif [ -d "$FALLBACK_TERMINFO" ]; then
  mkdir -p "$TERMINFO_DEST"
  rsync -a --delete "$FALLBACK_TERMINFO/" "$TERMINFO_DEST/"
else
  rm -rf "$TERMINFO_DEST"
fi
# Overlay any cmux-specific terminfo adjustments.
# This intentionally does not use --delete so we only patch specific entries.
if [ -d "$TERMINFO_OVERLAY" ]; then
  mkdir -p "$TERMINFO_DEST"
  rsync -a "$TERMINFO_OVERLAY/" "$TERMINFO_DEST/"
fi
if [ -d "$CMUX_SHELL_SRC" ]; then
  mkdir -p "$CMUX_SHELL_DEST"
  # Use '/.' so dotfiles like .zshenv/.zprofile are copied too.
  rsync -a --delete "$CMUX_SHELL_SRC/." "$CMUX_SHELL_DEST/"
else
  rm -rf "$CMUX_SHELL_DEST"
fi
if [ -f "$CMUX_GHOSTTY_ZSH_SRC" ]; then
  mkdir -p "$CMUX_SHELL_DEST"
  rsync -a "$CMUX_GHOSTTY_ZSH_SRC" "$CMUX_SHELL_DEST/ghostty-integration.zsh"
fi
if [ ! -x "$BUILD_GHOSTTY_HELPER" ]; then
  echo "error: missing Ghostty CLI helper build script at $BUILD_GHOSTTY_HELPER" >&2
  exit 1
fi
ARCHS_LIST=" ${ARCHS:-} "
HAS_ARM64=0
HAS_X86_64=0
GHOSTTY_HELPER_TARGET=""
case "$ARCHS_LIST" in
  *" arm64 "*) HAS_ARM64=1 ;;
esac
case "$ARCHS_LIST" in
  *" x86_64 "*) HAS_X86_64=1 ;;
esac
if [ "$HAS_ARM64" -eq 1 ] && [ "$HAS_X86_64" -eq 1 ]; then
  "$BUILD_GHOSTTY_HELPER" --universal --output "$GHOSTTY_HELPER_DEST"
elif [ "$HAS_ARM64" -eq 1 ]; then
  GHOSTTY_HELPER_TARGET="aarch64-macos"
elif [ "$HAS_X86_64" -eq 1 ]; then
  GHOSTTY_HELPER_TARGET="x86_64-macos"
fi
if [ -n "$GHOSTTY_HELPER_TARGET" ]; then
  "$BUILD_GHOSTTY_HELPER" --target "$GHOSTTY_HELPER_TARGET" --output "$GHOSTTY_HELPER_DEST"
elif [ "$HAS_ARM64" -eq 0 ] || [ "$HAS_X86_64" -eq 0 ]; then
  "$BUILD_GHOSTTY_HELPER" --output "$GHOSTTY_HELPER_DEST"
fi
if [ ! -x "$GHOSTTY_HELPER_DEST" ]; then
  echo "error: Ghostty CLI helper was not created at $GHOSTTY_HELPER_DEST" >&2
  exit 1
fi
if [ ! -x "$BUILD_CMUX_CUA" ]; then
  echo "error: missing cmux-cua build script at $BUILD_CMUX_CUA" >&2
  exit 1
fi
"$BUILD_CMUX_CUA" --output "$CMUX_CUA_DEST" --archs "${ARCHS:-}"
if [ ! -x "$CMUX_CUA_DEST" ]; then
  echo "error: cmux-cua was not created at $CMUX_CUA_DEST" >&2
  exit 1
fi
update_commit


mkdir -p "$(dirname "$STAMP")"
stamp_tmp="$(mktemp "${STAMP}.tmp.XXXXXX")"
trap 'rm -f "$stamp_tmp"' EXIT
printf '%s\n' "$fingerprint" > "$stamp_tmp"
mv -f "$stamp_tmp" "$STAMP"
manifest_tmp="$(mktemp "${OUTPUT_MANIFEST}.tmp.XXXXXX")"
trap 'rm -f "$manifest_tmp"' EXIT
output_fingerprint > "$manifest_tmp"
mv -f "$manifest_tmp" "$OUTPUT_MANIFEST"
trap - EXIT
