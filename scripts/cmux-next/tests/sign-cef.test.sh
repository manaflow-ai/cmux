#!/usr/bin/env bash
# sign-cef.sh signs the embedded Chromium engine inside out and exits 0, with
# and without the Chromium host. A bundle whose host did not build has none:
# f8d6cd0139e ended its host loop with a bare `[[ -d ]] && codesign`, so
# sign-cef.sh exited 1 for every such bundle and failed every nightly-next
# build (fixed in 7670c8d5be7).
# The host is signed last, before the app, with the app's bundle id as its
# identifier, the hardened runtime and a timestamp for a real identity, and the
# browser-process subset of the app's entitlements (keychain group, passkey,
# device.* and personal-information.* keys; no allow-jit);
# `sign-cef.sh --verify-host` refuses a host signed any other way.
# codesign is a stand-in on PATH that logs its arguments and answers -d and
# --verify from FAKE_* variables, so this needs no signing identity and no
# real Mach-O.
#
# Not in CI (lead, 2026-10-23: no new CI tests); run it when you change
# sign-cef.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sign-cef-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/codesign" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CODESIGN_LOG"
target="${*: -1}"
case " $* " in
  *" --verify "*)
    [[ -z "${FAKE_VERIFY_FAIL:-}" ]]; exit ;;
  *" -d --entitlements "*)
    if [[ "$target" == *" Chromium Host" ]]; then printf '%s' "${FAKE_HOST_ENTITLEMENTS:-}"; else printf '%s' "${FAKE_APP_ENTITLEMENTS:-}"; fi
    exit 0 ;;
  *" --entitlements "*)
    # Keep the host's entitlements file: sign-cef.sh deletes it on exit.
    if [[ "$target" == *" Chromium Host" ]]; then
      args=("$@")
      for i in "${!args[@]}"; do
        [[ "${args[$i]}" == --entitlements ]] && cp "${args[$((i + 1))]}" "$(dirname "$CODESIGN_LOG")/host-entitlements.plist"
      done
    fi
    exit 0 ;;
  *" -d "*)
    if [[ "$target" == *" Chromium Host" ]]; then printf '%s\n' "$FAKE_HOST_DISPLAY" >&2; else printf '%s\n' "$FAKE_APP_DISPLAY" >&2; fi
    exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/codesign"

bundle() { # <dir> [host] [plist]: an app with the engine, the shim, three helpers, with "host" the host, with "plist" an Info.plist
  local app="$1/app.app" fw="$1/app.app/Contents/Frameworks" helper
  mkdir -p "$fw/Chromium Embedded Framework.framework/Versions/A/Libraries"
  : > "$fw/Chromium Embedded Framework.framework/Versions/A/Libraries/libEGL.dylib"
  : > "$fw/libcmux_cef_shim.dylib"
  for helper in "app Helper" "app Helper (GPU)" "app Helper (Renderer)"; do
    mkdir -p "$fw/$helper.app/Contents/MacOS"
  done
  mkdir -p "$app/Contents/MacOS"
  if [[ "${2:-}" == host ]]; then
    : > "$app/Contents/MacOS/app Chromium Host"
    : > "$fw/libcmux_cef_shim_remote.dylib"
  fi
  if [[ "${3:-}" == plist ]]; then
    /usr/bin/python3 -c 'import plistlib, sys; plistlib.dump({"CFBundleIdentifier": "test.app"}, open(sys.argv[1], "wb"))' \
      "$app/Contents/Info.plist"
  fi
}
sign() { # <dir> [identity] [app entitlements]: sign-cef.sh (identity "-" by default); its exit status
  local dir="$1"
  shift
  CODESIGN_LOG="$dir/codesign.log" PATH="$TMP/bin:/usr/bin:/bin" /bin/bash "$ROOT/scripts/cmux-next/sign-cef.sh" "$dir/app.app" "${1:--}" \
    "${@:2}" 2> "$dir/sign.err"
}
keys() { # <plist>: its top-level keys, sorted, one per line
  /usr/bin/python3 -c 'import plistlib, sys; print("\n".join(sorted(plistlib.load(open(sys.argv[1], "rb")))))' "$1"
}
# The browser-process subset of cmux.release.entitlements (chrome/app/app-entitlements.plist's set).
BROWSER_KEYS="com.apple.application-identifier
com.apple.developer.team-identifier
com.apple.developer.web-browser.public-key-credential
com.apple.security.device.audio-input
com.apple.security.device.camera
com.apple.security.personal-information.addressbook
com.apple.security.personal-information.calendars
com.apple.security.personal-information.location
com.apple.security.personal-information.photos-library
keychain-access-groups"

