#!/usr/bin/env python3
"""Surface lifecycle stress for a tagged cmux-next build.

Runs random tab moves (to new splits, new columns, sibling panes), new tabs
and column scrolls through the app's control socket, samples `debug.surfaces`
after each one, and fails if any visible pane is blank once layout settles.

  scripts/cmux-next/surface-drag-stress.py --tag <tag> [--ops 20] [--seed 1] [--settle 0.05]

The tagged app must be running (launched with CMUX_NEXT_SOCKET_MODE=automation).
Samples taken `--settle` seconds after an op may catch a pane mid re-attach;
the pass criterion is the settled state: blank_panes == 0 and
invariant_violations == 0.
"""
import argparse, glob, json, os, random, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--ops", type=int, default=20)
parser.add_argument("--seed", type=int, default=1)
parser.add_argument("--settle", type=float, default=0.05)
parser.add_argument("--cli", help="cmux CLI inside the tagged app (default: found in DerivedData)")
opts = parser.parse_args()
OPS, SEED, SETTLE = opts.ops, opts.seed, opts.settle
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
CLI = opts.cli or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app/Contents/Resources/bin/cmux")))), None)
if not CLI:
    sys.exit(f"no tagged CLI for {opts.tag}; pass --cli")
random.seed(SEED)
# A clean environment: never inherit the caller's cmux workspace/surface ids.
ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "PATH": "/usr/bin:/bin",
       "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "CMUX_SOCKET_PATH": SOCKET}

def cli(*args, check=False):
    r = subprocess.run([CLI, "--socket", SOCKET, *args], capture_output=True, text=True, timeout=30, env=ENV)
    if check and r.returncode:
        raise RuntimeError(r.stderr or r.stdout)
    return r

def rpc(method, params=None):
    r = cli("rpc", method, json.dumps(params or {}))
    try:
        return json.loads(r.stdout)
    except Exception:
        return {"error": (r.stdout + r.stderr).strip()}

def run(action, tab=None, pane=None, args=None):
    p = {"action": action}
    if tab: p["target"] = {"kind": "tab", "id": tab}
    elif pane: p["target"] = {"kind": "pane", "id": pane}
    if args: p["args"] = args
    return rpc("action.run", p)

def topology():
    snap = rpc("snapshot.get")["topology"]
    ws = snap["windows"][0]["workspace"]
    w = next(w for w in snap["workspaces"] if w["id"] == ws)
    panes = [p for s in w["screens"] for p in s["panes"]]
    return panes

def surfaces():
    return rpc("debug.surfaces")

def blanks(report):
    out = []
    for w in report.get("windows", []):
        for p in w["panes"]:
            if p["blank"]:
                out.append(p)
    return out

log = []
# Seed: a few tabs.
for _ in range(3):
    cli("new-surface")
    time.sleep(0.3)
time.sleep(SETTLE)

total_blank = 0
for i in range(OPS):
    panes = topology()
    tabs = [(p["id"], t["id"]) for p in panes for t in p["tabs"]]
    op = random.choice(["split", "split", "column", "next", "prev", "newtab", "focusL", "focusR"])
    if len(tabs) < 3:
        op = "newtab"
    pane, tab = random.choice(tabs)
    if op == "split":
        res = run("tab.moveToNewSplit", tab=tab, args={"direction": random.choice(["left", "right", "up", "down"])})
    elif op == "column":
        res = run("tab.moveToNewColumn", tab=tab)
    elif op == "next":
        res = run("moveSurfaceToNextPane", tab=tab)
    elif op == "prev":
        res = run("moveSurfaceToPreviousPane", tab=tab)
    elif op == "newtab":
        r = cli("new-surface")
        res = {"error": r.stderr.strip()} if r.returncode else {}
    elif op == "focusL":
        res = run("column.focusLeft")
    else:
        res = run("column.focusRight")
    time.sleep(SETTLE)
    report = surfaces()
    b = blanks(report)
    total_blank += len(b)
    err = res.get("error") if isinstance(res, dict) else None
    line = f"op{i:02d} {op:7s} tab={tab[-6:]} panes={len(panes)} blank={len(b)} live={report.get('live_terminals')} viol={report.get('invariant_violations')}"
    if err: line += f" err={str(err)[:80]}"
    print(line, flush=True)
    for p in b:
        print("   BLANK", json.dumps(p), flush=True)

time.sleep(1.0)
final = surfaces()
result = {"transient_blank_samples": total_blank, "blank_panes": final.get("blank_panes"),
          "collapsed_panes": final.get("collapsed_panes"), "invariant_violations": final.get("invariant_violations"),
          "live_terminals": final.get("live_terminals")}
print(json.dumps(result))
sys.exit(0 if result["blank_panes"] == 0 and result["invariant_violations"] == 0 else 1)
