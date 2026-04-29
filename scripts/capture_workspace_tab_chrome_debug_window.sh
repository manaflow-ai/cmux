#!/usr/bin/env bash
set -euo pipefail

TAG="${1:-workspace-tab-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

build_log="$(mktemp)"
./scripts/reload.sh --tag "$TAG" | tee "$build_log"
app_path="$(awk '/^App path:/{getline; sub(/^  /, ""); print; exit}' "$build_log")"
rm -f "$build_log"

if [[ -z "$app_path" || ! -d "$app_path" ]]; then
  echo "Failed to locate app path for tag $TAG" >&2
  exit 1
fi

binary_path="$(find "$app_path/Contents/MacOS" -maxdepth 1 -type f -perm -111 ! -name "*.dylib" | head -n 1)"
output_dir="${TMPDIR:-/tmp}/cmux-workspace-tab-chrome-captures/$TAG"
outfile="$output_dir/window.png"
mkdir -p "$output_dir"
rm -f "$outfile"

if [[ -z "$binary_path" || ! -x "$binary_path" ]]; then
  echo "Failed to locate executable binary inside $app_path" >&2
  exit 1
fi

pkill -f "$binary_path" >/dev/null 2>&1 || true
app_pid=""
trap 'if [[ -n "$app_pid" ]]; then kill "$app_pid" >/dev/null 2>&1 || true; fi' EXIT
CMUX_WORKSPACE_TAB_CHROME_DEBUG_SNAPSHOT_FILE="$outfile" \
CMUX_WORKSPACE_TAB_CHROME_SNAPSHOT_ONLY=1 \
"$binary_path" >/tmp/cmux-workspace-tab-chrome-capture-$TAG.log 2>&1 &
app_pid=$!

if [[ -z "$app_pid" ]]; then
  echo "Failed to find launched app pid for $binary_path" >&2
  exit 1
fi

for _ in $(seq 1 80); do
  if [[ -f "$outfile" ]]; then
    break
  fi
  if ! kill -0 "$app_pid" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

if [[ ! -f "$outfile" ]]; then
  echo "Failed to render Workspace Tab Chrome Debug snapshot for pid $app_pid" >&2
  exit 1
fi

echo "$outfile"
