#!/usr/bin/env python3
"""The diff tab of a large diff in the app itself: the code view's open, Plain English's first paint, and the
frame times of a scroll of the Plain English view (scripts/measure/diff-page-frames.sh runs it per arm).

One run launches a bench (or DEV) app in a scratch home (bench_memory.py `launch`, a direct child on a fleet
step), opens a diff tab on a scratch repository's uncommitted changes, turns Plain English on and scrolls it:

  repository   FILES files of LINES lines, every 10th line changed and not committed: LINES/10 hunks per file
               (90 x 1250: 11,250 hunks, 22,500 changed lines, 101,610 lines of `git diff`). The same bytes each
               time, so two arms read the same tree.
  summarizer   Plain English offers itself only when this Mac's acpmux has a harness with a headless mode
               (`cmux.diff.summaryCheck`). The run adds one as a profile file in its own XDG_CONFIG_HOME:
               harness `claude` (the automatic default), protocol claude-stdio, whose program is a shell script
               in the scratch folder that answers each hunk with one fixed sentence. No model and no network: every hunk's sentence costs one `sh` run.
  code_open_ms `openDiffViewer` (with focus) sent to the first `.file-header` of the code view in the page
               (`debug.page wait`), on this script's clock: the code view's first file drawn.
  plain_english  the toggle (`#plain-english-toggle`, else the "..." menu row) clicked inside the page; on the
               page's clock (Chromium, DevTools Runtime.evaluate): `click_to_dom_ms` to the first
               `.plain-english-hunk` in the DOM, `click_to_paint_ms` to the end of the first animation frame after
               it (a rAF, then a task), `mounted_hunks` and `nodes` then and 2 s later.
  scroll       PASSES passes of FRAMES frames: from the top, the Plain English scroller moves STEP px in each
               requestAnimationFrame; every rAF-to-rAF interval is kept (the main thread's frame time as the page
               sees it). p50/p95/p99/max, frames over 33.4 ms and over 50 ms per pass.
  clip         --clip PATH records the screen (`screencapture -v`) from just before the first pass for
               --clip-seconds. The clip is to look at; its timestamps are not frame times (only changed frames
               are written).

The page must be a Chromium page (the default engine): a WebKit page gives no script call, and the run ends.
Usage: diff-page-frames.py --app BUNDLE --label ARM --json OUT [--files 90] [--lines 1250] [--frames 600]
       [--step 120] [--passes 2] [--clip OUT.mov] [--clip-seconds 18] [--keep-repo DIR]
Exit 0 every part measured, 1 a part failed (the JSON says which), 2 usage.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_memory as bm  # noqa: E402
import diff_tab_cells as cells  # noqa: E402

PAGE = cells.PAGE
STUB = "#!/bin/sh\ncat >/dev/null\necho run >> \"$(dirname \"$0\")/summarizer.runs\"\necho 'Changes one constant value in this file.'\n"


def profile_toml(stub: str) -> str:
    """The stand-in summarizer's harness profile file (schema 1): id `claude`, the automatic default."""
    return ("schema = 1\nid = \"claude\"\nname = \"Bench summarizer\"\nprotocol = \"claude-stdio\"\n"
            f"command = {json.dumps(stub)}\nargs = []\n")


def make_repository(root: str, files: int, lines: int) -> dict:
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(cells._GIT_ENV)

    def git(*args):
        return subprocess.run(["git", "-C", root, *args], check=True, capture_output=True, env=env, text=True).stdout

    def write(changed: bool):
        for f in range(files):
            with open(os.path.join(root, f"f{f:02d}.ts"), "w") as handle:
                handle.writelines(f"export const v_{f}_{i} = {i * 2 if changed and i % 10 == 5 else i};\n"
                                  for i in range(lines))

    os.makedirs(root)
    git("init", "-q", "-b", "main")
    write(False)
    git("add", "-A")
    git("-c", "commit.gpgsign=false", "commit", "-q", "-m", "base")
    write(True)
    diff = git("diff")
    return {"files": files, "lines_per_file": lines, "diff_lines": diff.count("\n"),
            "hunks": sum(1 for line in diff.splitlines() if line.startswith("@@")),
            "changed_lines": sum(1 for line in diff.splitlines()
                                 if line[:1] in "+-" and not line.startswith(("+++", "---")))}


