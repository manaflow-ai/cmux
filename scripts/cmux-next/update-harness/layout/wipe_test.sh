#!/bin/bash
# bash wipe_test.sh [UPD]: `upd.py wipe` on a temp HOME with stub defaults/getconf: removes the proof id's paths, keeps another id's, refuses shipped ids.
set -u
upd=${1:-"$(dirname "$0")/upd.py"}
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/var/T" "$t/var/X/p.id.code_sign_clone/a" "$t/var/X/other.id.code_sign_clone"
printf '#!/bin/sh\necho "$@" >> %s/defaults.log\n' "$t" > "$t/bin/defaults"
printf '#!/bin/sh\necho %s/var/T/\n' "$t" > "$t/bin/getconf"
chmod +x "$t/bin/"*
H=$t/home; L=$H/Library
mkdir -p "$L/Caches/p.id" "$L/Application Support/p.id" "$L/Application Support/cmux-next/p.id" \
  "$L/HTTPStorages/p.id" "$L/WebKit/p.id" "$H/.cmux/chief/p.id" "$L/Logs/cmux-next" "$L/Preferences" \
  "$L/Caches/other.id" "$L/Application Support/p.id.x"
touch "$L/Preferences/p.id.plist" "$L/Logs/cmux-next/p.id-1.log" "$L/Logs/cmux-next/p.id.x-1.log" "$L/Preferences/other.id.plist"
out=$(HOME=$H PATH=$t/bin:$PATH python3 -I "$upd" wipe p.id) || { echo "FAIL rc"; exit 1; }
echo "$out"
fail=0
for p in "$L/Caches/p.id" "$L/Application Support/p.id" "$L/Application Support/cmux-next/p.id" "$L/HTTPStorages/p.id" \
  "$L/WebKit/p.id" "$H/.cmux/chief/p.id" "$L/Preferences/p.id.plist" "$L/Logs/cmux-next/p.id-1.log" "$t/var/X/p.id.code_sign_clone"; do
  [ -e "$p" ] && { echo "FAIL kept $p"; fail=1; }
done
for p in "$L/Caches/other.id" "$L/Application Support/p.id.x" "$L/Logs/cmux-next/p.id.x-1.log" "$L/Preferences/other.id.plist" "$t/var/X/other.id.code_sign_clone"; do
  [ -e "$p" ] || { echo "FAIL removed $p"; fail=1; }
done
grep -qx "delete p.id" "$t/defaults.log" || { echo "FAIL no defaults delete"; fail=1; }
for id in com.cmuxterm.app com.cmuxterm.app.next com.cmuxterm.app.nightly.cmux-next ../x ""; do
  HOME=$H PATH=$t/bin:$PATH python3 -I "$upd" wipe "$id" >/dev/null 2>&1 && { echo "FAIL accepted '$id'"; fail=1; }
done
[ $fail = 0 ] && echo PASS
exit $fail
