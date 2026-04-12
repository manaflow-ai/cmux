#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/harden-release-app-layout.sh <app-path>

Normalizes a built release app bundle into a Gatekeeper-friendlier layout by
moving bundled helper executables out of Contents/Resources/bin and into
Contents/Helpers before the app is signed.
EOF
}

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 1
fi

APP_PATH="$1"
CONTENTS_DIR="$APP_PATH/Contents"
RESOURCE_BIN_DIR="$CONTENTS_DIR/Resources/bin"
HELPERS_DIR="$CONTENTS_DIR/Helpers"

if [[ ! -d "$CONTENTS_DIR" ]]; then
  echo "Release app bundle is missing its Contents directory at $CONTENTS_DIR" >&2
  exit 1
fi

mkdir -p "$HELPERS_DIR"

relocate_helper_executable() {
  local executable_name="$1"
  local source_path="$RESOURCE_BIN_DIR/$executable_name"
  local destination_path="$HELPERS_DIR/$executable_name"

  if [[ ! -e "$source_path" ]]; then
    return 0
  fi

  if [[ ! -x "$source_path" ]]; then
    echo "Expected bundled helper executable $source_path to be executable before release signing" >&2
    exit 1
  fi

  if [[ -e "$destination_path" && ! "$source_path" -ef "$destination_path" ]]; then
    rm -f "$destination_path"
  fi

  mv -f "$source_path" "$destination_path"
  chmod 0755 "$destination_path"
}

relocate_helper_executable "cmux"
relocate_helper_executable "ghostty"

for helper_name in cmux ghostty; do
  helper_path="$HELPERS_DIR/$helper_name"
  if [[ -e "$helper_path" && ! -x "$helper_path" ]]; then
    echo "Normalized helper executable $helper_path exists but is not executable" >&2
    exit 1
  fi
done

if [[ -d "$RESOURCE_BIN_DIR" ]]; then
  resource_bin_entries=()
  while IFS= read -r -d '' entry; do
    resource_bin_entries+=("$entry")
  done < <(find "$RESOURCE_BIN_DIR" -mindepth 1 -maxdepth 1 -print0)

  if [[ ${#resource_bin_entries[@]} -eq 0 ]]; then
    rmdir "$RESOURCE_BIN_DIR"
  fi
fi

echo "Normalized release bundle layout for $APP_PATH"
