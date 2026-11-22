#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: verify-app-bundle-licenses.sh <app-path>

Verifies that a built cmux app contains the canonical project GPL and its
third-party license notices before the app is placed in a distributed DMG:
every Mach-O file must map to its notices (scripts/cmux-next/notices/bundle-map.json).
EOF
}

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$1"
RESOURCES_PATH="$APP_PATH/Contents/Resources"
SOURCE_LICENSE="$ROOT_DIR/LICENSE"
BUNDLED_LICENSE="$RESOURCES_PATH/LICENSE"
BUNDLED_THIRD_PARTY="$RESOURCES_PATH/THIRD_PARTY_LICENSES.md"

if [[ ! -d "$APP_PATH/Contents" ]]; then
  echo "error: app bundle not found at $APP_PATH" >&2
  exit 1
fi

if [[ ! -s "$BUNDLED_LICENSE" ]]; then
  echo "error: cmux project license missing or empty at $BUNDLED_LICENSE" >&2
  exit 1
fi

if ! cmp -s "$SOURCE_LICENSE" "$BUNDLED_LICENSE"; then
  echo "error: bundled cmux project license differs from $SOURCE_LICENSE" >&2
  exit 1
fi

if [[ ! -s "$BUNDLED_THIRD_PARTY" ]]; then
  echo "error: third-party licenses missing or empty at $BUNDLED_THIRD_PARTY" >&2
  exit 1
fi

# The Rust and Zig standard library notices must match this checkout's
# toolchain pins (rust-toolchain.toml files, Ghostty minimum_zig_version).
if ! python3 "$ROOT_DIR/cmux-tui/build-support/notices/toolchains/toolchain_notices.py" check-repo --repo "$ROOT_DIR"; then
  echo "error: the Rust or Zig standard library notices do not match the toolchain pins" >&2
  exit 1
fi

# Every Mach-O in the bundle must map to its notices (scripts/cmux-next/notices/bundle-map.json).
# A bundled Ghostty license tree must name the Ghostty revision of this checkout.
check_args=()
if ghostty_revision="$(git -C "$ROOT_DIR" rev-parse --verify --quiet HEAD:ghostty 2>/dev/null)"; then
  check_args+=(--ghostty-revision "$ghostty_revision")
fi
# bin/cmux's libghostty-vt tree names the gitlink of the submodule that
# ghostty-vt-sys's build.rs selects (check_ghostty_vt_notices.py).
if vt_source="$(python3 "$ROOT_DIR/scripts/cmux-next/notices/check_ghostty_vt_notices.py" --repo "$ROOT_DIR" --print-source 2>/dev/null | sed -n 's/^libghostty-vt source: //p')" \
  && [[ -n "$vt_source" && "${vt_source%% *}" != ghostty ]]; then
  check_args+=(--tree-revision "Contents/Resources/${vt_source%% *}-licenses=${vt_source##* }")
fi
if ! python3 "$ROOT_DIR/scripts/cmux-next/notices/check_bundle_notices.py" "$APP_PATH" ${check_args[@]+"${check_args[@]}"}; then
  echo "error: third-party notices do not cover every binary in $APP_PATH" >&2
  exit 1
fi

echo "verified app bundle licenses: $APP_PATH"
