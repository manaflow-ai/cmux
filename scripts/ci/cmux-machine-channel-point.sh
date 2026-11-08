#!/usr/bin/env bash
# Sign a Cloud machine channel payload (scripts/ci/cmux-machine-channel.py payload) and move
# cmux-tui/channels/cloud-machine.json to it, unless the channel already names this build or a
# newer one (scripts/cmux-next/web-ota-pointer.py newer). Used by point-machine-channel-early
# and point-machine-channel in .github/workflows/cmux-tui-artifacts.yml.
#
# usage: scripts/ci/cmux-machine-channel-point.sh PAYLOAD DIR
#
# DIR is a private scratch directory (mode 700). Reads SIGNING_KEY, R2_ENDPOINT and the R2
# credentials (AWS_*) from the environment. A compare-and-swap on the bytes compared (as
# cmux-tui-point-channel.sh): a run that finds the channel moved under it reads and compares again.
set -euo pipefail
payload=$1 dir=$2
if [[ -z "${SIGNING_KEY:-}" ]]; then
  echo "::error::CMUX_WEB_OTA_SIGNING_KEY is required to sign the Cloud machine channel"
  exit 1
fi
ptr=scripts/cmux-next/web-ota-pointer.py
keys=Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Resources/web-update-keys.json
trap 'rm -f "$dir/key.pem"' EXIT
(umask 077; printf '%s\n' "$SIGNING_KEY" > "$dir/key.pem")
python3 "$ptr" sign --payload "$payload" --key "$dir/key.pem" --keys "$keys" --out "$dir/cloud-machine.json"
rm -f "$dir/key.pem"
upload=(python3 scripts/ci/upload-r2-object.py --endpoint-url "$R2_ENDPOINT" --bucket cmux-binaries
  --cache-control "public, max-age=60, must-revalidate" --file "$dir/cloud-machine.json"
  --key "cmux-tui/channels/cloud-machine.json" --content-type application/json --conflict-exit-code 9)
for attempt in 1 2 3 4 5; do
  rm -f "$dir/current.json"
  code="$(curl -sS -o "$dir/current.json" -w '%{http_code}' --max-time 60 "https://files.cmux.com/cmux-tui/channels/cloud-machine.json?pointer=$GITHUB_RUN_ID-$attempt" || true)"
  case "$code" in
    200) mode=(--replace-sha256 "$(sha256sum "$dir/current.json" | cut -d' ' -f1)") ;;
    404) rm -f "$dir/current.json"; mode=(--write-once) ;;
    *) echo "::error::the Cloud machine channel could not be read (HTTP $code)"; exit 1 ;;
  esac
  rc=0
  python3 "$ptr" newer --pointer "$dir/cloud-machine.json" --keys "$keys" --current "$dir/current.json" || rc=$?
  [[ $rc == 3 ]] && exit 0
  [[ $rc == 0 ]] || exit "$rc"
  rc=0
  "${upload[@]}" "${mode[@]}" || rc=$?
  [[ $rc == 0 ]] && break
  [[ $rc == 9 ]] || exit "$rc"
  echo "Another run moved the Cloud machine channel first; reading it again."
  [[ $attempt == 5 ]] && { echo "The channel kept changing under this run; the next push moves it."; exit 0; }
done
curl -fsS --retry 3 --max-time 60 -o "$dir/check.json" "https://files.cmux.com/cmux-tui/channels/cloud-machine.json?check=$GITHUB_RUN_ID"
python3 "$ptr" verify --pointer "$dir/check.json" --keys "$keys" --channel cloud-machine
echo "Cloud machine channel -> ${GITHUB_SHA:0:12}" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
