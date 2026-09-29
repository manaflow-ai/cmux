#!/usr/bin/env bash
# Downloads, verifies, and caches the pinned CEF artifact for cmux-next
# (scripts/cmux-next/cef-manifest.json, a release on the private
# manaflow-ai/cef repo), then prints the artifact directory on stdout.
#
#   ensure-cef.sh             fail (exit 1) when the artifact is unavailable
#   ensure-cef.sh --optional  warn and print nothing instead (Xcode phase)
#
# Environment:
#   CMUX_NEXT_SKIP_CEF=1   print nothing, exit 0 (builds without CEF)
#   CMUX_CEF_PATH=<dir>    use a local dist (fork development); no checksum
#   CMUX_CEF_CACHE_DIR     cache root (default ~/Library/Caches/cmux/cef)
#   GH_TOKEN/GITHUB_TOKEN  used when `gh` is not logged in (private repo)
#
# Cache layout: <root>/<version>/ holds the extracted artifact and a
# .verified file with the archive sha256. A damaged entry is re-downloaded.
set -euo pipefail

optional=0
[[ "${1:-}" == "--optional" ]] && optional=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${CMUX_CEF_MANIFEST:-$SCRIPT_DIR/cef-manifest.json}"
FRAMEWORK="Chromium Embedded Framework.framework"

fail() {
  if (( optional )); then
    echo "warning: CEF unavailable: $*; building without the Chromium engine" >&2
    exit 0
  fi
  echo "error: $*" >&2
  exit 1
}

if [[ "${CMUX_NEXT_SKIP_CEF:-0}" == "1" ]]; then
  echo "note: CMUX_NEXT_SKIP_CEF=1, skipping CEF" >&2
  exit 0
fi

if [[ -n "${CMUX_CEF_PATH:-}" ]]; then
  [[ -d "$CMUX_CEF_PATH/$FRAMEWORK" && -d "$CMUX_CEF_PATH/include" ]] ||
    fail "CMUX_CEF_PATH=$CMUX_CEF_PATH has no framework or include/"
  echo "warning: using local CEF at $CMUX_CEF_PATH (checksum not verified)" >&2
  echo "$CMUX_CEF_PATH"
  exit 0
fi

field() { /usr/bin/plutil -extract "$1" raw -o - "$MANIFEST"; }
version="$(field version)"; tag="$(field tag)"; repo="$(field repo)"
asset="$(field asset)"; url="$(field url)"; sha="$(field sha256)"

root="${CMUX_CEF_CACHE_DIR:-$HOME/Library/Caches/cmux/cef}"
dest="$root/$version"
if [[ -f "$dest/.verified" && "$(cat "$dest/.verified")" == "$sha" && -d "$dest/$FRAMEWORK" ]]; then
  echo "$dest"
  exit 0
fi

mkdir -p "$root"
lock="$root/.$version.lock"
waited=0
while ! mkdir "$lock" 2>/dev/null; do
  if (( waited > 900 )); then rm -rf "$lock"; continue; fi
  sleep 1; waited=$((waited + 1))
  if [[ -f "$dest/.verified" && "$(cat "$dest/.verified")" == "$sha" ]]; then echo "$dest"; exit 0; fi
done
tmp="$(mktemp -d "$root/.incoming.XXXXXX")"
trap 'rm -rf "$tmp" "$lock"' EXIT

archive="$tmp/$asset"
echo "==> downloading $asset ($version)" >&2
downloaded=0
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  gh release download "$tag" --repo "$repo" --pattern "$asset" --dir "$tmp" >&2 && downloaded=1
fi
token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if (( ! downloaded )) && [[ -n "$token" ]]; then
  asset_api="$(curl -fsSL -H "Authorization: Bearer $token" "https://api.github.com/repos/$repo/releases/tags/$tag" |
    /usr/bin/python3 -c 'import json,sys; a=sys.argv[1]; print(next(x["url"] for x in json.load(sys.stdin)["assets"] if x["name"]==a))' "$asset" || true)"
  if [[ -n "$asset_api" ]]; then
    curl -fL --retry 5 -H "Authorization: Bearer $token" -H "Accept: application/octet-stream" \
      -o "$archive" "$asset_api" >&2 && downloaded=1
  fi
fi
if (( ! downloaded )); then
  curl -fL --retry 5 -o "$archive" "$url" >&2 && downloaded=1 || true
fi
(( downloaded )) || fail "could not download $url (private repo: log in with gh or set GH_TOKEN)"

actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
[[ "$actual" == "$sha" ]] || fail "checksum mismatch for $asset: expected $sha, got $actual"

mkdir -p "$tmp/x"
tar -xJf "$archive" -C "$tmp/x"
[[ -d "$tmp/x/$version/$FRAMEWORK" ]] || fail "archive $asset has no $version/$FRAMEWORK"
printf '%s' "$sha" > "$tmp/x/$version/.verified"
rm -rf "$dest"
mv "$tmp/x/$version" "$dest"
echo "==> CEF $version ready at $dest" >&2
echo "$dest"
