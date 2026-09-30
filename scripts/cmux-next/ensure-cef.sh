#!/usr/bin/env bash
# Downloads, verifies, and caches the pinned CEF artifact for cmux-next
# (scripts/cmux-next/cef-manifest.json), then prints the artifact directory
# on stdout.
#
#   ensure-cef.sh             fail (exit 1) when the artifact is unavailable
#   ensure-cef.sh --optional  warn and print nothing instead (Xcode phase)
#
# Sources, in order; every download is checked against the manifest sha256:
#   1. the local cache
#   2. the private R2 bucket (manifest r2_bucket/r2_key) through the S3 API,
#      when read credentials are set (environment or an env file, below)
#   3. the private GitHub release on manaflow-ai/cef (gh login or a token)
#
# Environment:
#   CMUX_NEXT_SKIP_CEF=1   print nothing, exit 0 (builds without CEF)
#   CMUX_CEF_PATH=<dir>    use a local dist (fork development); no checksum
#   CMUX_CEF_CACHE_DIR     cache root (default ~/Library/Caches/cmux/cef)
#   CMUX_CEF_R2_ACCOUNT_ID, CMUX_CEF_R2_ACCESS_KEY_ID,
#   CMUX_CEF_R2_SECRET_ACCESS_KEY
#                          read-only R2 credentials. When unset, they are read
#                          from CMUX_CEF_R2_ENV_FILE (default
#                          ~/.secrets/cmux-cef.env) if that file exists.
#   CMUX_CEF_R2_ENDPOINT   S3 endpoint override (default
#                          https://<account>.r2.cloudflarestorage.com)
#   CMUX_CEF_NO_R2=1       skip R2 (test the GitHub fallback)
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

field() { /usr/bin/plutil -extract "$1" raw -o - "$MANIFEST" 2>/dev/null || true; }
version="$(field version)"; tag="$(field tag)"; repo="$(field repo)"
asset="$(field asset)"; url="$(field url)"; sha="$(field sha256)"
r2_bucket="$(field r2_bucket)"; r2_key="$(field r2_key)"
[[ -n "$version" && -n "$asset" && -n "$sha" ]] || fail "manifest $MANIFEST lacks version, asset or sha256"

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

# Reads the three read-only R2 names from an env file without sourcing it,
# so the file can hold other lines and nothing in it executes.
load_r2_env_file() {
  local file="${CMUX_CEF_R2_ENV_FILE:-$HOME/.secrets/cmux-cef.env}" line name value
  [[ -r "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#export }"
    name="${line%%=*}"; value="${line#*=}"
    case "$name" in
      CMUX_CEF_R2_ACCOUNT_ID|CMUX_CEF_R2_ACCESS_KEY_ID|CMUX_CEF_R2_SECRET_ACCESS_KEY) ;;
      *) continue ;;
    esac
    [[ -n "${!name:-}" ]] && continue
    value="${value%\"}"; value="${value#\"}"; value="${value%\'}"; value="${value#\'}"
    printf -v "$name" '%s' "$value"
  done < "$file"
}

verified() { # <file>; the manifest sha256 decides every source
  local actual
  actual="$(shasum -a 256 "$1" | awk '{print $1}')"
  [[ "$actual" == "$sha" ]] && return 0
  echo "warning: checksum mismatch for $asset from $2: expected $sha, got $actual" >&2
  rm -f "$1"
  return 1
}

fetch_r2() {
  [[ "${CMUX_CEF_NO_R2:-0}" == "1" ]] && return 1
  [[ -n "$r2_bucket" && -n "$r2_key" ]] || return 1
  load_r2_env_file
  local account="${CMUX_CEF_R2_ACCOUNT_ID:-}" id="${CMUX_CEF_R2_ACCESS_KEY_ID:-}"
  local secret="${CMUX_CEF_R2_SECRET_ACCESS_KEY:-}"
  [[ -n "$id" && -n "$secret" ]] || return 1
  local endpoint="${CMUX_CEF_R2_ENDPOINT:-}"
  if [[ -z "$endpoint" ]]; then
    [[ -n "$account" ]] || { echo "warning: CMUX_CEF_R2_ACCOUNT_ID is not set; skipping R2" >&2; return 1; }
    endpoint="https://$account.r2.cloudflarestorage.com"
  fi
  echo "==> downloading $asset ($version) from R2 $r2_bucket" >&2
  # The credential goes through a config on stdin, never on the command line.
  if printf 'user = "%s:%s"\n' "$id" "$secret" |
    curl --config - --fail --silent --show-error --location --retry 5 --retry-delay 2 \
      --connect-timeout 15 --max-time 1800 --aws-sigv4 "aws:amz:auto:s3" \
      -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" \
      -o "$archive" "${endpoint%/}/$r2_bucket/$r2_key" >&2; then
    verified "$archive" R2 && return 0
  else
    echo "warning: R2 download failed; trying the GitHub release" >&2
    rm -f "$archive"
  fi
  return 1
}

fetch_github() {
  echo "==> downloading $asset ($version) from GitHub $repo" >&2
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh release download "$tag" --repo "$repo" --pattern "$asset" --dir "$tmp" --clobber >&2 &&
      verified "$archive" "GitHub release" && return 0
  fi
  local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}" asset_api
  if [[ -n "$token" ]]; then
    asset_api="$(curl -fsSL -H "Authorization: Bearer $token" "https://api.github.com/repos/$repo/releases/tags/$tag" |
      /usr/bin/python3 -c 'import json,sys; a=sys.argv[1]; print(next(x["url"] for x in json.load(sys.stdin)["assets"] if x["name"]==a))' "$asset" || true)"
    if [[ -n "$asset_api" ]]; then
      curl -fL --retry 5 -H "Authorization: Bearer $token" -H "Accept: application/octet-stream" \
        -o "$archive" "$asset_api" >&2 && verified "$archive" "GitHub API" && return 0
    fi
  fi
  curl -fL --retry 5 -o "$archive" "$url" >&2 2>/dev/null && verified "$archive" "$url" && return 0
  return 1
}

fetch_r2 || fetch_github ||
  fail "could not download a verified $asset (set CMUX_CEF_R2_* or ~/.secrets/cmux-cef.env, or log in with gh / set GH_TOKEN)"

mkdir -p "$tmp/x"
tar -xJf "$archive" -C "$tmp/x"
[[ -d "$tmp/x/$version/$FRAMEWORK" ]] || fail "archive $asset has no $version/$FRAMEWORK"
printf '%s' "$sha" > "$tmp/x/$version/.verified"
rm -rf "$dest"
mv "$tmp/x/$version" "$dest"
echo "==> CEF $version ready at $dest" >&2
echo "$dest"
