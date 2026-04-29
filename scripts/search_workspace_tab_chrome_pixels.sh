#!/usr/bin/env bash
set -euo pipefail

TAG="${1:-workspace-tab-search}"
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
if [[ -z "$binary_path" || ! -x "$binary_path" ]]; then
  echo "Failed to locate app binary in $app_path" >&2
  exit 1
fi

python3 - "$binary_path" "$ROOT/vendor/bonsplit" <<'PY'
import json
import math
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

binary_path = sys.argv[1]
package_path = sys.argv[2]
scenario_ids = ",".join([
    "selected-idle",
    "selected-close-hover",
    "dirty-unread",
    "pinned",
    "zoomed",
    "long-title",
])

param_keys = [
    "CMUX_TAB_CHROME_TITLE_DX",
    "CMUX_TAB_CHROME_TITLE_DY",
    "CMUX_TAB_CHROME_TITLE_POINT_SIZE_DELTA",
    "CMUX_TAB_CHROME_TITLE_KERN",
    "CMUX_TAB_CHROME_ICON_DX",
    "CMUX_TAB_CHROME_ICON_DY",
    "CMUX_TAB_CHROME_ICON_POINT_SIZE_DELTA",
    "CMUX_TAB_CHROME_ACCESSORY_DX",
    "CMUX_TAB_CHROME_ACCESSORY_DY",
    "CMUX_TAB_CHROME_ACCESSORY_POINT_SIZE_DELTA",
]

defaults = {
    "CMUX_TAB_CHROME_TITLE_DX": 1.0,
    "CMUX_TAB_CHROME_TITLE_DY": 0.375,
    "CMUX_TAB_CHROME_TITLE_POINT_SIZE_DELTA": 0.0,
    "CMUX_TAB_CHROME_TITLE_KERN": 0.0,
    "CMUX_TAB_CHROME_ICON_DX": -1.0,
    "CMUX_TAB_CHROME_ICON_DY": -0.875,
    "CMUX_TAB_CHROME_ICON_POINT_SIZE_DELTA": -0.5,
    "CMUX_TAB_CHROME_ACCESSORY_DX": 0.0,
    "CMUX_TAB_CHROME_ACCESSORY_DY": -0.359375,
    "CMUX_TAB_CHROME_ACCESSORY_POINT_SIZE_DELTA": 0.09375,
}

cache: dict[tuple[tuple[str, float], ...], tuple[float, dict]] = {}


def normalized(config: dict[str, float]) -> tuple[tuple[str, float], ...]:
    return tuple(sorted((key, round(float(value), 4)) for key, value in config.items()))


def evaluate(config: dict[str, float], full_suite: bool = False) -> tuple[float, dict]:
    key = normalized(config) + (("__full__", 1.0 if full_suite else 0.0),)
    if key in cache:
        return cache[key]

    export_dir = Path(tempfile.mkdtemp(prefix="cmux-tab-chrome-search-"))
    manifest_path = export_dir / "manifest.json"
    comparison_manifest_path = export_dir / "comparison-manifest.json"
    env = os.environ.copy()
    env["CMUX_WORKSPACE_TAB_CHROME_EXPORT_ONLY"] = "1"
    env["CMUX_WORKSPACE_TAB_CHROME_EXPORT_DIR"] = str(export_dir)
    if not full_suite:
        env["CMUX_WORKSPACE_TAB_CHROME_SCENARIO_IDS"] = scenario_ids
    for name, value in config.items():
        env[name] = f"{value:.4f}"

    proc = subprocess.Popen(
        [binary_path],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=env,
    )
    try:
        for _ in range(240):
            if manifest_path.exists():
                break
            if proc.poll() is not None:
                break
            time.sleep(0.25)
        if not manifest_path.exists():
            raise RuntimeError(f"manifest not found for {config}")
        subprocess.run(
            ["swift", "run", "--package-path", package_path, "BonsplitTabChromeDebugCLI", str(export_dir)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if not comparison_manifest_path.exists():
            raise RuntimeError(f"comparison manifest not found for {config}")
        manifest = json.loads(comparison_manifest_path.read_text())
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=3)

    score = 0.0
    differing = 0
    total_pixels = 0
    for result in manifest["scenarioResults"]:
        metrics = result["metrics"]
        score += metrics["meanAbsoluteChannelDelta"] * metrics["totalPixelCount"]
        differing += metrics["differingPixelCount"]
        total_pixels += metrics["totalPixelCount"]

    payload = {
        "score": score,
        "differingPixelCount": differing,
        "totalPixelCount": total_pixels,
        "scenarioResults": manifest["scenarioResults"],
    }
    cache[key] = (score, payload)
    return score, payload


best = defaults.copy()
best_score, best_payload = evaluate(best)
print("baseline", json.dumps({"score": best_score, "differingPixelCount": best_payload["differingPixelCount"]}))

for step in (1.0, 0.5, 0.25):
    improved = True
    while improved:
        improved = False
        for key in param_keys:
            candidate_values = [best[key], best[key] - step, best[key] + step]
            local_best = best
            local_score = best_score
            local_payload = best_payload
            for value in candidate_values:
                candidate = dict(best)
                candidate[key] = value
                score, payload = evaluate(candidate)
                if (score, payload["differingPixelCount"]) < (local_score, local_payload["differingPixelCount"]):
                    local_best = candidate
                    local_score = score
                    local_payload = payload
            if local_best is not best:
                best = local_best
                best_score = local_score
                best_payload = local_payload
                improved = True
                print(
                    "improved",
                    json.dumps(
                        {
                            "step": step,
                            "key": key,
                            "score": best_score,
                            "differingPixelCount": best_payload["differingPixelCount"],
                            "config": best,
                        },
                        sort_keys=True,
                    ),
                )

full_score, full_payload = evaluate(best, full_suite=True)
print("best-config", json.dumps(best, sort_keys=True))
print(
    "focused-score",
    json.dumps(
        {
            "score": best_score,
            "differingPixelCount": best_payload["differingPixelCount"],
            "totalPixelCount": best_payload["totalPixelCount"],
        },
        sort_keys=True,
    ),
)
print(
    "full-score",
    json.dumps(
        {
            "score": full_score,
            "differingPixelCount": full_payload["differingPixelCount"],
            "totalPixelCount": full_payload["totalPixelCount"],
        },
        sort_keys=True,
    ),
)
for result in full_payload["scenarioResults"]:
    metrics = result["metrics"]
    print(
        result["id"],
        json.dumps(
            {
                "diff": metrics["differingPixelCount"],
                "total": metrics["totalPixelCount"],
                "max": metrics["maxChannelDelta"],
                "mean": round(metrics["meanAbsoluteChannelDelta"], 4),
            },
            sort_keys=True,
        ),
    )
PY
