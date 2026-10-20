#!/bin/zsh
# AutoFill pill probe (r13 D3). Builds a one-view simulator app whose UITextView has the
# terminal composer's traits, taps the focused, empty field with axe (simulator HID only),
# and screenshots it: plain UITextView shows the "AutoFill" edit-menu pill above the field;
# with -fix (buildMenu removes .autoFill, as ComposerUITextView does) nothing shows.
#   usage: run.sh HOST AXE_PATH   (runs on HOST, e.g. a cmux mini with an iOS 26.5 runtime)
set -euo pipefail
host=${1:?host} axe=${2:?path to axe on host}
here=${0:a:h}
ssh $host 'mkdir -p ~/afprobe/AFProbe.app'
scp -q $here/main.swift $here/Info.plist ${host}:afprobe/
ssh $host "cd ~/afprobe && cp Info.plist AFProbe.app/ && xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios26.0-simulator -O main.swift -o AFProbe.app/AFProbe 2>/dev/null && codesign -s - --force AFProbe.app 2>/dev/null
U=\$(xcrun simctl create afprobe 'iPhone 17 Pro' com.apple.CoreSimulator.SimRuntime.iOS-26-5); xcrun simctl boot \$U; xcrun simctl bootstatus \$U -b >/dev/null
xcrun simctl install \$U AFProbe.app
for mode in plain fix; do
  xcrun simctl launch --terminate-running-process \$U dev.cmux.r13.afprobe -variant 0 \$( [ \$mode = fix ] && echo -fix ) >/dev/null
  perl -e 'select(undef,undef,undef,2.5)'   # the probe focuses its field 0.5 s after launch
  $axe tap --udid \$U -x 40 -y 536 --tap-style simulator >/dev/null 2>&1
  perl -e 'select(undef,undef,undef,1.5)'   # the edit menu's show animation
  xcrun simctl io \$U screenshot --type=png tap-\$mode.png >/dev/null 2>&1
done
xcrun simctl delete \$U"
scp -q "${host}:afprobe/tap-*.png" .
echo "tap-plain.png: AutoFill pill expected; tap-fix.png: none"
