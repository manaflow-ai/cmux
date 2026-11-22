#!/usr/bin/env bash
# Downloads, verifies, and caches the pinned CEF artifact for cmux-next
# (scripts/cmux-next/cef-manifest.json), then prints the artifact directory
# on stdout.
#
#   ensure-cef.sh             fail (exit 1) when the artifact is unavailable
#   ensure-cef.sh --optional  warn and print nothing instead (Xcode phase)
#   --arch arm64|x86_64       which artifact (default arm64). The arm64 one
#                             is the manifest's top-level fields; x86_64 is
#                             its "x86_64" object (asset, sha256, r2_key,
#                             url), cached at <root>/<version>-x86_64. A
#                             manifest without that object has no x86_64
#                             artifact (fails, or prints nothing with
#                             --optional).
#
# Sources, in order; every download is checked against the manifest sha256:
#   1. the local cache
#   2. the fleet controller's artifact store: the controller signs a short-lived
#      GET of sha256:<manifest sha256> for a caller on its tailnet (no token or
#      credential on this host); unreachable off the tailnet, then skipped
#   3. the private R2 bucket (manifest r2_bucket/r2_key) through the S3 API,
#      when read credentials are set (environment or an env file, below)
#   4. the private GitHub release on manaflow-ai/cef (gh login or a token)
#
# Environment:
#   CMUX_NEXT_SKIP_CEF=1   print nothing, exit 0 (builds without CEF)
#   CMUX_CEF_PATH=<dir>    use a local dist (fork development); no checksum
#   CMUX_CEF_CACHE_DIR     cache root (default: cef-cache-root.sh, the fleet host
#                          cache on a fleet Mac, else ~/Library/Caches/cmux/cef)
#   CMUX_CEF_R2_ACCOUNT_ID, CMUX_CEF_R2_ACCESS_KEY_ID,
#   CMUX_CEF_R2_SECRET_ACCESS_KEY
#                          read-only R2 credentials. When unset, they are read
#                          from CMUX_CEF_R2_ENV_FILE (default
#                          ~/.secrets/cmux-cef.env) if that file exists.
#   CMUX_CEF_R2_ENDPOINT   S3 endpoint override (default
#                          https://<account>.r2.cloudflarestorage.com)
#   CMUX_CEF_STORE_URL     fleet controller (default http://100.89.225.106:18765,
#                          its tailnet address; MagicDNS does not resolve on
#                          every fleet host)
#   CMUX_CEF_NO_STORE=1    skip the controller artifact store
#   CMUX_CEF_NO_R2=1       skip R2 (test the GitHub fallback)
#   GH_TOKEN/GITHUB_TOKEN  used when `gh` is not logged in (private repo)
#
# Cache layout: <root>/<version>/ holds the extracted artifact and a
# .verified file with the archive sha256. A damaged entry is re-downloaded.
set -euo pipefail

optional=0
arch=arm64
while (($#)); do
  case "$1" in
    --optional) optional=1; shift ;;
    --arch) arch="${2:?--arch needs arm64 or x86_64}"; shift 2 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$arch" in arm64|x86_64) ;; *) echo "error: --arch must be arm64 or x86_64" >&2; exit 2 ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${CMUX_CEF_MANIFEST:-$SCRIPT_DIR/cef-manifest.json}"
FRAMEWORK="Chromium Embedded Framework.framework"

