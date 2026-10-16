#!/usr/bin/env bash
# Every keychain-access-groups entry an entitlements file asks for must be
# granted by the provisioning profile it is signed with: an exact entry, or the
# profile's "<team>.*" wildcard. A group the profile does not grant makes AMFI
# refuse to launch the notarized app (passkeys.md K3/K5 class), so signing
# jobs run this before codesign.
#
# The app asks for "<team>.<bundle id>.webauthn" next to its own group: the
# keychain group of Chromium's macOS platform authenticator (passkeys.md K19).
# The Developer ID profiles grant "7WLXT3NR37.*", which covers it.
#
# Usage: check-profile-keychain-groups.sh <entitlements.plist> <profile.provisionprofile|decoded profile .plist>
set -euo pipefail
[[ $# -eq 2 ]] || { echo "usage: $0 <entitlements> <profile>" >&2; exit 2; }
entitlements="$1"
profile="$2"
decoded="$(mktemp)"
trap 'rm -f "$decoded"' EXIT
if ! plutil -lint "$profile" >/dev/null 2>&1; then
  security cms -D -i "$profile" > "$decoded"
else
  cp "$profile" "$decoded"
fi

list() { # <plist> <key path>: one array element per line, nothing when absent
  local i=0 value
  while value="$(/usr/libexec/PlistBuddy -c "Print :$2:$i" "$1" 2>/dev/null)"; do
    printf '%s\n' "$value"
    i=$((i + 1))
  done
}

granted="$(list "$decoded" "Entitlements:keychain-access-groups")"
status=0
while IFS= read -r group; do
  [[ -n "$group" ]] || continue
  ok=0
  while IFS= read -r pattern; do
    [[ -n "$pattern" ]] || continue
    if [[ "$pattern" == "$group" ]]; then ok=1; break; fi
    if [[ "$pattern" == *'.*' && "$group" == "${pattern%\*}"* ]]; then ok=1; break; fi
  done <<< "$granted"
  if [[ $ok -eq 1 ]]; then
    echo "keychain group $group: granted by the profile"
  else
    echo "keychain group $group: NOT granted by the profile (grants: $(tr '\n' ' ' <<< "$granted"))" >&2
    status=1
  fi
done < <(list "$entitlements" "keychain-access-groups")
exit $status
