#!/usr/bin/env bash
# nightly.yml nightly-next-pkg: the published nightly-next DMG's app as an installer package whose postinstall
# pre-warms the installed copy (scripts/cmux-next/pkg; RFD 0134 Table 4 row 1, cuts row 2). An update is already
# pre-warmed by the updater (cmux#43890); a first install had nothing, about 2 s of first-sight check before `main`.
#
#   next-pkg.sh DMG OUT_DIR
#
# Writes OUT_DIR/<DMG stem>.pkg, signed with the certificate's "Developer ID Installer" identity, notarized and
# stapled, then uploads it beside the DMG (NIGHTLY_NEXT_R2_PREFIX<stem>.pkg) and as the channel's stable name
# (NIGHTLY_NEXT_R2_PREFIX<prefix>-<variant>.pkg) when R2 credentials are set.
#
# Never fails the nightly: every outcome exits 0 with one "next-pkg:" line saying what happened. A certificate
# with no Installer identity (APPLE_CERTIFICATE_BASE64 holds only "Developer ID Application") builds nothing:
# an unsigned package is refused by Gatekeeper on a double-click, worse than the DMG.
#
# Env: APPLE_CERTIFICATE_BASE64, APPLE_CERTIFICATE_PASSWORD (signing-keychain.sh); ASC_API_KEY_ID,
# ASC_API_ISSUER_ID, ASC_API_KEY_P8_BASE64 (notary-auth.sh); AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, R2_ENDPOINT,
# NIGHTLY_NEXT_R2_BUCKET, NIGHTLY_NEXT_R2_PREFIX (upload); CHANNEL_DMG_PREFIX, NIGHTLY_VARIANT (the stable name).
# Tools can be replaced for tests: HDIUTIL, SECURITY, DITTO, BUILD_PKG, KEYCHAIN_TOOL, UPLOAD.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
HDIUTIL="${HDIUTIL:-hdiutil}"
SECURITY="${SECURITY:-security}"
DITTO="${DITTO:-ditto}"
BUILD_PKG="${BUILD_PKG:-$ROOT/scripts/cmux-next/pkg/build-pkg.sh}"
KEYCHAIN_TOOL="${KEYCHAIN_TOOL:-$ROOT/scripts/ci/signing-keychain.sh}"
UPLOAD="${UPLOAD:-python3 $ROOT/scripts/ci/upload-r2-object.py}"

say() { echo "next-pkg: $*"; [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "next-pkg: $*" >>"$GITHUB_STEP_SUMMARY"; return 0; }

main() {
  local dmg="${1:-}" out_dir="${2:-}"
  [ -f "$dmg" ] && [ -n "$out_dir" ] || { say "usage: next-pkg.sh DMG OUT_DIR (no DMG at '${dmg}'); no package"; return 0; }
  local stem; stem="$(basename "$dmg" .dmg)"
  mkdir -p "$out_dir" || { say "cannot make $out_dir; no package"; return 0; }
  local work; work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/next-pkg.XXXXXX")"
  local mount="$work/mount" keychain_made=0
  # shellcheck disable=SC2317
  cleanup() {
    [ -d "$mount" ] && "$HDIUTIL" detach "$mount" -quiet -force >/dev/null 2>&1
    [ "$keychain_made" = 1 ] && "$KEYCHAIN_TOOL" delete >/dev/null 2>&1
    rm -rf "$work"
  }
  trap cleanup RETURN

  if [ -z "${APPLE_CERTIFICATE_BASE64:-}" ] || [ -z "${APPLE_CERTIFICATE_PASSWORD:-}" ]; then
    say "no signing certificate in this job; no package"; return 0
  fi
  "$KEYCHAIN_TOOL" create >/dev/null || { say "the signing keychain could not be made; no package"; return 0; }
  keychain_made=1
  # productbuild signs with an installer identity, which `find-identity -p codesigning` never lists.
  local identity
  identity="$("$SECURITY" find-identity -v -p basic build.keychain 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Installer: [^"]*\)".*/\1/p' | head -1)"
  if [ -z "$identity" ]; then
    say "the signing certificate holds no Developer ID Installer identity; no package (add one to APPLE_CERTIFICATE_BASE64 to ship it)"
    return 0
  fi

  mkdir -p "$mount"
  "$HDIUTIL" attach "$dmg" -nobrowse -readonly -noautoopen -mountpoint "$mount" -quiet \
    || { say "could not mount $dmg; no package"; return 0; }
  local app
  app="$(find "$mount" -maxdepth 1 -name '*.app' -type d -print -quit)"
  [ -n "$app" ] || { say "no app in $dmg; no package"; return 0; }
  "$DITTO" "$app" "$work/$(basename "$app")" || { say "copying $(basename "$app") out of the DMG failed; no package"; return 0; }
  "$HDIUTIL" detach "$mount" -quiet -force >/dev/null 2>&1; rmdir "$mount" 2>/dev/null

  local pkg="$out_dir/$stem.pkg"
  "$KEYCHAIN_TOOL" unlock >/dev/null 2>&1
  if ! "$BUILD_PKG" "$work/$(basename "$app")" "$pkg" --sign "$identity" --keychain build.keychain --notarize; then
    rm -f "$pkg"; say "build-pkg.sh failed (above); no package"; return 0
  fi
  "$KEYCHAIN_TOOL" delete >/dev/null 2>&1; keychain_made=0

  if [ -z "${R2_ENDPOINT:-}" ] || [ -z "${NIGHTLY_NEXT_R2_BUCKET:-}" ]; then
    say "built $pkg; no R2 credentials, not uploaded"; return 0
  fi
  local key stable="" uploaded=""
  [ -n "${CHANNEL_DMG_PREFIX:-}" ] && [ -n "${NIGHTLY_VARIANT:-}" ] && stable="${CHANNEL_DMG_PREFIX}-${NIGHTLY_VARIANT}.pkg"
  for key in "$stem.pkg" ${stable:+"$stable"}; do
    local cache="public, max-age=31536000, immutable"
    [ "$key" = "$stable" ] && cache="no-cache, no-store, must-revalidate"
    # shellcheck disable=SC2086
    if $UPLOAD --file "$pkg" --endpoint-url "$R2_ENDPOINT" --bucket "$NIGHTLY_NEXT_R2_BUCKET" \
        --key "${NIGHTLY_NEXT_R2_PREFIX:-}$key" --content-type application/octet-stream --cache-control "$cache" >/dev/null; then
      uploaded="$uploaded ${NIGHTLY_NEXT_R2_PREFIX:-}$key"
    else
      say "upload of ${NIGHTLY_NEXT_R2_PREFIX:-}$key failed"
    fi
  done
  say "built $(basename "$pkg") (signed by $identity, notarized, stapled); uploaded:${uploaded:- nothing}"
  return 0
}

main "$@"
exit 0
