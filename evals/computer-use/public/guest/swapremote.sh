# swapremote.sh ZIP : replace cmux Remote inside the installed app (every cmux
# process stopped first, so no daemon restarts the host from a half-replaced
# bundle), re-sign the outer app ad hoc, start the app, and check that the
# staged copy the worker runs from is the new one.
A="/Applications/cmux DEV cuparity2.app"; PW=admin
sudo_() { echo "$PW" | sudo -S -p '' "$@"; }
# The app relaunches itself and its daemon restarts cmux Remote: stop all of
# it until nothing is left (bounded), so the swap is not raced.
for _ in $(seq 1 15); do
  pgrep -f "$A/|cmux-remote" >/dev/null || break
  pkill -9 -f "$A/" 2>/dev/null; pkill -9 -f "cmux-remote" 2>/dev/null
  /bin/sleep 1
done
pgrep -fl "$A/|cmux-remote" >/dev/null && { echo "ERROR: cmux processes still running"; exit 1; }
sudo_ rm -rf "$A/Contents/Library/cmux Remote (dev).app"
sudo_ ditto -x -k "$1" "$A/Contents/Library"
sudo_ codesign --force --sign - "$A" >/dev/null 2>&1
codesign --verify --strict --deep "$A/Contents/Library/cmux Remote (dev).app" && echo remote-signature-ok
open -g -j -a "$A"
for i in $(seq 1 90); do pgrep -f "cmux-remote worker computer-use" >/dev/null && break; /bin/sleep 1; done
w=$(pgrep -f "cmux-remote worker computer-use" | head -1)
echo "worker: $w"
running=$(ps -o command= -p "$w" | sed -E 's#(.*\.app)/Contents/MacOS/cmux-remote.*#\1#')
if cmp -s "$running/Contents/Frameworks/libcmux_computer_use.dylib" "$A/Contents/Library/cmux Remote (dev).app/Contents/Frameworks/libcmux_computer_use.dylib"; then
  echo "staged copy matches the installed helper"
else
  echo "ERROR: the worker runs a different helper than the one installed"; exit 1
fi
