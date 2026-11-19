#!/usr/bin/env bash
# launch-fresh-install.sh's mount_point reads `hdiutil info -plist` from a pipe. plistlib.load needs a seekable file,
# so on a pipe it raised "File or stream is not seekable" every 0.2 s, found no mount, and row q/m fell back to an
# unquarantined hdiutil attach (fleet step c5408b53, 2026-11-19). This proves the plist on a pipe yields the mount
# point. No Mac: hdiutil is a stand-in that prints a plist.
# Run: bash scripts/measure/tests/launch-fresh-install-mount-point.test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
got="$(bash -c '
  source "$1"
  hdiutil() {
    printf "%s" "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>images</key><array><dict><key>image-path</key><string>/tmp/x.dmg</string><key>system-entities</key><array><dict><key>content-hint</key><string>GUID_partition_scheme</string></dict><dict><key>mount-point</key><string>/Volumes/cmux X</string></dict></array></dict></array></dict></plist>"
  }
  mount_point /tmp/x.dmg 2
' _ "$here/launch-fresh-install.sh" 2>&1)"
[[ "$got" == "/Volumes/cmux X" ]] || { echo "launch-fresh-install mount_point: want '/Volumes/cmux X', got: ${got:0:300}" >&2; exit 1; }
echo "launch-fresh-install mount_point: ok"
