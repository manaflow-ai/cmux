#!/usr/bin/env bash
set -euo pipefail

TAG="${1:-workspace-tab-verify}"
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

app_name="$(basename "$app_path" .app)"
binary_path="$(find "$app_path/Contents/MacOS" -maxdepth 1 -type f -perm -111 ! -name "*.dylib" | head -n 1)"
export_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-workspace-tab-chrome-verify-$TAG.XXXXXX")"
manifest_path="$export_dir/manifest.json"
comparison_manifest_path="$export_dir/comparison-manifest.json"

pkill -f "$binary_path" >/dev/null 2>&1 || true
CMUX_WORKSPACE_TAB_CHROME_EXPORT_DIR="$export_dir" \
CMUX_WORKSPACE_TAB_CHROME_EXPORT_ONLY=1 \
"$binary_path" >/tmp/cmux-workspace-tab-chrome-verify-$TAG.log 2>&1 &
app_pid=$!

for _ in $(seq 1 120); do
  if [[ -f "$manifest_path" ]]; then
    break
  fi
  if ! kill -0 "$app_pid" >/dev/null 2>&1 && [[ ! -f "$manifest_path" ]]; then
    break
  fi
  sleep 0.25
done

if [[ ! -f "$manifest_path" ]]; then
  echo "Export manifest not found: $manifest_path" >&2
  exit 1
fi

swift run --package-path "$ROOT/vendor/bonsplit" BonsplitTabChromeDebugCLI "$export_dir" >/tmp/cmux-workspace-tab-chrome-reference-$TAG.log 2>&1

if [[ ! -f "$comparison_manifest_path" ]]; then
  echo "Comparison manifest not found: $comparison_manifest_path" >&2
  exit 1
fi

python3 - "$comparison_manifest_path" <<'PY'
import json
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
manifest = json.loads(manifest_path.read_text())
results = manifest.get("scenarioResults", [])
failures = []
for result in results:
    metrics = result["metrics"]
    if not metrics.get("matchingPixels", False):
        failures.append(
            f"{result['id']}: diff={metrics['differingPixelCount']}/{metrics['totalPixelCount']} max={metrics['maxChannelDelta']} mean={metrics['meanAbsoluteChannelDelta']:.2f}"
        )

print(f"manifest={manifest_path}")
print(f"scenarios={len(results)}")
if failures:
    print("status=FAIL")
    for failure in failures:
        print(failure)
    sys.exit(1)
print("status=PASS")
PY