def runtime(app, browser: int, expression: str, timeout: float = 60):
    """`expression` (a promise of JSON text) awaited in the page; its value, or {"error": ...}."""
    reply = cells.devtools(app, browser, "Runtime.evaluate",
                           {"expression": expression, "returnByValue": True, "awaitPromise": True}, timeout=timeout)
    result = reply.get("result") if isinstance(reply.get("result"), dict) else {}
    value = result.get("value")
    if not isinstance(value, str):
        return {"error": json.dumps(reply)[:400]}
    try:
        return json.loads(value)
    except ValueError as error:
        return {"error": str(error)}


TOGGLE_STATE = """(async()=>{const t=document.getElementById('plain-english-toggle');return JSON.stringify(
{toggle:t?{pressed:t.getAttribute('aria-pressed'),disabled:!!t.disabled||t.getAttribute('aria-disabled')==='true',
label:(t.getAttribute('aria-label')||t.textContent||'').slice(0,60)}:null,
headers:document.querySelectorAll('.file-header').length,nodes:document.getElementsByTagName('*').length,
width:innerWidth,height:innerHeight,focus:document.hasFocus(),visibility:document.visibilityState})})()"""

# The click and the first paint, on the page's clock. The toggle's own click handler (a button), else the
# "..." menu row of Plain English.
FIRST_PAINT = """(async()=>{const q=s=>document.querySelector(s);let t=document.getElementById('plain-english-toggle');
let via='pill';if(!t){const o=document.getElementById('options-button');if(o)o.click();await new Promise(r=>setTimeout(r,300));
t=[...document.querySelectorAll('[role=menuitem],[role=menuitemcheckbox],button')].find(e=>/plain english/i.test(e.textContent||''));via='menu';}
if(!t)return JSON.stringify({error:'no Plain English control'});
const r={via};const done=new Promise(res=>{const seen=()=>{if(r.dom!=null)return;if(!q('.plain-english-hunk'))return;
r.dom=performance.now()-r.t0;mo.disconnect();requestAnimationFrame(()=>{r.raf=performance.now()-r.t0;
setTimeout(()=>{r.paint=performance.now()-r.t0;res()},0)})};const mo=new MutationObserver(seen);
mo.observe(document.body,{childList:true,subtree:true});setTimeout(()=>{mo.disconnect();res()},120000)});
r.t0=performance.now();t.click();r.click_ms=performance.now()-r.t0;await done;
const count=()=>({mounted_hunks:document.querySelectorAll('.plain-english-hunk').length,nodes:document.getElementsByTagName('*').length});
const first=count();await new Promise(res=>setTimeout(res,2000));
const pe=q('.plain-english');return JSON.stringify({via,click_handler_ms:+r.click_ms.toFixed(2),
click_to_dom_ms:r.dom==null?null:+r.dom.toFixed(2),click_to_raf_ms:r.raf==null?null:+r.raf.toFixed(2),
click_to_paint_ms:r.paint==null?null:+r.paint.toFixed(2),at_paint:first,after_2s:count(),
scroller:pe?{scrollHeight:pe.scrollHeight,clientHeight:pe.clientHeight}:null})})()"""

SCROLL = """(async()=>{const pe=document.querySelector('.plain-english');let s=pe&&pe.scrollHeight>pe.clientHeight+100?pe:null;
if(!s){const c=[...document.querySelectorAll('*')].filter(e=>e.scrollHeight>e.clientHeight+100&&/(auto|scroll)/.test(getComputedStyle(e).overflowY));
c.sort((a,b)=>b.scrollHeight-a.scrollHeight);s=c[0];}if(!s)return JSON.stringify({error:'no scroller'});
s.scrollTop=0;await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
const d=[];let last=0,n=0;const t0=performance.now();await new Promise(res=>{const step=()=>{const now=performance.now();
if(last)d.push(now-last);last=now;n++;if(n<=FRAMES){s.scrollTop+=STEP;requestAnimationFrame(step)}else res()};requestAnimationFrame(step)});
const wall=performance.now()-t0;return JSON.stringify({scroller:String(s.className).slice(0,60),scrollHeight:s.scrollHeight,
end:s.scrollTop,wall_ms:Math.round(wall),deltas:d.map(x=>+x.toFixed(2)),
mounted_hunks:document.querySelectorAll('.plain-english-hunk').length,nodes:document.getElementsByTagName('*').length})})()"""


