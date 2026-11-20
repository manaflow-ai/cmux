# swapapp.sh ZIP : replace the installed cmux DEV cuparity2 app with the one in
# ZIP (a fleet build of the same tag), keeping its bundle id, settings and
# grants; every cmux process stopped first. swapremote.sh runs after it.
A="/Applications/cmux DEV cuparity2.app"; PW=admin
sudo_() { echo "$PW" | sudo -S -p '' "$@"; }
for _ in $(seq 1 15); do
  pgrep -f "$A/|cmux-remote" >/dev/null || break
  pkill -9 -f "$A/" 2>/dev/null; pkill -9 -f "cmux-remote" 2>/dev/null
  /bin/sleep 1
done
pgrep -fl "$A/|cmux-remote" >/dev/null && { echo "ERROR: cmux processes still running"; exit 1; }
t=$(mktemp -d); ditto -x -k "$1" "$t" || { echo "ERROR: unzip failed"; exit 1; }
new=$(find "$t" -maxdepth 2 -name "*.app" -type d | head -1)
[ -n "$new" ] || { echo "ERROR: no app in $1"; exit 1; }
id=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$new/Contents/Info.plist")
[ "$id" = "com.cmuxterm.app.debug.cuparity2" ] || { echo "ERROR: bundle id $id"; exit 1; }
sudo_ rm -rf "$A"; sudo_ ditto "$new" "$A"; xattr -cr "$A" 2>/dev/null; sudo_ xattr -cr "$A" 2>/dev/null
rm -rf "$t"
echo "app swapped: $("$A/Contents/Resources/bin/cmux" --version 2>/dev/null | head -1)"
