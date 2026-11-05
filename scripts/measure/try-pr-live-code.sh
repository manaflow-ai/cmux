#!/usr/bin/env bash
# try-pr.sh --live-code end to end on a fleet Mac (docs/cmux-next/hot-reload.md, "Try a pull request"):
# builds this commit as a live code bench build (scripts/live-code/build.sh), then tries a fixture pull
# request that turns Home's background red (HomeHostView.updateLayer, a function body, the edit
# live-code-app.sh makes) in a side instance with try-pr.sh --live-code. The PR comes from a scratch
# clone whose origin serves it as refs/pull/1/head, so no GitHub. The side instance is made and opened
# first and captured, then try-pr.sh is timed from its start to the copy's "applied" line, captured
# again, and both captures' red pixels counted. A second PR, whose patch needs Swift only its newer base
# has, must take the dev build. Then the side instances are removed.
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

# The fixture: an origin that borrows this repo's objects and serves two pull requests whose base is
# newer than the build (the case try-pr.sh sorts again from the build's own commit):
#   PR 1 on HEAD+1 (a docs edit): Home's background red, a function body; it applies and shows.
#   PR 2 on HEAD+2 (HEAD+1 plus a new HomeHostView method): the same line calls that method, which the
#        build lacks, so its patch cannot compile against the build and it takes the dev build.
# try-pr.sh runs from a clone of it.
view="Packages/macOS/CmuxNext/Sources/CmuxNextApp/Home/HomeHostView.swift"
original="layer?.backgroundColor = nil"
red="layer?.backgroundColor = NSColor.systemRed.cgColor"
grep -qF "$original" "$view" || { echo "try-pr-live-code: $view no longer has $original" >&2; exit 1; }
fx="$out/fixture"; rm -rf "$fx"; mkdir -p "$fx"
git init -q --bare "$fx/origin.git"
echo "$(cd "$(git rev-parse --git-common-dir)" && pwd)/objects" >"$fx/origin.git/objects/info/alternates"
# PARENT PATH MESSAGE (the file's new text on stdin): a commit of PARENT with PATH replaced; no checkout.
commit_with() {
  local parent="$1" path="$2" message="$3" blob index="$fx/index"
  blob="$(git hash-object -w --stdin)"
  rm -f "$index"
  GIT_INDEX_FILE="$index" git read-tree "$parent"
  GIT_INDEX_FILE="$index" git update-index --cacheinfo "100644,$blob,$path"
  git -c user.name=try-pr-live-code -c user.email=try-pr@localhost commit-tree \
    "$(GIT_INDEX_FILE="$index" git write-tree)" -p "$parent" -m "$message"
}
build_commit="$(git rev-parse HEAD)"
docs="docs/cmux-next/live-code.md"
newer="$( (cat "$docs"; echo; echo "<!-- try-pr-live-code fixture -->") | commit_with "$build_commit" "$docs" "fixture: a newer base")"
pr1="$(sed "s/$original/$red/" "$view" | commit_with "$newer" "$view" "fixture: Home red")"
helper='extension HomeHostView {\n    func tryPrLiveTint() -> CGColor { NSColor.systemRed.cgColor }\n}'
newest="$( (cat "$view"; printf '\n%b\n' "$helper") | commit_with "$newer" "$view" "fixture: a base with a new method")"
pr2="$(git show "$newest:$view" | sed "s/$original/layer?.backgroundColor = tryPrLiveTint()/" | commit_with "$newest" "$view" "fixture: Home tint from the new method")"
git push -q "$fx/origin.git" "$newest:refs/heads/feat-cmux-next" "$pr1:refs/pull/1/head" "$pr2:refs/pull/2/head"
git clone -q --shared -b feat-cmux-next "$fx/origin.git" "$fx/checkout"

export CMUX_SIDE_ROOT="$out/side"
try="$fx/checkout/scripts/cmux-next/try-pr.sh"
side="$fx/checkout/scripts/cmux-next/side-instance.sh"
# The copy draws its own main window (debug.window_snapshot, as live-code-app.py does): a fleet Mac's step
# has no Screen Recording grant, so screencapture fails there with "could not create image from display".
# The copy's control socket is among the sockets its recorded pid has open.
capture() {
  python3 - "$CMUX_SIDE_ROOT/pr-1/pid" "$out/$1.png" <<'PY'
import os, subprocess, sys
sys.path.insert(0, os.path.join(os.getcwd(), "scripts", "cmux-next"))
from bench_launch import rpc_at
pid, png = open(sys.argv[1]).read().strip(), sys.argv[2]
names = subprocess.run(["lsof", "-a", "-p", pid, "-U", "-Fn"], capture_output=True, text=True).stdout.split("\n")
socks = [n[1:] for n in names if n.startswith("n") and n.endswith(".sock") and "cmux" in os.path.basename(n)]
if not socks:
    sys.exit(f"try-pr-live-code: the copy (pid {pid}) has no cmux socket open")
# It also holds client sockets (its daemon's): the control socket is the one that answers.
replies = {}
for sock in dict.fromkeys(socks):
    replies[sock] = rpc_at(sock, "debug.window_snapshot", {"kind": "main", "path": png}, timeout=60)
    if os.path.exists(png):
        sys.exit(0)
sys.exit(f"try-pr-live-code: no snapshot from the copy's sockets: {replies}")
PY
}
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
# PR 2: its patch needs the newer base's method, so it must not apply.
start2="$(python3 -c 'import time; print(time.time())')"
set +e
"$try" 2 --from "$app" --live-code "$log" --no-build >"$out/try-pr-2.log" 2>&1
code2=$?
set -e
end2="$(python3 -c 'import time; print(time.time())')"
"$try" 2 --stop >"$out/stop-2.log" 2>&1 || true
python3 - "$out" "$build_s" "$code" "$start" "$end" "$build_commit" "$code2" "$start2" "$end2" <<'PY'
import json, os, re, sys
out, build_s, code, start, end, base = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5]), sys.argv[6]
code2, start2, end2 = int(sys.argv[7]), float(sys.argv[8]), float(sys.argv[9])
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
text2 = open(os.path.join(out, "try-pr-2.log")).read()
result["pr2"] = {"exit": code2, "s": round(end2 - start2, 2), "applied": "live code: applied" in text2,
                 "fell_back": "so a dev build" in text2, "compile_refused": "did not compile against the build" in text2}
result["pass"] = bool(code == 0 and applied and after[0] > before[0] + 1000
                      and code2 == 0 and not result["pr2"]["applied"] and result["pr2"]["compile_refused"])
json.dump(result, open(os.path.join(out, "result.json"), "w"), indent=2)
print(json.dumps(result))
sys.exit(0 if result["pass"] else 1)
PY