# 1. No host (a build whose host did not build).
mkdir "$TMP/release"
bundle "$TMP/release"
status=0
sign "$TMP/release" || status=$?
(( status == 0 )) || fail "sign-cef.sh exited $status for a bundle with no Chromium host"
log="$(cat "$TMP/release/codesign.log")"
grep -q '/libEGL.dylib$' <<<"$log" || fail "the framework's libraries were not signed: $log"
grep -q 'Chromium Embedded Framework.framework$' <<<"$log" || fail "the framework was not signed: $log"
grep -q '/libcmux_cef_shim.dylib$' <<<"$log" || fail "the shim was not signed: $log"
grep -q -- '--entitlements .*app Helper (GPU).app$' <<<"$log" || fail "the GPU helper lost its JIT entitlements: $log"
grep -q -- '--entitlements .*app Helper (Renderer).app$' <<<"$log" || fail "the renderer helper lost its JIT entitlements: $log"
grep -q 'app Helper.app$' <<<"$log" || fail "the base helper was not signed: $log"
if grep -q 'Chromium Host' <<<"$log"; then fail "a host was signed in a bundle without one: $log"; fi

# 2. Ad hoc with the host and the app's Info.plist (a dev build): the remote shim
# signed; the host signed last, without entitlements, as the app's identifier.
mkdir "$TMP/debug"
bundle "$TMP/debug" host plist
status=0
sign "$TMP/debug" || status=$?
(( status == 0 )) || fail "sign-cef.sh exited $status for a bundle with the Chromium host"
grep -q '/libcmux_cef_shim_remote.dylib$' "$TMP/debug/codesign.log" || fail "the remote shim was not signed: $(cat "$TMP/debug/codesign.log")"
last="$(tail -n 1 "$TMP/debug/codesign.log")"
[[ "$last" == *"Contents/MacOS/app Chromium Host" && "$last" != *--entitlements* ]] || fail "the host was not signed last without entitlements: $last"
[[ "$last" == *"--identifier test.app "* ]] || fail "the host was not signed with the app's identifier: $last"

# 3. Developer ID (release signing, sign-cmux-bundle.sh with the app's
# entitlements): the host has the hardened runtime, a secure timestamp, the
# app's identifier and the browser-process subset of cmux.release.entitlements:
# the keychain group and passkey entitlement stay, allow-jit,
# allow-unsigned-executable-memory, disable-library-validation and apple-events
# go. GPU and Renderer keep allow-jit.
mkdir "$TMP/devid"
bundle "$TMP/devid" host plist
status=0
sign "$TMP/devid" "Developer ID Application: Test (TEAM123)" "$ROOT/cmux.release.entitlements" || status=$?
(( status == 0 )) || fail "sign-cef.sh exited $status for a Developer ID signature: $(cat "$TMP/devid/sign.err")"
last="$(tail -n 1 "$TMP/devid/codesign.log")"
[[ "$last" == *"Contents/MacOS/app Chromium Host" ]] || fail "the host was not signed last: $last"
for want in "--options runtime" "--timestamp " "--identifier test.app " "--sign Developer ID Application: Test (TEAM123)" "--entitlements "; do
  [[ "$last" == *"$want"* ]] || fail "the host's signature lacks '$want': $last"
done
[[ "$(keys "$TMP/devid/host-entitlements.plist")" == "$BROWSER_KEYS" ]] ||
  fail "the host's entitlements are not the browser-process set: $(keys "$TMP/devid/host-entitlements.plist")"
/usr/bin/python3 - "$ROOT/cmux.release.entitlements" "$TMP/devid/host-entitlements.plist" <<'PY' || fail "the host's entitlement values differ from the app's"
import plistlib, sys
app, host = (plistlib.load(open(p, "rb")) for p in sys.argv[1:3])
sys.exit(0 if all(app[k] == v for k, v in host.items()) else 1)
PY
grep -q -- '--options runtime .*--entitlements .*app Helper (GPU).app$' "$TMP/devid/codesign.log" ||
  fail "the GPU helper lost the hardened runtime or allow-jit: $(cat "$TMP/devid/codesign.log")"
# A real identity without the app's entitlements (Embed CEF in Xcode) gives the host none.
mkdir "$TMP/devid-noent"
bundle "$TMP/devid-noent" host plist
sign "$TMP/devid-noent" "Apple Development: Test (TEAM123)" || fail "signing without app entitlements failed: $(cat "$TMP/devid-noent/sign.err")"
[[ "$(tail -n 1 "$TMP/devid-noent/codesign.log")" != *--entitlements* ]] ||
  fail "the host got entitlements without the app's: $(tail -n 1 "$TMP/devid-noent/codesign.log")"
