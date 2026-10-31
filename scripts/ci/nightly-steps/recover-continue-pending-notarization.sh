#!/usr/bin/env bash
# nightly.yml recover-nightly-next-notarization: "Continue the newest accepted pending notarization".
# Moved out of the workflow verbatim to keep nightly.yml under GitHub's
# workflow file size limit; the step's env: still sets every input.
set -euo pipefail
feeds=()
for appcast in appcast.xml appcast-arm64.xml appcast-x86_64.xml; do
  feeds+=(--feed-if-present "${NIGHTLY_NEXT_FEED_BASE}/${appcast}" --feed "${NIGHTLY_NEXT_LEGACY_FEED_BASE}/${appcast}" --feed "https://files.cmux.com/nightly/${appcast}")
done
mkdir -p recovered
newer_stapled_pending=false
while IFS=$'\t' read -r run_id artifact; do
  dir="recovery/$run_id"
  echo "::group::run $run_id ($artifact)"
  if ! gh run download "$run_id" --repo "$GITHUB_REPOSITORY" --name "$artifact" --dir "$dir"; then
    echo "::notice::run $run_id: could not download $artifact; skipping"
    echo "::endgroup::"; continue
  fi
  if ! python3 scripts/ci/find-nightly-next-recovery.py check-manifest \
      "$dir/cmux-nightly-notarization-recovery.json" --run-id "$run_id" \
      --channel "$CHANNEL" --release-tag "$CHANNEL_RELEASE_TAG" --dmg-dir "$dir" > "$dir/manifest.env"; then
    echo "::notice::run $run_id: its recovery manifest cannot be continued; skipping"
    echo "::endgroup::"; continue
  fi
  # shellcheck disable=SC1090
  source "$dir/manifest.env"
  if ! verdict="$(bash scripts/ci/nightly-next-recovery-lineage.sh "$GITHUB_REPOSITORY" "$CHANNEL_RELEASE_TAG" "$BUILD_SHA" </dev/null)"; then
    echo "::notice title=Recovery refused::run $run_id: build $BUILD: $verdict; skipping"
    echo "::endgroup::"; continue
  fi
  if ! python3 scripts/ci/nightly_version.py check-build --build "$BUILD" "${feeds[@]}"; then
    echo "::notice::run $run_id: build $BUILD is no longer above both feeds; skipping"
    echo "::endgroup::"; continue
  fi
  # Every nightly-next build ships Apple silicon and Intel together:
  # take this run's x86_64 leg only if it notarized, its signed app
  # and its final DMG passed, and the DMG bytes are the tested ones.
  # Checked before any notarization step, so a skipped candidate
  # makes no new submission.
  intel="$dir/intel"
  intel_ok=true
  for artifact_name in cmux-nightly-variant-x86_64 cmux-nightly-tested-x86_64 cmux-nightly-signed-verified-x86_64 cmux-nightly-signed-verified-arm64; do
    gh run download "$run_id" --repo "$GITHUB_REPOSITORY" --name "$artifact_name" --dir "$intel" || intel_ok=false
  done
  intel_dmg="$intel/${CHANNEL_DMG_PREFIX}-x86_64-${BUILD}.dmg"
  # The arm64 signed app passed verify-signed-nightly in that run too;
  # verify-recovered-nightly-next verifies only the final DMG.
  if $intel_ok && [ "$(cat "$intel/signed-verified-x86_64" 2>/dev/null)" = "$BUILD" ] \
      && [ "$(cat "$intel/signed-verified-arm64" 2>/dev/null)" = "$BUILD" ] \
      && [ -f "$intel_dmg" ] && [ -f "$intel/${CHANNEL_DMG_PREFIX}-x86_64.dmg" ] \
      && [ -f "$intel/appcast-x86_64.xml" ] && [ -f "$intel/tested-x86_64.sha256" ]; then
    for dmg in "$intel_dmg" "$intel/${CHANNEL_DMG_PREFIX}-x86_64.dmg"; do
      grep -Fxq "$(shasum -a 256 "$dmg" | awk '{print $1}')  $(basename "$dmg")" "$intel/tested-x86_64.sha256" || intel_ok=false
    done
    python3 scripts/ci/nightly-next-guard.py appcast "$intel/appcast-x86_64.xml" || intel_ok=false
  else
    intel_ok=false
  fi
  if ! $intel_ok; then
    echo "::notice::run $run_id: build $BUILD has no verified Intel (x86_64) app or arm64 signed app; skipping"
    echo "::endgroup::"; continue
  fi
  # The visual gate's verdict on this build, recorded by the run that built it.
  if ! python3 scripts/ci/nightly_next_canary_mode.py admit --mode "${VISUAL_GATE_MODE:-report}" \
      --build-sha "$BUILD_SHA" --verdicts "$VISUAL_GATE_VERDICTS"; then
    echo "::notice title=Recovery refused::run $run_id: build $BUILD failed the visual gate in enforce mode; skipping"
    echo "::endgroup::"; continue
  fi
  mkdir -p "$dir/cmux-nightly-notarization-recovery-app"
  tar -C "$dir/cmux-nightly-notarization-recovery-app" -xzf "$dir/cmux-nightly-notarization-recovery-app.tar.gz"
  pending="$dir/github-output"
  : > "$pending"
  if ! CMUX_CHANNEL="$SIGN_CHANNEL" CMUX_NOTARY_CONTINUE_STATE="$dir/$STATE_NAME" GITHUB_OUTPUT="$pending" \
      CMUX_STAPLED_APP_NO_NEW_SUBMISSION="$newer_stapled_pending" \
      ./scripts/ci/notarize-nightly-dmg.sh "$dir/$APP_NAME" "$dir/$DMG_NAME" "recovered/$IMMUTABLE_NAME"; then
    # notarize-nightly-dmg.sh reports Apple's verdict once it has one.
    notary_status="$(sed -n 's/^notary_status=//p' "$pending" | tail -n 1)"
    if [ "$notary_status" = Accepted ]; then
      echo "::error::run $run_id: Apple accepted submission $SUBMISSION_ID, but a check after acceptance failed (see the log above); skipping"
    elif [ -n "$notary_status" ]; then
      echo "::notice::run $run_id: Apple did not accept submission $SUBMISSION_ID (status $notary_status); skipping"
    else
      echo "::notice::run $run_id: Apple's verdict on submission $SUBMISSION_ID is unknown (see the log above); skipping"
    fi
    echo "::endgroup::"; continue
  fi
  if grep -Fxq "submission_pending=true" "$pending"; then
    if grep -Fxq "stapled_app_pending=true" "$pending"; then
      # Apple accepted its first DMG; the DMG around the stapled app is
      # not accepted yet. Older candidates still ship at their own 6 h
      # fallback, but make no new submission while this one waits.
      echo "::notice::run $run_id: the first DMG is accepted and the DMG around the stapled app is not; older builds ship only at their 6 h fallback"
      newer_stapled_pending=true
      echo "::endgroup::"; continue
    fi
    echo "::notice::run $run_id: submission $SUBMISSION_ID is still in progress"
    echo "::endgroup::"; continue
  fi
  cp "$dir/$DMG_NAME" "recovered/$DMG_NAME"
  mkdir -p recovered-intel recovered-intel-tested
  cp "$intel_dmg" "$intel/${CHANNEL_DMG_PREFIX}-x86_64.dmg" "$intel/appcast-x86_64.xml" recovered-intel/
  cp "$intel/tested-x86_64.sha256" recovered-intel-tested/tested-recovered-x86_64.sha256
  if grep -Fxq "stapled_app_fallback=true" "$pending"; then
    fallback_id="$(sed -n 's/^stapled_app_pending_id=//p' "$pending" | tail -n 1)"
    echo "stapled_app_fallback_id=${fallback_id:-unknown}" >> "$GITHUB_OUTPUT"
  fi
  cp "$dir"/remote-daemon-assets/cmuxd-remote-* recovered/
  if [ -d "$dir/recovery-source-archive" ]; then
    cp -R "$dir/recovery-source-archive" recovered/source-archive
  fi
  {
    echo "accepted=true"
    echo "run_id=$run_id"
    echo "build=$BUILD"
    echo "build_sha=$BUILD_SHA"
    echo "tip_sha=$TIP_SHA"
    echo "behind=$BEHIND"
    echo "behind_hours=$BEHIND_HOURS"
  } >> "$GITHUB_OUTPUT"
  {
    echo "RECOVERED_APP=$dir/$APP_NAME"
    echo "RECOVERED_IMMUTABLE=recovered/$IMMUTABLE_NAME"
  } >> "$GITHUB_ENV"
  echo "### Continued nightly-next run $run_id (build $BUILD, $BUILD_SHA): Apple accepted it" >> "$GITHUB_STEP_SUMMARY"
  echo "::endgroup::"
  exit 0
done < <(echo "$CANDIDATES" | python3 -c 'import json, sys; [print("%s\t%s" % (c["run_id"], c["artifact"])) for c in json.load(sys.stdin)]')
echo "accepted=false" >> "$GITHUB_OUTPUT"
echo "No pending nightly-next notarization was accepted; nothing to continue." >> "$GITHUB_STEP_SUMMARY"
