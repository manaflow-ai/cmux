#!/usr/bin/env bash
# The cmux-tui phase creates acpmux -> cmux. The later acpmux phase must retain
# that alias instead of replacing it with a second binary.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
bin="$TMP/app/Contents/Resources/bin"
mkdir -p "$bin"
printf '#!/bin/sh\n' > "$bin/cmux"
chmod 755 "$bin/cmux"
ln -s cmux "$bin/acpmux"
printf 'commit=%s\nsource=tree-hosted\n' "$(printf 'a%.0s' {1..40})" > "$bin/cmux-tui.version"

TARGET_BUILD_DIR="$TMP/app" UNLOCALIZED_RESOURCES_FOLDER_PATH=Contents/Resources \
  bash "$ROOT/scripts/cmux-next/bundle-acpmux.sh" >"$TMP/out" 2>&1 \
  || { cat "$TMP/out" >&2; echo 'bundle-acpmux-alias: phase failed' >&2; exit 1; }

[[ -L "$bin/acpmux" ]] || { cat "$TMP/out" >&2; echo 'bundle-acpmux-alias: acpmux was replaced' >&2; exit 1; }
[[ "$(readlink "$bin/acpmux")" == cmux ]] || { echo 'bundle-acpmux-alias: link target changed' >&2; exit 1; }
grep -qx 'source=tree-hosted' "$bin/acpmux.version" || { cat "$bin/acpmux.version" >&2; echo 'bundle-acpmux-alias: metadata was not refreshed' >&2; exit 1; }
echo 'bundle-acpmux-alias: ok'
