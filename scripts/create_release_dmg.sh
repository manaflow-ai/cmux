#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 <app-path> <dmg-output-path> [signing-identity]" >&2
  exit 1
fi

APP_PATH="$1"
DMG_OUTPUT="$2"
SIGNING_IDENTITY="${3:-}"
MODERN_CREATE_DMG_VERSION="${CMUX_CREATE_DMG_MODERN_VERSION:-8.0.0}"
REQUIRE_MODERN="${CMUX_CREATE_DMG_REQUIRE_MODERN:-0}"

if [ ! -d "$APP_PATH" ]; then
  echo "App not found: $APP_PATH" >&2
  exit 1
fi

OUTPUT_DIR="$(dirname "$DMG_OUTPUT")"
mkdir -p "$OUTPUT_DIR"

cleanup_paths=()
cleanup() {
  local path
  for path in "${cleanup_paths[@]-}"; do
    [ -n "$path" ] && rm -rf "$path"
  done
}
trap cleanup EXIT

detect_create_dmg_mode() {
  local bin_name version_output major help_output
  bin_name="$1"

  version_output="$("$bin_name" --version 2>/dev/null || true)"
  major="$(printf '%s\n' "$version_output" | sed -n 's/.* \([0-9][0-9]*\)\..*/\1/p' | head -n1)"
  if [ -n "$major" ]; then
    if [ "$major" -lt 2 ]; then
      echo "legacy"
    else
      echo "modern"
    fi
    return
  fi

  help_output="$("$bin_name" --help 2>&1 || true)"
  if printf '%s\n' "$help_output" | grep -Fq "<output_name.dmg> <source_folder>"; then
    echo "legacy"
  else
    echo "modern"
  fi
}

create_dmg_legacy() {
  local staging_dir app_name volume_name cmd
  staging_dir="$(mktemp -d)"
  cleanup_paths+=("$staging_dir")

  cp -R "$APP_PATH" "$staging_dir/"
  app_name="$(basename "$APP_PATH")"
  volume_name="$(basename "$DMG_OUTPUT" .dmg)"

  cmd=(
    create-dmg
    --volname "$volume_name"
    --window-size 660 400
    --icon-size 128
    --icon "$app_name" 180 170
    --hide-extension "$app_name"
    --app-drop-link 480 170
  )
  if [ -n "$SIGNING_IDENTITY" ]; then
    cmd+=(--codesign "$SIGNING_IDENTITY")
  fi
  cmd+=("$DMG_OUTPUT" "$staging_dir")

  "${cmd[@]}"
}

create_dmg_modern() {
  local temp_output_dir generated_dmg
  local -a modern_bin cmd

  modern_bin=("$@")
  temp_output_dir="$(mktemp -d)"
  cleanup_paths+=("$temp_output_dir")

  cmd=("${modern_bin[@]}" --overwrite)
  if [ -n "$SIGNING_IDENTITY" ]; then
    cmd+=(--identity="$SIGNING_IDENTITY")
  else
    cmd+=(--no-code-sign)
  fi
  cmd+=("$APP_PATH" "$temp_output_dir")

  "${cmd[@]}"

  generated_dmg="$(find "$temp_output_dir" -maxdepth 1 -type f -name '*.dmg' | head -n1)"
  if [ -z "$generated_dmg" ]; then
    echo "create-dmg did not produce a DMG file in $temp_output_dir" >&2
    exit 1
  fi

  rm -f "$DMG_OUTPUT"
  mv "$generated_dmg" "$DMG_OUTPUT"
}

if command -v create-dmg >/dev/null 2>&1; then
  if [ "$(detect_create_dmg_mode create-dmg)" = "modern" ]; then
    create_dmg_modern create-dmg
    exit 0
  fi
fi

if command -v npx >/dev/null 2>&1; then
  create_dmg_modern npx --yes "create-dmg@${MODERN_CREATE_DMG_VERSION}"
  exit 0
fi

if [ "$REQUIRE_MODERN" = "1" ]; then
  echo "Modern create-dmg is required but unavailable (need create-dmg>=2 or npx)." >&2
  exit 1
fi

if ! command -v create-dmg >/dev/null 2>&1; then
  echo "create-dmg is required but not found in PATH" >&2
  exit 1
fi

if [ "$(detect_create_dmg_mode create-dmg)" = "legacy" ]; then
  create_dmg_legacy
else
  create_dmg_modern create-dmg
fi
