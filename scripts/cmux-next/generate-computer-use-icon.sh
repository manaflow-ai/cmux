#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Writes Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Resources/ComputerUseIcon.icns from Computer Use's tile,
# webviews/src/agent-session/acpmux/icons/computerUseTile.png (Lucas's midnight cursor, the one the composer's
# @computer-use and the Computer Use setup window's head draw). The icns is what the setup's drag row, its drag
# image, the agent permission card and the bundled helper (System Settings' Privacy & Security rows) show
# (CmuxNextDesign's ComputerUseAppIcon, bundle-screen-sharing-helper.sh), so every place shows the same tile.
#
# Each size keeps 9% of its side clear on every edge, as the setup window's head does (onboarding styles.css,
# `.onb-cu-helper[data-tile]`): the tile fills its picture, an app icon does not. The tile is 192 px, so the icns
# stops at 256 px (128@2x, 256@1x); macOS scales the largest one for bigger places.
#
# Run it on a Mac (sips, iconutil) after the tile changes; ComputerUseAppIconTests fails when the two differ.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tile="$repo_root/webviews/src/agent-session/acpmux/icons/computerUseTile.png"
out="${1:-$repo_root/Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Resources/ComputerUseIcon.icns}"
[[ -f "$tile" ]] || { echo "error: no tile at $tile" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
iconset="$work/ComputerUseIcon.iconset"
mkdir -p "$iconset"
# <file name> <pixels>
for spec in icon_16x16:16 icon_16x16@2x:32 icon_32x32:32 icon_32x32@2x:64 icon_128x128:128 icon_128x128@2x:256 icon_256x256:256; do
  name="${spec%%:*}"; side="${spec##*:}"
  inner=$(( (side * 82 + 50) / 100 ))   # 9% clear on each side
  sips -z "$inner" "$inner" "$tile" --out "$work/inner.png" >/dev/null
  sips --padToHeightWidth "$side" "$side" "$work/inner.png" --out "$iconset/$name.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$out"
echo "wrote $out from $tile"
