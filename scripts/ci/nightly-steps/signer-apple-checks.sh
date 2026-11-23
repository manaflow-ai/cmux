#!/usr/bin/env bash
# nightly.yml signer-dmg-image and verify-final-dmg-nightly (signer-final-dmg-checks.sh): Apple's checks of a cmux NEXT
# app the release runner pool signed, on a Mac with no secrets.
#
#   signer-apple-checks.sh <app>
#
# codesign --verify --deep --strict, a stapled ticket (stapler validate),
# Gatekeeper's verdict (spctl: Notarized Developer ID), syspolicy_check
# distribution. Results go to the step summary.
set -euo pipefail
app="${1%/}"
[[ -d "$app/Contents" ]] || { echo "no app at $app" >&2; exit 1; }
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
notarized() {
  local out
  out="$(spctl -a -vv -t exec "$1" 2>&1)" || { echo "$out" >&2; return 1; }
  echo "$out"
  grep -qx 'source=Notarized Developer ID' <<<"$out" || { echo "$1 is not a Notarized Developer ID app" >&2; return 1; }
}
{
  echo "== codesign --verify --deep --strict"; /usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
  echo "== stapler validate"; xcrun stapler validate "$app"
  echo "== spctl"; notarized "$app"
  echo "== syspolicy_check distribution"; syspolicy_check distribution "$app"
} 2>&1 | tee "$RUNNER_TEMP/apple-checks.txt"

{ echo "### Apple's checks: ${app##*/}"; echo '```'; cat "$RUNNER_TEMP/apple-checks.txt"; echo '```'; } >> "$summary"
