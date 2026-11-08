#!/usr/bin/env bash
# Keep only previous nightly DMGs that embed the Sparkle key this build signs with.
#
#   drop-previous-nightlies-with-other-sparkle-key.sh <dir-of-previous-dmgs> <public-key>
#
# Sparkle validates a delta update against the installed app's EdDSA key only;
# the Developer ID fallback that lets a full update rotate keys does not apply
# to deltas. After a key change (NIGHTLY_SPARKLE_KEY), a delta built from a
# previous build that embeds the other key can never install: clients download
# it, reject it, and fall back to the full DMG. Removing those DMGs before
# generate_appcast skips building them. Anything unreadable is kept, which only
# costs a delta that might be rejected, never a publish.
set -euo pipefail

dir="${1:?previous DMG directory}"
expected="${2:?Sparkle public key this build signs with}"

shopt -s nullglob
for dmg in "$dir"/*.dmg; do
  mount="$(mktemp -d "${RUNNER_TEMP:-/tmp}/sparkle-key-check.XXXXXX")"
  embedded=""
  if hdiutil attach -nobrowse -readonly -noverify -mountpoint "$mount" "$dmg" >/dev/null 2>&1; then
    app="$(find "$mount" -maxdepth 1 -name '*.app' -print -quit)"
    if [ -n "$app" ]; then
      embedded="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist" 2>/dev/null || true)"
    fi
    hdiutil detach "$mount" -quiet || hdiutil detach "$mount" -force -quiet || true
  fi
  rmdir "$mount" 2>/dev/null || true
  if [ -n "$embedded" ] && [ "$embedded" != "$expected" ]; then
    echo "skipping delta from $(basename "$dmg"): it embeds a different Sparkle key"
    rm -f "$dmg"
  fi
done
