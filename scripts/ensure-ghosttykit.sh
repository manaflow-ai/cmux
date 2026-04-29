#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

hash_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

hash_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    sha256sum "$path" | awk '{print $1}'
  fi
}

lookup_pinned_ghosttykit_sha256() {
  local ghostty_sha="$1"
  local checksums_file="$2"
  awk -v sha="$ghostty_sha" '
    $1 == sha {
      print $2
      found = 1
      exit
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "$checksums_file"
}

validate_bridge_header() {
  local path="$1"
  python3 - "$path" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
required = '#include "ghostty/include/ghostty.h"'
if required not in text:
    raise SystemExit(1)
PY
}

xcframework_is_usable() {
  local path="$1"
  [[ -d "$path" && -f "$path/Info.plist" && -f "$path/macos-arm64_x86_64/libghostty.a" ]]
}

refresh_archive_index() {
  local archive="$1"
  if [[ ! -f "$archive" ]]; then
    return 0
  fi

  echo "==> Refreshing libghostty archive index..."
  if ! command -v xcrun >/dev/null 2>&1; then
    echo "error: xcrun is required to refresh libghostty archive index." >&2
    exit 1
  fi
  if ! XCODE_RANLIB="$(xcrun --find ranlib 2>/dev/null)"; then
    echo "error: could not locate ranlib via xcrun." >&2
    exit 1
  fi
  "$XCODE_RANLIB" "$archive"
}

reuse_existing_xcframework_without_rebuild() {
  local root_xcframework="$1"
  local local_xcframework="$2"
  local source=""

  if xcframework_is_usable "$root_xcframework"; then
    source="$root_xcframework"
  elif xcframework_is_usable "$local_xcframework"; then
    source="$local_xcframework"
  else
    return 1
  fi

  if [[ "$source" != "$root_xcframework" ]]; then
    rm -rf "$root_xcframework"
    cp -R "$source" "$root_xcframework"
  fi

  refresh_archive_index "$root_xcframework/macos-arm64_x86_64/libghostty.a"
  return 0
}

if [[ ! -d "$PROJECT_DIR/ghostty" ]]; then
  echo "error: ghostty submodule is missing. Run ./scripts/setup.sh first." >&2
  exit 1
fi

if [[ ! -f "$PROJECT_DIR/ghostty/include/ghostty.h" ]]; then
  echo "error: ghostty/include/ghostty.h is missing. Run ./scripts/setup.sh first." >&2
  exit 1
fi

if ! validate_bridge_header "$PROJECT_DIR/ghostty.h"; then
  echo "error: ghostty.h no longer points at ghostty/include/ghostty.h." >&2
  echo "Restore the bridge header so Xcode uses Ghostty's canonical C API." >&2
  exit 1
fi

ROOT_XCFRAMEWORK="$PROJECT_DIR/GhosttyKit.xcframework"
LOCAL_XCFRAMEWORK="$PROJECT_DIR/ghostty/macos/GhosttyKit.xcframework"
HAS_ZIG=1
HAS_GHOSTTY_GIT=1

if ! command -v zig >/dev/null 2>&1; then
  HAS_ZIG=0
fi

if ! git -C ghostty rev-parse HEAD >/dev/null 2>&1; then
  HAS_GHOSTTY_GIT=0
fi

if [[ "$HAS_ZIG" -eq 0 || "$HAS_GHOSTTY_GIT" -eq 0 ]]; then
  if reuse_existing_xcframework_without_rebuild "$ROOT_XCFRAMEWORK" "$LOCAL_XCFRAMEWORK"; then
    if [[ "$HAS_ZIG" -eq 0 && "$HAS_GHOSTTY_GIT" -eq 0 ]]; then
      echo "==> Reusing existing GhosttyKit.xcframework (zig missing, ghostty git metadata unavailable)"
    elif [[ "$HAS_ZIG" -eq 0 ]]; then
      echo "==> Reusing existing GhosttyKit.xcframework (zig missing)"
    else
      echo "==> Reusing existing GhosttyKit.xcframework (ghostty git metadata unavailable)"
    fi
    exit 0
  fi

  if [[ "$HAS_ZIG" -eq 0 ]]; then
    echo "Error: zig is not installed." >&2
    echo "Install via: brew install zig" >&2
  fi
  if [[ "$HAS_GHOSTTY_GIT" -eq 0 ]]; then
    echo "error: ghostty git metadata is unavailable and no reusable GhosttyKit.xcframework was found." >&2
  fi
  exit 1
fi

GHOSTTY_SHA="$(git -C ghostty rev-parse HEAD)"
GHOSTTY_KEY="$GHOSTTY_SHA"
UNTRACKED_FILES="$(git -C ghostty ls-files --others --exclude-standard)"
if ! git -C ghostty diff --quiet --ignore-submodules=all HEAD -- || [[ -n "$UNTRACKED_FILES" ]]; then
  DIRTY_HASH="$(
    {
      printf 'head=%s\n' "$GHOSTTY_SHA"
      git -C ghostty diff --binary HEAD -- .
      if [[ -n "$UNTRACKED_FILES" ]]; then
        printf '\n--untracked--\n'
        while IFS= read -r path; do
          [[ -n "$path" ]] || continue
          printf 'path=%s\n' "$path"
          hash_file "$PROJECT_DIR/ghostty/$path"
        done <<< "$UNTRACKED_FILES"
      fi
    } | hash_stdin
  )"
  GHOSTTY_KEY="${GHOSTTY_SHA}-dirty-${DIRTY_HASH}"