# App entitlements with no browser-process key: the host gets none.
mkdir "$TMP/devid-nobrowser"
bundle "$TMP/devid-nobrowser" host plist
/usr/bin/python3 -c 'import plistlib, sys; plistlib.dump({"com.apple.security.cs.allow-jit": True, "com.apple.security.automation.apple-events": True}, open(sys.argv[1], "wb"))' \
  "$TMP/nobrowser.entitlements"
sign "$TMP/devid-nobrowser" "Developer ID Application: Test (TEAM123)" "$TMP/nobrowser.entitlements" ||
  fail "signing with no browser-process key failed: $(cat "$TMP/devid-nobrowser/sign.err")"
[[ "$(tail -n 1 "$TMP/devid-nobrowser/codesign.log")" != *--entitlements* ]] ||
  fail "the host got entitlements the app has none of: $(tail -n 1 "$TMP/devid-nobrowser/codesign.log")"
# A missing entitlements file stops signing.
mkdir "$TMP/devid-missing"
bundle "$TMP/devid-missing" host plist
if sign "$TMP/devid-missing" "Developer ID Application: Test (TEAM123)" "$TMP/no-such.entitlements"; then
  fail "sign-cef.sh signed the host with a missing entitlements file"
fi

# 4. Developer ID without an Info.plist: the host's identity would be its file
# name, so signing stops instead of shipping a host that is not the app.
mkdir "$TMP/noplist"
bundle "$TMP/noplist" host
if sign "$TMP/noplist" "Developer ID Application: Test (TEAM123)"; then
  fail "sign-cef.sh signed a Developer ID host without the app's bundle id"
fi
grep -q "no CFBundleIdentifier" "$TMP/noplist/sign.err" || fail "no error for the missing bundle id: $(cat "$TMP/noplist/sign.err")"
# Xcode's Embed CEF before Info.plist exists: PRODUCT_BUNDLE_IDENTIFIER names the id.
mkdir "$TMP/xcode"
bundle "$TMP/xcode" host
PRODUCT_BUNDLE_IDENTIFIER=test.app sign "$TMP/xcode" "Apple Development: Test (TEAM123)" ||
  fail "a host signed during Embed CEF without Info.plist failed: $(cat "$TMP/xcode/sign.err")"
[[ "$(tail -n 1 "$TMP/xcode/codesign.log")" == *"--identifier test.app "*"app Chromium Host" ]] ||
  fail "the Embed CEF host did not take PRODUCT_BUNDLE_IDENTIFIER: $(tail -n 1 "$TMP/xcode/codesign.log")"
# Ad hoc with no id at all (outside Xcode) still signs it.
mkdir "$TMP/noplist-adhoc"
bundle "$TMP/noplist-adhoc" host
sign "$TMP/noplist-adhoc" || fail "an ad hoc host without an Info.plist failed: $(cat "$TMP/noplist-adhoc/sign.err")"
[[ "$(tail -n 1 "$TMP/noplist-adhoc/codesign.log")" == *"app Chromium Host" ]] || fail "the ad hoc host was not signed"

# 5. --verify-host.
display() { # <identifier> <flags> <team>
  printf 'Executable=/x\nIdentifier=%s\nFormat=Mach-O thin (arm64)\nCodeDirectory v=20500 size=1 flags=%s hashes=1+7 location=embedded\nTeamIdentifier=%s\n' "$1" "$2" "$3"
}
# The app signed with cmux.release.entitlements, the host with the set step 3 derived.
APP_ENTITLEMENTS="$(cat "$ROOT/cmux.release.entitlements")"
HOST_ENTITLEMENTS="$(cat "$TMP/devid/host-entitlements.plist")"
host_entitlements() { # [-key...] [+key=xml value...]: the host's set with keys removed or added
  /usr/bin/python3 - "$TMP/devid/host-entitlements.plist" "$@" <<'PY'
import plistlib, sys
ents = plistlib.load(open(sys.argv[1], "rb"))
for change in sys.argv[2:]:
    if change.startswith("-"):
        del ents[change[1:]]
    else:
        key, _, value = change[1:].partition("=")
        ents[key] = plistlib.loads(f'<plist version="1.0">{value}</plist>'.encode())
sys.stdout.write(plistlib.dumps(ents).decode())
PY
}
verify() { # [VAR=value...]: sign-cef.sh --verify-host on the Developer ID bundle; its exit status
  env CODESIGN_LOG="$TMP/devid/verify.log" PATH="$TMP/bin:/usr/bin:/bin" \
    FAKE_APP_DISPLAY="$(display test.app '0x10000(runtime)' TEAM123)" \
    FAKE_HOST_DISPLAY="$(display test.app '0x10000(runtime)' TEAM123)" \
    FAKE_APP_ENTITLEMENTS="$APP_ENTITLEMENTS" FAKE_HOST_ENTITLEMENTS="$HOST_ENTITLEMENTS" \
    "$@" /bin/bash "$ROOT/scripts/cmux-next/sign-cef.sh" --verify-host "$TMP/devid/app.app" > "$TMP/verify.out" 2>&1
}
verify || fail "--verify-host refused a host signed as the app with the browser set: $(cat "$TMP/verify.out")"
verify FAKE_APP_ENTITLEMENTS= FAKE_HOST_ENTITLEMENTS= ||
  fail "--verify-host refused an app and host that both have no entitlements: $(cat "$TMP/verify.out")"
