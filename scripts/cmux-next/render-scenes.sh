#!/usr/bin/env bash
set -euo pipefail

# Render app-owned PNGs from named DEBUG scenes. The tagged app owns fixture
# setup and snapshots; this script only calls its automation socket and records
# the returned artifact metadata.
usage() {
  cat >&2 <<'USAGE'
Usage: render-scenes.sh <tag> [scene ...]

The tagged DEBUG app must have a fleet-built artifact. Without scene arguments,
all registered scenes are rendered. Set CMUX_SCENE_OUT to choose the output
folder (default: captures/cmux-next-scenes/<tag>).
USAGE
}

[[ $# -ge 1 ]] || { usage; exit 2; }
TAG=$1
shift
[[ $TAG =~ ^[A-Za-z0-9._-]+$ ]] || { echo "error: unsafe tag: $TAG" >&2; exit 2; }
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
OUT=${CMUX_SCENE_OUT:-$ROOT/captures/cmux-next-scenes/$TAG}
mkdir -p "$OUT"

cli() { CMUX_TAG="$TAG" "$ROOT/scripts/cmux-debug-cli.sh" "$@"; }
json_quote() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

# The helper scopes the app socket, bundle id and CLI to this tag. It launches
# one exact tagged product and avoids activating the user's current app.
"$ROOT/scripts/launch-tagged-automation.sh" "$TAG" --env CMUX_NEXT_SHOWCASE=1 --env CMUX_TAG="$TAG" --wait-socket 20 >/dev/null

cleanup() {
  set +e
  cli rpc debug.quit '{"open":true}' >/dev/null 2>&1
  cli rpc debug.quit '{"press":"end-everything"}' >/dev/null 2>&1
  local app="$HOME/Library/Developer/Xcode/DerivedData/cmux-$(printf '%s' "$TAG" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')/Build/Products/Debug/cmux DEV $TAG.app/Contents/MacOS/cmux DEV"
  local pid
  pid=$(pgrep -n -f -- "$app" 2>/dev/null || true)
  if [[ -n "$pid" ]]; then
    for _ in {1..40}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
    kill "$pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

registered=$(cli rpc debug.scene.list '{}')
# The local backend's supported empty-workspace route is the same route used
# by the product CLI. Seed named rows before each app-owned scene render so
# the rail is populated even when no saved workspace snapshot exists.
for workspace in cmux-next docs-site infra; do
  cli --json workspace create --name "$workspace" --empty >/dev/null
done
scenes=()
while IFS= read -r scene; do
  scenes+=("$scene")
done < <(python3 - "$registered" "$@" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
if isinstance(payload, dict) and payload.get("error"):
    raise SystemExit(payload["error"])
value = payload.get("result", payload) if isinstance(payload, dict) else payload
known = [item["name"] for item in value.get("scenes", [])] if isinstance(value, dict) else []
if isinstance(value, list):
    known = [item["name"] for item in value]
requested = sys.argv[2:]
if not known:
    known = ["main-showcase", "composer", "sidebar-tiles", "settings", "history-narrow", "hints-cmd-held", "hints-ctrl-held"]
for scene in requested or known:
    if scene not in known:
        raise SystemExit(f"unknown scene: {scene}")
    print(scene)
PY
)

manifest="$OUT/manifest.jsonl"
: > "$manifest"
for scene in "${scenes[@]}"; do
  path="$OUT/$scene.png"
  result=$(cli rpc debug.scene.render "$(printf '{"scene":%s,"path":%s}' "$(json_quote "$scene")" "$(json_quote "$path")")")
  printf '%s\n' "$result" >> "$manifest"
  actual=$(python3 - "$result" <<'PY'
import json, sys
payload=json.loads(sys.argv[1])
value=payload.get("result", payload)
if value.get("error"): raise SystemExit(value["error"])
print(value.get("path", ""))
PY
)
  [[ "$actual" == "$path" && -s "$path" ]] || { echo "error: scene $scene did not produce $path" >&2; exit 1; }
  echo "rendered $scene $path"
done
python3 - "$manifest" "$OUT/manifest.json" "$TAG" <<'PY'
import json, pathlib, sys
lines=pathlib.Path(sys.argv[1]).read_text().splitlines()
items=[]
for line in lines:
    payload=json.loads(line); value=payload.get("result", payload)
    items.append(value)
out={"schema_version":1,"tag":sys.argv[3],"scenes":items}
pathlib.Path(sys.argv[2]).write_text(json.dumps(out,indent=2)+"\n")
PY
echo "render-scenes: wrote $OUT"
