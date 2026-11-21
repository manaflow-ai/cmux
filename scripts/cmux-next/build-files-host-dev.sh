#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Wraps a release cmux-files-host (cmux-tui/crates/cmux-files-host) into the unsigned
# "cmux Files (dev).app" (com.cmuxterm.files.dev, docs/cmux-files-host.md) and zips it:
#
#   build-files-host-dev.sh BINARY OUT.zip
#
# The fleet runs it after the release build (scripts/ci/cmux-tui-rust-check.sh files-host);
# sign-files-host-dev.sh signs the zip and writes the pin. Nothing is built or signed here.
set -euo pipefail
binary="${1:?usage: build-files-host-dev.sh BINARY OUT.zip}"
out="${2:?usage: build-files-host-dev.sh BINARY OUT.zip}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -x "$binary" ]] || { echo "error: $binary is not an executable" >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
app="$work/cmux Files (dev).app"
mkdir -p "$app/Contents/MacOS"
cp "$SCRIPT_DIR/files-host/Info.plist" "$app/Contents/Info.plist"
cp "$binary" "$app/Contents/MacOS/cmux-files-host"
chmod 755 "$app/Contents/MacOS/cmux-files-host"
# The linker's ad-hoc signature goes; the signer adds the team's.
codesign --remove-signature "$app/Contents/MacOS/cmux-files-host" 2>/dev/null || true
mkdir -p "$(dirname "$out")"
rm -f "$out"
ditto -c -k --keepParent "$app" "$out"
echo "unsigned cmux Files (dev).app: $out ($(shasum -a 256 "$out" | awk '{print $1}'))"
