#!/usr/bin/env bash
# nightly.yml "Install create-dmg" (recover-nightly-next-notarization, sign-nightly-identity-legacy) and "Install build
# deps" (build-sign-notarize-nightly, nightly-next-one). Moved out of the workflow to keep nightly.yml under its size
# budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -e  # the inline steps ran under bash -e
CMUX_NODE_BIN="$(command -v node)"
export npm_config_prefix="$RUNNER_TEMP/npm-global"
mkdir -p "$npm_config_prefix"
npm install --global "create-dmg@${CREATE_DMG_VERSION}"
wrapper_dir="$RUNNER_TEMP/create-dmg-wrapper"
mkdir -p "$wrapper_dir"
cat > "$wrapper_dir/create-dmg" <<EOF
#!/usr/bin/env bash
exec "$CMUX_NODE_BIN" "$npm_config_prefix/lib/node_modules/create-dmg/cli.js" "\$@"
EOF
chmod +x "$wrapper_dir/create-dmg"
echo "$wrapper_dir" >> "$GITHUB_PATH"
