#!/usr/bin/env bash
# sign-cef.sh signs the embedded Chromium engine inside out and exits 0, with
# and without the Chromium host (f8d6cd0139e ended its host loop with a bare
# `[[ -d ]] && codesign`, so sign-cef.sh exited 1 for every bundle without a
# host and failed every nightly-next build; fixed in 7670c8d5be7). The host is
# signed last, before the app, as <bundle id>.chromium-host with the hardened
# runtime for a real identity and Chrome's browser-process entitlements (no
# cs.* key). `sign-cef.sh --verify-host` refuses a host without the hardened
# runtime, the app's team, a timestamp or that identifier, or with any other
# entitlement.
# codesign is a stand-in on PATH that logs its arguments and prints canned
# signature details, so this needs no signing identity and no real Mach-O.
#
# Not in CI (lead, 2026-10-23: no new CI tests); run it when you change
# sign-cef.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sign-cef-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The stand-in. Signing: one log line of arguments, and a copy of the
# --entitlements file as <log>.ents/<target name>. `-d --verbose=2 X` prints
# $FAKE/<name of X>.info, `-d --entitlements :- X` prints $FAKE/<name>.ents,
# `--verify ... X` exits with $FAKE/<name>.verify (default 0).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/codesign" <<'STUB'
#!/usr/bin/env bash
target="${!#}"
name="$(basename "$target")"
case " $* " in
  *" --sign "*)
    printf '%s\n' "$*" >> "$CODESIGN_LOG"
    prev=""
    for arg in "$@"; do
      if [[ "$prev" == --entitlements ]]; then mkdir -p "$CODESIGN_LOG.ents"; cp "$arg" "$CODESIGN_LOG.ents/$name"; fi
      prev="$arg"
    done ;;
  *" --entitlements :- "*) cat "$FAKE/$name.ents" 2>/dev/null || true ;;
  *" -d "*) cat "$FAKE/$name.info" ;;
  *" --verify "*) exit "$(cat "$FAKE/$name.verify" 2>/dev/null || echo 0)" ;;
esac
STUB
chmod +x "$TMP/bin/codesign"

bundle() { # <dir> [host]: an app with the engine, the shim, three helpers and, with "host", the host
  local fw="$1/app.app/Contents/Frameworks" helper
  mkdir -p "$fw/Chromium Embedded Framework.framework/Versions/A/Libraries"
  : > "$fw/Chromium Embedded Framework.framework/Versions/A/Libraries/libEGL.dylib"
  : > "$fw/libcmux_cef_shim.dylib"
  for helper in "app Helper" "app Helper (GPU)" "app Helper (Renderer)"; do
    mkdir -p "$fw/$helper.app/Contents/MacOS"
  done
  mkdir -p "$1/app.app/Contents/MacOS"
  : > "$1/app.app/Contents/MacOS/app"
  if [[ "${2:-}" == host ]]; then : > "$1/app.app/Contents/MacOS/app Chromium Host"; fi
}
sign() { # <dir> <identity> [VAR=value...]: sign-cef.sh's exit status
  local dir="$1" identity="$2"
  shift 2
  env CODESIGN_LOG="$dir/codesign.log" PATH="$TMP/bin:/usr/bin:/bin" "$@" \
    /bin/bash "$ROOT/scripts/cmux-next/sign-cef.sh" "$dir/app.app" "$identity" > "$dir/sign.out" 2>&1
}
plist() { # <file> <key>...
  local file="$1" key
  shift
  { echo '<plist version="1.0"><dict>'; for key in "$@"; do echo "<key>$key</key><true/>"; done; echo '</dict></plist>'; } > "$file"
}

