#!/usr/bin/env python3
"""A Chromium page's frames while it scrolls and animates, and each frame producer's time in a commit.

The perf budget rows page.scroll.frame, terminal.commit.producer, page.commit.producer and frame.commit.all_producers
(scripts/cmux-next/perf-budget-table.tsv) read the rows this bench gives the perf cron (perf-budgets.py `page`, part
home-idle). Launches the tagged app itself (BenchApp: no activation, scratch config), splits the launch window's
terminal pane, opens a Chromium tab on a local tall page in the right pane, then:

  scroll    one wheel event on the page every 60 Hz frame for --seconds (debug.mouse, target page) while the
            terminal on the left prints (`seq`): the page's requestAnimationFrame intervals (performance.now()
            between frames, the frames Chromium made)
  animate   a CSS animation on the page for --seconds, nothing else moving: the same intervals
  resize    the two panes resized by keys (resizePaneLeft and resizePaneRight, --resizes times): a frame where both the
            terminal and the page redraw for a new size

From before `scroll` to after `resize`, `debug.commit_producers` (CommitProducerProbe, CmuxNextControl) times each synchronous
producer per Core Animation commit: a terminal's display pass and a page's placement. Its p95s are the commit rows.

Rows (JSON --json; perf-budgets.py maps them, ms):
  page.chromium.scroll.frame, page.chromium.animate.frame   p50/p95 of the page's frame interval
  commit.terminal.producer, commit.page.producer           p50/p95 of one producer's time in one commit
  commit.all.producer                                      p50/p95 of all producers of one commit together
A row whose part did not run (no Chromium in the build, an app with no debug.commit_producers) is left out, so
perf-budgets.py reports it incomplete and the budget table not measured, never a pass.

Not a gate. On a fleet GUI host, building the app in the step:
  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh --ref SHA \\
    --arg=--suite=budgets --arg=--only=page --artifact artifacts/split-spring/report.json
Local, on a built app (never on a laptop in use):
  page-frame-bench.py --tag T --app "<...>/cmux DEV T.app" --out DIR [--json F]
"""
import argparse, json, os, pathlib, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import BenchApp, LaunchError  # noqa: E402

PAGE = """<!doctype html><meta charset=utf-8><title>frames</title>
<style>body{margin:0;font:16px system-ui;background:linear-gradient(#204080,#802040 50%,#208040)}
.row{height:48px;border-bottom:1px solid #fff3;color:#fff;padding:12px}
#box{position:fixed;left:0;top:40%;width:60px;height:60px;background:#f0c000}
.go{animation:slide .5s linear infinite alternate}@keyframes slide{to{transform:translateX(600px)}}</style>
<div id=box></div><div id=rows></div>
<script>
const rows = document.getElementById('rows');
for (let i = 0; i < 2000; i++) { const d = document.createElement('div'); d.className = 'row'; d.textContent = 'row ' + i; rows.appendChild(d); }
let samples = [], last = null, until = 0;
function tick(t) { if (last !== null) samples.push(t - last); last = t; if (t < until) requestAnimationFrame(tick); else last = null; }
window.__record = function(ms, animate) {
  samples = []; last = null; until = performance.now() + ms;
  if (animate) document.getElementById('box').classList.add('go');
  requestAnimationFrame(tick);
  return true;
};
window.__done = function() { document.getElementById('box').classList.remove('go'); return samples.map(v => +v.toFixed(3)); };
document.title = 'frames ready';
</script>"""


