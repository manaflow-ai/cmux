#!/usr/bin/env bash
# nightly.yml signer-dmg: verify-signed-nightly's handoff, made on this Linux job instead of the Mac
# DMG job (signer-dmg-image), so the Mac never sends it back over the office uplink (86-101 s for
# 323 MB). It is signed-app-checks.sh package_handoff's layout: the app at the top of
# cmux-signed-app.tar.gz, and that file's shasum line. Its source is the stapled-app.tar signer-app
# packed and signer-dmg-image ran Apple's checks on.
#
#   signer-handoff.sh start    checks the tar's digest and starts the gzip in the background, so it
#                              runs while the DMG waits on Apple (no secret reaches it)
#   signer-handoff.sh finish   waits for it and fails on its failure
#
# The background job writes its status into a FIFO, which blocks until `finish` opens it: nothing polls.
set -euo pipefail
state="${RUNNER_TEMP:?}/signer-handoff"
case "${1:-}" in
  start)
    : "${APP_SHA256:?}"
    echo "$APP_SHA256  signer-app/stapled-app.tar" | sha256sum -c -
    rm -rf "$state" signed-app-handoff
    mkdir -p "$state" signed-app-handoff
    mkfifo "$state/status.fifo"
    # Every command returns on failure: set -e does not apply on the left of `||`.
    package() {
      local started=$SECONDS zip=gzip
      command -v pigz >/dev/null 2>&1 && zip=pigz
      "$zip" -6 -c signer-app/stapled-app.tar > signed-app-handoff/cmux-signed-app.tar.gz || return
      (cd signed-app-handoff && sha256sum cmux-signed-app.tar.gz > cmux-signed-app.tar.gz.sha256) || return
      echo "packaged the signed app for the verify job with $zip in $((SECONDS - started)) s"
    }
    (
      status=0
      package || status=$?
      echo "$status" > "$state/status.fifo"
    ) > "$state/handoff.log" 2>&1 < /dev/null &
    ;;
  finish)
    [ -p "$state/status.fifo" ] || { echo "the handoff packaging was never started" >&2; exit 1; }
    status=""
    read -r status < "$state/status.fifo" || true
    cat "$state/handoff.log"
    rm -rf "$state"
    [ "$status" = 0 ] || { echo "packaging the signed app for the verify job failed (status ${status:-none})" >&2; exit 1; }
    ls -l signed-app-handoff
    ;;
  *)
    echo "usage: signer-handoff.sh start|finish" >&2
    exit 2
    ;;
esac
