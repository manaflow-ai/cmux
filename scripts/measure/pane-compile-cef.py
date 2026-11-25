#!/usr/bin/env python3
"""Does cmux NEXT's Chromium (CEF) serve the agent pane's ES-module code from V8's code cache on a second load?

Launches a tagged DEBUG cmux-next app (extra Chromium switches are accepted only there) with
CMUX_NEXT_CEF_EXTRA_SWITCHES=remote-debugging-port=PORT, opens an agent chat, then runs
`node scripts/measure/pane-compile-ab.mjs --attach PORT`, which reloads the pane twice under a DevTools trace and
prints secondLoadConsumedCache, main-thread compiles and first contentful paint. Prints PANE-COMPILE lines.

  pane-compile-cef.py --app "<cmux DEV tag.app>" --out DIR [--port 9333] [--runs 5]
"""
import argparse, json, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "cmux-next"))
from bench_launch import BenchApp  # noqa: E402

p = argparse.ArgumentParser()
p.add_argument("--app", required=True)
p.add_argument("--out", required=True)
p.add_argument("--port", type=int, default=9333)
p.add_argument("--runs", type=int, default=5)
p.add_argument("--match", default="cmux.agent")
o = p.parse_args()
os.makedirs(o.out, exist_ok=True)
env = {"CMUX_NEXT_CEF_EXTRA_SWITCHES": f"remote-debugging-port={o.port}:remote-allow-origins=*"}
app = BenchApp(o.app, out=o.out, env=env)
results = []
try:
    app.launch()
    deadline = time.time() + 90
    while time.time() < deadline and (app.rpc("debug.cef") or {}).get("state") != "ready":
        time.sleep(0.5)
    print("PANE-COMPILE cef", json.dumps(app.rpc("debug.cef") or {})[:300], flush=True)
    opened = app.rpc("action.run", {"action": "palette.newAgentChat", "focus": True})
    print("PANE-COMPILE open", json.dumps(opened)[:300], flush=True)
    time.sleep(8)
    for run in range(o.runs):
        r = subprocess.run(["node", os.path.join(HERE, "pane-compile-ab.mjs"), "--attach", str(o.port), o.match],
                           capture_output=True, text=True, timeout=300)
        print(f"PANE-COMPILE run {run} rc={r.returncode} {r.stdout.strip()} {r.stderr.strip()[-400:]}", flush=True)
        try:
            results.append(json.loads(r.stdout))
        except ValueError:
            pass
        with open(os.path.join(o.out, "runs.json"), "w") as f:
            json.dump(results, f, indent=1)
finally:
    app.stop()
sys.exit(0 if results else 1)
