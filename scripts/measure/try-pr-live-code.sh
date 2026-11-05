#!/usr/bin/env bash
# try-pr.sh --live-code end to end on a fleet Mac (docs/cmux-next/hot-reload.md, "Try a pull request"):
# builds this commit as a live code bench build (scripts/live-code/build.sh), then tries a fixture pull
# request that turns Home's background red (HomeHostView.updateLayer, a function body, the edit
# live-code-app.sh makes) in a side instance with try-pr.sh --live-code. The PR comes from a scratch
# clone whose origin serves it as refs/pull/1/head, so no GitHub. The side instance is made and opened
# first and captured, then try-pr.sh is timed from its start to the copy's "applied" line, captured
# again, and both captures' red pixels counted; then the side instance is removed.
#   scripts/measure/try-pr-live-code.sh OUT     (OUT: logs, before.png, after.png, result.json)
set -euo pipefail
out="$(mkdir -p "${1:?usage: try-pr-live-code.sh OUT}" && cd "$1" && pwd)"
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
for sub in ghostty ghostty-next; do
  [ -e "$sub/.git" ] || git submodule update --init --depth 1 "$sub"
done
if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
  rm -rf GhosttyKit.xcframework
  if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
    export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
  fi
  ./scripts/download-prebuilt-ghosttykit.sh
fi
build_start=$SECONDS
app="$(scripts/live-code/build.sh "$out/build" try-pr-live bench CMUX_DEV_BACKEND_MODE=local | tail -n 1)"
build_s=$((SECONDS - build_start))
log="$out/build/xcodebuild.log"
[[ -d "$app" && -f "$log" ]] || { echo "try-pr-live-code: no live code build" >&2; exit 1; }

# The fixture: an origin that borrows this repo's objects, serving HEAD as feat-cmux-next and the
# red edit as pull request 1; try-pr.sh runs from a clone of it.
view="Packages/macOS/CmuxNext/Sources/CmuxNextApp/Home/HomeHostView.swift"
original="layer?.backgroundColor = nil"
red="layer?.backgroundColor = NSColor.systemRed.cgColor"
grep -qF "$original" "$view" || { echo "try-pr-live-code: $view no longer has $original" >&2; exit 1; }
fx="$out/fixture"; rm -rf "$fx"; mkdir -p "$fx"
git init -q --bare "$fx/origin.git"
echo "$(cd "$(git rev-parse --git-common-dir)" && pwd)/objects" >"$fx/origin.git/objects/info/alternates"
base="$(git rev-parse HEAD)"
blob="$(sed "s/$original/$red/" "$view" | git hash-object -w --stdin)"
index="$fx/index"
GIT_INDEX_FILE="$index" git read-tree HEAD
GIT_INDEX_FILE="$index" git update-index --cacheinfo "100644,$blob,$view"
tree="$(GIT_INDEX_FILE="$index" git write-tree)"
pr_commit="$(git -c user.name=try-pr-live-code -c user.email=try-pr@localhost commit-tree "$tree" -p "$base" -m "fixture: Home red")"
git push -q "$fx/origin.git" "$base:refs/heads/feat-cmux-next" "$pr_commit:refs/pull/1/head"
git clone -q --shared -b feat-cmux-next "$fx/origin.git" "$fx/checkout"

export CMUX_SIDE_ROOT="$out/side"
try="$fx/checkout/scripts/cmux-next/try-pr.sh"
side="$fx/checkout/scripts/cmux-next/side-instance.sh"
capture() { screencapture -x "$out/$1.png"; }
cleanup() { "$try" 1 --stop >"$out/stop.log" 2>&1 || true; }
trap cleanup EXIT
# The copy as try-pr.sh makes it (same app, label and --live-code), open in front, then captured.
"$side" make pr-1 --from "$app" --label "cmux PR #1" --live-code >"$out/make.log" 2>&1
"$side" launch pr-1 --front >"$out/launch.log" 2>&1
live="$CMUX_SIDE_ROOT/pr-1/live-code"
for _ in $(seq 1 300); do grep -q 'live code: watching' "$live/live-code.log" 2>/dev/null && break; sleep 0.2; done
grep -q 'live code: watching' "$live/live-code.log" || { echo "try-pr-live-code: the copy never watched $live" >&2; exit 1; }
sleep 3
capture before
start="$(python3 -c 'import time; print(time.time())')"
set +e
"$try" 1 --from "$app" --live-code "$log" --front --no-build >"$out/try-pr.log" 2>&1
code=$?
set -e
end="$(python3 -c 'import time; print(time.time())')"
sleep 2
capture after
python3 - "$out" "$build_s" "$code" "$start" "$end" "$base" <<'PY'
import json, os, re, sys
out, build_s, code, start, end, base = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5]), sys.argv[6]
sys.path.insert(0, os.path.join(os.getcwd(), "scripts", "measure"))
from importlib import util
spec = util.spec_from_file_location("lca", os.path.join(os.getcwd(), "scripts", "measure", "live-code-app.py"))
lca = util.module_from_spec(spec); spec.loader.exec_module(lca)
before, after = lca.pixels(os.path.join(out, "before.png")), lca.pixels(os.path.join(out, "after.png"))
text = open(os.path.join(out, "try-pr.log")).read()
patch = re.search(r"compile_s=([\d.]+) link_s=([\d.]+)", text)
applied = re.search(r"live code: applied (\S+) functions=(\d+) load_ms=(\d+) at=([\d.]+)", text)
result = {
    "commit": base, "build_s": build_s, "try_pr_exit": code,
    "try_pr_s": round(end - start, 2),
    "start_to_applied_s": round(float(applied.group(4)) - start, 2) if applied else None,
    "compile_s": float(patch.group(1)) if patch else None, "link_s": float(patch.group(2)) if patch else None,
    "functions": int(applied.group(2)) if applied else None, "load_ms": int(applied.group(3)) if applied else None,
    "red_px_before": before[0], "red_px_after": after[0],
}
result["pass"] = bool(code == 0 and applied and after[0] > before[0] + 1000)
json.dump(result, open(os.path.join(out, "result.json"), "w"), indent=2)
print(json.dumps(result))
sys.exit(0 if result["pass"] else 1)
PY
