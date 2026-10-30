#!/usr/bin/env bash
# Publishes the Chromium runtime pack cef-runtime-pack.sh wrote
# (plans/cmux-next/bundle-size-DESIGN.md section 6.6). Run in the publish job
# BEFORE the appcast that points at the app goes up.
#
# Usage: publish-cef-runtime.sh <out-dir>
#
# Uploads cef-runtime/<key>/cef-runtime-<key>.tar.xz, then
# cef-runtime/<key>/cef-runtime.json, both write-once (an identical object is
# accepted, different bytes fail), then downloads the pack from the public URL
# in the pin and checks its sha256 and size. A reused pack (<out-dir>/reused)
# is only checked.
#
# Env: R2_ENDPOINT, NIGHTLY_NEXT_R2_BUCKET (or CMUX_CEF_RUNTIME_BUCKET), and
# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY for scripts/ci/upload-r2-object.py.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${1:?usage: publish-cef-runtime.sh <out-dir>}"
pin="$out/cef-runtime.json"
[[ -f "$pin" ]] || { echo "publish-cef-runtime: no $pin" >&2; exit 1; }
read -r key sha size url < <(python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); print(p["key"], p["sha256"], p["size"], p["url"])' "$pin")
[[ "$key" =~ ^[0-9a-f]{16}$ ]] || { echo "publish-cef-runtime: bad key '$key'" >&2; exit 1; }

# The pack's own cap (bundle-size-budget.json, variant arm64-cef-on-demand).
cap="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["variants"]["arm64-cef-on-demand"].get("pack_max_bytes", ""))' "$SCRIPT_DIR/bundle-size-budget.json" 2>/dev/null || true)"
if [[ -n "$cap" ]] && (( size > cap )); then
  echo "publish-cef-runtime: the pack is $size bytes, over its cap $cap (scripts/cmux-next/bundle-size-budget.json)" >&2
  exit 1
fi

if [[ ! -f "$out/reused" ]]; then
  bucket="${CMUX_CEF_RUNTIME_BUCKET:-${NIGHTLY_NEXT_R2_BUCKET:?set NIGHTLY_NEXT_R2_BUCKET}}"
  asset="cef-runtime-$key.tar.xz"
  [[ -f "$out/$asset" ]] || { echo "publish-cef-runtime: no $out/$asset" >&2; exit 1; }
  upload() { # <file> <key> <content-type>
    python3 "$SCRIPT_DIR/../ci/upload-r2-object.py" --file "$1" --endpoint-url "${R2_ENDPOINT:?}" \
      --bucket "$bucket" --key "$2" --content-type "$3" --cache-control "public, max-age=31536000, immutable" --write-once
  }
  # The pack first, its pin last: a published pin always names a pack that exists.
  upload "$out/$asset" "cef-runtime/$key/$asset" application/x-xz
  upload "$pin" "cef-runtime/$key/cef-runtime.json" application/json
fi

check="$(mktemp "${TMPDIR:-/tmp}/cef-runtime-check.XXXXXX")"
trap 'rm -f "$check"' EXIT
curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 -o "$check" "$url"
got_sha="$(shasum -a 256 "$check" | awk '{print $1}')"
got_size="$(wc -c < "$check" | tr -d " ")"  # GNU and BSD alike (the publish job runs on Linux)
if [[ "$got_sha" != "$sha" || "$got_size" != "$size" ]]; then
  echo "publish-cef-runtime: $url has sha256 $got_sha ($got_size bytes), the pin says $sha ($size bytes)" >&2
  exit 1
fi
echo "==> Chromium runtime $key is live: $url"
