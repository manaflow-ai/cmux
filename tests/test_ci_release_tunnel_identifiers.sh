#!/usr/bin/env bash
# Regression guard for the stable release's Cloud tunnel extension naming.
#
# release.yml hardcodes three identifiers for the bundled system extension:
# the bundle identifier passed to scripts/normalize-system-extension-bundle.sh,
# the <bundle id>.systemextension directory it then verifies, and the App ID
# (team prefix + bundle id) that the provisioning profile must name. #11789
# passed the team-prefixed App ID as the bundle identifier, so the first
# release dry run after #12149 failed in "Verify binary architectures":
#   system extension identifier is 'com.cmuxterm.app.tunnel', expected
#   '7WLXT3NR37.com.cmuxterm.app.tunnel'
# Derive all three from the Xcode project so the workflow cannot drift again.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="${CMUX_RELEASE_WORKFLOW_FILE:-$ROOT_DIR/.github/workflows/release.yml}"
PROJECT="${CMUX_PROJECT_FILE:-$ROOT_DIR/cmux.xcodeproj/project.pbxproj}"

# The tunnel target's Release identifier is the one without a .debug segment.
bundle_id="$(grep -E 'PRODUCT_BUNDLE_IDENTIFIER = [A-Za-z0-9.-]+\.tunnel;' "$PROJECT" | sed -E 's/.*= ([A-Za-z0-9.-]+);.*/\1/' | grep -v '\.debug\.' | sort -u)"
if [ "$(wc -l <<<"$bundle_id" | tr -d ' ')" != "1" ] || [ -z "$bundle_id" ]; then
  echo "FAIL: expected exactly one non-debug tunnel PRODUCT_BUNDLE_IDENTIFIER in $PROJECT, got: $(tr '\n' ' ' <<<"$bundle_id")" >&2
  exit 1
fi
team_prefix="$(grep -E 'CMUX_TEAM_ID_PREFIX = "[A-Z0-9]+\.";' "$PROJECT" | sed -E 's/.*= "([A-Z0-9]+\.)";.*/\1/' | sort -u)"
if [ "$(wc -l <<<"$team_prefix" | tr -d ' ')" != "1" ] || [ -z "$team_prefix" ]; then
  echo "FAIL: expected exactly one CMUX_TEAM_ID_PREFIX in $PROJECT, got: $(tr '\n' ' ' <<<"$team_prefix")" >&2
  exit 1
fi
app_id="${team_prefix}${bundle_id}"

verify_job="$(
  awk '
    /^  build-sign-notarize:/ { in_job = 1; next }
    in_job && /^  [A-Za-z0-9_-]+:/ { exit }
    in_job { print }
  ' "$WORKFLOW"
)"
[ -n "$verify_job" ] || { echo "FAIL: build-sign-notarize job not found in $WORKFLOW" >&2; exit 1; }

normalize_calls="$(grep -E 'normalize-system-extension-bundle\.sh' <<<"$verify_job" || true)"
if [ -z "$normalize_calls" ]; then
  echo "FAIL: build-sign-notarize must normalize the system extension bundle name" >&2
  exit 1
fi
if ! grep -Eq "normalize-system-extension-bundle\.sh \"\\\$APP\" \"$bundle_id\"$" <<<"$normalize_calls"; then
  echo "FAIL: normalize-system-extension-bundle.sh must receive the Release bundle identifier '$bundle_id' (not the App ID), got:" >&2
  echo "$normalize_calls" >&2
  exit 1
fi

if ! grep -Eq "SystemExtensions/$bundle_id\.systemextension/Contents/MacOS/" <<<"$verify_job"; then
  echo "FAIL: build-sign-notarize must verify the tunnel binary under SystemExtensions/$bundle_id.systemextension" >&2
  exit 1
fi
if grep -Eq "SystemExtensions/$app_id\.systemextension" <<<"$verify_job"; then
  echo "FAIL: the system extension directory is named after the bundle identifier, never the team-prefixed App ID" >&2
  exit 1
fi

embed_args="$(grep -A3 'embed-tunnel-extension-profile.sh' <<<"$verify_job" | grep -E '^[[:space:]]+"[A-Za-z0-9.]+\.tunnel" \\$' | sed -E 's/^[[:space:]]+"([^"]+)".*/\1/' || true)"
if [ "$embed_args" != "$app_id" ]; then
  echo "FAIL: embed-tunnel-extension-profile.sh must check the profile against the App ID '$app_id', got '${embed_args:-<none>}'" >&2
  exit 1
fi

echo "PASS: release.yml names the tunnel extension $bundle_id (bundle) and $app_id (profile App ID)"
