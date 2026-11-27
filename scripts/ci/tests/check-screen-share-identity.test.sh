#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# scripts/ci/check-screen-share-identity.sh over fake signed apps. A stub PlistBuddy reads Info.plist
# with python3; a stub codesign prints the requirement written in the helper's fake-requirement file,
# as `codesign -d -r-` prints it. Covers: NIGHTLY's helper as it ships (passes), an ad-hoc helper
# (cdhash), a helper id that moved, another team, NIGHTLY under another team, an ad-hoc app, no
# helper, two helpers, a legacy "Screen Sharing.app" helper (alone or beside one), another bundle ending
# in " Helper.app", cmux Computer Use.app beside the helper, and another signer's own build.
# Runs on Linux and macOS (python3).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SCRIPT="$ROOT/scripts/ci/check-screen-share-identity.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n%s\n' "$1" "${2:-}" >&2; exit 1; }

cat > "$TMP/PlistBuddy" <<'STUB'
#!/usr/bin/env bash
# PlistBuddy -c "Print :KEY" FILE
exec python3 -I -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb"))[sys.argv[2]])' "$3" "${2#Print :}"
STUB
cat > "$TMP/codesign" <<'STUB'
#!/usr/bin/env bash
# codesign -dv APP (the app's team, from fake-team) or codesign -d -r- BUNDLE
if [[ "$1" == -dv ]]; then
  echo "TeamIdentifier=$(cat "${!#}/fake-team" 2>/dev/null || echo 7WLXT3NR37)" >&2
  exit 0
fi
echo "Executable=${!#}/Contents/MacOS/cmux-screen-sharing" >&2
printf 'designated => %s\n' "$(cat "${!#}/fake-requirement")"
STUB
chmod 755 "$TMP/PlistBuddy" "$TMP/codesign"

developer_id() { # <id> [team]
  printf 'identifier "%s" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = "%s"' \
    "$1" "${2:-7WLXT3NR37}"
}
info() { # <bundle> <id>
  mkdir -p "$1/Contents"
  python3 -I -c 'import plistlib, sys; plistlib.dump({"CFBundleIdentifier": sys.argv[2]}, open(sys.argv[1], "wb"))' "$1/Contents/Info.plist" "$2"
}
app() { # <case> <app id> -> $APP, with one helper "cmux NIGHTLY Helper.app" signed Developer ID
  APP="$TMP/$1/cmux NIGHTLY.app"
  HELPER="$APP/Contents/Library/cmux NIGHTLY Helper.app"
  info "$APP" "$2"
  info "$HELPER" "$2.screen-sharing"
  mkdir -p "$HELPER/Contents/MacOS"; : > "$HELPER/Contents/MacOS/cmux-screen-sharing"
  developer_id "$2.screen-sharing" > "$HELPER/fake-requirement"
}
run() {
  set +e
  out=$(CMUX_PLISTBUDDY="$TMP/PlistBuddy" CMUX_CODESIGN_TOOL="$TMP/codesign" /bin/bash "$SCRIPT" "$APP" 2>&1)
  rc=$?
  set -e
}
expect_pass() { run; [[ $rc == 0 ]] || fail "$1: exit $rc" "$out"; }
expect_fail() { # <case> <text the error must hold>
  run
  [[ $rc != 0 ]] || fail "$1: passed" "$out"
  [[ "$out" == *"$2"* ]] || fail "$1: error does not say '$2'" "$out"
}

app shipped com.cmuxterm.app.nightly
expect_pass "NIGHTLY as it ships"

app adhoc com.cmuxterm.app.nightly
echo 'cdhash H"0123456789abcdef0123456789abcdef01234567"' > "$HELPER/fake-requirement"
expect_fail "ad-hoc helper" "cdhash"

app moved com.cmuxterm.app.nightly
info "$HELPER" com.cmuxterm.cua
developer_id com.cmuxterm.cua > "$HELPER/fake-requirement"
expect_fail "helper id moved" "not com.cmuxterm.app.nightly.screen-sharing"

app requirement com.cmuxterm.app.nightly
developer_id com.cmuxterm.cua > "$HELPER/fake-requirement"
expect_fail "requirement names another id" "does not name com.cmuxterm.app.nightly.screen-sharing"

app team com.cmuxterm.app.nightly
developer_id com.cmuxterm.app.nightly.screen-sharing AAAAAAAAAA > "$HELPER/fake-requirement"
expect_fail "another team" "not Developer ID team 7WLXT3NR37"

app none com.cmuxterm.app.nightly
rm -rf "$HELPER"
expect_fail "no helper" "holds 0 Screen Sharing helpers"

app nightly_no_helper com.cmuxterm.app.nightly
rm -rf "$HELPER"
set +e
out=$(NIGHTLY_COMPONENT_GATES= CMUX_PLISTBUDDY="$TMP/PlistBuddy" CMUX_CODESIGN_TOOL="$TMP/codesign" /bin/bash "$SCRIPT" "$APP" 2>&1)
rc=$?
set -e
[[ $rc == 0 ]] || fail "nightly without helper: exit $rc" "$out"
[[ "$out" == *"::warning title=Nightly stale part::cmux-screen-sharing: this nightly carries no Screen Sharing helper"* ]] \
  || fail "nightly without helper: missing warning" "$out"

app nightly_blocked_no_helper com.cmuxterm.app.nightly
rm -rf "$HELPER"
set +e
out=$(NIGHTLY_COMPONENT_GATES=block CMUX_PLISTBUDDY="$TMP/PlistBuddy" CMUX_CODESIGN_TOOL="$TMP/codesign" /bin/bash "$SCRIPT" "$APP" 2>&1)
rc=$?
set -e
[[ $rc != 0 ]] || fail "blocked nightly without helper: passed" "$out"
[[ "$out" == *"holds 0 Screen Sharing helpers"* ]] || fail "blocked nightly without helper: wrong error" "$out"

app nightly_no_helper_with_cua com.cmuxterm.app.nightly
rm -rf "$HELPER"
info "$APP/Contents/Library/cmux Computer Use.app" com.cmuxterm.cua
run
[[ $rc != 0 ]] || fail "nightly without helper and CUA: passed" "$out"
[[ "$out" == *"a second Screen Recording holder"* ]] || fail "nightly without helper and CUA: wrong error" "$out"

app two com.cmuxterm.app.nightly
cp -R "$HELPER" "$APP/Contents/Library/cmux NEXT Helper.app"
expect_fail "two helpers" "holds 2 Screen Sharing helpers"

app newandlegacy com.cmuxterm.app.nightly
cp -R "$HELPER" "$APP/Contents/Library/cmux NIGHTLY Screen Sharing.app"
expect_fail "a helper and a legacy-named one" "holds 2 Screen Sharing helpers"

app legacy com.cmuxterm.app.nightly
mv "$HELPER" "$APP/Contents/Library/cmux NIGHTLY Screen Sharing.app"
expect_fail "only a legacy-named helper" "the name from before the rename"

app otherhelper com.cmuxterm.app.nightly
info "$APP/Contents/Library/Other Helper.app" com.example.other
expect_pass "another bundle ending in Helper.app"

app cua com.cmuxterm.app.nightly
info "$APP/Contents/Library/cmux Computer Use.app" com.cmuxterm.cua
expect_fail "second holder" "a second Screen Recording holder"

app pinnedteam com.cmuxterm.app.nightly
echo AAAAAAAAAA > "$APP/fake-team"
developer_id com.cmuxterm.app.nightly.screen-sharing AAAAAAAAAA > "$HELPER/fake-requirement"
expect_fail "NIGHTLY signed by another team" "signed by team AAAAAAAAAA, not 7WLXT3NR37"

app adhocapp com.cmuxterm.app.nightly
echo "not set" > "$APP/fake-team"
expect_fail "an ad-hoc app" "not Developer ID signed"

app dev com.cmuxterm.app.next.dev
expect_pass "an unpinned channel derives its id"

app outside com.example.cmux
echo BBBBBBBBBB > "$APP/fake-team"
developer_id com.example.cmux.screen-sharing BBBBBBBBBB > "$HELPER/fake-requirement"
expect_pass "another signer's own build, under its own team"

echo "check-screen-share-identity: all cases pass"
