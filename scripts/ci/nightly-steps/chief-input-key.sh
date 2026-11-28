#!/usr/bin/env bash
# nightly.yml resolve-nightly-cmux-tui-client: "Compute portable OptChat Chief input key". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
# The depth-64 checkout already holds BUILD_SHA (the build commit is the tip or one of its last 64): fetch only
# when it does not, so the nightly makes no github.com git fetch here (Leo's checkout-429 order).
GIT_NO_LAZY_FETCH=1 git cat-file -e "$BUILD_SHA^{commit}" 2>/dev/null || git fetch --no-recurse-submodules --no-tags origin "$BUILD_SHA"
git checkout --detach --quiet "$BUILD_SHA"
toolchain="$(sed -n 's/^channel *= *"\(.*\)"/\1/p' cmux-tui/rust-toolchain.toml)"
[[ -n "$toolchain" ]] || { echo "error: cannot read cmux-tui/rust-toolchain.toml" >&2; exit 1; }
key="$(python3 scripts/cmux-next/optchat-chief-input-key.py --portable --archs "$ARCHS" --toolchain "$toolchain")"
[[ "$key" =~ ^[0-9a-f]{64}$ ]] || { echo "error: invalid portable Chief key" >&2; exit 1; }
echo "key=$key" >> "$GITHUB_OUTPUT"
