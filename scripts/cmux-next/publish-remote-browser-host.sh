#!/usr/bin/env bash
# Publishes a fleet-built cmux-remote-browser-host binary for DEV app builds
# and writes its pin (scripts/cmux-next/remote-browser-host.pin.json), which
# ensure-remote-browser-host.sh and embed-remote-browser-host.sh read.
#
#   publish-remote-browser-host.sh --step STEP_ID --commit SHA [--dry-run]
#
# STEP_ID is a passed fleet step of scripts/ci/cmux-remote-browser-host-build.sh
# at commit SHA, run with --cef sha256:<cef-manifest.json sha256>, so the host
# links the app's own CEF build:
#   cmux-ci run --class isolated --script scripts/ci/cmux-remote-browser-host-build.sh \
#     --ref SHA --cef sha256:<manifest sha256> \
#     --artifact .build/artifacts/cmux-remote-browser-host --arg=--build-only
# The binary goes write-once (If-None-Match: *) to the private R2 bucket at
# remote-browser-host/<sha256>/cmux-remote-browser-host-macos-arm64, is read
# back and checked, and one line is appended to
# $CMUX_RB_HOST_PUBLISH_LOG (default <hq>/artifacts/rb-host-r2-publish.log
# when this checkout sits in a cmuxterm-hq tree). --dry-run writes the pin
# and uploads nothing.
#
# Credentials (environment first, then CMUX_CEF_R2_ENV_FILE, default
# ~/.secrets/cmux-cef.env; read here only, values never printed):
#   CMUX_CEF_R2_ACCOUNT_ID, CMUX_CEF_R2_WRITE_ACCESS_KEY_ID,
#   CMUX_CEF_R2_WRITE_SECRET_ACCESS_KEY (+ optional read-only pair for the read-back)
set -euo pipefail

step=""; commit=""; dry=0
while (( $# )); do
  case "$1" in
    --step) step="${2:?}"; shift 2 ;;
    --commit) commit="${2:?}"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    *) echo "usage: publish-remote-browser-host.sh --step STEP_ID --commit SHA [--dry-run]" >&2; exit 2 ;;
  esac
done
[[ -n "$step" && "$commit" =~ ^[0-9a-f]{40}$ ]] ||
  { echo "usage: publish-remote-browser-host.sh --step STEP_ID --commit SHA [--dry-run]" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
pin="$SCRIPT_DIR/remote-browser-host.pin.json"
manifest="$SCRIPT_DIR/cef-manifest.json"
asset=cmux-remote-browser-host-macos-arm64
bucket="${CMUX_CEF_R2_BUCKET:-cmux-cef}"
cmux_ci="${CMUX_CI:-$HOME/.local/bin/cmux-ci}"

crate_tree="$(git -C "$repo_root" rev-parse "$commit:cmux-tui/crates/cmux-remote-browser-host")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
"$cmux_ci" artifact "$step" "$work/$asset" >&2
[[ -f "$work/$asset" ]] || { echo "error: step $step returned no artifact" >&2; exit 1; }
/usr/bin/file -b "$work/$asset" | grep -q 'Mach-O' || { echo "error: the artifact is not a Mach-O" >&2; exit 1; }
lipo -archs "$work/$asset" | tr ' ' '\n' | grep -qx arm64 || { echo "error: the artifact has no arm64 slice" >&2; exit 1; }
sha="$(shasum -a 256 "$work/$asset" | awk '{print $1}')"
key="remote-browser-host/$sha/$asset"

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
    -H "x-amz-meta-sha256: $sha" -T "$work/$asset" "$url")" || status=000
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
  log="${CMUX_RB_HOST_PUBLISH_LOG:-}"
  if [[ -z "$log" ]]; then
    hq="$(cd "$repo_root/../.." 2>/dev/null && pwd)"
    [[ -d "$hq/artifacts" ]] && log="$hq/artifacts/rb-host-r2-publish.log"
  fi
  if [[ -n "$log" ]]; then
    printf '%s %s bucket=%s key=%s sha256=%s readback=ok commit=%s step=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$result" "$bucket" "$key" "$sha" "$commit" "$step" >> "$log"
  fi
fi

/usr/bin/python3 - "$pin" "$manifest" "$asset" "$sha" "$bucket" "$key" "$commit" "$crate_tree" "$step" <<'PY'
import json, sys
pin, manifest, asset, sha, bucket, key, commit, tree, step = sys.argv[1:]
cef = json.load(open(manifest, encoding="utf-8"))
data = {
    "asset": asset,
    "arch": "arm64",
    "sha256": sha,
    "r2_bucket": bucket,
    "r2_key": key,
    "source_commit": commit,
    "crate_tree": tree,
    "cef_version": cef["version"],
    "cef_sha256": cef["sha256"],
    "build_step": step,
}
with open(pin, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
echo "==> wrote $pin (sha256 $sha)" >&2
