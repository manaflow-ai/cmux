#!/usr/bin/env bash
# nightly.yml nightly-next-one: the hand-offs between the split jobs' steps, in one workspace (no artifacts).
#   one-job.sh paths     before the build: the app path, mktemp under $RUNNER_TEMP, and no keychain an ended
#                        job left (the job holds the whole Mac, so a build.keychain-db now is a leftover)
#   one-job.sh inputs    after the build: the build number, the Ghostty helper and license trees for prepare
#   one-job.sh signed    after notarization: the verify steps read the signed app restored from its tarball
#   one-job.sh final     the final DMG and appcast where verify-final-dmg.sh reads them
#   one-job.sh source    publish-nightly's "Select the build to publish", for this job's own build only
#   one-job.sh wipe      last: this job's temp files and copies, and its hold on the kept tree; the workspace
#                        stays for the next warm build
set -euo pipefail
case "${1:-}" in
  paths)
    python3 -c 'import json, sys; sys.exit(json.loads(sys.argv[1]) != ["arm64"])' "$VARIANTS" \
      || { echo "nightly-next-one builds arm64 only, not $VARIANTS" >&2; exit 1; }
    { echo "CHANNEL_APP_PATH=build-universal/Build/Products/Release/$APP_NAME.app"; echo "TMPDIR=$RUNNER_TEMP"; } >> "$GITHUB_ENV"
    leftover="$HOME/Library/Keychains/build.keychain-db"
    if [ -e "$leftover" ]; then
      echo "Deleting the signing keychain an ended job left: $leftover"
      security delete-keychain "$leftover" 2>/dev/null || rm -f "$leftover"
    fi
    ;;
  inputs)
    [[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "no daemon build: $BUILD" >&2; exit 1; }
    { echo "NIGHTLY_BUILD=$BUILD"; echo "NIGHTLY_MARKETING_VERSION=$VERSION"; } >> "$GITHUB_ENV"
    mkdir -p nightly-inputs/ghostty nightly-inputs/license-trees
    install -m 755 nightly-helper/ghostty nightly-inputs/ghostty/ghostty
    cp -R "$RUNNER_TEMP"/source-archive/*-licenses nightly-inputs/license-trees/
    ;;
  signed)
    { echo "CHANNEL_APP_PATH=signed/$APP_NAME.app"; echo "STAPLED_APP_FALLBACK_ID=$FALLBACK"; } >> "$GITHUB_ENV"
    ;;
  final)
    mkdir -p final-dmg
    cp "$CHANNEL_DMG_PREFIX"-*.dmg appcast*.xml final-dmg/
    ;;
  source)
    [[ "$NIGHTLY_BUILD" =~ ^[0-9]+$ && "$BUILD_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "invalid build $NIGHTLY_BUILD at $BUILD_SHA" >&2; exit 1; }
    # nightly-out (and cef-runtime): what publish-nightly downloads, from this workspace.
    mkdir -p nightly-out
    cp final-dmg/* remote-daemon-assets/cmuxd-remote-* nightly-out/
    if [ "$CEF" = true ]; then cp -R "$RUNNER_TEMP/cef-runtime" cef-runtime; fi
    printf '%s\n' source=own "build=$NIGHTLY_BUILD" "build_sha=$BUILD_SHA" "build_short_sha=${BUILD_SHA:0:7}" \
      "tip_sha=$TIP_SHA" "behind=$BEHIND" "behind_hours=$BEHIND_HOURS" "variant_pattern=cmux-nightly-variant-*" \
      "tested_pattern=cmux-nightly-tested-*" run_id= "cef=$CEF" "source_archive=$SOURCE_ARCHIVE" >> "$GITHUB_OUTPUT"
    ;;
  wipe)
    tmp="${RUNNER_TEMP:-}"
    if [ -n "$tmp" ] && [ -d "$tmp" ] && [ "$tmp" != / ] && [ "$tmp" != "$HOME" ]; then
      find "$tmp" -mindepth 1 -maxdepth 1 ! -name '_*' -exec rm -rf {} +
    fi
    rm -rf signed signed-app-handoff final-dmg nightly-out tested cef-runtime
    python3 "$(dirname "$0")/../nightly_build_state.py" release || true
    ;;
  *) echo "usage: one-job.sh paths|inputs|signed|final|source|wipe" >&2; exit 2 ;;
esac
