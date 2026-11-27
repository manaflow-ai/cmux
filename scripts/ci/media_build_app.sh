#!/usr/bin/env bash
# Build one tagged app for the cmux-next media tour and write its path to
# GITHUB_OUTPUT as <output>=<app> (.github/workflows/cmux-next-media.yml).
#
#   media_build_app.sh SOURCE_DIR TAG LOG OUTPUT_NAME
#
# A warm tag's DerivedData keeps the explicit module Xcode precompiled from
# GhosttyNextKit's ghostty.h and does not rebuild it for a new pin ("ghostty.h
# has been modified since the module file", job 117892119256). The stamp
# clears the dir's build state (the whole Build dir: clearing only the modules
# left a build description pointing at them, job 118285853270) only when a
# binary pin changed since the tag's last good build.
set -euo pipefail
dir="$1" tag="$2" log="$3" output="$4"
stamp="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/media_module_cache_stamp.py"
derived="$HOME/Library/Developer/Xcode/DerivedData/cmux-$tag"
python3 "$stamp" clear --source "$dir" --derived-data "$derived"
(cd "$dir" && ./scripts/reload.sh --tag "$tag" --no-global-cli-links) 2>&1 | tee "$log"
python3 "$stamp" record --source "$dir" --derived-data "$derived"
app="$(awk '/^App path:/ { getline; sub(/^ +/, ""); print; exit }' "$log")"
if [ -z "$app" ] || [ ! -d "$app" ]; then
  app="$(find "$derived/Build/Products/Debug" -maxdepth 1 -name '*.app' -print -quit)"
fi
[ -d "$app" ] || { echo "::error::reload.sh built no $tag app"; exit 1; }
echo "$output=$app" >> "$GITHUB_OUTPUT"
echo "Built $tag: $app"