# 1. No host (CEF only).
mkdir "$TMP/nohost"
bundle "$TMP/nohost"
status=0
sign "$TMP/nohost" - CMUX_CEF_BUNDLE_ID=test.app || status=$?
(( status == 0 )) || fail "sign-cef.sh exited $status for a bundle with no Chromium host: $(cat "$TMP/nohost/sign.out")"
log="$(cat "$TMP/nohost/codesign.log")"
grep -q '/libEGL.dylib$' <<<"$log" || fail "the framework's libraries were not signed: $log"
grep -q 'Chromium Embedded Framework.framework$' <<<"$log" || fail "the framework was not signed: $log"
grep -q '/libcmux_cef_shim.dylib$' <<<"$log" || fail "the shim was not signed: $log"
grep -q -- '--entitlements .*app Helper (GPU).app$' <<<"$log" || fail "the GPU helper lost its JIT entitlements: $log"
grep -q -- '--entitlements .*app Helper (Renderer).app$' <<<"$log" || fail "the renderer helper lost its JIT entitlements: $log"
grep -q 'app Helper.app$' <<<"$log" || fail "the base helper was not signed: $log"
grep -q 'com.apple.security.cs.allow-jit' "$TMP/nohost/codesign.log.ents/app Helper (GPU).app" || fail "the GPU helper's entitlements have no allow-jit"
if grep -q 'Chromium Host' <<<"$log"; then fail "a host was signed in a bundle without one: $log"; fi

# 2. With the host, ad hoc (dev builds): signed last, after the helpers, as
# test.app.chromium-host, with the host entitlements: no cs.* key.
mkdir "$TMP/adhoc"
bundle "$TMP/adhoc" host
status=0
sign "$TMP/adhoc" - CMUX_CEF_BUNDLE_ID=test.app || status=$?
(( status == 0 )) || fail "sign-cef.sh exited $status for a bundle with the Chromium host: $(cat "$TMP/adhoc/sign.out")"
last="$(tail -n 1 "$TMP/adhoc/codesign.log")"
[[ "$last" == *"Contents/MacOS/app Chromium Host" ]] || fail "the host was not signed last: $last"
[[ "$last" == *"--identifier test.app.chromium-host "* ]] || fail "the host was not signed as test.app.chromium-host: $last"
[[ "$last" != *"--options runtime"* ]] || fail "an ad hoc host got the hardened runtime: $last"
ents="$TMP/adhoc/codesign.log.ents/app Chromium Host"
[[ -f "$ents" ]] || fail "the host was signed without its entitlements file: $last"
if grep -q 'com.apple.security.cs\.' "$ents"; then fail "the host has a cs.* entitlement: $(cat "$ents")"; fi
for key in com.apple.security.device.audio-input com.apple.security.device.camera com.apple.security.personal-information.location; do
  grep -q "<key>$key</key><true/>" "$ents" || fail "the host entitlements lack $key: $(cat "$ents")"
done
[[ "$(grep -c '<key>' "$ents")" == 3 ]] || fail "the host has entitlements beyond Chrome's browser-process set: $(cat "$ents")"

# 3. Developer ID: the host gets the hardened runtime and a secure timestamp;
# the bundle id comes from the app's Info.plist when CMUX_CEF_BUNDLE_ID is unset.
mkdir "$TMP/release"
bundle "$TMP/release" host
/usr/bin/python3 -c 'import plistlib, sys; plistlib.dump({"CFBundleIdentifier": "com.cmuxterm.app"}, open(sys.argv[1], "wb"))' \
  "$TMP/release/app.app/Contents/Info.plist"
status=0
sign "$TMP/release" "Developer ID Application: Test (TEAM123456)" || status=$?
(( status == 0 )) || fail "sign-cef.sh exited $status for a Developer ID host: $(cat "$TMP/release/sign.out")"
last="$(tail -n 1 "$TMP/release/codesign.log")"
[[ "$last" == *"--options runtime --timestamp "* ]] || fail "the Developer ID host has no hardened runtime and timestamp: $last"
[[ "$last" == *"--identifier com.cmuxterm.app.chromium-host "* ]] || fail "the host identifier did not come from Info.plist: $last"

# 4. A host with no bundle id to name it: signing fails, it does not guess.
mkdir "$TMP/noid"
bundle "$TMP/noid" host
if sign "$TMP/noid" -; then fail "sign-cef.sh signed a host with no bundle id"; fi
grep -q 'no bundle id for the Chromium host' "$TMP/noid/sign.out" || fail "no error names the missing bundle id: $(cat "$TMP/noid/sign.out")"

