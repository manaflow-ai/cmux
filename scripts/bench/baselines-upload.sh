#!/usr/bin/env bash
# Upload a `cmux-bench baselines record|from-log --out ROOT` tree to the cmux-ci-cache-next R2 bucket as is, then
# the stamp object STAMP_KEY. Zero objects is red: a recorder that records nothing fails and the stamp stays old.
# Needs AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, CI_CACHE_R2_ENDPOINT, CI_CACHE_R2_BUCKET; GITHUB_SHA names the stamp.
#   scripts/bench/baselines-upload.sh ROOT STAMP_KEY
set -euo pipefail
root="$1" stamp_key="$2"
put() { # <file> <object key>
  local code
  code="$(printf 'user = "%s:%s"\n' "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" \
    | curl --config - --silent --show-error --retry 3 --retry-delay 2 --max-time 60 \
        --aws-sigv4 "aws:amz:auto:s3" -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" \
        -H "Content-Type: application/json" -H "Cache-Control: max-age=600" \
        -X PUT --upload-file "$1" -o /dev/null -w '%{http_code}' \
        "$CI_CACHE_R2_ENDPOINT/$CI_CACHE_R2_BUCKET/$2")"
  [ "$code" = 200 ] || { echo "::error::PUT $2 answered HTTP $code"; return 1; }
  echo "put $2"
}
n=0
if [ -d "$root" ]; then
  while IFS= read -r f; do
    put "$f" "${f#"$root"/}"
    n=$((n + 1))
  done < <(find "$root" -type f -name '*.json' | sort)
fi
if [ "$n" -eq 0 ]; then
  echo "::error::No bench measured all 3 repeats; nothing recorded, the stamp stays old (a recorder that records nothing is red, not green)"
  exit 1
fi
stamp="$(mktemp)"
printf '{"recorded_at": "%s", "sha": "%s", "objects": %d}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${GITHUB_SHA:-}" "$n" > "$stamp"
put "$stamp" "$stamp_key"
rm -f "$stamp"
