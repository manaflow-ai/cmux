#!/usr/bin/env bash
# The signed Screen Sharing helper of the checked-out commit, for its Mac live update file
# (cmux-tui-artifacts.yml point-machine-channel, "Sign the Mac live update file"): finds the helper
# cmux-tui-team-signed.yml signed for the commit's helper source key
# (cmux-tui/screen-sharing-helper/<key>/helper.json, scripts/ci/screen_sharing_helper_release.py),
# waiting up to WAIT seconds for a key whose signing is still running, checks it, copies its zip to
# the commit's own prefix (cmux-tui/<commit>/cmux-screen-sharing-helper-aarch64-apple-darwin.zip,
# write-once) and prints the record's path for cmux-machine-channel.py --screen-sharing-helper.
#
# usage: scripts/ci/mac-live-screen-sharing-helper.sh COMMIT DIR WAIT
#
# Prints nothing (and exits 0) when the key has no signed helper yet: the file then carries no helper
# key, and `cmux app try` leaves the app's helper as it is. Delivery, not a gate. Reads R2_ENDPOINT
# and the R2 credentials (AWS_*) from the environment.
set -euo pipefail
commit=$1 dir=$2 wait=$3
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::bad commit $commit" >&2; exit 1; }
[[ "$(git rev-parse HEAD)" == "$commit" ]] || { echo "::error::the checkout is not $commit" >&2; exit 1; }
release=scripts/ci/screen_sharing_helper_release.py
key="$(scripts/cmux-next/build-screen-sharing-helper.sh --print-key)"
[[ "$key" =~ ^[0-9a-f]{16}$ ]] || { echo "::error::no helper source key for $commit ($key)" >&2; exit 1; }
base="https://files.cmux.com/cmux-tui/screen-sharing-helper/$key"
deadline=$((SECONDS + wait))
until curl -fsS --retry 2 --max-time 30 -o "$dir/helper.json" "$base/helper.json?mac-live=$commit" 2>/dev/null; do
  if (( SECONDS >= deadline )); then
    echo "::notice title=No Screen Sharing helper::helper key $key of $commit has no signed helper after ${wait}s; its Mac live update file carries none" >&2
    exit 0
  fi
  sleep 30
done
python3 "$release" verify-record "$dir/helper.json" --key "$key"
sha="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["sha256"])' "$dir/helper.json")"
zip="$dir/helper.zip"
curl -fsS --retry 3 --max-time 600 -o "$zip" "$base/$sha/cmux-screen-sharing-helper-aarch64-apple-darwin.zip?mac-live=$commit"
python3 "$release" verify-record "$dir/helper.json" --key "$key" --zip "$zip"
# Write-once: a second run of the same commit uploads the same bytes (accepted); other bytes fail.
python3 scripts/ci/upload-r2-object.py --write-once --endpoint-url "$R2_ENDPOINT" --bucket cmux-binaries \
  --key "cmux-tui/$commit/cmux-screen-sharing-helper-aarch64-apple-darwin.zip" --file "$zip" \
  --content-type application/zip --cache-control "public, max-age=31536000, immutable" >&2
rm -f "$zip"
printf '%s\n' "$dir/helper.json"
