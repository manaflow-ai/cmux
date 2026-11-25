#!/usr/bin/env bash
# scripts/cmux-next/pkg: the installer package of cmux NEXT and its pre-warm postinstall (RFD 0134 Table 4 row 1).
# Runs on Linux: pkgbuild, productbuild, plutil, launchctl, sudo and id are stubs; the app is a fake bundle whose
# executables are shell scripts that log how they were run.
# build-pkg.sh:
# - an unsigned build hands pkgbuild a root of the app, /Applications, the bundle id's .pkg identifier, the
#   build as version, a component plist that never relocates or version-skips, and a scripts folder with the
#   postinstall and pkg.env; productbuild gets an arm64 distribution and no --sign;
# - --sign and --keychain reach productbuild; --notarize without --sign is refused;
# - an app whose code lacks the pre-warm arguments, or whose Info.plist has an odd character, is refused.
# postinstall:
# - as the console user (launchctl asuser, sudo -u): the app's --cmux-prewarm-launch, cmux and cmux-tui --version
#   and each helper's --version first, the app's --cmux-prewarm-chromium after all of them, the copy chowned to
#   the user, the launch marker left in the user's Application Support; exit 0;
# - a run that hangs is stopped at the run cap and the install still exits 0, well inside the total cap;
# - a failing run, no console user, another volume, or no app: exit 0, and nothing runs in the last three.
# scripts/ci/nightly-steps/next-pkg.sh (nightly.yml nightly-next-pkg):
# - the DMG's app goes to build-pkg.sh with the Installer identity and --notarize, the .pkg beside the DMG in R2;
# - no Installer identity, a failed build, no certificate or no DMG: exit 0 with a next-pkg: line.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
PKG_DIR="$ROOT/scripts/cmux-next/pkg"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

stubs="$TMP/stubs"; mkdir -p "$stubs"
# plutil -extract KEY raw -o - PLIST: the <string> on <key>KEY</key>'s line.
cat >"$stubs/plutil" <<'EOF'
#!/usr/bin/env bash
key="$2" file="${@: -1}"
awk -v k="<key>$key</key>" 'index($0, k) { sub(/.*<string>/, ""); sub(/<\/string>.*/, ""); print; exit }' "$file" | grep .
EOF
# pkgbuild/productbuild: record the arguments and what the folders they name hold; write the output file.
cat >"$stubs/pkgbuild" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$STUB_LOG/pkgbuild.args"
while [ "$#" -gt 1 ]; do
  case "$1" in
    --scripts) cp -R "$2" "$STUB_LOG/scripts" ;;
    --component-plist) cp "$2" "$STUB_LOG/component.plist" ;;
    --root) ls "$2" >"$STUB_LOG/root.ls" ;;
  esac
  shift
