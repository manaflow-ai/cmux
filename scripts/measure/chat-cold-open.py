#!/usr/bin/env python3
"""A cold chat open's V8 parse+compile ms and script bytes in cmux NEXT's own Chromium (CEF), with and without the code cache.

Each of --runs pairs launches a tagged DEBUG cmux-next app twice (extra Chromium switches are accepted only there),
with CMUX_NEXT_CEF_EXTRA_SWITCHES=remote-debugging-port=PORT:
  uncached: the profile's `Code Cache` folders moved aside before the launch: the first open after an install;
  cached:   the next launch, the folders as the uncached launch left them: every later app launch.
In each launch it waits for CEF, lets the app settle, starts a whole-browser trace
(scripts/measure/chat-cold-open-trace.mjs), opens a new agent chat (palette.newAgentChat) and traces --settle ms more.
The chat is the renderer that fetched pane.js. Prints CHAT-COLD-OPEN lines and writes runs.json (every load) and
summary.json (p50/p90 per arm of parseCompileMs, mainParseCompileMs, scriptBytes, cacheConsumed).

With --set-storage KEY=VALUE (repeatable) one warm-up launch before the pairs opens a chat and sets that localStorage
key on its page (the cmux-page origin; the profile keeps it across launches, and the pairs move aside only the
`Code Cache` folders), e.g. --set-storage cmux.paneClassicChunks=1 for the classic lazy chunks (cmux#65619).

  chat-cold-open.py --app "<cmux DEV tag.app>" --out DIR [--runs 10] [--port 9334] [--settle 8000]
                    [--set-storage KEY=VALUE ...]
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import plistlib
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "cmux-next"))
from bench_launch import BenchApp  # noqa: E402

METRICS = ("parseCompileMs", "mainParseCompileMs", "scriptBytes", "scriptFiles", "cacheConsumed", "cacheProduced")


def pct(values, q):
    xs = sorted(v for v in values if v is not None)
    if not xs:
        return None
    return xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))]


def code_cache_dirs(app):
    """`Code Cache` folders of this bundle's Chromium root (CEFProfileStorage: <Application Support>/<folder>/Chromium,
    the folder named for the bundle id), every profile."""
    with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
        bundle_id = plistlib.load(f).get("CFBundleIdentifier", "")
    support = os.path.expanduser("~/Library/Application Support")
    found = []
    for root in glob.glob(os.path.join(support, "*", "Chromium")):
        folder = os.path.basename(os.path.dirname(root))
        if bundle_id and (folder == bundle_id or folder.startswith(bundle_id + ".") or folder.lower().startswith(bundle_id.lower())):
            found += glob.glob(os.path.join(root, "*", "Code Cache"))
    return bundle_id, found


def one_open(app, out, port, settle, label):
    """Launches, opens one chat under a whole-browser trace, quits. The trace summary, or None."""
    env = {"CMUX_NEXT_CEF_EXTRA_SWITCHES": f"remote-debugging-port={port}:remote-allow-origins=*"}
    bench = BenchApp(app, out=out, env=env)
    trace_out = os.path.join(out, f"{label}.json")
    try:
        bench.launch()
        deadline = time.time() + 90
        while time.time() < deadline and (bench.rpc("debug.cef") or {}).get("state") != "ready":
            time.sleep(0.5)
        time.sleep(5)  # launch work settles before the open
        tracer = subprocess.Popen(
            ["node", os.path.join(HERE, "chat-cold-open-trace.mjs"), "--port", str(port), "--out", trace_out, "--settle", str(settle)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        line = tracer.stdout.readline()
        if "TRACING" not in line:
            print(f"CHAT-COLD-OPEN {label} tracer did not start: {line!r} {tracer.stderr.read()[-400:]}", flush=True)
            tracer.kill()
            return None
        opened = bench.rpc("action.run", {"action": "palette.newAgentChat", "focus": True})
        tracer.stdin.write("opened\n")
        tracer.stdin.flush()
        tracer.stdin.close()
        try:
            stdout, stderr = tracer.communicate(timeout=settle / 1000 + 120)
        except subprocess.TimeoutExpired:
            tracer.kill()
            print(f"CHAT-COLD-OPEN {label} tracer timed out", flush=True)
            return None
        try:
            summary = json.loads(stdout.strip().splitlines()[-1])
        except (ValueError, IndexError):
            print(f"CHAT-COLD-OPEN {label} rc={tracer.returncode} no summary: {stderr[-400:]}", flush=True)
            return None
        summary["opened"] = opened
        return summary
    finally:
        bench.stop()


SET_STORAGE_JS = r"""
const [port, pairs] = [process.argv[1], JSON.parse(process.argv[2])];
for (let i = 0; i < 600; i++) {
  let targets = [];
  try { targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json(); } catch {}
  const page = targets.find((t) => t.type === "page" && /^cmux-page:/.test(t.url) && t.webSocketDebuggerUrl);
  if (page) {
    const ws = new WebSocket(page.webSocketDebuggerUrl);
    await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
    const expr = `(${JSON.stringify(pairs)}).map(([k, v]) => (localStorage.setItem(k, v), k + "=" + localStorage.getItem(k))).join(" ")`;
    const reply = await new Promise((r) => {
      ws.onmessage = (m) => { const msg = JSON.parse(String(m.data)); if (msg.id === 1) r(msg); };
      ws.send(JSON.stringify({ id: 1, method: "Runtime.evaluate", params: { expression: expr, returnByValue: true } }));
    });
    console.log(`${page.url} ${JSON.stringify(reply.result?.result?.value ?? reply)}`);
    process.exit(0);
  }
  await new Promise((r) => setTimeout(r, 100));
}
console.error("no cmux-page target");
process.exit(3);
"""


def set_storage(app, out, port, pairs):
    """One launch that opens a chat and sets localStorage `pairs` on its cmux-page origin; True once it read them back."""
    env = {"CMUX_NEXT_CEF_EXTRA_SWITCHES": f"remote-debugging-port={port}:remote-allow-origins=*"}
    bench = BenchApp(app, out=out, env=env)
    try:
        bench.launch()
        deadline = time.time() + 90
        while time.time() < deadline and (bench.rpc("debug.cef") or {}).get("state") != "ready":
            time.sleep(0.5)
        bench.rpc("action.run", {"action": "palette.newAgentChat", "focus": True})
        done = subprocess.run(["node", "--input-type=module", "-e", SET_STORAGE_JS, str(port), json.dumps(pairs)],
                              capture_output=True, text=True, timeout=120)
        print(f"CHAT-COLD-OPEN set-storage rc={done.returncode} {done.stdout.strip()} {done.stderr.strip()[-300:]}", flush=True)
        time.sleep(2)  # localStorage reaches disk before the quit
        return done.returncode == 0
    finally:
        bench.stop()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--app", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--runs", type=int, default=10)
    p.add_argument("--port", type=int, default=9334)
    p.add_argument("--settle", type=int, default=8000)
    p.add_argument("--set-storage", action="append", default=[], metavar="KEY=VALUE")
    o = p.parse_args()
    os.makedirs(o.out, exist_ok=True)
    pairs = [kv.split("=", 1) for kv in o.set_storage]
    if any(len(kv) != 2 for kv in pairs):
        p.error("--set-storage takes KEY=VALUE")
    if pairs and not set_storage(o.app, o.out, o.port, pairs):
        print("CHAT-COLD-OPEN set-storage failed: no run", flush=True)
        return 1
    runs = []
    for i in range(o.runs):
        bundle_id, dirs = code_cache_dirs(o.app)
        aside = os.path.join(o.out, f"code-cache-aside-{i}")
        for n, d in enumerate(dirs):
            shutil.move(d, os.path.join(aside, str(n)))
        print(f"CHAT-COLD-OPEN pair {i} {bundle_id}: moved {len(dirs)} Code Cache folder(s) aside", flush=True)
        for arm in ("uncached", "cached"):
            label = f"{arm}-{i}"
            summary = one_open(o.app, o.out, o.port, o.settle, label)
            chat = (summary or {}).get("chat") or {}
            row = {"pair": i, "arm": arm, **{k: chat.get(k) for k in METRICS}, "threads": chat.get("threads")}
            runs.append(row)
            print(f"CHAT-COLD-OPEN {label} {json.dumps(row)}", flush=True)
            with open(os.path.join(o.out, "runs.json"), "w") as f:
                json.dump(runs, f, indent=1)
        shutil.rmtree(aside, ignore_errors=True)  # this run's own copies
    summary = {"setStorage": dict(pairs)}
    for arm in ("uncached", "cached"):
        rows = [r for r in runs if r["arm"] == arm and r["parseCompileMs"] is not None]
        summary[arm] = {"n": len(rows), **{f"{k}_p50": pct([r[k] for r in rows], 0.5) for k in METRICS},
                        **{f"{k}_p90": pct([r[k] for r in rows], 0.9) for k in ("parseCompileMs", "mainParseCompileMs")}}
    u, c = summary["uncached"].get("parseCompileMs_p50"), summary["cached"].get("parseCompileMs_p50")
    summary["cachedCutPct_p50"] = round(100 * (1 - c / u), 1) if u and c is not None else None
    with open(os.path.join(o.out, "summary.json"), "w") as f:
        json.dump(summary, f, indent=1)
    print(f"CHAT-COLD-OPEN summary {json.dumps(summary)}", flush=True)
    return 0 if summary["uncached"]["n"] and summary["cached"]["n"] else 1


if __name__ == "__main__":
    sys.exit(main())
