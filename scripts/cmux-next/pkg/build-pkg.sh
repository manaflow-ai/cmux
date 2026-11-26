#!/usr/bin/env bash
# Build an installer package (.pkg) of cmux NEXT from its release .app, with a postinstall that pre-warms the
# installed copy as the console user (scripts/cmux-next/pkg/postinstall; RFD 0134 Table 4 row 1).
#
# Usage:
#   build-pkg.sh APP OUT.pkg [--sign IDENTITY] [--keychain PATH] [--notarize]
#
#   APP         the signed (and notarized) release .app, as the DMG carries it
#   OUT.pkg     the product archive to write
#   --sign      a "Developer ID Installer: ..." identity (default: $CMUX_PKG_INSTALLER_IDENTITY; none: unsigned)
#   --keychain  the keychain holding it (productbuild --keychain)
#   --notarize  submit OUT.pkg to Apple (notarytool, ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_P8_BASE64
#               as scripts/ci/lib/notary-auth.sh takes them) and staple the ticket; needs --sign
#
# The package installs APP into /Applications (never relocated to another copy the system finds, never skipped
# for a newer copy already there) and runs postinstall. It refuses an APP whose code does not know the pre-warm
# arguments (--cmux-prewarm-launch, --cmux-prewarm-chromium): an older build would start for real on them.
# Nothing here runs the bundle's code. Tools can be replaced for tests: PKGBUILD, PRODUCTBUILD, PLUTIL, XCRUN.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKGBUILD="${PKGBUILD:-pkgbuild}"
PRODUCTBUILD="${PRODUCTBUILD:-productbuild}"
PLUTIL="${PLUTIL:-plutil}"
XCRUN="${XCRUN:-xcrun}"

die() { echo "build-pkg: $*" >&2; exit 1; }
usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

[ "$#" -ge 2 ] || usage
app="${1%/}" out="$2"; shift 2
identity="${CMUX_PKG_INSTALLER_IDENTITY:-}" keychain="" notarize=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --sign) [ "$#" -ge 2 ] || usage; identity="$2"; shift 2 ;;
    --keychain) [ "$#" -ge 2 ] || usage; keychain="$2"; shift 2 ;;
    --notarize) notarize=1; shift ;;
    *) usage ;;
  esac
done
[ -d "$app/Contents" ] && [ -f "$app/Contents/Info.plist" ] || die "not an app bundle: $app"
[[ "$out" == *.pkg ]] || die "OUT must end in .pkg: $out"
[ "$notarize" = 0 ] || [ -n "$identity" ] || die "--notarize needs --sign (Apple notarizes only a signed package)"

plist() { "$PLUTIL" -extract "$1" raw -o - "$app/Contents/Info.plist" 2>/dev/null || true; }
app_name="$(basename "$app")"
bundle_id="$(plist CFBundleIdentifier)"
build="$(plist CFBundleVersion)"
version="$(plist CFBundleShortVersionString)"
executable="$(plist CFBundleExecutable)"
min_os="$(plist LSMinimumSystemVersion)"
[ -n "$bundle_id" ] && [ -n "$build" ] && [ -n "$executable" ] || die "Info.plist lacks CFBundleIdentifier, CFBundleVersion or CFBundleExecutable"
[ -f "$app/Contents/MacOS/$executable" ] || die "no executable $app/Contents/MacOS/$executable"
# Values go into a shell file and XML: refuse anything but plain names.
for value in "$app_name" "$bundle_id" "$build" "$executable" "${version:-0}" "${min_os:-11.0}"; do
  [[ "$value" =~ ^[A-Za-z0-9\ ._-]+$ ]] || die "unexpected character in '$value'"
done

# The pre-warm arguments are string constants in the app's own code: the executable, or the framework it
# loads (the stub layout, cmux#44204).
for argument in --cmux-prewarm-launch --cmux-prewarm-chromium; do
  grep -rqaF -- "$argument" "$app/Contents/MacOS" "$app/Contents/Frameworks/CmuxNextApp.framework" 2>/dev/null \
    || die "$app_name does not know $argument: its postinstall would start the app, not pre-warm it"
done

work="$(mktemp -d "${TMPDIR:-/tmp}/cmux-pkg.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/root" "$work/scripts" "$work/packages"
# The root holds the app itself (a clone where the volume clones, as APFS does), never a modified copy.
cp -cR "$app" "$work/root/" 2>/dev/null || cp -R "$app" "$work/root/"

cp "$HERE/postinstall" "$work/scripts/postinstall"
chmod 0755 "$work/scripts/postinstall"
printf 'APP_NAME=%q\nEXECUTABLE=%q\nBUNDLE_ID=%q\nBUILD=%q\n' "$app_name" "$executable" "$bundle_id" "$build" >"$work/scripts/pkg.env"

# One bundle at the root: never relocated (installer would otherwise update a copy it finds elsewhere), never
# skipped for a newer version already there, replaced whole.
cat >"$work/component.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
  <dict>
    <key>RootRelativeBundlePath</key><string>$app_name</string>
    <key>BundleIsRelocatable</key><false/>
    <key>BundleIsVersionChecked</key><false/>
    <key>BundleHasStrictIdentifier</key><true/>
    <key>BundleOverwriteAction</key><string>upgrade</string>
  </dict>
</array>
</plist>
EOF

component_id="$bundle_id.pkg"
"$PKGBUILD" --root "$work/root" --component-plist "$work/component.plist" --scripts "$work/scripts" \
  --identifier "$component_id" --version "$build" --install-location /Applications \
  "$work/packages/component.pkg"

archs="${CMUX_PKG_HOST_ARCHS:-arm64}"
cat >"$work/distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>${app_name%.app}</title>
  <options customize="never" require-scripts="false" hostArchitectures="$archs"/>
  <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
  <volume-check>
    <allowed-os-versions><os-version min="${min_os:-11.0}"/></allowed-os-versions>
  </volume-check>
  <choices-outline>
    <line choice="default"><line choice="$component_id"/></line>
  </choices-outline>
  <choice id="default"/>
  <choice id="$component_id" visible="false"><pkg-ref id="$component_id"/></choice>
  <pkg-ref id="$component_id" version="$build" onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
EOF

sign_args=()
if [ -n "$identity" ]; then
  sign_args=(--sign "$identity")
  [ -n "$keychain" ] && sign_args+=(--keychain "$keychain")
fi
mkdir -p "$(dirname "$out")"
"$PRODUCTBUILD" --distribution "$work/distribution.xml" --package-path "$work/packages" ${sign_args[@]+"${sign_args[@]}"} "$out"

notarized=no
if [ "$notarize" = 1 ]; then
  # shellcheck source=../../ci/lib/notary-auth.sh
  source "$HERE/../../ci/lib/notary-auth.sh"
  mkdir -p "$work/notary"
  notary_auth_init "$work/notary" || die "no notarization credentials"
  result="$("$XCRUN" notarytool submit "$out" "${NOTARY_AUTH_ARGS[@]}" --wait --timeout "${CMUX_PKG_NOTARY_TIMEOUT:-40m}" 2>&1)" || true
  echo "$result"
  grep -qE '^ *status: Accepted' <<<"$result" || die "Apple did not accept $out"
  "$XCRUN" stapler staple "$out" || die "stapling $out failed"
  notarized=yes
fi
echo "build-pkg: wrote $out ($app_name $version ($build), ${identity:+signed by $identity}${identity:-unsigned}, notarized $notarized)"
