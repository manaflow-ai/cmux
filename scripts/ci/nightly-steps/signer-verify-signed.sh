#!/usr/bin/env bash
# nightly.yml signer-dmg-image: verify-signed-nightly's checks of the stapled app, on the Mac that
# already holds it, while the DMG is built and sent. The pool path used to gzip the same
# stapled-app.tar on Linux and send it to a second office Mac, whose download alone took 2-5 min
# (runs 40905688542, 40913618519, 40918131595) beside verify-final-dmg-nightly's. The checks are
# the same commands verify-signed-nightly runs, from the build tree (the job's working directory),
# on a copy of the app the DMG is built from, so a check that writes into the bundle cannot change
# what the DMG holds. verify-signed-nightly's codesign --verify --deep --strict is
# signer-apple-checks.sh's, which the job runs on the app before this starts.
#
#   signer-verify-signed.sh start <app>   copy <app>, start the checks on the copy in the
#                                         background, and return at once (no secret reaches them)
#   signer-verify-signed.sh finish        wait for them, print their log, and fail on their failure
#
# Env: NIGHTLY_BUILD, BUNDLE_REMOTE_DAEMON_ASSETS, CHANNEL_RELEASE_TAG, CHANNEL_ENTITLEMENTS, TRACK,
# and remote-daemon-assets/ in the working directory.
# The background job writes its status into a FIFO, which blocks until `finish` opens it: nothing polls.
set -euo pipefail
state="${RUNNER_TEMP:?}/signer-verify-signed"

run_checks() {
  local app="$1"
  local failed=()
  step() {
    local name="$1" started=$SECONDS
    shift
    echo "::group::$name"
    if "$@"; then
      echo "$name: ok ($((SECONDS - started)) s)"
    else
      echo "$name: FAILED ($((SECONDS - started)) s)"
      failed+=("$name")
    fi
    echo "::endgroup::"
  }
  # These run inside `if`, where set -e does not apply: every command returns on failure.
  version_surfaces() {
    [[ "$TRACK" != nightly-next ]] && return 0
    ./scripts/cmux-next/check-version-surfaces.sh "$app"
  }
  # verify-signed-nightly's "Verify bundled CLI commands run from the bundle alone".
  bundled_cli_commands() {
    [[ "$TRACK" != nightly-next ]] && return 0
    [[ -f scripts/cmux-next/check-bundled-cli-commands.sh ]] || { echo "the build commit has no check-bundled-cli-commands.sh"; return 0; }
    local archs
    archs="$(lipo -archs "$app/Contents/Resources/bin/cmux")" || return
    if [[ " $archs " == *" $(uname -m) "* ]]; then
      ./scripts/cmux-next/check-bundled-cli-commands.sh "$app"
    else
      echo "bin/cmux is $archs; this Mac is $(uname -m): the matching variant checks it"
    fi
  }
  sidecar_contract() {
    local archs
    archs="$(lipo -archs "$app/Contents/MacOS/cmux")" || return
    ./scripts/verify-diff-sidecar-artifact.sh "$app/Contents/Resources/bin/cmux-diff-sidecar" \
      --archs "$archs" --require-signed
  }
  # verify-signed-nightly runs it only when the build commit has the script (hashFiles); a
  # pool-signed app's Computer Use helper carries its own ticket.
  entitlements_and_helper_ticket() {
    [[ -f scripts/ci/nightly-steps/verify-signed-app-checks.sh ]] || { echo "the build commit has no verify-signed-app-checks.sh"; return 0; }
    CHANNEL_APP_PATH="$app" REQUIRE_HELPER_TICKET=true bash scripts/ci/nightly-steps/verify-signed-app-checks.sh
  }
  theme_picker_helper() {
    CMUX_APP_PATH="$app" ./tests/test_bundled_ghostty_theme_picker_helper.sh
  }
  ssh_daemon_contract() {
    local args=()
    [[ "$BUNDLE_REMOTE_DAEMON_ASSETS" == true ]] && args+=(--require-bundled-assets)
    # cmux-next bundles the Rust CLI, which has no classic remote-daemon-status command.
    [[ "$CHANNEL_RELEASE_TAG" == nightly-next ]] || args+=(--verify-cli)
    python3 scripts/verify_remote_daemon_release.py \
      --manifest "remote-daemon-assets/cmuxd-remote-manifest-${NIGHTLY_BUILD}.json" \
      --assets-dir remote-daemon-assets --app "$app" ${args[@]+"${args[@]}"}
  }
  step "Verify version surfaces" version_surfaces
  step "Verify bundled CLI commands run from the bundle alone" bundled_cli_commands
  step "Verify signed diff sidecar protocol contract" sidecar_contract
  step "Verify signed app entitlements and the Computer Use helper ticket" entitlements_and_helper_ticket
  step "Run bundled Ghostty theme picker helper regression" theme_picker_helper
  step "Verify signed app SSH daemon contract" ssh_daemon_contract
  if [[ "${#failed[@]}" -gt 0 ]]; then
    printf 'failed: %s\n' "${failed[@]}"
    return 1
  fi
}

case "${1:-}" in
  start)
    app="${2:?usage: signer-verify-signed.sh start <app>}"
    app="${app%/}"
    : "${NIGHTLY_BUILD:?}" "${BUNDLE_REMOTE_DAEMON_ASSETS:?}" "${CHANNEL_RELEASE_TAG:?}" "${CHANNEL_ENTITLEMENTS:?}" "${TRACK:?}"
    [[ -d "$app/Contents" ]] || { echo "no app at $app" >&2; exit 1; }
    rm -rf "$state"
    mkdir -p "$state/snapshot"
    copy="$state/snapshot/${app##*/}"
    ditto "$app" "$copy"
    mkfifo "$state/status.fifo"
    (
      status=0
      run_checks "$copy" || status=$?
      echo "$status" > "$state/status.fifo"
    ) > "$state/checks.log" 2>&1 < /dev/null &
    echo "verify-signed checks started on a copy of $app (PID $!); signer-verify-signed.sh finish prints them"
    ;;
  finish)
    [[ -p "$state/status.fifo" ]] || { echo "the verify-signed checks were never started" >&2; exit 1; }
    status=""
    read -r status < "$state/status.fifo" || true
    cat "$state/checks.log"
    rm -rf "$state"
    [[ "$status" == 0 ]] || { echo "the verify-signed checks failed (status ${status:-none})" >&2; exit 1; }
    echo "verify-signed checks passed"
    ;;
  *)
    echo "usage: signer-verify-signed.sh start <app> | finish" >&2
    exit 2
    ;;
esac