fi

CACHE_ROOT="${CMUX_GHOSTTYKIT_CACHE_DIR:-$HOME/.cache/cmux/ghosttykit}"
CACHE_DIR="$CACHE_ROOT/$GHOSTTY_KEY"
CACHE_XCFRAMEWORK="$CACHE_DIR/GhosttyKit.xcframework"
LOCAL_KEY_STAMP="$LOCAL_XCFRAMEWORK/.ghostty_state_key"
LEGACY_LOCAL_SHA_STAMP="$LOCAL_XCFRAMEWORK/.ghostty_sha"
LOCK_DIR="$CACHE_ROOT/$GHOSTTY_KEY.lock"
GHOSTTYKIT_CHECKSUMS_FILE="${CMUX_GHOSTTYKIT_CHECKSUMS_FILE:-$SCRIPT_DIR/ghosttykit-checksums.txt}"
GHOSTTYKIT_ARCHIVE_VALIDATOR="${CMUX_GHOSTTYKIT_ARCHIVE_VALIDATOR:-$SCRIPT_DIR/validate-xcframework-archive.py}"

mkdir -p "$CACHE_ROOT"

echo "==> Ghostty build key: $GHOSTTY_KEY"

LOCK_TIMEOUT=300
LOCK_START=$SECONDS
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
  if (( SECONDS - LOCK_START > LOCK_TIMEOUT )); then
    echo "==> Lock stale (>${LOCK_TIMEOUT}s), removing and retrying..."
    rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR"
    continue
  fi
  echo "==> Waiting for GhosttyKit cache lock for $GHOSTTY_KEY..."
  sleep 1
done
trap 'rmdir "$LOCK_DIR" >/dev/null 2>&1 || true' EXIT