fail() {
  if (( optional )); then
    echo "warning: CEF unavailable: $*; building without the Chromium engine" >&2
    exit 0
  fi
  echo "error: $*; see cmuxterm-hq REPAIR.md (ensure-cef store parser)" >&2
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

field() {
  local key="$1" value
  if [[ -x /usr/bin/plutil ]] && value=$(/usr/bin/plutil -extract "$key" raw -o - "$MANIFEST" 2>/dev/null); then
    printf "%s\n" "$value"
    return 0
  fi
  # CI also exercises this script on Linux, where macOS plutil is absent.
  # Keep the manifest reader JSON-only and portable without changing the
  # signed artifact or checksum path.
  python3 - "$key" "$MANIFEST" <<'PYJSON'
import json
import sys
try:
    value = json.load(open(sys.argv[2], encoding="utf-8"))
    for part in sys.argv[1].split("."):
        value = value[part]
    if value is not None:
        print(value)
except (FileNotFoundError, KeyError, TypeError, ValueError, json.JSONDecodeError):
    pass
PYJSON
}
version="$(field version)"; tag="$(field tag)"; repo="$(field repo)"
r2_bucket="$(field r2_bucket)"
if [[ "$arch" == "arm64" ]]; then
  prefix=""; suffix=""
else
  prefix="$arch."; suffix="-$arch"
  [[ -n "$(field "${prefix}asset")" ]] || fail "manifest $MANIFEST has no $arch artifact"
fi
asset="$(field "${prefix}asset")"; url="$(field "${prefix}url")"; sha="$(field "${prefix}sha256")"
r2_key="$(field "${prefix}r2_key")"
[[ -n "$version" && -n "$asset" && -n "$sha" ]] || fail "manifest $MANIFEST lacks version, asset or sha256 for $arch"

root="$("$SCRIPT_DIR/cef-cache-root.sh")"
dest="$root/$version$suffix"
# The framework's GN args (archive.json gn_args): DCHECKs must be off, or a
# DCHECK that web content reaches aborts cmux (crash-elimination.md). A warning
# until the manifest sets "require_dcheck_off": true (the cmux.17 pin).
check_build_flags() { # <cef folder>
  local require=()
  case "$(field require_dcheck_off)" in true|True|1) require=(--require) ;; esac
  python3 "$SCRIPT_DIR/cef_build_flags.py" "$1" ${require[@]+"${require[@]}"} >&2 ||
    fail "CEF $version was built with DCHECKs on; pin a framework built with dcheck_always_on=false"
}
if [[ -f "$dest/.verified" && "$(cat "$dest/.verified")" == "$sha" && -d "$dest/$FRAMEWORK" ]]; then
  check_build_flags "$dest"
  echo "$dest"
  exit 0
fi

mkdir -p "$root"
lock="$root/.$version$suffix.lock"
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

# The archive is content addressed in the store, and verified() checks the bytes
# against the manifest, so trust stays with the manifest, as for every source.
fetch_store() {
  [[ "${CMUX_CEF_NO_STORE:-0}" == "1" ]] && return 1
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  # The signed URL is a read capability: never trace it (a debugging `bash -x` run
  # would print it into a job log). Tracing resumes after the download.
  local traced=0 status=1
  if [[ $- == *x* ]]; then traced=1; set +x; fi
  store_download && status=0
  if (( traced )); then set -x; fi
  return "$status"
}

# Untraced (fetch_store): ask the controller for a signed GET of the digest and download it.
store_download() {
  local controller="${CMUX_CEF_STORE_URL:-http://100.89.225.106:18765}" signed
  # The artifact edge refuses some default user agents; send ours.
  signed="$(curl --fail --silent --show-error --connect-timeout 5 --max-time 30 \
      -A cmux-ensure-cef "${controller%/}/v1/artifacts/sha256:$sha/url" 2>/dev/null |
    /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("url", ""))' 2>/dev/null || true)"
  [[ "$signed" == https://* || "$signed" == http://* ]] || return 1
  echo "==> downloading $asset ($version) from the controller artifact store" >&2
  if curl --fail --silent --show-error --location --retry 3 --retry-delay 2 --connect-timeout 15 \
      --max-time 1800 -A cmux-ensure-cef -o "$archive" "$signed" 2>&1 | sed -E 's/\?X-Amz-[^ ]*//g' >&2; then
    verified "$archive" "the controller artifact store" && return 0
  else
    echo "warning: artifact store download failed; trying R2" >&2
    rm -f "$archive"
  fi
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

fetch_store || fetch_r2 || fetch_github ||
  fail "could not download a verified $asset (set CMUX_CEF_R2_* or ~/.secrets/cmux-cef.env, or log in with gh / set GH_TOKEN)"

mkdir -p "$tmp/x"
tar -xJf "$archive" -C "$tmp/x"
[[ -d "$tmp/x/$version/$FRAMEWORK" ]] || fail "archive $asset has no $version/$FRAMEWORK"
check_build_flags "$tmp/x/$version"
printf '%s' "$sha" > "$tmp/x/$version/.verified"
rm -rf "$dest"
mv "$tmp/x/$version" "$dest"
echo "==> CEF $version ready at $dest" >&2
echo "$dest"
