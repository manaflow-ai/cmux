#!/usr/bin/env bash
# Sign a payload of scripts/ci/cmux-machine-channel.py and move its channel pointer to it, unless
# the channel already names this build or a newer one (scripts/cmux-next/web-ota-pointer.py newer).
# The payload's purpose names the files:
#
#   cmux-cloud-machine-update  cmux-tui/channels/cloud-machine.json
#   cmux-linux-release         cmux-tui/<commit>/release.json, written once, then
#                              cmux-tui/channels/linux-<channel>.json (the same signed file)
#
# Used by point-machine-channel-early, point-machine-channel and sign-linux-release in
# .github/workflows/cmux-tui-artifacts.yml.
#
# usage: scripts/ci/cmux-machine-channel-point.sh PAYLOAD DIR
#
# DIR is a private scratch directory (mode 700). Reads SIGNING_KEY, R2_ENDPOINT and the R2
# credentials (AWS_*) from the environment. A compare-and-swap on the bytes compared (as
# cmux-tui-point-channel.sh): a run that finds the channel moved under it reads and compares again.
set -euo pipefail
payload=$1 dir=$2
ptr=scripts/cmux-next/web-ota-pointer.py
keys=Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Resources/web-update-keys.json
read -r purpose channel commit < <(python3 -c '
import json, sys
p = json.load(open(sys.argv[1]))
print(p["purpose"], p["channel"], p["commit"])' "$payload")
case "$purpose" in
  cmux-cloud-machine-update) object=cmux-tui/channels/cloud-machine.json label="Cloud machine channel" ;;
  cmux-linux-release) object="cmux-tui/channels/linux-$channel.json" label="Linux release channel $channel" ;;
  *) echo "::error::$payload has the unknown purpose $purpose"; exit 1 ;;
esac
if [[ -z "${SIGNING_KEY:-}" ]]; then
  echo "::error::CMUX_WEB_OTA_SIGNING_KEY is required to sign the $label"
  exit 1
fi
signed="$dir/signed.json"
trap 'rm -f "$dir/key.pem"' EXIT
(umask 077; printf '%s\n' "$SIGNING_KEY" > "$dir/key.pem")
python3 "$ptr" sign --payload "$payload" --key "$dir/key.pem" --keys "$keys" --out "$signed"
rm -f "$dir/key.pem"
upload() { # KEY CACHE-CONTROL MODE...
  local key=$1 cache=$2
  shift 2
  python3 scripts/ci/upload-r2-object.py --endpoint-url "$R2_ENDPOINT" --bucket cmux-binaries \
    --cache-control "$cache" --file "$signed" --key "$key" --content-type application/json \
    --conflict-exit-code 9 "$@"
}

if [[ "$purpose" == cmux-linux-release ]]; then
  # The per-commit release file is written once. A file already there of the same build (another
  # run or attempt signed it at another time) is kept; one of another build is an error: an
  # installer that asked for this version by name would install other bytes.
  release="cmux-tui/$commit/release.json"
  for attempt in 1 2 3; do
    rm -f "$dir/release-current.json"
    code="$(curl -sS -o "$dir/release-current.json" -w '%{http_code}' --max-time 60 "https://files.cmux.com/$release?release=$GITHUB_RUN_ID-$attempt" || true)"
    case "$code" in
      200)
        python3 "$ptr" same-build --pointer "$signed" --current "$dir/release-current.json" --keys "$keys" || {
          echo "::error title=immutable-r2-conflict::$release already holds another build; it is never replaced"
          exit 1
        }
        break ;;
      404)
        rc=0
        upload "$release" "public, max-age=31536000, immutable" --write-once || rc=$?
        [[ $rc == 0 ]] && break
        [[ $rc == 9 ]] || exit "$rc"
        echo "Another run wrote $release first; reading it again." ;;
      *) echo "::error::$release could not be read (HTTP $code)"; exit 1 ;;
    esac
    [[ $attempt == 3 ]] && { echo "::error::$release kept changing under this run"; exit 1; }
  done
  curl -fsS --retry 3 --max-time 60 -o "$dir/release-check.json" "https://files.cmux.com/$release?check=$GITHUB_RUN_ID"
  python3 "$ptr" verify --pointer "$dir/release-check.json" --keys "$keys" --purpose "$purpose" --channel "$channel" \
    --allow-expired >/dev/null
  echo "Linux release file -> $release" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
fi

for attempt in 1 2 3 4 5; do
  rm -f "$dir/current.json"
  code="$(curl -sS -o "$dir/current.json" -w '%{http_code}' --max-time 60 "https://files.cmux.com/$object?pointer=$GITHUB_RUN_ID-$attempt" || true)"
  case "$code" in
    200) mode=(--replace-sha256 "$(sha256sum "$dir/current.json" | cut -d' ' -f1)") ;;
    404) rm -f "$dir/current.json"; mode=(--write-once) ;;
    *) echo "::error::the $label could not be read (HTTP $code)"; exit 1 ;;
  esac
  rc=0
  python3 "$ptr" newer --pointer "$signed" --keys "$keys" --current "$dir/current.json" || rc=$?
  [[ $rc == 3 ]] && exit 0
  [[ $rc == 0 ]] || exit "$rc"
  rc=0
  upload "$object" "public, max-age=60, must-revalidate" "${mode[@]}" || rc=$?
  [[ $rc == 0 ]] && break
  [[ $rc == 9 ]] || exit "$rc"
  echo "Another run moved the $label first; reading it again."
  [[ $attempt == 5 ]] && { echo "The channel kept changing under this run; the next push moves it."; exit 0; }
done
curl -fsS --retry 3 --max-time 60 -o "$dir/check.json" "https://files.cmux.com/$object?check=$GITHUB_RUN_ID"
python3 "$ptr" verify --pointer "$dir/check.json" --keys "$keys" --purpose "$purpose" --channel "$channel" >/dev/null
echo "$label -> ${commit:0:12}" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
