#!/usr/bin/env bash
# sign-cef.sh signs the embedded Chromium engine inside out and exits 0, with
# and without the Chromium host. A bundle whose host did not build has none:
# f8d6cd0139e ended its host loop with a bare `[[ -d ]] && codesign`, so
# sign-cef.sh exited 1 for every such bundle and failed every nightly-next
# build (fixed in 7670c8d5be7).
# The host is signed last, before the app, with the app's bundle id as its
# identifier, the hardened runtime and a timestamp for a real identity, and no
# entitlements (p01-process-088); `sign-cef.sh --verify-host` refuses a host
# signed any other way.
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
    if [[ "$target" == *" Chromium Host" ]]; then printf '%s' "${FAKE_HOST_ENTITLEMENTS:-}"; fi
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
sign() { # <dir> [identity]: sign-cef.sh (identity "-" by default); its exit status
  CODESIGN_LOG="$1/codesign.log" PATH="$TMP/bin:/usr/bin:/bin" /bin/bash "$ROOT/scripts/cmux-next/sign-cef.sh" "$1/app.app" "${2:--}" \
    2> "$1/sign.err"
}

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

# 3. Developer ID (release signing, sign-cmux-bundle.sh): the host has the
# hardened runtime, a secure timestamp, the app's identifier and no entitlements
# (no allow-jit: the browser process does not JIT); GPU and Renderer keep allow-jit.
mkdir "$TMP/devid"
bundle "$TMP/devid" host plist
status=0
sign "$TMP/devid" "Developer ID Application: Test (TEAM123)" || status=$?
(( status == 0 )) || fail "sign-cef.sh exited $status for a Developer ID signature: $(cat "$TMP/devid/sign.err")"
last="$(tail -n 1 "$TMP/devid/codesign.log")"
[[ "$last" == *"Contents/MacOS/app Chromium Host" ]] || fail "the host was not signed last: $last"
for want in "--options runtime" "--timestamp " "--identifier test.app " "--sign Developer ID Application: Test (TEAM123)"; do
  [[ "$last" == *"$want"* ]] || fail "the host's signature lacks '$want': $last"
done
[[ "$last" != *--entitlements* ]] || fail "the host was signed with entitlements: $last"
grep -q -- '--options runtime .*--entitlements .*app Helper (GPU).app$' "$TMP/devid/codesign.log" ||
  fail "the GPU helper lost the hardened runtime or allow-jit: $(cat "$TMP/devid/codesign.log")"

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
verify() { # [VAR=value...]: sign-cef.sh --verify-host on the Developer ID bundle; its exit status
  env CODESIGN_LOG="$TMP/devid/verify.log" PATH="$TMP/bin:/usr/bin:/bin" \
    FAKE_APP_DISPLAY="$(display test.app '0x10000(runtime)' TEAM123)" \
    FAKE_HOST_DISPLAY="$(display test.app '0x10000(runtime)' TEAM123)" \
    "$@" /bin/bash "$ROOT/scripts/cmux-next/sign-cef.sh" --verify-host "$TMP/devid/app.app" > "$TMP/verify.out" 2>&1
}
verify || fail "--verify-host refused a host signed as the app: $(cat "$TMP/verify.out")"
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
refuses "a host with allow-jit" "carries entitlements" \
  FAKE_HOST_ENTITLEMENTS='<plist><dict><key>com.apple.security.cs.allow-jit</key><true/></dict></plist>'
refuses "a host whose signature does not verify" "does not verify" FAKE_VERIFY_FAIL=1
# No host: a note, exit 0.
/usr/bin/python3 -c 'import plistlib, sys; plistlib.dump({"CFBundleIdentifier": "test.app"}, open(sys.argv[1], "wb"))' \
  "$TMP/release/app.app/Contents/Info.plist"
env CODESIGN_LOG="$TMP/release/verify.log" PATH="$TMP/bin:/usr/bin:/bin" FAKE_APP_DISPLAY="$(display test.app '0x10000(runtime)' TEAM123)" \
  /bin/bash "$ROOT/scripts/cmux-next/sign-cef.sh" --verify-host "$TMP/release/app.app" > "$TMP/verify.out" 2>&1 ||
  fail "--verify-host failed for a bundle without a host: $(cat "$TMP/verify.out")"
grep -q "carries no Chromium host" "$TMP/verify.out" || fail "--verify-host did not note the missing host: $(cat "$TMP/verify.out")"

echo "sign-cef tests: ok"
