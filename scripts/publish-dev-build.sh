#!/usr/bin/env bash
set -euo pipefail

# Publish one fleet-built cmux dev archive and its Sparkle feed. The worker
# supplies the private key and R2 credentials through a root-owned secret file;
# this script never prints either value.

if [[ $# -ne 3 ]]; then
  echo "usage: publish-dev-build.sh <app-path> <archive-path> <metadata-path>" >&2
  exit 2
fi

APP_PATH="$1"
ARCHIVE_PATH="$2"
METADATA_PATH="$3"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${CMUX_DEV_BUILD_TRACK:?CMUX_DEV_BUILD_TRACK is required}"
: "${CMUX_DEV_BUILD_SHA:?CMUX_DEV_BUILD_SHA is required}"
: "${CMUX_DEV_BUILD_BRANCH:?CMUX_DEV_BUILD_BRANCH is required}"
: "${CMUX_DEV_R2_ENDPOINT:?CMUX_DEV_R2_ENDPOINT is required}"
: "${CMUX_DEV_R2_BUCKET:?CMUX_DEV_R2_BUCKET is required}"
: "${CMUX_DEV_R2_PUBLIC_BASE:?CMUX_DEV_R2_PUBLIC_BASE is required}"
: "${CMUX_DEV_SPARKLE_PRIVATE_KEY:?CMUX_DEV_SPARKLE_PRIVATE_KEY is required}"

case "$CMUX_DEV_BUILD_TRACK" in
  classic|next) ;;
  *) echo "error: unsupported dev build track '$CMUX_DEV_BUILD_TRACK'" >&2; exit 2 ;;