def pct(values, q):
    if not values:
        return None
    s = sorted(values)
    return round(s[min(len(s) - 1, round(q * (len(s) - 1)))], 3)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag")
    ap.add_argument("--app", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--json")
    ap.add_argument("--seconds", type=float, default=5.0)
    ap.add_argument("--resizes", type=int, default=12)
    opts = ap.parse_args()
    os.makedirs(opts.out, exist_ok=True)
    probe = os.path.join(opts.out, "frames.html")
    open(probe, "w").write(PAGE)
    url = pathlib.Path(probe).as_uri()
    result = {"rows": {}, "notes": []}
    app = BenchApp(opts.app, out=opts.out)
    tab = {}

    def rpc(method, params=None, timeout=60):
        return app.rpc(method, params, timeout)

    def action(name, args=None, settle=0.0, timeout=60):
        reply = rpc("action.run", {"action": name, "args": args or {}, "focus": True, "origin": "script"}, timeout=timeout)
        if settle:
            time.sleep(settle)  # test harness: the action's motion settles
        return reply

    def page(script):
        reply = rpc("browser.page.eval", {"script": script, **({"tab": tab["id"]} if tab.get("id") else {})}, timeout=20)
        if isinstance(reply, dict) and reply.get("tab"):
            tab.setdefault("id", reply["tab"])
        return reply.get("value") if isinstance(reply, dict) and "error" not in reply else None

    def wait(check, seconds, step=0.25):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            value = check()
            if value:
                return value
            time.sleep(step)  # test harness polling a live app
        return None

    def frames(name, animate):
        if not page(f"window.__record({int(opts.seconds * 1000)}, {'true' if animate else 'false'})"):
            result["notes"].append(f"{name}: the page did not start recording")
            return
        end = time.monotonic() + opts.seconds
        while time.monotonic() < end:
            if not animate:
                rpc("debug.mouse", {"target": "page", "action": "scroll", "dy": -12})
            time.sleep(1 / 60)  # test harness: one wheel event per 60 Hz frame (animate: just the wait)
        time.sleep(0.3)  # test harness: the last frames land
        values = page("window.__done()") or []
        result[name] = {"n": len(values), "p50": pct(values, 0.5), "p95": pct(values, 0.95), "max": pct(values, 1.0)}
        if len(values) >= 10:
            result["rows"][f"page.chromium.{name}.frame"] = [pct(values, 0.5), pct(values, 0.95)]

    code = 0
    try:
        app.launch()
        cef = rpc("debug.cef") or {}
        result["cef"] = {"unavailable": cef.get("unavailable"), "fallback": cef.get("fallback")}
        action("splitRight", settle=1.0)
        opened = action("openBrowser.chromium", {"url": url}, timeout=120)
        if not wait(lambda: page("document.title === 'frames ready'"), 90, 0.5):
            result["error"] = f"the page never loaded in Chromium: {json.dumps(opened)[:300]}"
            code = 1
            return code
        result["engine"] = (rpc("debug.agent_pane", {"action": "engine"}) or {}).get("engine")
        action("focusLeft", settle=0.3)
        action("terminal.sendText", {"text": "seq 1 2000000\r"})
        action("focusRight", settle=0.5)
        started = rpc("debug.commit_producers", {"action": "start"}) or {}
        if started.get("error"):
            result["notes"].append(f"no commit producer timer in this build: {started.get('error')}")
        frames("scroll", animate=False)
        frames("animate", animate=True)
        for i in range(opts.resizes):
            action("resizePaneLeft" if i % 2 == 0 else "resizePaneRight", settle=0.15)
        if not started.get("error"):
            report = rpc("debug.commit_producers", {"action": "stop"}) or {}
            result["commit_producers"] = report
            for kind in ("terminal", "page", "all"):
                stats = report.get(kind) or {}
                if stats.get("samples"):
                    result["rows"][f"commit.{kind}.producer"] = [stats.get("p50_ms"), stats.get("p95_ms")]
    except LaunchError as error:
        result["error"] = error.reason
        code = 1
    finally:
        for path in filter(None, [os.path.join(opts.out, "page-frame-bench.json"), opts.json]):
            os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
            with open(path, "w") as f:
                json.dump(result, f, indent=1)
        print("PAGE-FRAME-BENCH " + json.dumps({k: v for k, v in result.items() if k != "commit_producers"}), flush=True)
        app.stop()
    return code


if __name__ == "__main__":
    sys.exit(main())
