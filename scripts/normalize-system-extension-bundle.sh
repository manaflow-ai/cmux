#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/normalize-system-extension-bundle.sh <path-to-app> <bundle-id>

Renames the embedded system extension so its directory name is
<bundle-id>.systemextension, as required by macOS system-extension loading.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 2
fi

APP_PATH="$1"
EXPECTED_BUNDLE_ID="$2"

if [[ ! "$EXPECTED_BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "error: invalid system extension bundle identifier: $EXPECTED_BUNDLE_ID" >&2
  exit 2
fi

SYSTEM_EXTENSIONS_DIR="$APP_PATH/Contents/Library/SystemExtensions"
if [[ ! -d "$SYSTEM_EXTENSIONS_DIR" ]]; then
  echo "error: system extension directory not found: $SYSTEM_EXTENSIONS_DIR" >&2
  exit 1
fi

extensions=()
while IFS= read -r extension_path; do
  extensions+=("$extension_path")
done < <(find "$SYSTEM_EXTENSIONS_DIR" -mindepth 1 -maxdepth 1 -type d -name '*.systemextension' -print | sort)
if [[ "${#extensions[@]}" -ne 1 ]]; then
  echo "error: expected exactly one system extension under $SYSTEM_EXTENSIONS_DIR, found ${#extensions[@]}" >&2
  exit 1
fi

extension="${extensions[0]}"
plist="$extension/Contents/Info.plist"
if [[ ! -f "$plist" ]]; then
  echo "error: system extension Info.plist not found: $plist" >&2
  exit 1
fi

actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
if [[ "$actual_bundle_id" != "$EXPECTED_BUNDLE_ID" ]]; then
  echo "error: system extension identifier is '$actual_bundle_id', expected '$EXPECTED_BUNDLE_ID'" >&2
  exit 1
fi

expected_path="$SYSTEM_EXTENSIONS_DIR/${EXPECTED_BUNDLE_ID}.systemextension"
if [[ "$extension" != "$expected_path" ]]; then
  if [[ -e "$expected_path" ]]; then
    echo "error: target system extension path already exists: $expected_path" >&2
    exit 1
  fi
  mv "$extension" "$expected_path"
  echo "renamed system extension bundle to $(basename "$expected_path")"
else
  echo "system extension bundle name already matches $(basename "$expected_path")"
fi
