#!/usr/bin/env bash
# Publishes the language packs scripts/cmux-next/language-packs.py split wrote (CMUX-570,
# languages download on first use). Run in the publish job BEFORE the appcast that points at
# the app goes up: the app's pin (Contents/Resources/language-packs.json) must never name an
# object that is not published.
#
# Usage: publish-language-packs.sh <out-dir>
#
# For each pack in <out-dir>/language-packs.json, uploads <out-dir>/<lang>.tar.zst write-once
# (an identical object is accepted, different bytes fail) to language-packs/<sha256>/<lang>.tar.zst,
# immutable, then downloads it again from the pin's public URL and checks its sha256 and size.
# Content addressed: an unchanged language re-uses the object an earlier nightly published.
# files-next.cmux.com serves the bucket's root, as for cef-runtime/ (publish-cef-runtime.sh).
#
# Env: R2_ENDPOINT, NIGHTLY_NEXT_R2_BUCKET (or CMUX_LANGUAGE_PACKS_BUCKET), and
# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY for scripts/ci/upload-r2-object.py.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${1:?usage: publish-language-packs.sh <out-dir>}"
pin="$out/language-packs.json"
[[ -f "$pin" ]] || { echo "publish-language-packs: no $pin" >&2; exit 1; }
public="https://files-next.cmux.com/language-packs"
bucket="${CMUX_LANGUAGE_PACKS_BUCKET:-${NIGHTLY_NEXT_R2_BUCKET:?set NIGHTLY_NEXT_R2_BUCKET}}"

# lang sha256 size url, one pack per line; the pin's shape is checked here, once.
packs="$(python3 -I -c '
import json, re, sys
pin = json.load(open(sys.argv[1]))
assert pin.get("version") == 1, "pin version is not 1"
for lang, p in sorted(pin["packs"].items()):
    assert re.fullmatch(r"[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})*", lang), lang
    assert re.fullmatch(r"[0-9a-f]{64}", p["sha256"]), p["sha256"]
    assert p["url"] == sys.argv[2] + "/" + p["sha256"] + "/" + lang + ".tar.zst", p["url"]
    print(lang, p["sha256"], int(p["size"]), p["url"])
' "$pin" "$public")" || { echo "publish-language-packs: $pin is not a pin for $public" >&2; exit 1; }
[[ -n "$packs" ]] || { echo "publish-language-packs: $pin names no packs"; exit 0; }

sha256_of() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }

while read -r lang sha size url; do
  asset="$out/$lang.tar.zst"
  [[ -f "$asset" ]] || { echo "publish-language-packs: no $asset" >&2; exit 1; }
  [[ "$(sha256_of "$asset")" == "$sha" && "$(wc -c < "$asset" | tr -d ' ')" == "$size" ]] \
    || { echo "publish-language-packs: $asset does not match its pin" >&2; exit 1; }
  python3 "$SCRIPT_DIR/../ci/upload-r2-object.py" --file "$asset" --endpoint-url "${R2_ENDPOINT:?}" \
    --bucket "$bucket" --key "language-packs/$sha/$lang.tar.zst" --content-type application/zstd \
    --cache-control "public, max-age=31536000, immutable" --write-once
done <<< "$packs"

check="$(mktemp "${TMPDIR:-/tmp}/language-pack-check.XXXXXX")"
trap 'rm -f "$check"' EXIT
while read -r lang sha size url; do
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 -o "$check" "$url"
  got_sha="$(sha256_of "$check")"
  got_size="$(wc -c < "$check" | tr -d ' ')"
  if [[ "$got_sha" != "$sha" || "$got_size" != "$size" ]]; then
    echo "publish-language-packs: $url has sha256 $got_sha ($got_size bytes), the pin says $sha ($size bytes)" >&2
    exit 1
  fi
  echo "==> language pack $lang is live: $url"
done <<< "$packs"
