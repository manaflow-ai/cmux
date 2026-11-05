#!/usr/bin/env bash
# nightly.yml recover-nightly-next-notarization and sign-nightly-identity-legacy: "Install create-dmg". Moved out of the workflow to keep nightly.yml under
# GitHub's workflow file size limit; the step's env: still sets every input.
set -e  # the inline step ran under bash -e
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
