#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Fetches, verifies and caches one pinned signed asset (cmux-remote-dev.pin.json,
# the Apple Development signed cmux Remote (dev).app written by
# sign-cmux-remote-dev.sh and published by publish-signed-pinned-asset.sh) and
# prints its cached path on stdout.
#
#   ensure-signed-pinned-asset.sh PIN.json [--optional | --allow-no-source]
#
# --optional: an unavailable asset warns, prints no path and exits 0.
# --allow-no-source: only "this machine has no source for the asset" is not an error: no cached or
# local copy, a store that gives no URL for it (or no answer), and no read credentials. It prints
# nothing and exits 3, and the caller says what it leaves out. A download that started and failed,
# from the store's URL or from R2, is still an error. A damaged cached file is a note in this mode,
# so the caller's line is the only warning.
#
# Sources, each checked against the pin sha256 (a mismatch always fails,
# also with --optional): the local cache; CMUX_CUA_ASSET_FILE (a local copy);
# the fleet controller artifact store (signed GET of sha256:<pin sha256>,
# tailnet only, as in ensure-remote-browser-host.sh; `cmux-ci artifact-put`
# stages it for a fleet job); then the private R2 bucket with the read-only
# CMUX_CEF_R2_* credentials (environment, else CMUX_CEF_R2_ENV_FILE, default
# ~/.secrets/cmux-cef.env). CMUX_CUA_ASSET_NO_STORE=1 skips the store. CMUX_CUA_ASSET_CACHE_DIR overrides the
# cache root (default <cef-cache-root>/cua-helper-v2).
set -euo pipefail
pin="${1:?usage: ensure-signed-pinned-asset.sh PIN.json [--optional | --allow-no-source]}"
optional=0
allow_no_source=0
case "${2:-}" in
  --optional) optional=1 ;;
  --allow-no-source) allow_no_source=1 ;;
esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unavailable() {
  if (( optional )); then echo "warning: $(basename "$pin") unavailable: $*" >&2; exit 0; fi
  echo "error: $(basename "$pin") unavailable: $*" >&2
  exit 1
}
[[ -f "$pin" ]] || unavailable "no pin file $pin"
read -r sha asset bucket key < <(/usr/bin/python3 -I - "$pin" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print(d.get("sha256", ""), d.get("asset", ""), d.get("r2_bucket", ""), d.get("r2_key", ""))
PY
)
[[ "$sha" =~ ^[0-9a-f]{64}$ && -n "$asset" && "$asset" != */* ]] || { echo "error: pin $pin lacks a sha256 or asset" >&2; exit 1; }
root="${CMUX_CUA_ASSET_CACHE_DIR:-$("$SCRIPT_DIR/cef-cache-root.sh")/cua-helper-v2}"
dest="$root/$sha/$asset"
sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }
if [[ -f "$dest" ]]; then
  [[ "$(sha_of "$dest")" == "$sha" ]] && { echo "$dest"; exit 0; }
  level=warning
  (( allow_no_source )) && level=note
  echo "$level: cached $dest is damaged; fetching it again" >&2
  rm -f "$dest"
fi
mkdir -p "$root/$sha"
tmp="$(mktemp -d "$root/.incoming.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
out="$tmp/$asset"
# Set when the store gave a URL for the asset and the download of its bytes failed: the store is a
# source then, so this is a failed download and not "no source".
store_failed=""
from_store() {
  [[ "${CMUX_CUA_ASSET_NO_STORE:-0}" == "1" ]] && return 1
  local controller="${CMUX_CEF_STORE_URL:-http://100.89.225.106:18765}" signed traced=0
  if [[ $- == *x* ]]; then traced=1; set +x; fi  # the signed URL is a read capability
  signed="$(curl --fail --silent --show-error --connect-timeout 5 --max-time 30 \
      -A cmux-ensure-cua "${controller%/}/v1/artifacts/sha256:$sha/url" 2>/dev/null |
    /usr/bin/python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("url", ""))' 2>/dev/null || true)"
  local ok=1
  case "$signed" in
    https://*|http://*|file://*)
      echo "==> downloading $asset from the controller artifact store" >&2
      if curl --fail --silent --show-error --location --retry 3 --retry-delay 2 --connect-timeout 15 \
        --max-time 900 -A cmux-ensure-cua -o "$out" "$signed" 2>/dev/null; then
        ok=0
      else
        store_failed="the download from the artifact store failed"
      fi ;;
  esac
  if (( traced )); then set -x; fi
  return "$ok"
}
if [[ -n "${CMUX_CUA_ASSET_FILE:-}" ]]; then
  # A local copy (for example the artifact a build just produced); still checked.
  cp "$CMUX_CUA_ASSET_FILE" "$out"
elif from_store; then
  :
else
  file="${CMUX_CEF_R2_ENV_FILE:-$HOME/.secrets/cmux-cef.env}"
  if [[ -r "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line#export }"; name="${line%%=*}"; value="${line#*=}"
      case "$name" in CMUX_CEF_R2_ACCOUNT_ID|CMUX_CEF_R2_ACCESS_KEY_ID|CMUX_CEF_R2_SECRET_ACCESS_KEY|CMUX_CEF_R2_ENDPOINT) ;; *) continue ;; esac
      [[ -n "${!name:-}" ]] && continue
      value="${value%\"}"; value="${value#\"}"; value="${value%\'}"; value="${value#\'}"
      printf -v "$name" '%s' "$value"
    done < "$file"
  fi
  id="${CMUX_CEF_R2_ACCESS_KEY_ID:-}"; secret="${CMUX_CEF_R2_SECRET_ACCESS_KEY:-}"
  endpoint="${CMUX_CEF_R2_ENDPOINT:-}"
  [[ -z "$endpoint" && -n "${CMUX_CEF_R2_ACCOUNT_ID:-}" ]] && endpoint="https://$CMUX_CEF_R2_ACCOUNT_ID.r2.cloudflarestorage.com"
  if [[ -z "$id" || -z "$secret" || -z "$endpoint" || -z "$bucket" || -z "$key" ]]; then
    (( allow_no_source )) && [[ -z "$store_failed" ]] && exit 3
    unavailable "${store_failed:+$store_failed, and }no CMUX_CEF_R2_* read credentials"
  fi
  echo "==> downloading $asset from R2 $bucket" >&2
  printf 'user = "%s:%s"\n' "$id" "$secret" |
    curl --config - --fail --silent --show-error --location --retry 5 --retry-delay 2 \
      --connect-timeout 15 --max-time 900 --aws-sigv4 "aws:amz:auto:s3" \
      -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" -o "$out" "${endpoint%/}/$bucket/$key" >&2 ||
    unavailable "R2 download failed"
fi
actual="$(sha_of "$out")"
[[ "$actual" == "$sha" ]] || { echo "error: sha256 mismatch for $asset: expected $sha, got $actual" >&2; exit 1; }
mv -f "$out" "$dest"
echo "$dest"