esac
[[ "$CMUX_DEV_BUILD_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "error: invalid dev build SHA" >&2; exit 2; }
[[ -d "$APP_PATH/Contents" && -f "$ARCHIVE_PATH" ]] || { echo "error: dev build inputs are missing" >&2; exit 1; }

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$APP_PATH/Contents/Info.plist"
}

version="$(plist_value CFBundleVersion)"
short_version="$(plist_value CFBundleShortVersionString)"
bundle_id="$(plist_value CFBundleIdentifier)"
[[ "$bundle_id" == "com.cmuxterm.app.dev" ]] || {
  echo "error: dev archive has bundle id '$bundle_id', expected com.cmuxterm.app.dev" >&2
  exit 1
}
[[ "$version" =~ ^[0-9]+$ ]] || { echo "error: dev build version is not numeric" >&2; exit 1; }

archive_name="cmux-${CMUX_DEV_BUILD_TRACK}-${CMUX_DEV_BUILD_SHA:0:12}.zip"
public_root="${CMUX_DEV_R2_PUBLIC_BASE%/}/${CMUX_DEV_BUILD_TRACK}"
immutable_prefix="cmux-dev/${CMUX_DEV_BUILD_TRACK}/builds/${CMUX_DEV_BUILD_SHA}"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-dev-publish.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

named_archive="$work_dir/$archive_name"
cp -p "$ARCHIVE_PATH" "$named_archive"
appcast="$work_dir/appcast.xml"
download_prefix="$public_root/builds/${CMUX_DEV_BUILD_SHA}/"
release_notes="https://github.com/manaflow-ai/cmux/commit/${CMUX_DEV_BUILD_SHA}"
SPARKLE_PRIVATE_KEY="$CMUX_DEV_SPARKLE_PRIVATE_KEY" \
  DOWNLOAD_URL_PREFIX="$download_prefix" \
  RELEASE_NOTES_URL="$release_notes" \
  SPARKLE_MAXIMUM_DELTAS=0 \
  "$ROOT_DIR/scripts/sparkle_generate_appcast.sh" "$named_archive" "$version" "$appcast"

upload() {
  local file="$1" key="$2" type="$3" write_once="${4:-0}"
  local args=(
    --file "$file"
    --endpoint-url "$CMUX_DEV_R2_ENDPOINT"
    --bucket "$CMUX_DEV_R2_BUCKET"
    --key "$key"
    --content-type "$type"
    --cache-control "no-cache, no-store, must-revalidate"
  )
  [[ "$write_once" == 1 ]] && args+=(--write-once)
  AWS_DEFAULT_REGION=auto python3 "$ROOT_DIR/scripts/ci/upload-r2-object.py" "${args[@]}"
}

upload "$named_archive" "$immutable_prefix/$archive_name" application/zip 1
# Keep one non-track-specific recovery alias valid for updater failures where
# the app does not retain its track metadata. The per-track immutable URL
# remains the canonical link shown on the stable page.
upload "$named_archive" "cmux-dev/latest.zip" application/zip 0
upload "$appcast" "cmux-dev/${CMUX_DEV_BUILD_TRACK}/appcast.xml" application/xml 0

metadata="$work_dir/build.json"
title="${CMUX_DEV_BUILD_TITLE:-}"
if [[ -z "$title" ]]; then
  title="$(git -C "$ROOT_DIR" show -s --format=%s "$CMUX_DEV_BUILD_SHA" 2>/dev/null || true)"
fi
CMUX_DEV_BUILD_METADATA_OUT="$metadata" \
  CMUX_DEV_BUILD_ARCHIVE_URL="$download_prefix$archive_name" \
  CMUX_DEV_BUILD_APPCAST_URL="$public_root/appcast.xml" \
  CMUX_DEV_BUILD_VERSION="$version" \
  CMUX_DEV_BUILD_SHORT_VERSION="$short_version" \
  CMUX_DEV_BUILD_ARCHIVE_NAME="$archive_name" \
  CMUX_DEV_BUILD_TITLE="$title" \
  python3 - "$metadata" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

payload = {
    "track": os.environ["CMUX_DEV_BUILD_TRACK"],
    "sha": os.environ["CMUX_DEV_BUILD_SHA"],
    "branch": os.environ["CMUX_DEV_BUILD_BRANCH"],
    "title": os.environ.get("CMUX_DEV_BUILD_TITLE", ""),
    "pr_url": os.environ.get("CMUX_DEV_BUILD_PR_URL", ""),
    "version": os.environ["CMUX_DEV_BUILD_VERSION"],
    "short_version": os.environ["CMUX_DEV_BUILD_SHORT_VERSION"],
    "archive": os.environ["CMUX_DEV_BUILD_ARCHIVE_URL"],
    "archive_name": os.environ["CMUX_DEV_BUILD_ARCHIVE_NAME"],
    "appcast": os.environ["CMUX_DEV_BUILD_APPCAST_URL"],
    "published_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
}
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(payload, stream, indent=2, sort_keys=True)
    stream.write("\n")
PY

# Each track owns its small index. The stable top-level page is static and
# reads both indexes, so classic and next jobs never overwrite one another.
existing="$work_dir/existing.json"
if ! curl --fail --silent --show-error --max-time 15 "$public_root/index.json" -o "$existing"; then
  printf '{"track":%s,"builds":[]}' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$CMUX_DEV_BUILD_TRACK")" > "$existing"
fi
index="$work_dir/index.json"
python3 - "$existing" "$metadata" "$index" <<'PY'
import json, sys
old = json.load(open(sys.argv[1], encoding="utf-8"))
new = json.load(open(sys.argv[2], encoding="utf-8"))
rows = [new] + [row for row in old.get("builds", []) if row.get("sha") != new["sha"]]
json.dump({"track": new["track"], "builds": rows[:20]}, open(sys.argv[3], "w", encoding="utf-8"), indent=2, sort_keys=True)
open(sys.argv[3], "a", encoding="utf-8").write("\n")
PY
upload "$index" "cmux-dev/${CMUX_DEV_BUILD_TRACK}/index.json" application/json 0

page="$work_dir/index.html"
cat > "$page" <<'HTML'
<!doctype html>
<meta charset="utf-8">
<title>cmux dev builds</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{font:15px system-ui,sans-serif;max-width:900px;margin:40px auto;padding:0 20px;color:#17202a}table{border-collapse:collapse;width:100%}th,td{text-align:left;padding:9px;border-bottom:1px solid #ddd}code{font-family:ui-monospace,monospace}</style>
<h1>cmux dev builds</h1>
<p>Fleet builds from green merges. Each track updates itself through Sparkle.</p>
<div id="builds">Loading…</div>
<script>
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
Promise.all(['classic','next'].map(track => fetch(`${track}/index.json`, {cache:'no-store'}).then(r => r.json()).then(x => [track,x]).catch(() => [track,{builds:[]}]))).then(all => {
  document.querySelector('#builds').innerHTML = all.map(([track,data]) => `<h2>${esc(track)}</h2><table><tr><th>Commit</th><th>Title</th><th>Published</th><th>Download</th></tr>${(data.builds||[]).map(b => `<tr><td><code>${esc(b.sha.slice(0,12))}</code></td><td>${esc(b.title)}</td><td>${esc(b.published_at)}</td><td><a href="${esc(b.archive)}">zip</a></td></tr>`).join('')}</table>`).join('');
});
</script>
HTML
upload "$page" cmux-dev/index.html text/html 0

cp -p "$metadata" "$METADATA_PATH"
echo "Published cmux dev ${CMUX_DEV_BUILD_TRACK} ${CMUX_DEV_BUILD_SHA:0:12}: ${CMUX_DEV_BUILD_ARCHIVE_URL}"
