#!/usr/bin/env bash
# Verify a released cmux .app the way an end user would, against the EXACT
# commands reported in https://github.com/manaflow-ai/cmux/issues/6670:
#
#   codesign --verify --deep --strict --verbose=4 <app>
#   spctl --assess --type execute --verbose=4 <app>
#   codesign -dv --verbose=4 <app>   (Authority chain + Info.plist binding +
#                                      stapled notarization ticket)
#
# The release/nightly pipelines already staple and `spctl`-check the app BEFORE
# it is packaged into the DMG, but they never re-verify the copy a user actually
# extracts from the shipped DMG. This script closes that gap: pointed at the
# final DMG (`--dmg`), it mounts the image read-only, copies the app out with
# `ditto` (exactly as `brew install --cask` and a manual `ditto` install do),
# and runs the end-user verification on that copy. A regression that corrupts
# the signature during DMG packaging — the failure class users report as
# "invalid signature (code or signature have been modified)" /
# "internal error in Code Signing subsystem" — then fails the release instead of
# shipping.
#
# Usage:
#   scripts/verify-released-app-bundle.sh <app-path>
#   scripts/verify-released-app-bundle.sh --dmg <dmg-path>
#   scripts/verify-released-app-bundle.sh --self-test
#
# Env:
#   CMUX_VERIFY_REQUIRE_NOTARIZED  (default: 1)
#     1 -> require Gatekeeper acceptance, a stapled notarization ticket, and a
#          resolvable Developer ID authority chain (release/nightly artifacts).
#     0 -> structural codesign checks only; skip the notarization/Gatekeeper
#          assertions (ad-hoc / local bundles, used by --self-test).

set -euo pipefail

log() { printf '%s\n' "$*" >&2; }
fail() {
  log "ERROR: $*"
  exit 1
}

REQUIRE_NOTARIZED="${CMUX_VERIFY_REQUIRE_NOTARIZED:-1}"

# run_checks <app-path> — run the end-user verification suite on a .app bundle.
run_checks() {
  local app="$1"
  [[ -d "$app" ]] || fail "app bundle not found at $app"
  log "==> verifying $app (require_notarized=$REQUIRE_NOTARIZED)"

  # 1. codesign --verify --deep --strict — catches the user-reported
  #    "invalid signature (code or signature have been modified)" and
  #    "a sealed resource is missing or invalid".
  local verify_out
  if ! verify_out="$(/usr/bin/codesign --verify --deep --strict --verbose=4 "$app" 2>&1)"; then
    log "$verify_out"
    fail "codesign --verify --deep --strict failed for $app"
  fi
  log "    codesign --verify --deep --strict: OK"

  # 2. codesign -dv metadata — Info.plist binding and (when notarized) the
  #    Developer ID authority chain + stapled ticket. The issue showed a broken
  #    install printing "Info.plist=not bound" and "Authority=(unavailable)".
  local meta
  meta="$(/usr/bin/codesign -dv --verbose=4 "$app" 2>&1 || true)"
  if grep -q 'Info.plist=not bound' <<<"$meta"; then
    log "$meta"
    fail "signed app reports Info.plist=not bound for $app"
  fi

  if [[ "$REQUIRE_NOTARIZED" == "1" ]]; then
    grep -q '^Info.plist entries=' <<<"$meta" \
      || { log "$meta"; fail "signed app is missing a bound Info.plist for $app"; }
    grep -q '^Authority=Developer ID Application' <<<"$meta" \
      || { log "$meta"; fail "signed app is missing a Developer ID authority for $app"; }
    grep -q 'Authority=(unavailable)' <<<"$meta" \
      && { log "$meta"; fail "signed app reports Authority=(unavailable) for $app"; }
    grep -q '^Notarization Ticket=stapled' <<<"$meta" \
      || { log "$meta"; fail "signed app is missing a stapled notarization ticket for $app"; }
    log "    codesign -dv: Developer ID authority + stapled ticket present"

    # 3. spctl Gatekeeper assessment — catches the user-reported
    #    "internal error in Code Signing subsystem" and any non-acceptance.
    local spctl_out spctl_rc=0
    spctl_out="$(/usr/sbin/spctl --assess --type execute --verbose=4 "$app" 2>&1)" || spctl_rc=$?
    if [[ "$spctl_rc" -ne 0 ]] \
      || ! grep -q 'accepted' <<<"$spctl_out" \
      || ! grep -q 'source=Notarized Developer ID' <<<"$spctl_out"; then
      log "$spctl_out"
      fail "spctl --assess --type execute did not accept $app as Notarized Developer ID"
    fi
    log "    spctl --assess: accepted (Notarized Developer ID)"
  else
    grep -q '^Info.plist entries=' <<<"$meta" \
      && log "    codesign -dv: Info.plist bound" \
      || log "    codesign -dv: Info.plist binding not reported (ad-hoc bundle)"
  fi

  log "==> OK: $app passes end-user signature verification"
}

