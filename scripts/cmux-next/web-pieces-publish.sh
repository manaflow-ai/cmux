#!/usr/bin/env bash
# Signs and uploads a web update channel's switch file (cmux-next-web-pieces.yml; the payload is
# web-pieces-file.py's, the signature web-ota-pointer.py's).
#
#   web-pieces-publish.sh WORKDIR KEY.pem
#
# Reads CHANNEL, OUT_OF, REASON, LIVE, REFUSE, ALLOW (space separated lists) and ALL_LIVE
# (true|false). The published file is read first and must verify under the pinned key (none yet:
# the channel's first file); the new one continues its serial. WEB_PIECES_BASE (default
# https://files.cmux.com/cmux-next-web/ota) and WEB_PIECES_KEYS replace the place and the key list
# (tests); WEB_PIECES_DRY_RUN=1 stops before the upload and leaves WORKDIR/pieces-CHANNEL.json.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
dir=$1
pem=$2
ptr="$ROOT/scripts/cmux-next/web-ota-pointer.py"
keys=${WEB_PIECES_KEYS:-$ROOT/Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Resources/web-update-keys.json}
base=${WEB_PIECES_BASE:-https://files.cmux.com/cmux-next-web/ota}
name="pieces-$CHANNEL.json"
stamp=${GITHUB_RUN_ID:-$$}

words=(--channel "$CHANNEL" --out "$dir/payload.json")
code=$(curl -sS -o "$dir/current.json" -w '%{http_code}' --retry 3 --max-time 60 "$base/$name?switch=$stamp" 2>/dev/null || true)
case "$code" in
  200)
    # A published file no pinned key covers is never continued: fail, and a person looks.
    python3 "$ptr" verify --pointer "$dir/current.json" --keys "$keys" --channel "$CHANNEL" \
      --purpose cmux-web-pieces --allow-expired > "$dir/current-payload.json"
    words+=(--current "$dir/current-payload.json")
    ;;
  403 | 404) ;;
  *)
    echo "web-pieces-publish: could not read $base/$name (HTTP $code); not guessing its serial" >&2
    exit 1
    ;;
esac
# shellcheck disable=SC2086 # the lists are split on spaces
{
  for word in ${OUT_OF:-}; do words+=(--out-of "$word${REASON:+:$REASON}"); done
  for word in ${LIVE:-}; do words+=(--live "$word"); done
  for word in ${REFUSE:-}; do words+=(--refuse "$word"); done
  for word in ${ALLOW:-}; do words+=(--allow "$word"); done
}
[[ "${ALL_LIVE:-false}" == true ]] && words+=(--all-live)
python3 "$ROOT/scripts/cmux-next/web-pieces-file.py" payload "${words[@]}"
python3 "$ptr" sign --payload "$dir/payload.json" --key "$pem" --keys "$keys" --out "$dir/$name"
python3 "$ptr" verify --pointer "$dir/$name" --keys "$keys" --channel "$CHANNEL" --purpose cmux-web-pieces --allow-expired >/dev/null
[[ "${WEB_PIECES_DRY_RUN:-}" == 1 ]] && exit 0
python3 "$ROOT/scripts/ci/upload-r2-object.py" --endpoint-url "$R2_ENDPOINT" --bucket cmux-binaries \
  --cache-control "public, max-age=60, must-revalidate" --file "$dir/$name" \
  --key "cmux-next-web/ota/$name" --content-type application/json
curl -fsS --retry 3 --max-time 60 -o "$dir/check.json" "$base/$name?check=$stamp"
python3 "$ptr" verify --pointer "$dir/check.json" --keys "$keys" --channel "$CHANNEL" --purpose cmux-web-pieces --allow-expired >/dev/null
