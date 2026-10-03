#!/usr/bin/env bash
# Xcode "Bundle CLI resources" phase of the cmux-next target. Runs after
# "Copy CLI" has put the cmux CLI into <app>/Contents/Resources/bin and puts
# beside it everything the CLI reads from the app bundle:
#
#   Resources/bin/<bundle>.bundle  SwiftPM resource bundles the CLI's packages
#                                  load through Bundle.module. A bare executable
#                                  looks for them next to itself; the app does
#                                  not link those packages, so nothing else puts
#                                  them in the bundle. Without them the CLI traps
#                                  ("unable to find bundle named ...").
#   Resources/bin/<wrappers>       Resources/bin/* (agent wrappers, cmux-sudo,
#                                  open, grok, profiling helpers) and
#                                  scripts/setup-pam-tid.sh.
#   Resources/feed-tui             `cmux feed` TUI.
#   Resources/markdown-viewer      diff/markdown viewer assets (`cmux diff`),
#                                  JS deflated like the legacy target did.
#   Resources/opencode-plugin.js   `cmux opencode` plugin.
#
# The CLI string table (Resources/Localizable.xcstrings) is a Resources-phase
# input, not copied here. The diff sidecar has its own phase.
#
# Resource bundles are discovered from the CLI binary itself: every SwiftPM
# resource accessor embeds the literal "unable to find bundle named <name>",
# so the list is exact and follows package changes without an allowlist. A
# bundle the CLI names but the build did not produce fails the phase.
set -euo pipefail

dest="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
bin="$dest/bin"
cli="$bin/cmux"
products="${BUILT_PRODUCTS_DIR:?}"
src="${SRCROOT:?}"

if [[ ! -x "$cli" ]]; then
  echo "error: $cli is missing; the Copy CLI phase must run first" >&2
  exit 1
fi

mkdir -p "$bin"

# 1. SwiftPM resource bundles named by the CLI.
bundles=()
while IFS= read -r name; do
  [[ -n "$name" ]] && bundles+=("$name")
done < <(strings -a "$cli" | sed -n 's/^unable to find bundle named \([A-Za-z0-9_.-]*\)$/\1/p' | LC_ALL=C sort -u)

keep=" "
for name in "${bundles[@]}"; do
  source_bundle="$products/$name.bundle"
  if [[ ! -d "$source_bundle" ]]; then
    echo "error: the CLI loads $name.bundle but $source_bundle was not built" >&2
    exit 1
  fi
  mkdir -p "$bin/$name.bundle"
  rsync -a --delete "$source_bundle/" "$bin/$name.bundle/"
  keep+="$name.bundle "
done
# Drop bundles a previous build copied that the CLI no longer names.
for existing in "$bin"/*.bundle; do
  [[ -d "$existing" ]] || continue
  case "$keep" in
    *" ${existing##*/} "*) ;;
    *) rm -rf "$existing" ;;
  esac
done

# 2. Wrappers and helper scripts. Provider executables (codex, claude, ...)
#    are rejected by the "Reject Bundled Provider Binaries" phase, never
#    copied from here.
for file in "$src/Resources/bin/"* "$src/scripts/setup-pam-tid.sh"; do
  [[ -f "$file" ]] || continue
  rsync -a "$file" "$bin/${file##*/}"
done

# 3. Directory and file resources.
sync_dir() {
  mkdir -p "$2"
  rsync -a --delete "$1/" "$2/"
}
sync_dir "$src/Resources/feed-tui" "$dest/feed-tui"
sync_dir "$src/Resources/markdown-viewer" "$dest/markdown-viewer"
"$src/scripts/compress-markdown-viewer-assets.sh" "$dest/markdown-viewer"
rsync -a "$src/Resources/opencode-plugin.js" "$dest/opencode-plugin.js"

# 4. Bun code-mode prototype resources. Keep these beside the CLI so
# `cmux run` can locate the runner from current_exe without relying on PATH.
code_mode="$dest/code-mode"
mkdir -p "$code_mode/sdk"
rsync -a --delete "$src/cmux-tui/bindings/typescript/src/" "$code_mode/sdk/src/"
rsync -a "$src/cmux-tui/bindings/typescript/code-mode/" "$code_mode/sdk/code-mode/"
cp "$src/cmux-tui/bindings/typescript/code-mode/mcp.mjs" "$code_mode/mcp.mjs"
cp "$src/cmux-tui/bindings/typescript/code-mode/proxy.mjs" "$code_mode/sdk/code-mode/proxy.mjs"
cp "$src/cmux-tui/spec/resource-operations-v2.json" "$code_mode/resource-operations-v2.json"
cp "$src/backend/catalog/cloud-operations.json" "$code_mode/cloud-operations.json"
cp "$src/backend/catalog/cloud-relay-operations.json" "$code_mode/cloud-relay-operations.json"
install -m 755 "$src/scripts/cmux-next/cmux-code-mode-runner" "$bin/cmux-code-mode-runner"

echo "bundled CLI resources into $dest (resource bundles: ${bundles[*]:-none})"
