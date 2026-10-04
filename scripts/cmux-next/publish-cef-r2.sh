#!/usr/bin/env bash
# Mirrors the .tar.xz assets of one manaflow-ai/cef release into the private
# R2 bucket that ensure-cef.sh reads first.
#
#   publish-cef-r2.sh <tag> [--repo manaflow-ai/cef] [--dir <assets dir>]
#                     [--manifest <cef-manifest.json>]
#
# Each asset goes to the content-addressed key cef/<sha256>/<asset name>.
# Uploads are write-once (If-None-Match: *); an existing key is only
# re-verified. After upload every object is downloaded again, with the
# read-only credentials when they are set, and its sha256 checked.
# With --manifest, the r2_bucket, r2_key and debug_r2_key fields of every
# artifact (top level and the x86_64 object, added when missing) are written
# into that manifest by cef_manifest_r2.py (run it on your pin commit).
#
# --dir takes assets already on disk (for example the fork's
# binary_distrib output); without it the assets are fetched with
# `gh release download` and checked against the release's SHA256SUMS.
#
# Credentials (environment first, then CMUX_CEF_R2_ENV_FILE, default
# ~/.secrets/cmux-cef.env; values are never printed):
#   CMUX_CEF_R2_ACCOUNT_ID
#   CMUX_CEF_R2_WRITE_ACCESS_KEY_ID, CMUX_CEF_R2_WRITE_SECRET_ACCESS_KEY
#   CMUX_CEF_R2_ACCESS_KEY_ID, CMUX_CEF_R2_SECRET_ACCESS_KEY (verify; optional)
#   CMUX_CEF_R2_BUCKET (default cmux-cef), CMUX_CEF_R2_ENDPOINT (optional)
set -euo pipefail

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }

tag=""; repo="manaflow-ai/cef"; dir=""; manifest=""
while (( $# )); do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --dir) dir="$2"; shift 2 ;;
    --manifest) manifest="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    -*) echo "unknown option $1" >&2; usage ;;
    *) [[ -z "$tag" ]] || usage; tag="$1"; shift ;;
  esac
done
[[ -n "$tag" || -n "$dir" ]] || usage

names=(CMUX_CEF_R2_ACCOUNT_ID CMUX_CEF_R2_WRITE_ACCESS_KEY_ID CMUX_CEF_R2_WRITE_SECRET_ACCESS_KEY
  CMUX_CEF_R2_ACCESS_KEY_ID CMUX_CEF_R2_SECRET_ACCESS_KEY CMUX_CEF_R2_BUCKET CMUX_CEF_R2_ENDPOINT)
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
bucket="${CMUX_CEF_R2_BUCKET:-cmux-cef}"
endpoint="${CMUX_CEF_R2_ENDPOINT:-}"
if [[ -z "$endpoint" ]]; then
  [[ -n "${CMUX_CEF_R2_ACCOUNT_ID:-}" ]] || { echo "error: CMUX_CEF_R2_ACCOUNT_ID is not set" >&2; exit 1; }
  endpoint="https://$CMUX_CEF_R2_ACCOUNT_ID.r2.cloudflarestorage.com"
fi
endpoint="${endpoint%/}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# s3 <read|write> <curl args...>; prints the HTTP status. The credential goes
# through a config on stdin, never on the command line.
s3() {
  local id secret
  if [[ "$1" == read && -n "${CMUX_CEF_R2_ACCESS_KEY_ID:-}" && -n "${CMUX_CEF_R2_SECRET_ACCESS_KEY:-}" ]]; then
    id="$CMUX_CEF_R2_ACCESS_KEY_ID"; secret="$CMUX_CEF_R2_SECRET_ACCESS_KEY"
  else
    id="$CMUX_CEF_R2_WRITE_ACCESS_KEY_ID"; secret="$CMUX_CEF_R2_WRITE_SECRET_ACCESS_KEY"
  fi
  shift
  printf 'user = "%s:%s"\n' "$id" "$secret" |
    curl --config - --silent --show-error --retry 3 --retry-delay 2 --connect-timeout 15 \
      --max-time 3600 --aws-sigv4 "aws:amz:auto:s3" -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" \
      -w '%{http_code}' "$@"
}

if [[ -z "$dir" ]]; then
  dir="$work/assets"
  mkdir -p "$dir"
  echo "==> downloading $repo $tag assets" >&2
  gh release download "$tag" --repo "$repo" --pattern '*.tar.xz' --dir "$dir" >&2
  if gh release download "$tag" --repo "$repo" --pattern SHA256SUMS --dir "$dir" >/dev/null 2>&1; then
    (cd "$dir" && grep '\.tar\.xz$' SHA256SUMS | shasum -a 256 -c - >&2) ||
      { echo "error: assets do not match the release SHA256SUMS" >&2; exit 1; }
  fi
fi

shopt -s nullglob
assets=("$dir"/*.tar.xz)
(( ${#assets[@]} )) || { echo "error: no .tar.xz assets in $dir" >&2; exit 1; }

keys=()
for path in "${assets[@]}"; do
  name="$(basename "$path")"
  sha="$(shasum -a 256 "$path" | awk '{print $1}')"
  key="cef/$sha/$name"
  url="$endpoint/$bucket/$key"
  status="$(s3 write -o /dev/null -H 'If-None-Match: *' -H 'content-type: application/x-xz' \
    -H "x-amz-meta-sha256: $sha" -T "$path" "$url")" || status=000
  case "$status" in
    200) echo "==> uploaded $key" >&2 ;;
    412) echo "==> $key already exists; verifying it" >&2 ;;
    *) echo "error: upload of $key failed (HTTP $status)" >&2; exit 1 ;;
  esac
  status="$(s3 read -o "$work/check" "$url")" || status=000
  [[ "$status" == 200 ]] || { echo "error: read-back of $key failed (HTTP $status)" >&2; exit 1; }
  actual="$(shasum -a 256 "$work/check" | awk '{print $1}')"
  rm -f "$work/check"
  [[ "$actual" == "$sha" ]] || { echo "error: $key read back as $actual" >&2; exit 1; }
  echo "==> verified $key" >&2
  keys+=("$name $sha $key")
done

printf '%s\n' "${keys[@]}"

if [[ -n "$manifest" ]]; then
  printf '%s\n' "${keys[@]}" | /usr/bin/python3 "$(dirname "$0")/cef_manifest_r2.py" "$manifest" "$bucket"
fi
