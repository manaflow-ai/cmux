#!/usr/bin/env bash
# nightly.yml signer-dmg-image: "Staple the app's notarization ticket", on the Mac, with Apple's
# stapler and no secret.
#
#   signer-staple-app.sh <app>
#
# signer-app-notary submits the app signer-app signed (the bytes of the tar whose digest this job
# checked) to Apple at the same time as this job downloads and checks it, so the DMG Mac no longer
# waits for Apple before its download starts. Apple's ticket is published under the app's CDHash
# once Apple accepts the submission; until then `stapler staple` finds no ticket. This asks Apple
# for it every STAPLE_RETRY_SECONDS (default 10) up to STAPLE_MAX_WAIT_SECONDS (default 1500:
# signer-app-notary waits up to 1200 s after its upload), then `stapler validate` checks the
# staple. A submission Apple rejects never gets a ticket, so this fails at the deadline (and
# signer-app-notary fails first). The bundle changes only by the ticket stapler writes.
set -euo pipefail
app="${1:?usage: signer-staple-app.sh <app>}"
app="${app%/}"
[[ -d "$app/Contents" ]] || { echo "no app at $app" >&2; exit 1; }
xcrun="${XCRUN_TOOL:-xcrun}"
max_wait="${STAPLE_MAX_WAIT_SECONDS:-1500}"
retry="${STAPLE_RETRY_SECONDS:-10}"
[[ "$max_wait" =~ ^[0-9]+$ && "$retry" =~ ^[1-9][0-9]*$ ]] || { echo "STAPLE_MAX_WAIT_SECONDS and STAPLE_RETRY_SECONDS must be whole seconds" >&2; exit 2; }
started=$SECONDS
attempt=0
while :; do
  attempt=$((attempt + 1))
  if out="$("$xcrun" stapler staple "$app" 2>&1)"; then
    echo "$out"
    break
  fi
  waited=$((SECONDS - started))
  if (( waited + retry > max_wait )); then
    echo "$out" >&2
    echo "error: no notarization ticket for ${app##*/} after ${waited} s ($attempt attempts); Apple has not accepted signer-app-notary's submission" >&2
    exit 1
  fi
  # Each attempt's own output stays in the log, so a failure other than "no ticket yet" shows.
  echo "attempt $attempt after ${waited} s: no ticket yet ($(tail -n 1 <<<"$out"))"
  sleep "$retry"
done
"$xcrun" stapler validate "$app"
echo "stapled ${app##*/} after $((SECONDS - started)) s ($attempt attempts)" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
