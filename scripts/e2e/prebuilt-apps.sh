#!/usr/bin/env bash
# Move the iOS e2e lane's two tagged apps from their build jobs to the E2E job.
#
# The builds run in parallel on their own runners (the Mac app on a warm glaeda
# side runner, the simulator app next to it) and hold no secrets: everything
# they bake is the same for every run of a commit (tag ci-main, the fixed
# backend name). The E2E job adds the one per-machine value, the path of the CI
# credentials file, exactly as scripts/reload.sh writes it, then re-signs the
# way reload.sh does after its own Info.plist edits.
#
# Usage: prebuilt-apps.sh package-mac <derived-data> <out.zip>
#        prebuilt-apps.sh package-ios <out.zip>
#        prebuilt-apps.sh install-mac <app.zip> <credentials-file>
#        prebuilt-apps.sh install-ios <app.zip> <simulator-udid>
# Env: CMUX_E2E_TAG (the tag both apps were built with).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TAG="${CMUX_E2E_TAG:?CMUX_E2E_TAG is required}"
# shellcheck source=scripts/lib/mobile-attach.sh
source "$REPO_ROOT/scripts/lib/mobile-attach.sh"
SLUG="$(cmux_attach__slug "$TAG")"

die() { echo "::error::[infra-preflight] prebuilt-apps: $*" >&2; exit 1; }

zip_app() {
  local app="$1" out="$2"
  [[ -d "$app" ]] || die "no built app at $app"
  mkdir -p "$(dirname "$out")"
  (cd "$(dirname "$app")" && ditto -c -k --sequesterRsrc --keepParent "$(basename "$app")" "$out")
  echo "packaged $(basename "$app") ($(du -sh "$out" | cut -f1))"
}

# Same helper reload.sh uses for LSEnvironment.
set_plist_env() {
  /usr/libexec/PlistBuddy -c "Set :LSEnvironment:$2 \"$3\"" "$1" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :LSEnvironment:$2 string \"$3\"" "$1"
}

case "${1:-}" in
  package-mac)
    derived="${2:?derived data path}"
    zip_app "$derived/Build/Products/Debug/cmux DEV $SLUG.app" "${3:?output zip}"
    ;;
  package-ios)
    app="$(find "$HOME/Library/Developer/Xcode/DerivedData/cmux-ios-$SLUG/Build/Products" \
      -maxdepth 2 -type d -path '*-iphonesimulator/*.app' | head -1)"
    zip_app "$app" "${2:?output zip}"
    ;;
  install-mac)
    zip="${2:?app zip}"
    credentials="${3:?credentials file}"
    [[ -f "$credentials" ]] || die "credentials file $credentials is missing"
    # Where scripts/lib/mobile-attach.sh (cmux_attach_mac_app_path) and the
    # driver look for the tagged Mac app.
    app="$(cmux_attach_mac_app_path "$TAG")"
    rm -rf "${app:?}"
    mkdir -p "$(dirname "$app")"
    ditto -x -k "$zip" "$(dirname "$app")"
    [[ -d "$app" ]] || die "archive did not contain $(basename "$app")"
    plist="$app/Contents/Info.plist"
    # The values reload.sh bakes for --auth-profile agent --credentials-file.
    set_plist_env "$plist" CMUX_AUTH_CREDENTIALS_FILE "$credentials"
    set_plist_env "$plist" CMUX_DEV_AUTH_PROFILE agent
    set_plist_env "$plist" CMUX_DEV_AUTH_REPLACE_SESSION 1
    /usr/bin/codesign --force --sign - --timestamp=none --generate-entitlement-der "$app" >/dev/null \
      || die "re-signing $app failed"
    echo "installed $app"
    ;;
  install-ios)
    zip="${2:?app zip}"
    udid="${3:?simulator udid}"
    dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/ios-app.XXXXXX")"
    ditto -x -k "$zip" "$dir"
    app="$(find "$dir" -maxdepth 1 -type d -name '*.app' | head -1)"
    [[ -n "$app" ]] || die "archive did not contain an .app"
    xcrun simctl install "$udid" "$app"
    rm -rf "${dir:?}"
    echo "installed $(basename "$app") on $udid"
    ;;
  *)
    echo "usage: $0 package-mac <derived-data> <out.zip> | package-ios <out.zip> | install-mac <zip> <credentials> | install-ios <zip> <udid>" >&2
    exit 2
    ;;
esac