# 5. --verify-host.
FAKE="$TMP/fake"
mkdir -p "$FAKE"
export FAKE
verify() { # <app> [VAR=value...]: --verify-host's exit status, output in $TMP/verify.out
  local app="$1"
  shift
  env PATH="$TMP/bin:/usr/bin:/bin" CMUX_CEF_BUNDLE_ID=com.cmuxterm.app "$@" \
    /bin/bash "$ROOT/scripts/cmux-next/sign-cef.sh" --verify-host "$app" > "$TMP/verify.out" 2>&1
}
good_host() {
  printf 'Identifier=com.cmuxterm.app\nCodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+7 location=embedded\nTeamIdentifier=TEAM123456\nTimestamp=Oct 26, 2026\n' > "$FAKE/app.app.info"
  printf 'Identifier=com.cmuxterm.app.chromium-host\nCodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+7 location=embedded\nTeamIdentifier=TEAM123456\nTimestamp=Oct 26, 2026\n' > "$FAKE/app Chromium Host.info"
  plist "$FAKE/app Chromium Host.ents" com.apple.security.device.camera com.apple.security.personal-information.location com.apple.security.device.audio-input
  rm -f "$FAKE/app Chromium Host.verify"
}
app="$TMP/release/app.app"
good_host
verify "$app" || fail "--verify-host refused a well signed host: $(cat "$TMP/verify.out")"
grep -q 'Chromium host signature OK' "$TMP/verify.out" || fail "--verify-host printed no OK line: $(cat "$TMP/verify.out")"

expect_refused() { # <what> <message pattern> [VAR=value...]
  local what="$1" pattern="$2"
  shift 2
  if verify "$app" "$@"; then fail "--verify-host accepted $what"; fi
  grep -q -- "$pattern" "$TMP/verify.out" || fail "--verify-host refused $what without saying '$pattern': $(cat "$TMP/verify.out")"
}
sed -i.bak 's/flags=0x10000(runtime)/flags=0x0(none)/' "$FAKE/app Chromium Host.info"
expect_refused "a host without the hardened runtime" "not signed with the hardened runtime"
good_host
sed -i.bak 's/TEAM123456/OTHERTEAM1/' "$FAKE/app Chromium Host.info"
expect_refused "a host of another team" "signed by team 'OTHERTEAM1'"
good_host
sed -i.bak '/^Timestamp=/d' "$FAKE/app Chromium Host.info"
expect_refused "a host without a secure timestamp" "no secure timestamp"
verify "$app" CMUX_TIMESTAMP=none || fail "--verify-host with CMUX_TIMESTAMP=none still wanted a timestamp: $(cat "$TMP/verify.out")"
good_host
sed -i.bak 's/^Identifier=.*/Identifier=app Chromium Host/' "$FAKE/app Chromium Host.info"
expect_refused "a host signed with its file name as identifier" "not 'com.cmuxterm.app.chromium-host'"
good_host
plist "$FAKE/app Chromium Host.ents" com.apple.security.device.camera com.apple.security.personal-information.location \
  com.apple.security.device.audio-input com.apple.security.cs.allow-jit
expect_refused "a host with allow-jit" "com.apple.security.cs.allow-jit"
good_host
: > "$FAKE/app Chromium Host.ents"
expect_refused "a host with no entitlements (no camera or microphone under the hardened runtime)" "has entitlements \[\]"
good_host
echo 1 > "$FAKE/app Chromium Host.verify"
expect_refused "a host whose signature does not verify" "codesign --verify --strict failed"
good_host
sed -i.bak '/^TeamIdentifier=/d' "$FAKE/app.app.info"
expect_refused "an app with no team" "has no signing team"
verify "$TMP/nohost/app.app" || fail "--verify-host failed for an app with no host: $(cat "$TMP/verify.out")"

echo "sign-cef tests: ok"
