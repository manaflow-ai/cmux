#!/bin/bash
# swapremote2.sh ZIP : public/guest/swapremote.sh for whichever cmux DEV app the guest has installed
# (~/cub-assets/cmux-app-name): replace its cmux Remote helper with ZIP (a signed helper build), re-sign
# the outer app ad hoc, start it, check the worker runs the new engine, and approve its capture path.
A="/Applications/$(cat ~/cub-assets/cmux-app-name)"
sed "s#^A=\"/Applications/cmux DEV cuparity2.app\"#A=\"$A\"#" ~/swapremote.sh > /tmp/swapremote-run.sh
bash /tmp/swapremote-run.sh "$1" || exit 1
bash ~/cu/quiet2.sh >/dev/null 2>&1
w=$(pgrep -f "cmux-remote worker computer-use" | head -1)
running=$(ps -o command= -p "$w" | sed -E 's#(.*\.app)/Contents/MacOS/cmux-remote.*#\1#')
shasum -a 256 "$running/Contents/Frameworks/libcmux_computer_use.dylib"