def stats(deltas: list[float]) -> dict:
    d = sorted(deltas)
    if not d:
        return {"frames": 0}
    def q(p: float) -> float:  # nearest rank
        return d[max(0, math.ceil(len(d) * p) - 1)]

    return {"frames": len(d), "p50": q(0.5), "p95": q(0.95), "p99": q(0.99), "max": d[-1],
            "over_33ms": sum(x > 33.4 for x in d), "over_50ms": sum(x > 50 for x in d),
            "mean": round(sum(d) / len(d), 2)}


def wait_toggle(app, browser: int, seconds: float = 60) -> dict:
    """The toggle's state once it is ready (not disabled), or the last state read at the deadline."""
    deadline = time.monotonic() + seconds
    state: dict = {}
    while time.monotonic() < deadline:
        state = runtime(app, browser, TOGGLE_STATE, timeout=30)
        toggle = state.get("toggle") if isinstance(state, dict) else None
        if toggle and not toggle.get("disabled"):
            return state
        time.sleep(1)  # test script: the page asks summaryCheck once; wait for its answer
    return state


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--json", required=True)
    parser.add_argument("--files", type=int, default=90)
    parser.add_argument("--lines", type=int, default=1250)
    parser.add_argument("--frames", type=int, default=600)
    parser.add_argument("--step", type=int, default=120)
    parser.add_argument("--passes", type=int, default=2)
    parser.add_argument("--clip")
    parser.add_argument("--clip-seconds", type=int, default=18)
    args = parser.parse_args()
    bundle = os.path.abspath(args.app)
    out: dict = {"label": args.label, "app": bundle, "ok": False, "errors": []}
    work = tempfile.mkdtemp(prefix="diff-page-frames-")
    repo = os.path.join(work, "repo")
    recorder = None
    scratch = None
    try:
        out["repository"] = make_repository(repo, args.files, args.lines)
        print(f"DIFF-FRAMES {args.label} repository {json.dumps(out['repository'])}", flush=True)
        stub = os.path.join(work, "summarizer.sh")
        with open(stub, "w") as handle:
            handle.write(STUB)
        os.chmod(stub, 0o755)
        # The stand-in is a harness profile file, not `agent.harness.add`: that action takes only
        # protocol acp or terminal, and only a claude-stdio harness has a headless recipe (`claude -p`,
        # acpmux complete/recipes.rs). A user profile file wins over the discovered `claude` for its id
        # (config/profiles.rs), and XDG_CONFIG_HOME names its folder, so the run's acpmux reads only it.
        xdg = os.path.join(work, "xdg")
        os.makedirs(os.path.join(xdg, "cmux", "harnesses"), exist_ok=True)
        with open(os.path.join(xdg, "cmux", "harnesses", "claude.toml"), "w") as handle:
            handle.write(profile_toml(stub))
        out["harness_add"] = "profile file"
        # The keyboard and the screen: the window comes to the front (no CMUX_NEXT_NO_ACTIVATE), as a person's.
        pid, socket_path, scratch = bm.launch(bundle, {}, {"CMUX_NEXT_NO_ACTIVATE": None, "XDG_CONFIG_HOME": xdg})
        app = bm.App(bundle, socket_path)
        for _ in range(30):
            if app.ping():
                break
            time.sleep(1)  # test script: the app's socket answers once its control service runs
        made = app.run("workspace.newAtBottom")
        app.run("workspace.selectLast")
        app.run("newSurface")
        out["workspace"] = (made.get("created") or [None])[0] if isinstance(made.get("created"), list) else made.get("error")
        time.sleep(3)  # test script: the new terminal settles before the timed open
        started = time.monotonic()
        opened = app.action("openDiffViewer", focus=True, path=repo)
        waited = app.call("debug.page", {"page": PAGE, "action": "wait", "selector": ".file-header", "timeout_ms": 90000},
                          timeout=100) or {}
        code_ms = (time.monotonic() - started) * 1000
        out["code_view"] = {"open_to_first_file_header_ms": round(code_ms, 1) if waited.get("matched") is True else None,
                            "open": {k: opened[k] for k in ("created", "state", "error", "code") if k in opened},
                            "wait": {k: waited[k] for k in ("matched", "error", "ms") if k in waited}}
        print(f"DIFF-FRAMES {args.label} code_view {json.dumps(out['code_view'])}", flush=True)
        if waited.get("matched") is not True:
            raise RuntimeError(f"the code view drew no file: {waited}")
        facts = cells.page_facts(app)
        out["page"] = {k: facts.get(k) for k in ("engine", "browser", "focus", "visibility", "width", "height", "painted")}
        if facts.get("browser") is None:
            raise RuntimeError(f"the diff page is not a Chromium page (no script call into it): {facts.get('engine')}")
        browser = facts["browser"]
        check = app.call("debug.page", {"page": PAGE, "action": "call", "op": "cmux.diff.summaryCheck", "params": {}},
                         timeout=60) or {}
        out["summary_check"] = json.dumps(check)[:300]
        state = wait_toggle(app, browser)
        out["toggle_before"] = state
        print(f"DIFF-FRAMES {args.label} toggle {json.dumps(state)[:400]} summaryCheck {out['summary_check']}", flush=True)
        time.sleep(2)  # test script: the code view's own work after its first file ends before the timed click
        paint = runtime(app, browser, FIRST_PAINT, timeout=150)
        out["plain_english"] = paint
        print(f"DIFF-FRAMES {args.label} plain_english {json.dumps(paint)}", flush=True)
        if paint.get("error") or paint.get("click_to_paint_ms") is None:
            raise RuntimeError(f"Plain English did not paint: {json.dumps(paint)[:300]}")
        time.sleep(3)  # test script: the first sentences are asked and answered before the scroll
        runs = os.path.join(work, "summarizer.runs")
        sentences = runtime(app, browser, "(async()=>JSON.stringify([...document.querySelectorAll("
                            "'.plain-english-sentence')].slice(0,5).map(e=>e.textContent)))()", timeout=30)
        out["sentences"] = sentences
        out["summarizer_runs_before_scroll"] = sum(1 for _ in open(runs)) if os.path.exists(runs) else 0
        if not out["summarizer_runs_before_scroll"]:
            # Sentences that did not come from the stand-in come from another harness: stop before the scroll asks more.
            raise RuntimeError(f"the stand-in summarizer did not run (sentences {json.dumps(sentences)[:200]})")
        if args.clip:
            recorder = subprocess.Popen(["screencapture", "-x", "-v", "-V", str(args.clip_seconds), args.clip],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            time.sleep(1.5)  # test script: the recording starts before the first pass
        out["passes"] = []
        script = SCROLL.replace("FRAMES", str(args.frames)).replace("STEP", str(args.step))
        for index in range(args.passes):
            got = runtime(app, browser, script, timeout=180)
            deltas = got.pop("deltas", []) if isinstance(got, dict) else []
            got.update(stats(deltas), deltas=deltas, index=index + 1)
            out["passes"].append(got)
            summary = {k: got.get(k) for k in ("frames", "p50", "p95", "p99", "max", "over_33ms", "over_50ms", "wall_ms",
                                               "mounted_hunks", "nodes", "scrollHeight", "end", "error")}
            print(f"DIFF-FRAMES {args.label} pass {index + 1} {json.dumps(summary)}", flush=True)
            time.sleep(1)  # test script: a pause between the passes, as a reader's
        out["summarizer_runs_total"] = sum(1 for _ in open(runs)) if os.path.exists(runs) else 0
        if recorder is not None:
            try:
                _, err = recorder.communicate(timeout=args.clip_seconds + 30)
                out["clip"] = {"path": args.clip, "exit": recorder.returncode,
                               "bytes": os.path.getsize(args.clip) if os.path.exists(args.clip) else 0,
                               "stderr": (err or b"").decode(errors="replace")[:300]}
            except subprocess.TimeoutExpired:
                recorder.kill()
                out["clip"] = {"path": args.clip, "error": "screencapture did not end"}
            recorder = None
        out["ok"] = all(not p.get("error") and p.get("frames") for p in out["passes"])
    except (RuntimeError, SystemExit, OSError, subprocess.SubprocessError, ValueError) as error:
        out["errors"].append(str(error)[:600])
        print(f"DIFF-FRAMES {args.label} error {str(error)[:600]}", file=sys.stderr, flush=True)
    finally:
        if recorder is not None:
            recorder.kill()
        bm.end_bundle(bundle)
        if scratch:
            shutil.rmtree(scratch, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)
        with open(args.json, "w") as handle:
            json.dump(out, handle, indent=1)
    return 0 if out["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
