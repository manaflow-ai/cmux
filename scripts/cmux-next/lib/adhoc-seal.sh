# shellcheck shell=bash
# Re-seal a copy of a signed cmux app ad hoc, so it runs after its Info.plist or its code changed. One procedure
# for every copy that must launch the same way: side-instance.sh make (its new identity, and its swapped binary with
# --swap) and swap-binary.sh seal (both arms of a launch A/B, the unchanged nightly included, so the arms differ only
# by the change).
#
#   cmux_adhoc_seal APP SIGNED ENTITLEMENTS_OUT
#
# APP is the copy; SIGNED is the signed app it came from (its entitlements are read there: a swapped executable
# carries none). The outer bundle is re-signed ad hoc; nested code (frameworks, helpers) keeps its own signatures. An
# ad hoc signature may carry only unrestricted entitlements: one that needs the team's provisioning profile (the
# Keychain group, application-identifier, any com.apple.developer key) gets the copy killed at launch, so those go,
# with the profile, and are written to ENTITLEMENTS_OUT. The copy then has no Keychain items of the original's group.
# Returns non-zero when the sealed copy does not verify.
cmux_adhoc_seal() {
  local app="$1" signed="$2" entitlements="$3"
  xattr -cr "$app" 2>/dev/null || true
  rm -f "$app/Contents/embedded.provisionprofile"
  codesign -d --entitlements :- "$signed" 2>/dev/null | python3 -c '
import plistlib, sys
data = sys.stdin.buffer.read()
kept = {k: v for k, v in (plistlib.loads(data) if data.strip() else {}).items() if k.startswith("com.apple.security.")}
sys.stdout.buffer.write(plistlib.dumps(kept))' >"$entitlements"
  # A framework a swap added (swap-binary.sh place) comes unsigned; the outer seal needs its nested code signed.
  local fw
  for fw in "$app/Contents/Frameworks"/*.framework; do
    [[ -d "$fw" ]] || continue
    codesign --verify "$fw" >/dev/null 2>&1 || codesign --force --sign - --timestamp=none "$fw" >&2
  done
  codesign --force --sign - --timestamp=none --entitlements "$entitlements" "$app" 2>&1 | grep -v 'replacing existing signature' >&2 || true
  codesign --verify --strict "$app"
}
