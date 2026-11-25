#!/usr/bin/env bash
# The resident UI preview worker (scripts/cmux-next/ui-preview-worker.py) on a display Mac, timed: warm it the way
# the resident daemon stays warm (clone, the UI shell's .build, node_modules, the gallery dev server), then take one
# ui-preview-request/v1 a pushed probe branch at a time, stamped pushed_at at the moment it is handed over, and
# record each receipt's push_to_post_s and stage timings. The worker's own code, end to end; the receipts and the
# message the recipient would get go into the artifact.
#
#   scripts/measure/ui-preview-worker-push.sh KIND:BRANCH:BASE:HEAD:FILE[,FILE] ...
#   cmux-ci run --class light --script scripts/measure/ui-preview-worker-push.sh --ref SHA --display \
#     --arg swift:lane/x:BASE:HEAD:Packages/macOS/CmuxNext/Sources/CmuxNextTabs/Playground/TabBarPlaygroundView.swift \
#     --artifact Prototypes/UiLayerHost/.build/ui-preview-push.tar
#
# Each HEAD must be BRANCH's tip on manaflow-ai/cmux (the worker refuses anything else).
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="$repo/Prototypes/UiLayerHost/.build/ui-preview-push"

if [ -n "${CMUX_CI_STEP_KEY:-}" ] && [ -z "${DEVELOPER_DIR:-}" ]; then
  xcode_env="$(mktemp)"
  GITHUB_ENV="$xcode_env" CMUX_CI_SKIP_XCODE_SELECT=1 "$repo/scripts/select-ci-xcode.sh" >&2
  DEVELOPER_DIR="$(sed -n 's/^DEVELOPER_DIR=//p' "$xcode_env" | tail -n 1)"
  rm -f "$xcode_env"
  [ -n "$DEVELOPER_DIR" ] || { echo "error: select-ci-xcode.sh selected no Xcode" >&2; exit 1; }
  export DEVELOPER_DIR
fi
for dir in /Users/Shared/cmux-build-fleet/tools/bin "$HOME/.bun/bin" /opt/homebrew/bin; do
  [ -d "$dir" ] && PATH="$PATH:$dir"
done
export PATH

rm -rf "$out"
mkdir -p "$out"
state="${CMUX_UI_PREVIEW_STATE:-${TMPDIR:-/tmp}/cmux-ui-preview-push-state}"
status=0
python3 - "$repo/scripts/cmux-next/ui-preview-worker.py" "$state" "$out" "$@" <<'PY' || status=$?
import importlib.util, json, shutil, sys, time
from pathlib import Path

worker_py, state, out, *probes = sys.argv[1:]
spec = importlib.util.spec_from_file_location("ui_preview_worker", worker_py)
w = importlib.util.module_from_spec(spec)
sys.modules["ui_preview_worker"] = w
spec.loader.exec_module(w)

worker = w.Worker(Path(state), "http://preview-worker.invalid:8765", None, None)
report = {"host": worker.host, "warm": None, "looks": []}
t = time.monotonic()
report["warm"] = worker.warm()
report["warm"]["wall_s"] = round(time.monotonic() - t, 2)
print("warm:", json.dumps(report["warm"]), flush=True)
try:
    for probe in probes:
        kind, branch, base, head, files = probe.split(":", 4)
        req = w.check_request({
            "schema": "ui-preview-request/v1", "repo": "manaflow-ai/cmux", "head_sha": head, "base_sha": base,
            "branch": branch, "ui_files": files.split(","), "recipient": "measure/ui-preview-worker-push",
            "recipient_host": "measure", "pushed_at": w.utc_now(), "synthetic": True,
        })
        receipt = worker.look(req, received=time.monotonic())
        receipt["kind"] = kind
        report["looks"].append(receipt)
        print(f"look {kind}:", json.dumps({k: receipt.get(k) for k in
              ("push_to_post_s", "stages", "error", "scenes", "web_entries")}), flush=True)
finally:
    worker.stop_gallery()
Path(out, "report.json").write_text(json.dumps(report, indent=1))
for name in ("outbox", "looks"):
    if (worker.state / name).is_dir():
        shutil.copytree(worker.state / name, Path(out) / name, dirs_exist_ok=True)
if worker.receipts_path.is_file():
    shutil.copy(worker.receipts_path, Path(out) / worker.receipts_path.name)
summary = {r["kind"]: r.get("push_to_post_s") for r in report["looks"]}
print("ui-preview-push:", json.dumps(summary, sort_keys=True))
sys.exit(0 if report["looks"] and all(r.get("posted_at") for r in report["looks"]) else 1)
PY
cp "$state"/gallery-dev.log "$out/" 2>/dev/null || true
tar -cf "$repo/Prototypes/UiLayerHost/.build/ui-preview-push.tar" -C "$out" .
exit "$status"
