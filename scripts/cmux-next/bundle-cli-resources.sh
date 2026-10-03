#!/usr/bin/env bash
# Xcode "Bundle CLI resources" phase of the cmux-next target: copies the
# helper scripts in Resources/bin (profiling helpers) into
# <app>/Contents/Resources/bin, beside the `cmux` binary that
# bundle-cmux-tui.sh installs. The CLI itself is the cmux-tui binary
# (plans/cmux-next/cli.md).
set -euo pipefail

bin="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/bin"
dest="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
src="${SRCROOT:?}"

mkdir -p "$bin"
# Provider executables (codex, claude, ...) are rejected by the "Reject
# Bundled Provider Binaries" phase, never copied from here.
for file in "$src/Resources/bin/"*; do
  [[ -f "$file" ]] || continue
  rsync -a "$file" "$bin/${file##*/}"
done

# Bun code-mode resources stay beside the CLI so `cmux run` can locate the
# runner from current_exe without relying on PATH.
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
install -m 755 "$src/scripts/cmux-next/cmux-code-mode-macos-profile" "$bin/cmux-code-mode-macos-profile"

echo "bundled CLI resources into $dest"
