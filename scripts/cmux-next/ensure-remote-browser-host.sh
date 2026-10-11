#!/usr/bin/env bash
# Fetches, verifies and caches the pinned cmux-remote-browser-host binary
# (scripts/cmux-next/remote-browser-host.pin.json, written by
# publish-remote-browser-host.sh), then prints its path on stdout.
#
#   ensure-remote-browser-host.sh             fail (exit 1) when unavailable
#   ensure-remote-browser-host.sh --optional  warn and print nothing instead
#
# Sources, in order; every one is checked against the pin sha256:
#   1. the local cache (a damaged entry is fetched again)
#   2. the fleet controller artifact store (signed GET of sha256:<pin sha256>,
#      tailnet only), as in ensure-cef.sh
#   3. the private R2 bucket (pin r2_bucket/r2_key) with the read-only
#      CMUX_CEF_R2_* credentials (environment, else CMUX_CEF_R2_ENV_FILE,
#      default ~/.secrets/cmux-cef.env)
# Bytes from a source that do not match the pin sha256 fail the run, also
# with --optional: a wrong host binary is never embedded or retried around.
#
# Environment:
#   CMUX_NEXT_RB_HOST_PIN         pin file (default: the one beside this script)
#   CMUX_NEXT_RB_HOST_CACHE_DIR   cache root (default <cef-cache-root>/remote-browser-host)
#   CMUX_CEF_STORE_URL            fleet controller (default http://100.89.225.106:18765)
#   CMUX_RB_HOST_NO_STORE=1, CMUX_RB_HOST_NO_R2=1   skip a source
set -euo pipefail

optional=0
case "${1:-}" in
  "") ;;
  --optional) optional=1 ;;
  *) echo "usage: ensure-remote-browser-host.sh [--optional]" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIN="${CMUX_NEXT_RB_HOST_PIN:-$SCRIPT_DIR/remote-browser-host.pin.json}"

unavailable() {
  if (( optional )); then
    echo "warning: remote browser host unavailable: $*" >&2
    exit 0
  fi
  echo "error: remote browser host unavailable: $*" >&2
  exit 1
}

[[ -f "$PIN" ]] || unavailable "no pin file $PIN"
field() {
  /usr/bin/python3 - "$1" "$PIN" <<'PY'
import json, sys
try:
    value = json.load(open(sys.argv[2], encoding="utf-8")).get(sys.argv[1])
    if value is not None:
        print(value)
except (OSError, ValueError):
    pass
PY
}
sha="$(field sha256)"; asset="$(field asset)"
r2_bucket="$(field r2_bucket)"; r2_key="$(field r2_key)"
[[ "$sha" =~ ^[0-9a-f]{64}$ && -n "$asset" ]] || { echo "error: pin $PIN lacks a sha256 or asset" >&2; exit 1; }

root="${CMUX_NEXT_RB_HOST_CACHE_DIR:-$("$SCRIPT_DIR/cef-cache-root.sh")/remote-browser-host}"
dest="$root/$sha/$asset"
sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

if [[ -f "$dest" ]]; then
  if [[ "$(sha_of "$dest")" == "$sha" ]]; then
    echo "$dest"
    exit 0
  fi
  echo "warning: cached $dest is damaged; fetching it again" >&2
  rm -f "$dest"
fi

mkdir -p "$root/$sha"
tmp="$(mktemp -d "$root/.incoming.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
out="$tmp/$asset"

# A source whose bytes differ from the pin fails the run (fail closed).
check() { # <source name>
  local actual
  actual="$(sha_of "$out")"
  [[ "$actual" == "$sha" ]] && return 0
  echo "error: sha256 mismatch for $asset from $1: expected $sha, got $actual" >&2
  exit 1
}

fetch_store() {
  [[ "${CMUX_RB_HOST_NO_STORE:-0}" == "1" ]] && return 1
  local traced=0 status=1
  if [[ $- == *x* ]]; then traced=1; set +x; fi  # the signed URL is a read capability
  store_download && status=0
  if (( traced )); then set -x; fi
  return "$status"
}
store_download() {
  local controller="${CMUX_CEF_STORE_URL:-http://100.89.225.106:18765}" signed
  signed="$(curl --fail --silent --show-error --connect-timeout 5 --max-time 30 \
      -A cmux-ensure-cef "${controller%/}/v1/artifacts/sha256:$sha/url" 2>/dev/null |
    /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("url", ""))' 2>/dev/null || true)"
  case "$signed" in https://*|http://*|file://*) ;; *) return 1 ;; esac
  echo "==> downloading $asset from the controller artifact store" >&2
  curl --fail --silent --show-error --location --retry 3 --retry-delay 2 --connect-timeout 15 \
    --max-time 900 -A cmux-ensure-cef -o "$out" "$signed" 2>/dev/null || { rm -f "$out"; return 1; }
  check "the controller artifact store"
}

load_r2_env_file() {
  local file="${CMUX_CEF_R2_ENV_FILE:-$HOME/.secrets/cmux-cef.env}" line name value
  [[ -r "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#export }"; name="${line%%=*}"; value="${line#*=}"
    case "$name" in
      CMUX_CEF_R2_ACCOUNT_ID|CMUX_CEF_R2_ACCESS_KEY_ID|CMUX_CEF_R2_SECRET_ACCESS_KEY) ;;
      *) continue ;;
    esac
    [[ -n "${!name:-}" ]] && continue
    value="${value%\"}"; value="${value#\"}"; value="${value%\'}"; value="${value#\'}"
    printf -v "$name" '%s' "$value"
  done < "$file"
}
fetch_r2() {
  [[ "${CMUX_RB_HOST_NO_R2:-0}" == "1" ]] && return 1
  [[ -n "$r2_bucket" && -n "$r2_key" ]] || return 1
  load_r2_env_file
  local account="${CMUX_CEF_R2_ACCOUNT_ID:-}" id="${CMUX_CEF_R2_ACCESS_KEY_ID:-}"
  local secret="${CMUX_CEF_R2_SECRET_ACCESS_KEY:-}" endpoint="${CMUX_CEF_R2_ENDPOINT:-}"
  [[ -n "$id" && -n "$secret" ]] || return 1
  if [[ -z "$endpoint" ]]; then
    [[ -n "$account" ]] || return 1
    endpoint="https://$account.r2.cloudflarestorage.com"
  fi
  echo "==> downloading $asset from R2 $r2_bucket" >&2
  printf 'user = "%s:%s"\n' "$id" "$secret" |
    curl --config - --fail --silent --show-error --location --retry 5 --retry-delay 2 \
      --connect-timeout 15 --max-time 900 --aws-sigv4 "aws:amz:auto:s3" \
      -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" \
      -o "$out" "${endpoint%/}/$r2_bucket/$r2_key" >&2 || { rm -f "$out"; return 1; }
  check R2
}

fetch_store || fetch_r2 || unavailable "no source had $asset sha256:$sha (tailnet controller or CMUX_CEF_R2_* read credentials)"
chmod 755 "$out"
mv -f "$out" "$dest"
echo "==> remote browser host ready at $dest" >&2
echo "$dest"