grep -q "signed as nested code" "$TMP/verify.out" || fail "--verify-host did not report the host: $(cat "$TMP/verify.out")"
verify FAKE_HOST_DISPLAY="$(display test.app '0x10002(adhoc,runtime)' TEAM123)" ||
  fail "--verify-host refused runtime among several flags: $(cat "$TMP/verify.out")"
refuses() { # <what> <expected error> [VAR=value...]
  local what="$1" expected="$2"
  shift 2
  if verify "$@"; then fail "--verify-host accepted $what"; fi
  grep -q "$expected" "$TMP/verify.out" || fail "--verify-host refused $what without '$expected': $(cat "$TMP/verify.out")"
}
refuses "a host without the hardened runtime" "hardened runtime" FAKE_HOST_DISPLAY="$(display test.app '0x0(none)' TEAM123)"
refuses "a host signed as its file name" "identifier is 'app Chromium Host'" \
  FAKE_HOST_DISPLAY="$(display 'app Chromium Host' '0x10000(runtime)' TEAM123)"
refuses "a host of another team" "team 'OTHER'" FAKE_HOST_DISPLAY="$(display test.app '0x10000(runtime)' OTHER)"
refuses "an ad hoc host" "team 'not set'" FAKE_HOST_DISPLAY="$(display test.app '0x10002(adhoc,runtime)' 'not set')" \
  FAKE_APP_DISPLAY="$(display test.app '0x10002(adhoc,runtime)' 'not set')"
refuses "a host with allow-jit" "code-signing relaxation com.apple.security.cs.allow-jit" \
  FAKE_HOST_ENTITLEMENTS="$(host_entitlements '+com.apple.security.cs.allow-jit=<true/>')"
refuses "a host with disable-library-validation" "relaxation com.apple.security.cs.disable-library-validation" \
  FAKE_HOST_ENTITLEMENTS="$(host_entitlements '+com.apple.security.cs.disable-library-validation=<true/>')"
refuses "a host without the keychain group" "lacks the app's keychain-access-groups" \
  FAKE_HOST_ENTITLEMENTS="$(host_entitlements -keychain-access-groups)"
refuses "a host without the passkey entitlement" "lacks the app's com.apple.developer.web-browser.public-key-credential" \
  FAKE_HOST_ENTITLEMENTS="$(host_entitlements -com.apple.developer.web-browser.public-key-credential)"
refuses "a host without entitlements" "lacks the app's com.apple.application-identifier" FAKE_HOST_ENTITLEMENTS=
refuses "a host with another keychain group" "has keychain-access-groups=" \
  FAKE_HOST_ENTITLEMENTS="$(host_entitlements '+keychain-access-groups=<array><string>OTHER.group</string></array>')"
refuses "a host with apple-events" "carries com.apple.security.automation.apple-events" \
  FAKE_HOST_ENTITLEMENTS="$(host_entitlements '+com.apple.security.automation.apple-events=<true/>')"
refuses "a host whose signature does not verify" "does not verify" FAKE_VERIFY_FAIL=1
# No host: a note, exit 0.
/usr/bin/python3 -c 'import plistlib, sys; plistlib.dump({"CFBundleIdentifier": "test.app"}, open(sys.argv[1], "wb"))' \
  "$TMP/release/app.app/Contents/Info.plist"
env CODESIGN_LOG="$TMP/release/verify.log" PATH="$TMP/bin:/usr/bin:/bin" FAKE_APP_DISPLAY="$(display test.app '0x10000(runtime)' TEAM123)" \
  /bin/bash "$ROOT/scripts/cmux-next/sign-cef.sh" --verify-host "$TMP/release/app.app" > "$TMP/verify.out" 2>&1 ||
  fail "--verify-host failed for a bundle without a host: $(cat "$TMP/verify.out")"
grep -q "carries no Chromium host" "$TMP/verify.out" || fail "--verify-host did not note the missing host: $(cat "$TMP/verify.out")"

echo "sign-cef tests: ok"
