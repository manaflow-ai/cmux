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
# A tree no cmux-tui-artifacts run published (the tour's base, the previous
# nightly-next tip: nothing publishes a superseded commit's tree, runs
# 45115317828 and 45120545271) left reload.sh waiting 45 min and failing, so
# no clip recorded. Build that app's client set on this Mac instead, with a
# per-runner Cargo target so the next tour compiles incrementally. A stand-in
# tree (CMUX_TUI_TREE_KEY, the workflow's tree step) is already published.
client="$dir/scripts/cmux-next/build-cmux-tui-client.sh"
if [ -z "${CMUX_NEXT_TUI_BIN:-}${CMUX_TUI_CLIENT_LOCAL:-}${CMUX_TUI_TREE_KEY:-}" ] && [ -x "$client" ] &&
  ! (cd "$dir" && GITHUB_EVENT_NAME= CMUX_TUI_TREE_DISPATCH= CMUX_TUI_TREE_RECHECK_SECONDS=0 \
    ./scripts/cmux-next/pin-cmux-tui.sh probe 2>/dev/null) | grep -q ': ready ('; then
  export CMUX_TUI_CLIENT_TARGET_DIR="${CMUX_TUI_CLIENT_TARGET_DIR:-$HOME/Library/Caches/cmux-ci-media/cmux-tui-client-target/${RUNNER_NAME:-local}}"
  echo "cmux-tui tree for $tag is not published: building its client set here"
  # The tree's pinned Zig, not the Mac's (media_pinned_zig.sh); without it build.rs tries PATH's.
  if zig="$("$(dirname "${BASH_SOURCE[0]}")/media_pinned_zig.sh" "$dir")"; then
    export CMUX_ZIG="$zig"
  else
    echo "::warning title=What's New clip::no pinned Zig for $tag; its client builds with PATH's zig"
  fi
  CMUX_TUI_CLIENT_LOCAL="$(cd "$dir" && "$client" --print-path)"
  export CMUX_TUI_CLIENT_LOCAL
fi
# Swift packages clone from github.com with no token. One 403 from GitHub
# failed the whole tour (job 139577219503: "Could not resolve package
# dependencies", sentry-cocoa, Sparkle, swift-crypto 403 at once), so no clip
# recorded. The base and head builds share one per-runner clone dir, so the
# head reuses the base's bare repos, and a failed resolution is retried after
# a pause. Any other build failure fails at once.
export CMUX_SOURCE_PACKAGES_DIR="${CMUX_SOURCE_PACKAGES_DIR:-$HOME/Library/Caches/cmux-ci-media/source-packages/${RUNNER_NAME:-local}}"
tries="${MEDIA_SPM_TRIES:-3}" pause="${MEDIA_SPM_RETRY_SECONDS:-60}"
for try in $(seq 1 "$tries"); do
  if (cd "$dir" && ./scripts/reload.sh --tag "$tag" --no-global-cli-links) 2>&1 | tee "$log"; then
    break
  fi
  if [ "$try" -ge "$tries" ] || ! grep -q 'Could not resolve package dependencies' "$log"; then
    exit 1
  fi
  echo "::warning title=What's New clip::$tag: Swift package resolution failed (try $try of $tries); retrying in ${pause}s"
  sleep "$pause"
done
python3 "$stamp" record --source "$dir" --derived-data "$derived"
app="$(awk '/^App path:/ { getline; sub(/^ +/, ""); print; exit }' "$log")"
if [ -z "$app" ] || [ ! -d "$app" ]; then
  app="$(find "$derived/Build/Products/Debug" -maxdepth 1 -name '*.app' -print -quit)"
fi
[ -d "$app" ] || { echo "::error::reload.sh built no $tag app"; exit 1; }
echo "$output=$app" >> "$GITHUB_OUTPUT"
echo "Built $tag: $app"
