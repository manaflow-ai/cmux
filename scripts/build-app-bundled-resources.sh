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
CMUX_CUA_HELPER_EXEC="${DEST}/../Library/cmux Computer Use.app/Contents/MacOS/cmux-cua"
INFO_PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"

update_commit() {
  local commit
  commit="$(run_git -C "${SRCROOT}" rev-parse --short=9 HEAD 2>/dev/null || true)"
  if [ -n "$commit" ] && [ -f "$INFO_PLIST" ]; then
    /usr/libexec/PlistBuddy -c "Set :CMUXCommit $commit" "$INFO_PLIST" >/dev/null 2>&1 || /usr/libexec/PlistBuddy -c "Add :CMUXCommit string $commit" "$INFO_PLIST" >/dev/null 2>&1 || true
  fi
}

STAMP="${DERIVED_FILE_DIR}/cmux-bundled-resources.stamp"
OUTPUT_MANIFEST="${DERIVED_FILE_DIR}/cmux-bundled-resources.outputs"

# This phase also runs when Xcode's dependency graph is conservative. Keep the
# expensive helper builds incremental inside the phase by keying the output to
# every source that the phase copies or compiles, plus the build architecture.
run_git() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
    -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_PREFIX git "$@"
}
FINGERPRINT_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build-resource-fingerprint.py"
hash_tree() {
  python3 "$FINGERPRINT_HELPER" tree "$1"
}
hash_git_worktree() {
  python3 "$FINGERPRINT_HELPER" git "$1"
}

output_fingerprint() {
  {
    hash_tree "$GHOSTTY_DEST"
    hash_tree "$TERMINFO_DEST"
    hash_tree "$CMUX_SHELL_DEST"
    hash_tree "$GHOSTTY_HELPER_DEST"
    hash_tree "$CMUX_CUA_DEST"
    hash_tree "$CMUX_CUA_LICENSE_DEST"
    if [ -e "$CMUX_CUA_HELPER_EXEC" ]; then
      hash_tree "$CMUX_CUA_HELPER_EXEC"
    else
      printf 'missing:%s\n' "$CMUX_CUA_HELPER_EXEC"
    fi
  } | shasum | awk '{print $1}'
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
  printf 'helper-display=%s\n' "${CMUX_CUA_HELPER_DISPLAY_NAME:-}"
  printf 'bundle-id=%s\n' "${PRODUCT_BUNDLE_IDENTIFIER:-}"
  hash_git_worktree "${SRCROOT}/ghostty"
  if [ -n "${CMUX_CUA_SRC:-}" ]; then
    hash_git_worktree "${CMUX_CUA_SRC}"
  fi
  hash_tree "${SRCROOT}/scripts/build-app-bundled-resources.sh"
  hash_tree "$FINGERPRINT_HELPER"
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
if [[ "${CMUX_BUILD_CACHE_DIAGNOSTICS:-0}" == 1 ]]; then
  echo "Resource cache inputs: stored=$(cat "$STAMP" 2>/dev/null || true) current=$fingerprint"
  echo "Resource cache outputs: stored=$(cat "$OUTPUT_MANIFEST" 2>/dev/null || true) current=$output_fingerprint_value"
  for required in "$STAMP" "$GHOSTTY_HELPER_DEST" "$CMUX_CUA_DEST" "$CMUX_CUA_LICENSE_DEST" "$GHOSTTY_DEST" "$TERMINFO_DEST" "$CMUX_SHELL_DEST" "$INFO_PLIST" "$OUTPUT_MANIFEST" "$CMUX_CUA_HELPER_EXEC"; do
    if [ ! -e "$required" ]; then echo "Resource cache missing: $required"; fi
  done
fi

helper_output_ok=true
if [[ "$DEST" == *.app/Contents/Resources ]] && [ ! -x "$CMUX_CUA_HELPER_EXEC" ]; then
  helper_output_ok=false
fi
if [ -f "$STAMP" ] && [ -s "$GHOSTTY_HELPER_DEST" ] && [ -x "$CMUX_CUA_DEST" ] \
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
