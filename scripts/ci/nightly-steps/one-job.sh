#!/usr/bin/env bash
# nightly.yml nightly-next-one: the hand-offs between the split jobs' steps, in one workspace (no artifacts).
#   one-job.sh paths     before the build: the app path, mktemp under $RUNNER_TEMP, and no keychain an ended
#                        job left (the job holds the whole Mac, so a build.keychain-db now is a leftover)
#   one-job.sh inputs    after the build: the build number, the Ghostty helper and license trees for prepare
#   one-job.sh signed    after notarization: the verify steps read the signed app restored from its tarball
#   one-job.sh deltas-start   after notarization, with no key and no token: in the background, the keyless
#                        nearest deltas (appcast-with-nearest-deltas.sh prebuild) and the git fetch of the span
#                        the release notes cover, beside the verify steps, the launch smoke and the size budget
#   one-job.sh deltas-join    after them: waits for both; a failed or late one only leaves its work to the
#                        steps that did it before (the keyed appcast step, the release notes step). With
#                        NIGHTLY_NEXT_DELTAS_AFTER_FEED=true it gives an unfinished prebuild a bounded grace
#                        (NIGHTLY_NEXT_PREBUILD_GRACE_SECONDS, 150) so the feed's first item carries its deltas,
#                        then stops it; the post-feed delta step then does its work itself
#   one-job.sh final-dmg the final DMG where verify-final-dmg.sh, the launch smoke and the size budget read it
#   one-job.sh final-feed after the keyed appcast step: this build's appcast and deltas beside it
#   one-job.sh source    publish-nightly's "Select the build to publish", for this job's own build only
#   one-job.sh wipe      last: this job's temp files and copies, and its hold on the kept tree; the workspace
#                        stays for the next warm build
set -euo pipefail
case "${1:-}" in
  paths)
    python3 -c 'import json, sys; sys.exit(json.loads(sys.argv[1]) != ["arm64"])' "$VARIANTS" \
      || { echo "nightly-next-one builds arm64 only, not $VARIANTS" >&2; exit 1; }
    { echo "CHANNEL_APP_PATH=build-universal/Build/Products/Release/$APP_NAME.app"; echo "TMPDIR=$RUNNER_TEMP"; } >> "$GITHUB_ENV"
    # The keyless prebuild's deltas outlive this job for nightly-next-deltas, the job after the feed that signs them
    # when it lands on this Mac (its `done` names the build and the DMG's digest; anything else is rebuilt there).
    echo "NIGHTLY_NEXT_PREBUILT=$HOME/.cmux-nightly-next-prebuilt" >> "$GITHUB_ENV"
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
  deltas-start)
    state="$RUNNER_TEMP/nightly-helper-builds"
    [ -z "${SPARKLE_PRIVATE_KEY:-}${NEXT_SPARKLE_PRIVATE_KEY:-}${GH_TOKEN:-}${GITHUB_TOKEN:-}" ] \
      || { echo "error: the background work beside the bundle's checks gets no key and no token" >&2; exit 1; }
    # A build tree from before the keyless prebuild builds its deltas in the keyed step, as before.
    if [ "$TRACK" = nightly-next ] && grep -q '"${1:-}" = prebuild' scripts/ci/nightly-steps/appcast-with-nearest-deltas.sh 2>/dev/null; then
      python3 "$PUBLISH_TOOLING/ci/background_build.py" start --state "$state" nearest-deltas -- \
        bash scripts/ci/nightly-steps/appcast-with-nearest-deltas.sh prebuild
    fi
    if [ "$SHOULD_PUBLISH" = true ] && [[ "$NOTES_HEAD" =~ ^[0-9a-f]{40}$ ]] && [ -f scripts/cmux-next/fetch-release-notes-span.sh ]; then
      python3 "$PUBLISH_TOOLING/ci/background_build.py" start --state "$state" notes-span -- \
        bash "$PUBLISH_TOOLING/ci/nightly-steps/publish-prepare-release-notes.sh" prefetch
    fi
    ;;
  deltas-join)
    state="$RUNNER_TEMP/nightly-helper-builds"
    for name in nearest-deltas notes-span; do
      [ -f "$state/$name.pid" ] || continue
      if [ "$name" = nearest-deltas ] && [ "${NIGHTLY_NEXT_DELTAS_AFTER_FEED:-}" = true ] && [ ! -f "$state/$name.status" ]; then
        # A bounded grace, so the pushed build carries its nearest deltas (ask-1f1e9b8ec5): stopped at once, the
        # prebuild never made the feed (job 140827486829: stopped 98 s in, about 1 min short).
        if python3 "$PUBLISH_TOOLING/ci/background_build.py" join --state "$state" "$name" \
            --timeout "${NIGHTLY_NEXT_PREBUILD_GRACE_SECONDS:-150}" 2>&1 | sed 's/^::error::/::notice::/'; then
          continue
        fi
        python3 "$PUBLISH_TOOLING/ci/background_build.py" stop --state "$state" "$name"
        echo "::notice title=nightly-next $name::the prebuild did not finish beside the checks; the deltas after the feed build it"
        continue
      fi
      if ! python3 "$PUBLISH_TOOLING/ci/background_build.py" join --state "$state" "$name" --timeout "${DELTAS_JOIN_SECONDS:-900}"; then
        python3 "$PUBLISH_TOOLING/ci/background_build.py" stop --state "$state" "$name"
        echo "::warning title=nightly-next $name::the background $name did not finish; the step that did it before does it"
      fi
    done
    ;;
  final-dmg)
    mkdir -p final-dmg
    cp "$CHANNEL_DMG_PREFIX"-*.dmg final-dmg/
    ;;
  final-feed)
    cp appcast*.xml final-dmg/
    # This build's deltas (appcast-with-nearest-deltas.sh), never one a past build left in the kept workspace.
    for delta in "$CHANNEL_DMG_PREFIX"-*-"$NIGHTLY_BUILD"-*.delta; do
      if [ -f "$delta" ]; then cp "$delta" final-dmg/; fi
    done
    ;;
  source)
    [[ "$NIGHTLY_BUILD" =~ ^[0-9]+$ && "$BUILD_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "invalid build $NIGHTLY_BUILD at $BUILD_SHA" >&2; exit 1; }
    # nightly-out (and cef-runtime, language-packs): what publish-nightly downloads, from this workspace.
    mkdir -p nightly-out
    cp final-dmg/* remote-daemon-assets/cmuxd-remote-* nightly-out/
    if [ "$CEF" = true ]; then cp -R "$RUNNER_TEMP/cef-runtime" cef-runtime; fi
    # The packs and their pin only (not the split's stage/), as the language-packs artifact carries.
    if [ "${LANGUAGE_PACKS:-false}" = true ]; then
      mkdir -p language-packs
      cp "$RUNNER_TEMP"/language-packs/*.tar.zst "$RUNNER_TEMP/language-packs/language-packs.json" language-packs/
      # The tool packs (tool-packs.py, sign-cmux-bundle.sh 4c) sit in its tools/ when the app has them.
      if [ -f "$RUNNER_TEMP/language-packs/tools/tool-packs.json" ]; then
        mkdir -p language-packs/tools
        cp "$RUNNER_TEMP"/language-packs/tools/*.tar.zst "$RUNNER_TEMP/language-packs/tools/tool-packs.json" language-packs/tools/
      fi
    fi
    printf '%s\n' source=own "build=$NIGHTLY_BUILD" "build_sha=$BUILD_SHA" "build_short_sha=${BUILD_SHA:0:7}" \
      "tip_sha=$TIP_SHA" "behind=$BEHIND" "behind_hours=$BEHIND_HOURS" "variant_pattern=cmux-nightly-variant-*" \
      "tested_pattern=cmux-nightly-tested-*" run_id= "cef=$CEF" "language_packs=${LANGUAGE_PACKS:-false}" \
      language_packs_run= "source_archive=$SOURCE_ARCHIVE" >> "$GITHUB_OUTPUT"
    ;;
  wipe)
    tmp="${RUNNER_TEMP:-}"
    if [ -n "$tmp" ] && [ -d "$tmp" ] && [ "$tmp" != / ] && [ "$tmp" != "$HOME" ]; then
      # A stopped delta prebuild can leave a DMG mounted under it; rm -rf into a read-only volume fails the job.
      real="$(cd "$tmp" && pwd -P)"  # mount prints resolved paths
      mount | sed -n "s#^/dev/[^ ]* on \($real/.*\) (.*#\1#p" | while IFS= read -r mounted; do
        hdiutil detach "$mounted" -quiet </dev/null || hdiutil detach "$mounted" -force -quiet </dev/null || true
      done
      find "$tmp" -mindepth 1 -maxdepth 1 ! -name '_*' -exec rm -rf {} +
    fi
    rm -rf signed signed-app-handoff final-dmg nightly-out nightly-deltas tested cef-runtime language-packs
    rm -f "${CHANNEL_DMG_PREFIX:-cmux-nightly-next-macos}"-*.delta
    python3 "$(dirname "$0")/../nightly_build_state.py" release || true
    ;;
  *) echo "usage: one-job.sh paths|inputs|signed|final|source|wipe" >&2; exit 2 ;;
esac
