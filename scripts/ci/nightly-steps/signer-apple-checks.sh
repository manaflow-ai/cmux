#!/usr/bin/env bash
# nightly.yml signer-dmg-image and verify-final-dmg-nightly (signer-final-dmg-checks.sh): Apple's checks of a cmux NEXT
# app the release runner pool signed, on a Mac with no secrets.
#
#   signer-apple-checks.sh <app>
#
# codesign --verify --deep --strict, a stapled ticket (stapler validate),
# Gatekeeper's verdict (spctl: Notarized Developer ID), syspolicy_check
# distribution, and the Computer Use helper on its own: cmux copies it out of
# the app before launch, so a copy taken the same way (ditto keeps the stapled
# ticket) must carry its own ticket and pass codesign and spctl, without the
# outer app's ticket. Results go to the step summary.
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
  echo "== Computer Use helper signature"; bash scripts/ci/verify-computer-use-helper.sh signed "$app"
} 2>&1 | tee "$RUNNER_TEMP/apple-checks.txt"

helper="$app/Contents/Library/cmux Computer Use.app"
copy_dir="$(mktemp -d "$RUNNER_TEMP/helper-copy.XXXXXX")"
ditto "$helper" "$copy_dir/cmux Computer Use.app"
copy="$copy_dir/cmux Computer Use.app"
{
  echo "== copied helper: stapler validate"; xcrun stapler validate "$copy"
  echo "== copied helper: codesign --verify --deep --strict"; /usr/bin/codesign --verify --deep --strict --verbose=2 "$copy"
  echo "== copied helper: spctl"; notarized "$copy"
} 2>&1 | tee -a "$RUNNER_TEMP/apple-checks.txt"
rm -rf "$copy_dir"
{ echo "### Apple's checks: ${app##*/}"; echo '```'; cat "$RUNNER_TEMP/apple-checks.txt"; echo '```'; } >> "$summary"
