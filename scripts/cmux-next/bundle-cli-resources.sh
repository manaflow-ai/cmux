#!/usr/bin/env bash
# Xcode "Bundle CLI resources" phase of the cmux-next target: copies the
# helper scripts in Resources/bin (profiling helpers) into
# <app>/Contents/Resources/bin, beside the `cmux` binary that
# bundle-cmux-tui.sh installs. The CLI itself is the cmux-tui binary
# (plans/cmux-next/cli.md); it loads no resources from the bundle.
set -euo pipefail

bin="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/bin"
src="${SRCROOT:?}"

mkdir -p "$bin"
# Provider executables (codex, claude, ...) are rejected by the "Reject
# Bundled Provider Binaries" phase, never copied from here.
for file in "$src/Resources/bin/"*; do
  [[ -f "$file" ]] || continue
  rsync -a "$file" "$bin/${file##*/}"
done