try_fetch_prebuilt_xcframework() {
  # Only attempt when Ghostty submodule is clean — dirty trees won't match any
  # published release. Opt-out via CMUX_GHOSTTYKIT_NO_PREBUILT=1.
  #
  # Trust model: only install prebuilt artifacts whose SHA256 is pinned in the
  # reviewed checksum manifest for the current ghostty submodule commit.
  # Unpinned or mismatched artifacts fall back to a local ReleaseFast build.
  if [[ "$GHOSTTY_KEY" != "$GHOSTTY_SHA" ]]; then
    return 1
  fi
  if [[ "${CMUX_GHOSTTYKIT_NO_PREBUILT:-0}" == "1" ]]; then
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    return 1
  fi

  local url="https://github.com/manaflow-ai/ghostty/releases/download/xcframework-${GHOSTTY_SHA}/GhosttyKit.xcframework.tar.gz"
  if [[ ! -f "$GHOSTTYKIT_CHECKSUMS_FILE" ]]; then
    echo "==> Missing GhosttyKit checksum manifest; falling back to local build." >&2
    return 1
  fi

  local expected_sha
  if ! expected_sha="$(lookup_pinned_ghosttykit_sha256 "$GHOSTTY_SHA" "$GHOSTTYKIT_CHECKSUMS_FILE" 2>/dev/null)"; then
    echo "==> No pinned GhosttyKit checksum for ${GHOSTTY_SHA:0:12}; falling back to local build." >&2
    return 1
  fi

  local tmp_dir tmp_tar tmp_extract actual_sha
  tmp_dir="$(mktemp -d "$CACHE_ROOT/.ghosttykit-prebuilt.XXXXXX")"
  tmp_tar="$tmp_dir/GhosttyKit.xcframework.tar.gz"
  tmp_extract="$tmp_dir/extract"
  mkdir -p "$tmp_extract"
  echo "==> Fetching prebuilt GhosttyKit.xcframework for ${GHOSTTY_SHA:0:12}..."
  if ! curl -fSL --connect-timeout 10 --max-time 300 --retry 3 --retry-delay 2 --retry-all-errors -o "$tmp_tar" "$url"; then
    rm -rf "$tmp_dir"
    echo "==> Prebuilt xcframework not available; falling back to local build."
    return 1
  fi

  actual_sha="$(hash_file "$tmp_tar")"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    rm -rf "$tmp_dir"
    echo "==> Prebuilt xcframework checksum mismatch; falling back to local build." >&2
    echo "    expected: $expected_sha" >&2
    echo "    actual:   $actual_sha" >&2
    return 1
  fi

  if ! python3 "$GHOSTTYKIT_ARCHIVE_VALIDATOR" "$tmp_tar"; then
    rm -rf "$tmp_dir"
    echo "==> Prebuilt xcframework archive failed validation; falling back to local build." >&2
    return 1
  fi

  if ! tar --no-same-owner -xzf "$tmp_tar" -C "$tmp_extract"; then
    rm -rf "$tmp_dir"
    echo "==> Failed to extract verified prebuilt xcframework; falling back to local build." >&2
    return 1
  fi

  local extracted="$tmp_extract/GhosttyKit.xcframework"
  if [[ ! -d "$extracted" ]]; then
    rm -rf "$tmp_dir"
    echo "==> Prebuilt archive did not contain GhosttyKit.xcframework; falling back." >&2
    return 1
  fi

  mkdir -p "$(dirname "$LOCAL_XCFRAMEWORK")"
  rm -rf "$LOCAL_XCFRAMEWORK"
  mv "$extracted" "$LOCAL_XCFRAMEWORK"
  rm -rf "$tmp_dir"
  echo "$GHOSTTY_KEY" > "$LOCAL_KEY_STAMP"
  echo "$GHOSTTY_SHA" > "$LEGACY_LOCAL_SHA_STAMP"
  return 0
}

if [[ -d "$CACHE_XCFRAMEWORK" ]]; then
  echo "==> Reusing cached GhosttyKit.xcframework"
else
  LOCAL_KEY=""
  if [[ -f "$LOCAL_KEY_STAMP" ]]; then
    LOCAL_KEY="$(cat "$LOCAL_KEY_STAMP")"
  elif [[ -f "$LEGACY_LOCAL_SHA_STAMP" ]]; then
    LOCAL_KEY="$(cat "$LEGACY_LOCAL_SHA_STAMP")"
  fi

  if [[ -d "$LOCAL_XCFRAMEWORK" && "$LOCAL_KEY" == "$GHOSTTY_KEY" ]]; then
    echo "==> Seeding cache from existing local GhosttyKit.xcframework (build key matches)"
  elif try_fetch_prebuilt_xcframework; then
    echo "==> Seeding cache from prebuilt GhosttyKit.xcframework"
  else
    echo "==> Building GhosttyKit.xcframework (this may take a few minutes)..."
    (
      cd ghostty
      zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
    )
    echo "$GHOSTTY_KEY" > "$LOCAL_KEY_STAMP"
    echo "$GHOSTTY_SHA" > "$LEGACY_LOCAL_SHA_STAMP"
  fi

  if [[ ! -d "$LOCAL_XCFRAMEWORK" ]]; then
    echo "Error: GhosttyKit.xcframework not found at $LOCAL_XCFRAMEWORK" >&2
    exit 1
  fi

  TMP_DIR="$(mktemp -d "$CACHE_ROOT/.ghosttykit-tmp.XXXXXX")"
  mkdir -p "$CACHE_DIR"
  cp -R "$LOCAL_XCFRAMEWORK" "$TMP_DIR/GhosttyKit.xcframework"
  rm -rf "$CACHE_XCFRAMEWORK"
  mv "$TMP_DIR/GhosttyKit.xcframework" "$CACHE_XCFRAMEWORK"
  rmdir "$TMP_DIR"
  echo "==> Cached GhosttyKit.xcframework at $CACHE_XCFRAMEWORK"
fi

MACOS_ARCHIVE="$CACHE_XCFRAMEWORK/macos-arm64_x86_64/libghostty.a"
refresh_archive_index "$MACOS_ARCHIVE"

echo "==> Creating symlink for GhosttyKit.xcframework..."
ln -sfn "$CACHE_XCFRAMEWORK" GhosttyKit.xcframework
