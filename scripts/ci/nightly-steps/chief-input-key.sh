#!/usr/bin/env bash
# nightly.yml resolve-nightly-cmux-tui-client: "Compute portable OptChat Chief input key". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
git fetch --no-tags origin "$BUILD_SHA"
git checkout --detach --quiet "$BUILD_SHA"
toolchain="$(sed -n 's/^channel *= *"\(.*\)"/\1/p' cmux-tui/rust-toolchain.toml)"
[[ -n "$toolchain" ]] || { echo "error: cannot read cmux-tui/rust-toolchain.toml" >&2; exit 1; }
key="$(python3 scripts/cmux-next/optchat-chief-input-key.py --portable --archs "$ARCHS" --toolchain "$toolchain")"
[[ "$key" =~ ^[0-9a-f]{64}$ ]] || { echo "error: invalid portable Chief key" >&2; exit 1; }
echo "key=$key" >> "$GITHUB_OUTPUT"