# verify_dmg <dmg-path> — mount the shipped DMG read-only, copy the app out with
# ditto (the exact end-user install path), and verify that copy.
verify_dmg() {
  local dmg="$1"
  [[ -f "$dmg" ]] || fail "dmg not found at $dmg"

  local mountpoint extractdir
  mountpoint="$(mktemp -d "${TMPDIR:-/tmp}/cmux-verify-mnt.XXXXXX")"
  extractdir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-verify-app.XXXXXX")"
  # shellcheck disable=SC2064
  trap "/usr/bin/hdiutil detach -force '$mountpoint' >/dev/null 2>&1 || true; rm -rf '$mountpoint' '$extractdir'" EXIT

  log "==> mounting $dmg"
  # Verify the DMG container's own checksum on attach (no -noverify): for a gate
  # that exists to catch silent packaging regressions, a corrupted container
  # must fail here rather than be mounted and extracted anyway.
  /usr/bin/hdiutil attach -nobrowse -readonly -mountpoint "$mountpoint" "$dmg" >/dev/null

  local app
  app="$(/usr/bin/find "$mountpoint" -maxdepth 1 -name '*.app' -print -quit)"
  [[ -n "$app" ]] || fail "no .app found inside $dmg"

  local dest
  dest="$extractdir/$(basename "$app")"
  log "==> extracting $(basename "$app") with ditto"
  /usr/bin/ditto "$app" "$dest"

  run_checks "$dest"
}

# self_test — build a synthetic bundle, ad-hoc sign it, prove run_checks accepts
# it, then tamper a sealed Mach-O resource and prove run_checks rejects it with
# the same failure class as issue #6670. Runs on macOS without any secrets.
self_test() {
  command -v /usr/bin/codesign >/dev/null || fail "self-test requires codesign (macOS)"
  # Dynamic scoping: run_checks (called below) sees this, but the global stays
  # clean for any other call path.
  local REQUIRE_NOTARIZED=0

  local workdir app
  workdir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-verify-selftest.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$workdir'" EXIT
  app="$workdir/SelfTest.app"

  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/bin"
  cp /bin/echo "$app/Contents/MacOS/SelfTest"
  cp /bin/echo "$app/Contents/Resources/bin/helper"
  chmod +x "$app/Contents/MacOS/SelfTest" "$app/Contents/Resources/bin/helper"
  cat >"$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>SelfTest</string>
  <key>CFBundleIdentifier</key><string>com.cmuxterm.app.verify-selftest</string>
  <key>CFBundleName</key><string>SelfTest</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
PLIST

  # Inside-out ad-hoc sign: helper first, then the bundle (no --deep, matching
  # scripts/sign-cmux-bundle.sh ordering).
  /usr/bin/codesign --force --options runtime --timestamp=none --sign - \
    "$app/Contents/Resources/bin/helper" >/dev/null 2>&1
  /usr/bin/codesign --force --options runtime --timestamp=none --sign - \
    "$app" >/dev/null 2>&1

  log "--- self-test: clean bundle should PASS ---"
  if ! run_checks "$app"; then
    fail "self-test FAILED: clean ad-hoc bundle was rejected"
  fi

  log "--- self-test: tampered sealed resource should FAIL ---"
  printf 'tamper' | dd of="$app/Contents/Resources/bin/helper" bs=1 seek=64 conv=notrunc >/dev/null 2>&1
  if ( run_checks "$app" ) >/dev/null 2>&1; then
    fail "self-test FAILED: tampered bundle was accepted (verifier is not catching modifications)"
  fi
  log "--- self-test: tampered bundle correctly rejected ---"
  log "==> self-test OK"
}

main() {
  case "${1:-}" in
    --self-test)
      self_test
      ;;
    --dmg)
      [[ $# -eq 2 ]] || fail "usage: $0 --dmg <dmg-path>"
      verify_dmg "$2"
      ;;
    "" | -h | --help)
      cat >&2 <<EOF
usage:
  $0 <app-path>          verify a .app bundle directly
  $0 --dmg <dmg-path>    mount the DMG, ditto the app out, then verify it
  $0 --self-test         synthesize, sign, tamper, and self-check the verifier
EOF
      [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && exit 0
      exit 2
      ;;
    *)
      run_checks "$1"
      ;;
  esac
}

main "$@"