done
echo component >"$1"
EOF
cat >"$stubs/productbuild" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$STUB_LOG/productbuild.args"
[ "$1" = --distribution ] && cp "$2" "$STUB_LOG/distribution.xml"
echo product >"${@: -1}"
EOF
chmod +x "$stubs"/*

# make_app DIR [FLAGS]: a fake cmux NEXT bundle; FLAGS=0 leaves the pre-warm arguments out of its code.
make_app() {
  local app="$1/cmux NEXT.app" flags="${2:-1}"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/bin" \
    "$app/Contents/Frameworks/CmuxNextApp.framework/Versions/A" \
    "$app/Contents/Frameworks/cmux NEXT Helper.app/Contents/MacOS" \
    "$app/Contents/Frameworks/cmux NEXT Helper (GPU).app/Contents/MacOS"
  cat >"$app/Contents/Info.plist" <<'EOF'
<plist><dict>
<key>CFBundleIdentifier</key><string>com.cmuxterm.app.nightly</string>
<key>CFBundleVersion</key><string>4514220751701</string>
<key>CFBundleShortVersionString</key><string>0.70.0</string>
<key>CFBundleExecutable</key><string>cmux NEXT</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
EOF
  # Every executable logs "<name> <args> HOME=<home>" and does what RUN_<tag> says (sleep N, exit N).
  local runner='#!/usr/bin/env bash
echo "$(basename "$0") $* HOME=$HOME" >>"$RUN_LOG"
case "$*" in
  *--cmux-prewarm-chromium*) eval "${RUN_CHROMIUM:-:}" ;;
  *) eval "${RUN_DEFAULT:-:}" ;;
esac'
  printf '%s\n' "$runner" >"$app/Contents/MacOS/cmux NEXT"
  [ "$flags" = 1 ] && echo '# --cmux-prewarm-launch --cmux-prewarm-chromium' >>"$app/Contents/Frameworks/CmuxNextApp.framework/Versions/A/CmuxNextApp"
  echo data >"$app/Contents/Frameworks/CmuxNextApp.framework/Versions/A/Resources.dat"
  printf '%s\n' "$runner" >"$app/Contents/Resources/bin/cmux"
  printf '%s\n' "$runner" >"$app/Contents/Resources/bin/cmux-tui"
  printf '%s\n' "$runner" >"$app/Contents/Frameworks/cmux NEXT Helper.app/Contents/MacOS/cmux NEXT Helper"
  printf '%s\n' "$runner" >"$app/Contents/Frameworks/cmux NEXT Helper (GPU).app/Contents/MacOS/cmux NEXT Helper (GPU)"
  chmod +x "$app/Contents/MacOS/cmux NEXT" "$app/Contents/Resources/bin/"* "$app/Contents/Frameworks/"*.app/Contents/MacOS/*
  echo "$app"
}

build() { env PATH="$stubs:$PATH" PKGBUILD="$stubs/pkgbuild" PRODUCTBUILD="$stubs/productbuild" PLUTIL="$stubs/plutil" \
  STUB_LOG="$STUB_LOG" bash "$PKG_DIR/build-pkg.sh" "$@"; }

# --- build-pkg.sh ---
STUB_LOG="$TMP/b1"; mkdir -p "$STUB_LOG"
app=$(make_app "$TMP/b1")
build "$app" "$TMP/b1/out/cmux.pkg" >"$TMP/b1.log" 2>&1 || { cat "$TMP/b1.log"; fail "an unsigned build succeeds"; }
[ -s "$TMP/b1/out/cmux.pkg" ] || fail "the product archive is written"
grep -qx -- "--install-location" "$STUB_LOG/pkgbuild.args" && grep -qx /Applications "$STUB_LOG/pkgbuild.args" || fail "installs into /Applications"
grep -qx com.cmuxterm.app.nightly.pkg "$STUB_LOG/pkgbuild.args" || fail "the package id is the bundle id's .pkg"
grep -qx 4514220751701 "$STUB_LOG/pkgbuild.args" || fail "the package version is the build"
grep -qx "cmux NEXT.app" "$STUB_LOG/root.ls" || fail "the root holds the app"
grep -A0 BundleIsRelocatable "$STUB_LOG/component.plist" | grep -q '<false/>' || fail "the bundle is never relocated"
grep BundleIsVersionChecked "$STUB_LOG/component.plist" | grep -q '<false/>' || fail "a newer copy never skips the install"
[ -x "$STUB_LOG/scripts/postinstall" ] || fail "the scripts folder has an executable postinstall"
cmp -s "$STUB_LOG/scripts/postinstall" "$PKG_DIR/postinstall" || fail "the postinstall is the repo's"
( . "$STUB_LOG/scripts/pkg.env"; [ "$APP_NAME" = "cmux NEXT.app" ] && [ "$EXECUTABLE" = "cmux NEXT" ] \
  && [ "$BUNDLE_ID" = com.cmuxterm.app.nightly ] && [ "$BUILD" = 4514220751701 ] ) || fail "pkg.env names the app, executable, id and build"
grep -q 'hostArchitectures="arm64"' "$STUB_LOG/distribution.xml" || fail "the distribution is arm64"
grep -q '<os-version min="14.0"/>' "$STUB_LOG/distribution.xml" || fail "the distribution takes the app's minimum macOS"
grep -qx -- --sign "$STUB_LOG/productbuild.args" && fail "an unsigned build passes no --sign"
grep -q "unsigned, notarized no" "$TMP/b1.log" || fail "the summary says unsigned"
pass "an unsigned build"

STUB_LOG="$TMP/b2"; mkdir -p "$STUB_LOG"
build "$app" "$TMP/b2/cmux.pkg" --sign "Developer ID Installer: Manaflow (TEAM)" --keychain "$TMP/k.keychain" >/dev/null 2>&1 || fail "a signed build succeeds"
grep -qx "Developer ID Installer: Manaflow (TEAM)" "$STUB_LOG/productbuild.args" || fail "--sign reaches productbuild"
grep -qx "$TMP/k.keychain" "$STUB_LOG/productbuild.args" || fail "--keychain reaches productbuild"
pass "--sign and --keychain reach productbuild"

build "$app" "$TMP/b2/n.pkg" --notarize >"$TMP/b3.log" 2>&1 && fail "--notarize without --sign is refused"
grep -q "needs --sign" "$TMP/b3.log" || fail "the refusal says --notarize needs --sign"
STUB_LOG="$TMP/b4"; mkdir -p "$STUB_LOG"
old=$(make_app "$TMP/b4" 0)
build "$old" "$TMP/b4/o.pkg" >"$TMP/b4.log" 2>&1 && fail "an app without the pre-warm arguments is refused"
grep -q "does not know --cmux-prewarm-launch" "$TMP/b4.log" || fail "the refusal names the argument"
sed -i.bak 's/4514220751701/45";rm -rf x;"/' "$app/Contents/Info.plist"
build "$app" "$TMP/b2/x.pkg" >"$TMP/b5.log" 2>&1 && fail "an odd character in Info.plist is refused"
mv "$app/Contents/Info.plist.bak" "$app/Contents/Info.plist"
pass "refusals"

# --- postinstall ---
cat >"$stubs/launchctl" <<'EOF'
#!/usr/bin/env bash
[ "$1" = asuser ] && [ "$2" = 501 ] || { echo "launchctl $*" >>"$RUN_LOG"; exit 9; }
shift 2; exec "$@"
EOF
cat >"$stubs/sudo" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -u ] && [ "$2" = leo ] && [ "$3" = -H ] || { echo "sudo $*" >>"$RUN_LOG"; exit 9; }
shift 3; HOME="$USER_HOME" exec "$@"
EOF
printf '#!/usr/bin/env bash\n[ "$1 $2" = "-u leo" ] && echo 501\n' >"$stubs/id"
printf '#!/usr/bin/env bash\necho "chown $*" >>"$RUN_LOG"\n' >"$stubs/chown"
chmod +x "$stubs"/*

# install CASE [ENV...]: a fresh app in CASE/Applications, the package's scripts folder beside it, postinstall run.
install() {
  local dir="$TMP/$1"; shift
  mkdir -p "$dir/Applications" "$dir/home" "$dir/scripts"
  make_app "$dir/Applications" >/dev/null
  cp "$PKG_DIR/postinstall" "$dir/scripts/"
  cp "$TMP/b1/scripts/pkg.env" "$dir/scripts/"
  : >"$dir/runs.log"
  local start=$SECONDS
  env RUN_LOG="$dir/runs.log" USER_HOME="$dir/home" CMUX_PKG_CONSOLE_USER=leo CMUX_PKG_LAUNCHCTL="$stubs/launchctl" \
    CMUX_PKG_SUDO="$stubs/sudo" CMUX_PKG_ID="$stubs/id" CMUX_PKG_CHOWN="$stubs/chown" "$@" \
    bash "$dir/scripts/postinstall" "$TMP/cmux.pkg" "$dir/Applications" "${VOLUME:-/}" >"$dir/install.log" 2>&1
  STATUS=$? ELAPSED=$((SECONDS - start))
  RUNS="$dir/runs.log" OUT="$dir/install.log" HOMEDIR="$dir/home"
}

install p1
[ "$STATUS" = 0 ] || { cat "$OUT"; fail "a clean install exits 0"; }
for run in "cmux NEXT --cmux-prewarm-launch" "cmux --version" "cmux-tui --version" "cmux NEXT Helper --version" \
  "cmux NEXT Helper (GPU) --version" "cmux NEXT --cmux-prewarm-chromium"; do
  grep -qF "$run HOME=$HOMEDIR" "$RUNS" || { cat "$RUNS" "$OUT"; fail "ran as the console user: $run"; }
done
[ "$(tail -2 "$RUNS" | grep -c . )" -ge 1 ] && grep -n . "$RUNS" | tail -2 | grep -q -- "--cmux-prewarm-chromium" \
  || { cat "$RUNS"; fail "Chromium's start runs after every first-wave run"; }
[ "$(grep -c -- --cmux-prewarm-chromium "$RUNS")" = 1 ] || fail "Chromium's start runs once"
grep -q "chown -R leo $TMP/p1/Applications/cmux NEXT.app" "$RUNS" || fail "the copy is handed to the console user"
[ "$(cat "$HOMEDIR/Library/Application Support/com.cmuxterm.app.nightly/launch-prewarm")" = 4514220751701 ] \
  || fail "the launch marker names the build"
grep -q "^cmux pkg pre-warm: Frameworks read exit 0" "$OUT" || { cat "$OUT"; fail "the Frameworks are read"; }
grep -q "^cmux pkg pre-warm: done in" "$OUT" || fail "the log ends with done"
pass "postinstall pre-warms as the console user"

install p2 CMUX_PKG_PREWARM_RUN_S=2 CMUX_PKG_PREWARM_TOTAL_S=6 RUN_DEFAULT='sleep 60'
[ "$STATUS" = 0 ] || fail "a hanging run still exits 0"
[ "$ELAPSED" -le 12 ] || fail "hanging runs are stopped (took $ELAPSED s)"
grep -q "cmux NEXT --cmux-prewarm-launch stopped at" "$OUT" || { cat "$OUT"; fail "the hanging run is stopped and logged"; }
pgrep -f "$TMP/p2/" >/dev/null && fail "nothing from the copy is left running"
pass "a hanging run is stopped at its cap"

install p3 RUN_DEFAULT='exit 3' RUN_CHROMIUM='exit 4'
[ "$STATUS" = 0 ] || fail "failing runs still exit 0"
grep -q "cmux --version exit 3" "$OUT" && grep -q "cmux NEXT --cmux-prewarm-chromium exit 4" "$OUT" || { cat "$OUT"; fail "each status is logged"; }
pass "failing runs never fail the install"

install p4 CMUX_PKG_CONSOLE_USER=loginwindow
[ "$STATUS" = 0 ] && [ ! -s "$RUNS" ] && grep -q "no person at the console" "$OUT" || fail "no console user: nothing runs"
install p5 CMUX_PKG_CONSOLE_USER=
[ "$STATUS" = 0 ] && [ ! -s "$RUNS" ] || fail "an empty console user: nothing runs"
VOLUME=/Volumes/Other install p6
[ "$STATUS" = 0 ] && [ ! -s "$RUNS" ] && grep -q "not the boot volume" "$OUT" || fail "another volume: nothing runs"
install p7; rm -rf "$TMP/p7/Applications/cmux NEXT.app"
env CMUX_PKG_CONSOLE_USER=leo bash "$TMP/p7/scripts/postinstall" x "$TMP/p7/Applications" / >"$TMP/p7.log" 2>&1 \
  && grep -q "no app at" "$TMP/p7.log" || fail "no app: exit 0 and says so"
pass "no console user, another volume, no app: exit 0, nothing runs"

# --- scripts/ci/nightly-steps/next-pkg.sh (the nightly job) ---
NP="$ROOT/scripts/ci/nightly-steps/next-pkg.sh"
nl="$TMP/np"; mkdir -p "$nl/vol"
make_app "$nl/vol" >/dev/null
touch "$nl/cmux-nightly-next-macos-arm64-77.dmg"
printf '#!/usr/bin/env bash\necho "keychain $*" >>"$NP_LOG"\n' >"$stubs/keychain"
# hdiutil attach DMG ... -mountpoint M: M becomes a copy of the fake volume.
cat >"$stubs/hdiutil" <<'EOF'
#!/usr/bin/env bash
echo "hdiutil $1" >>"$NP_LOG"
if [ "$1" = attach ]; then while [ "$#" -gt 1 ]; do [ "$1" = -mountpoint ] && cp -R "$NP_VOL/." "$2/"; shift; done; fi
exit 0
EOF
printf '#!/usr/bin/env bash\ncp -R "$1" "$2"\n' >"$stubs/ditto"
printf '#!/usr/bin/env bash\necho "build-pkg $*" >>"$NP_LOG"; [ -n "${BUILD_FAIL:-}" ] && exit 1; echo pkg >"$2"\n' >"$stubs/buildpkg"
printf '#!/usr/bin/env bash\necho "upload $*" >>"$NP_LOG"\n' >"$stubs/upload"
printf '#!/usr/bin/env bash\necho "guard $*" >>"$NP_LOG"\n' >"$stubs/guard"
cat >"$stubs/security" <<'EOF'
#!/usr/bin/env bash
[ -n "${NO_INSTALLER:-}" ] || echo '  2) ABC "Developer ID Installer: Manaflow (TEAM)"'
echo '  1) DEF "Developer ID Application: Manaflow (TEAM)"'
EOF
chmod +x "$stubs"/*
np() {
  NP_LOG="$nl/$1.log"; : >"$NP_LOG"; shift
  env NP_LOG="$NP_LOG" NP_VOL="$nl/vol" HDIUTIL="$stubs/hdiutil" SECURITY="$stubs/security" DITTO="$stubs/ditto" \
    BUILD_PKG="$stubs/buildpkg" KEYCHAIN_TOOL="$stubs/keychain" UPLOAD="$stubs/upload" GUARD="$stubs/guard" \
    APPLE_CERTIFICATE_BASE64=x APPLE_CERTIFICATE_PASSWORD=y R2_ENDPOINT=https://r2 NIGHTLY_NEXT_R2_BUCKET=b \
    NIGHTLY_NEXT_R2_PREFIX=nightly-next/ CHANNEL_DMG_PREFIX=cmux-nightly-next-macos NIGHTLY_VARIANT=arm64 RUNNER_TEMP="$TMP" \
    GITHUB_STEP_SUMMARY= "$@" bash "$NP" "$nl/cmux-nightly-next-macos-arm64-77.dmg" "$nl/out" >"$NP_LOG.out" 2>&1
  NP_STATUS=$?
}
np n1
[ "$NP_STATUS" = 0 ] || { cat "$NP_LOG.out"; fail "a package build exits 0"; }
grep -qF "cmux NEXT.app $nl/out/cmux-nightly-next-macos-arm64-77.pkg --sign Developer ID Installer: Manaflow (TEAM) --keychain build.keychain --notarize" "$NP_LOG" \
  || { cat "$NP_LOG"; fail "build-pkg.sh gets the app, the DMG's stem as .pkg, the Installer identity and --notarize"; }
grep -qF -- "--key nightly-next/cmux-nightly-next-macos-arm64-77.pkg" "$NP_LOG" && grep -qF -- "--key nightly-next/cmux-nightly-next-macos-arm64.pkg" "$NP_LOG" \
  || { cat "$NP_LOG"; fail "the package goes beside the DMG and under the channel's stable name"; }
grep -qF "guard r2-key b nightly-next/cmux-nightly-next-macos-arm64-77.pkg" "$NP_LOG" || fail "each key passes nightly-next-guard first"
grep -q "keychain delete" "$NP_LOG" || fail "the signing keychain is deleted"
grep -q "^next-pkg: built cmux-nightly-next-macos-arm64-77.pkg" "$NP_LOG.out" || { cat "$NP_LOG.out"; fail "one line says it was built"; }
pass "next-pkg.sh builds, signs, notarizes and uploads"

np n2 NO_INSTALLER=1
{ [ "$NP_STATUS" = 0 ] && ! grep -q build-pkg "$NP_LOG" && ! grep -q upload "$NP_LOG" && grep -q "keychain delete" "$NP_LOG" \
  && grep -q "no Developer ID Installer identity" "$NP_LOG.out"; } || { cat "$NP_LOG" "$NP_LOG.out"; fail "no Installer identity: exit 0, nothing built, says so"; }
np n3 BUILD_FAIL=1
{ [ "$NP_STATUS" = 0 ] && ! grep -q upload "$NP_LOG" && grep -q "build-pkg.sh failed" "$NP_LOG.out"; } || fail "a failed build: exit 0, nothing uploaded"
np n4 APPLE_CERTIFICATE_BASE64=
{ [ "$NP_STATUS" = 0 ] && [ ! -s "$NP_LOG" ] && grep -q "no signing certificate" "$NP_LOG.out"; } || fail "no certificate: exit 0, nothing runs"
{ bash "$NP" "$nl/missing.dmg" "$nl/out" >"$nl/n5.out" 2>&1 && grep -q "no package" "$nl/n5.out"; } || fail "no DMG: exit 0"
pass "next-pkg.sh never fails the nightly"
echo "next-pkg: all passed"
