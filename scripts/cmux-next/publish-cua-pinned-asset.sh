#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Publishes one cmux Computer Use helper v2 input to the private R2 bucket and
# writes its pin. Same rules as publish-remote-browser-host.sh: the key is
# content-addressed (<prefix>/<sha256>/<asset>), the upload is write-once
# (If-None-Match: *), the object is always read back and its sha256 checked,
# credentials go to curl on stdin, and one line is appended to the publish log.
# Only the prefixes cua-driver-sdk/ and cua-helper-dev/ are allowed. Never
# publish keys, certificates or provisioning profiles.
#
#   publish-cua-pinned-asset.sh --file PATH --prefix cua-driver-sdk|cua-helper-dev \
#       --pin PIN.json [--field KEY=VALUE ...] [--dry-run]
#
# Credentials (environment first, then CMUX_CEF_R2_ENV_FILE, default
# ~/.secrets/cmux-cef.env; values never printed): CMUX_CEF_R2_ACCOUNT_ID,
# CMUX_CEF_R2_WRITE_ACCESS_KEY_ID, CMUX_CEF_R2_WRITE_SECRET_ACCESS_KEY
# (+ optional read-only CMUX_CEF_R2_ACCESS_KEY_ID/SECRET for the read-back).
# Log: $CMUX_CUA_PUBLISH_LOG, default <hq>/artifacts/cua-helper-v2-r2-publish.log.
set -euo pipefail

file=""; prefix=""; pin=""; dry=0; fields=()
usage() { echo "usage: publish-cua-pinned-asset.sh --file PATH --prefix cua-driver-sdk|cua-helper-dev --pin PIN [--field K=V ...] [--dry-run]" >&2; exit 2; }
while (( $# )); do
  case "$1" in
    --file) file="${2:?}"; shift 2 ;;
    --prefix) prefix="${2:?}"; shift 2 ;;
    --pin) pin="${2:?}"; shift 2 ;;
    --field) fields+=("${2:?}"); shift 2 ;;
    --dry-run) dry=1; shift ;;
    *) usage ;;
  esac
done
[[ -f "$file" && -n "$pin" ]] || usage
case "$prefix" in cua-driver-sdk|cua-helper-dev) ;; *) echo "error: prefix must be cua-driver-sdk or cua-helper-dev" >&2; exit 2 ;; esac
case "$(basename "$file")" in
  *.p12|*.pem|*.key|*.cer|*.mobileprovision|*.provisionprofile|*.env) echo "error: refusing to publish a credential-like file" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
bucket="${CMUX_CEF_R2_BUCKET:-cmux-cef}"
asset="$(basename "$file")"
sha="$(shasum -a 256 "$file" | awk '{print $1}')"
key="$prefix/$sha/$asset"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
result=dry-run

if (( ! dry )); then
  names=(CMUX_CEF_R2_ACCOUNT_ID CMUX_CEF_R2_WRITE_ACCESS_KEY_ID CMUX_CEF_R2_WRITE_SECRET_ACCESS_KEY
    CMUX_CEF_R2_ACCESS_KEY_ID CMUX_CEF_R2_SECRET_ACCESS_KEY CMUX_CEF_R2_ENDPOINT)
  env_file="${CMUX_CEF_R2_ENV_FILE:-$HOME/.secrets/cmux-cef.env}"
  if [[ -r "$env_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line#export }"; name="${line%%=*}"; value="${line#*=}"
      [[ " ${names[*]} " == *" $name "* ]] || continue
      [[ -n "${!name:-}" ]] && continue
      value="${value%\"}"; value="${value#\"}"; value="${value%\'}"; value="${value#\'}"
      printf -v "$name" '%s' "$value"
    done < "$env_file"
  fi
  for name in CMUX_CEF_R2_WRITE_ACCESS_KEY_ID CMUX_CEF_R2_WRITE_SECRET_ACCESS_KEY; do
    [[ -n "${!name:-}" ]] || { echo "error: $name is not set (environment or $env_file)" >&2; exit 1; }
  done
  endpoint="${CMUX_CEF_R2_ENDPOINT:-}"
  if [[ -z "$endpoint" ]]; then
    [[ -n "${CMUX_CEF_R2_ACCOUNT_ID:-}" ]] || { echo "error: CMUX_CEF_R2_ACCOUNT_ID is not set" >&2; exit 1; }
    endpoint="https://$CMUX_CEF_R2_ACCOUNT_ID.r2.cloudflarestorage.com"
  fi
  url="${endpoint%/}/$bucket/$key"
  s3() { # <read|write> curl args...; the credential goes on stdin, never argv
    local id secret
    if [[ "$1" == read && -n "${CMUX_CEF_R2_ACCESS_KEY_ID:-}" && -n "${CMUX_CEF_R2_SECRET_ACCESS_KEY:-}" ]]; then
      id="$CMUX_CEF_R2_ACCESS_KEY_ID"; secret="$CMUX_CEF_R2_SECRET_ACCESS_KEY"
    else
      id="$CMUX_CEF_R2_WRITE_ACCESS_KEY_ID"; secret="$CMUX_CEF_R2_WRITE_SECRET_ACCESS_KEY"
    fi
    shift
    printf 'user = "%s:%s"\n' "$id" "$secret" |
      curl --config - --silent --show-error --retry 3 --retry-delay 2 --connect-timeout 15 \
        --max-time 1800 --aws-sigv4 "aws:amz:auto:s3" -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" \
        -w '%{http_code}' "$@"
  }
  status="$(s3 write -o /dev/null -H 'If-None-Match: *' -H 'content-type: application/octet-stream' \
    -H "x-amz-meta-sha256: $sha" -T "$file" "$url")" || status=000
  case "$status" in
    200) echo "==> uploaded $key" >&2; result=uploaded ;;
    412) echo "==> $key already exists; verifying it" >&2; result=exists ;;
    *) echo "error: upload of $key failed (HTTP $status)" >&2; exit 1 ;;
  esac
  status="$(s3 read -o "$work/check" "$url")" || status=000
  [[ "$status" == 200 ]] || { echo "error: read-back of $key failed (HTTP $status)" >&2; exit 1; }
  actual="$(shasum -a 256 "$work/check" | awk '{print $1}')"
  [[ "$actual" == "$sha" ]] || { echo "error: $key read back as $actual" >&2; exit 1; }
  echo "==> verified $key" >&2
  log="${CMUX_CUA_PUBLISH_LOG:-}"
  if [[ -z "$log" ]]; then
    hq="$(cd "$repo_root/../.." 2>/dev/null && pwd)"
    [[ -d "$hq/artifacts" ]] && log="$hq/artifacts/cua-helper-v2-r2-publish.log"
  fi
  if [[ -n "$log" ]]; then
    printf '%s %s bucket=%s key=%s sha256=%s readback=ok head=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$result" "$bucket" "$key" "$sha" \
      "$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo unknown)" >> "$log"
  fi
fi

/usr/bin/python3 -I - "$pin" "$asset" "$sha" "$bucket" "$key" "${fields[@]+"${fields[@]}"}" <<'PY'
import json, sys
pin, asset, sha, bucket, key, *fields = sys.argv[1:]
data = {"asset": asset, "arch": "arm64", "sha256": sha, "r2_bucket": bucket, "r2_key": key}
for field in fields:
    name, _, value = field.partition("=")
    data[name] = value
with open(pin, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
echo "==> wrote $pin (sha256 $sha, $result)" >&2
