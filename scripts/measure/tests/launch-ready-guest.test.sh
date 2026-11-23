#!/usr/bin/env bash
# launch-ready.sh guest=1, a run on a person's own Mac beside their running NIGHTLY: the arguments it refuses
# (guest_args_ok), and the copy made its own app before anything reads its bundle id (guest_copy: <id>.launch-ready,
# URL schemes and document types removed, ad hoc re-sign, LR-GUEST). plutil and codesign are stand-ins that log.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

# shellcheck source=../launch-ready.sh
source "$here/launch-ready.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

# guest_args_ok DMG COPY LATE ENGINES PROFILE
ok() { LR_GUEST="$1" LR_CASE="$2" LR_STATE="${LR_STATE:-kept}" guest_args_ok "$3" "$4" "$5" "$6" "$7" 2>/dev/null; }
ok 1 "" nightly same 0 "" 0 || fail "guest=1 dmg=nightly refused"
ok 1 "" https://example.invalid/a.dmg same 0 "" 0 || fail "guest=1 dmg=URL refused"
ok 0 "" build fresh 50 chromium 1 || fail "guest=0 checked the guest rules"
! ok 1 "" build same 0 "" 0 || fail "guest=1 dmg=build accepted"
! ok 1 "" swap same 0 "" 0 || fail "guest=1 dmg=swap accepted"
! ok 1 update nightly same 0 "" 0 || fail "guest=1 case=update accepted"
! ok 1 "" nightly fresh 0 "" 0 || fail "guest=1 copy=fresh accepted"
! ok 1 "" nightly same 100 "" 0 || fail "guest=1 late= accepted"
! ok 1 "" nightly same 0 chromium 0 || fail "guest=1 engines= accepted"
! ok 1 "" nightly same 0 "" 1 || fail "guest=1 profile=1 accepted"
! LR_STATE=bare ok 1 "" nightly same 0 "" 0 || fail "guest=1 state=bare accepted"
! LR_KEYS=1 ok 1 "" nightly same 0 "" 0 || fail "guest=1 keys=1 accepted"
LR_TYPE=1 ok 1 "" nightly same 0 "" 0 || fail "guest=1 type=1 refused"
echo 'launch-ready guest: the arguments guest=1 takes and refuses'

# guest_copy: the bundle id gets .launch-ready (once), the link claims go, the copy is re-signed ad hoc.
app="$root/out/head/cmux NEXT.app"
mkdir -p "$app/Contents"
calls="$root/calls"
stub_id=com.cmuxterm.next.nightly
plutil() {
  echo "plutil $*" >>"$calls"
  case "$1" in
    -extract) echo "$stub_id" ;;
    -replace) stub_id="$4" ;;
  esac
}
codesign() { echo "codesign $*" >>"$calls"; }
line="$(guest_copy "$root/out" head "$app"; echo "apps=$LR_GUEST_APPS")"
[[ "$line" == "LR-GUEST head bundle=com.cmuxterm.next.nightly.launch-ready signed=adhoc"$'\n'"apps=$app" ]] \
  || fail "guest_copy printed '$line'"
grep -qx "plutil -replace CFBundleIdentifier -string com.cmuxterm.next.nightly.launch-ready $app/Contents/Info.plist" "$calls" \
  || fail "bundle id not replaced: $(cat "$calls")"
for key in CFBundleURLTypes CFBundleDocumentTypes UTExportedTypeDeclarations NSServices; do
  grep -qx "plutil -remove $key $app/Contents/Info.plist" "$calls" || fail "$key not removed"
done
grep -qx "codesign --force --deep --sign - $app" "$calls" || fail "not re-signed ad hoc: $(cat "$calls")"
# A copy already renamed keeps one suffix.
stub_id=com.cmuxterm.next.nightly.launch-ready
line="$(guest_copy "$root/out" head "$app")"
[[ "$line" == "LR-GUEST head bundle=com.cmuxterm.next.nightly.launch-ready signed=adhoc" ]] || fail "renamed twice: '$line'"
# A failed re-sign fails the copy.
codesign() { return 1; }
! guest_copy "$root/out" head "$app" >/dev/null || fail "a failed re-sign passed"
unset -f plutil codesign
echo 'launch-ready guest: the copy gets its own bundle id and an ad hoc signature before anything reads it'

# guest_forget with no guest copy, or no lsregister (Linux), does nothing and succeeds.
LR_GUEST_APPS="" guest_forget || fail "guest_forget with no copies failed"
LR_GUEST_APPS="$app"$'\n' guest_forget || fail "guest_forget without lsregister failed"
echo 'launch-ready guest: guest_forget is safe with nothing to forget'
