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
# Remove files owned by this phase before copying the current source set, so
# deleting or renaming a helper cannot leave an obsolete executable in a
# reused DerivedData bundle. The cmux-tui outputs are owned by another phase.
owned_bins=(
  cmux-code-mode-mcp cmux-code-mode-run start-cmux-profiling submit-cmux-profile
  cmux-code-mode-runner cmux-code-mode-sandbox cmux-code-mode-unpack cmux-dev-shim-install
  cmux-code-mode-macos-profile
  cmux-open-url open xdg-open
)
for name in "${owned_bins[@]}"; do
  rm -f "$bin/$name"
done
# Provider executables (codex, claude, ...) are rejected by the "Reject
# Bundled Provider Binaries" phase, never copied from here.
for file in "$src/Resources/bin/"*; do
  [[ -f "$file" ]] || continue
  rsync -a "$file" "$bin/${file##*/}"
done

# Bun code-mode resources stay beside the CLI so `cmux run` can locate the
# runner from current_exe without relying on PATH. They are staged here and
# shipped as one xz tar, Resources/code-mode.tar.xz (3.5 MB in 54 files, about
# 0.3 MB packed; CMUX-570): bin/cmux-code-mode-unpack unpacks it into the
# user's cache on the first `cmux run` or code-mode MCP start.
stage="${TARGET_TEMP_DIR:-${TMPDIR:-/tmp}}/cmux-code-mode-stage.$$"
rm -rf "$stage"
trap 'rm -rf "$stage"' EXIT
code_mode="$stage/code-mode"
mkdir -p "$code_mode/sdk"
rsync -a --delete "$src/cmux-tui/bindings/typescript/src/" "$code_mode/sdk/src/"
rsync -a --delete "$src/cmux-tui/bindings/typescript/code-mode/" "$code_mode/sdk/code-mode/"
cp "$src/cmux-tui/bindings/typescript/code-mode/mcp.mjs" "$code_mode/mcp.mjs"
cp "$src/cmux-tui/bindings/typescript/code-mode/proxy.mjs" "$code_mode/sdk/code-mode/proxy.mjs"
# Keep source catalogs reviewable, but ship compact JSON. Code mode parses these
# catalogs during runner startup, so this removes whitespace without changing the
# operation set or adding decompression work to the first request.
compact_json="$src/scripts/cmux-next/compact-json.py"
python3 "$compact_json" "$src/cmux-tui/spec/resource-operations-v2.json" "$code_mode/resource-operations-v2.json"
python3 "$compact_json" "$src/backend/catalog/cloud-operations.json" "$code_mode/cloud-operations.json"
python3 "$compact_json" "$src/backend/catalog/cloud-relay-operations.json" "$code_mode/cloud-relay-operations.json"
# The SDK's own tests are not run from the app.
find "$code_mode" -name '*.test.mjs' -delete
python3 "$src/scripts/cmux-next/pack-code-mode.py" "$code_mode" "$dest/code-mode.tar.xz"
# An unpacked folder from an older build of this bundle would shadow the archive.
rm -rf "$dest/code-mode"
install -m 755 "$src/scripts/cmux-next/cmux-code-mode-runner" "$bin/cmux-code-mode-runner"
install -m 755 "$src/scripts/cmux-next/cmux-code-mode-sandbox" "$bin/cmux-code-mode-sandbox"
install -m 755 "$src/scripts/cmux-next/cmux-code-mode-unpack" "$bin/cmux-code-mode-unpack"
# The managed dev shim, from its one source: tools that open this build
# refresh a user's managed `cmux` shim from it (plans/cmux-next/version-skew.md).
install -m 755 "$src/scripts/lib/cmux-dev-shim-install" "$bin/cmux-dev-shim-install"
install -m 755 "$src/scripts/cmux-next/cmux-code-mode-macos-profile" "$bin/cmux-code-mode-macos-profile"
# The URL opener a terminal's BROWSER names and its `open` / `xdg-open` shims
# (BundledCLIEnvironment, TerminalLinkOpener). Only this app's bin dir, which
# only its terminals put on PATH: never Resources/bin, which classic shares.
for shim in cmux-open-url open xdg-open; do
  install -m 755 "$src/scripts/cmux-next/url-open/$shim" "$bin/$shim"
done

# Rust and Zig standard library notices for every bundled binary that links
# them (cmux-tui/build-support/notices/toolchains; check_bundle_notices.py
# rust-std and zig-std). Fails when a stored text does not match its sha256.
python3 "$src/cmux-tui/build-support/notices/toolchains/toolchain_notices.py" install --resources "$dest"

echo "bundled CLI resources into $dest"
