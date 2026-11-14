#!/bin/bash
# install-aside.sh: in a cuev guest (aside-* VM), unpack the pinned Aside daemon component and CLI the way
# AgentEnv's aside driver does (agentenv-framework 0.9.1534, drivers/envs/aside/install.sh), under ~/aside.
# Expects ~/aside-dl/aside-daemon.crx and ~/aside-dl/aside-cli.zip (sha256-checked here).
set -eu
dl=$HOME/aside-dl; dest=$HOME/aside; helper="Aside Computer Use.app"
echo "47f54f506f1b8e7abb75d1ca263bb388e5d4e1bd295c3b52e64b5959082744c6  $dl/aside-daemon.crx" | shasum -a 256 -c -
echo "f4b234e8a63eb2a721a9094b7ded1c286d4f253ede3b4eb347c2d3e0ef04765c  $dl/aside-cli.zip" | shasum -a 256 -c -
rm -rf "$dest"; mkdir -p "$dest/bin" "$dest/home/runtime-computer-use"
tar -xf "$dl/aside-daemon.crx" -C "$dest"
ditto -x -k "$dl/aside-cli.zip" "$dest"
ln -s "../Aside CLI.app/Contents/MacOS/aside" "$dest/bin/aside"
xattr -dr com.apple.quarantine "$dest" || true
ditto "$dest/$helper" "$dest/home/runtime-computer-use/$helper"
mkdir -p "$dest/home/u/0"
printf '%s\n' '{"analytics":{"enabled":false}}' > "$dest/home/u/0/settings.json"
ls "$dest"
for p in "Aside Daemon.app/Contents/MacOS/aside-daemon" "$helper/Contents/MacOS/aside-computer-use" "bin/aside"; do
  shasum -a 256 "$dest/$p"
done
