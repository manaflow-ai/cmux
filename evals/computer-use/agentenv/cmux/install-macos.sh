#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Manaflow, Inc.
# macOS (unverified), as the session user: the cmux CLI and the signed cmux Remote (dev).app from the tarball
# overlay.py stages (bin/cmux-macos.tar.gz, holding cmux and "cmux Remote (dev).app"), quarantine removed.
set -eu
[ -f bin/cmux-macos.tar.gz ] || { echo "bin/cmux-macos.tar.gz is missing: stage it with overlay.py --cmux-macos" >&2; exit 1; }
mkdir -p bin/macos
tar -xzf bin/cmux-macos.tar.gz -C bin/macos
xattr -dr com.apple.quarantine bin/macos || true
sudo mkdir -p /usr/local/bin
sudo install -m 755 bin/macos/cmux /usr/local/bin/cmux
rm -rf "/Applications/cmux Remote (dev).app"
cp -R "bin/macos/cmux Remote (dev).app" /Applications/
