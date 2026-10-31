#!/usr/bin/env bash
# Run the read-only checks and the packaging of the signed app while Apple
# notarizes it (build-sign-notarize-nightly).
#
#   signed-app-checks.sh start <app>   copy <app>, start the checks on the copy
#                                      in the background, and return at once
#   signed-app-checks.sh finish        wait for them, print their log, and exit
#                                      with their status
#
# The notarize step changes the app in place (the helper's staple and the host
# reseal, then the app's own staple), so the checks run on a copy made right
# after Codesign apps: the same bytes these checks and the verify job's
# handoff read before, when they ran ahead of the notarization step.
#
# Environment (each "true" or "false"):
#   CHECK_MINOS        check every Mach-O against the macOS 14 floor
#   PACKAGE_HANDOFF    write signed-app-handoff/ for verify-signed-nightly
#   PACKAGE_UNNOTARIZED_ZIP
#                      write $RUNNER_TEMP/signed-unnotarized/<name>.zip; a
#                      failure here never fails the job (it is a convenience)
#   CHANNEL_DMG_PREFIX, VARIANT, NIGHTLY_BUILD name the zip.
set -euo pipefail

state_dir="${RUNNER_TEMP:?}/signed-app-checks"
fifo="$state_dir/status.fifo"
log="$state_dir/checks.log"

case "${1:-}" in
  start)
    app="${2:?usage: signed-app-checks.sh start <app>}"
    rm -rf "$state_dir"
    mkdir -p "$state_dir/snapshot"
    copy="$state_dir/snapshot/$(basename "$app")"
    ditto "$app" "$copy"
    mkfifo "$fifo"
    # The subshell writes its status into the FIFO; that write blocks until
    # `finish` opens the FIFO, so the status is never lost and nothing polls.
    (
      status=0
      bash "$0" run "$copy" || status=$?
      echo "$status" >"$fifo"
    ) >"$log" 2>&1 </dev/null &
    echo "signed-app checks started on a copy of $app (PID $!); signed-app-checks.sh finish prints them"
    ;;
  run)
    app="$2"
    failed=()
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
    # These run inside `if`, where set -e does not apply: every command
    # returns on failure.
    package_handoff() {
      mkdir -p signed-app-handoff || return 1
      tar -C "$(dirname "$app")" -czf signed-app-handoff/cmux-signed-app.tar.gz "$(basename "$app")" || return 1
      (cd signed-app-handoff && shasum -a 256 cmux-signed-app.tar.gz > cmux-signed-app.tar.gz.sha256) || return 1
    }
    package_zip() {
      local out="$RUNNER_TEMP/signed-unnotarized"
      mkdir -p "$out" || return 1
      ditto -c -k --sequesterRsrc --keepParent "$app" "$out/${CHANNEL_DMG_PREFIX}-${VARIANT}-${NIGHTLY_BUILD}-signed-unnotarized.zip" || return 1
      ls -l "$out"
    }
    step "Verify bundled Mach-O load commands" ./scripts/verify-bundle-load-commands.sh "$app"
    # Every Mach-O must map to its notices (bundle-map.json). notarize-nightly-dmg.sh
    # checks the app and the mounted DMG again.
    step "Verify third-party notices cover every bundled binary" ./scripts/verify-app-bundle-licenses.sh "$app"
    if [ "${CHECK_MINOS:-false}" = true ]; then
      step "Check every bundled Mach-O loads on the macOS floor" python3 scripts/ci/macho_minos.py scan "$app" --floor 14.0
    fi
    if [ "${PACKAGE_HANDOFF:-false}" = true ]; then
      step "Package signed app for the verify job" package_handoff
    fi
    if [ "${PACKAGE_UNNOTARIZED_ZIP:-false}" = true ]; then
      zip_started=$SECONDS
      if package_zip; then
        echo "Zip the signed app before notarization: ok ($((SECONDS - zip_started)) s)"
      else
        echo "::warning title=Unnotarized zip::zipping the signed app failed; the notarization and the publication go on"
      fi
    fi
    if [ "${#failed[@]}" -gt 0 ]; then
      printf 'failed: %s\n' "${failed[@]}"
      exit 1
    fi
    ;;
  finish)
    if [ ! -p "$fifo" ]; then
      echo "the signed-app checks were never started" >&2
      exit 1
    fi
    status=""
    read -r status <"$fifo" || true
    cat "$log"
    case "$status" in
      0) echo "signed-app checks passed" ;;
      "") echo "the signed-app checks ended without a status" >&2; exit 1 ;;
      *) echo "signed-app checks failed (status $status)" >&2; exit 1 ;;
    esac
    ;;
  *)
    echo "usage: signed-app-checks.sh start <app> | finish" >&2
    exit 2
    ;;
esac
