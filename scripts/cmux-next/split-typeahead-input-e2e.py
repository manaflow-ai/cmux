#!/usr/bin/env python3
"""Type-ahead after Cmd+D with real key events (cx-8w027.14 item 3; GUI host, `--needs input`).

The optimistic split shows its pane and takes the keyboard in the frame of Cmd+D; the daemon
confirms the pane later. Keys typed in between must reach the new pane, once, in order, and no
other pane. Unlike typeahead-compare.py (keys through `debug.key`, the app's router), every key
here is a real key-down posted to the app's process by CuaDriver (`hotkey`, `press_key`,
background delivery: the window is never brought to the front).

Each round: Cmd+D, then at once `echo tk<N>` + Return, key by key. Then (bounded wait) the new
pane's rendered viewport (`debug.surfaces` text) must hold the output line `tk<N>` exactly once,
and no other pane may show `tk<N>`, and only the new pane has focus. Odd rounds keep their pane,
so the next round splits a pane that was itself a provisional split; even rounds close back to one.

Usage (fleet-built Debug app, launched and quit by this script):
  nx-remote --needs input --input-reason "type-ahead after split" --app-from-fleet cmux --tag T --ref SHA \\
    -- 'python3 scripts/cmux-next/split-typeahead-input-e2e.py --app "$NX_APP" --out "$NX_ARTIFACTS" --rounds 8'
Exit 0 when every round passes.
"""
import argparse, importlib.util, json, os, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True, help="the `cmux DEV <tag>.app` bundle")
parser.add_argument("--out", default="/tmp")
parser.add_argument("--rounds", type=int, default=8)
parser.add_argument("--cua", default=os.path.expanduser("~/.local/bin/cua-driver"))
opts = parser.parse_args()

spec = importlib.util.spec_from_file_location("perf_gate", os.path.join(os.path.dirname(__file__), "perf-gate.py"))
perf_gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(perf_gate)


def cua(tool, args):
    done = subprocess.run([opts.cua, "call", tool, json.dumps(args)], capture_output=True, text=True, timeout=30)
    if done.returncode != 0 or '"candidates"' in done.stdout:
        raise SystemExit(f"cua {tool} did not post: {(done.stdout + done.stderr)[:300]}")
    try:
        return json.loads(done.stdout)
    except ValueError:
        return {}


def panes(app):
    """{pane key: (focused, viewport text)} of every pane the app shows."""
    out = {}
    for window in (app.rpc("debug.surfaces", {"text": True}) or {}).get("windows") or []:
        for pane in window.get("panes") or []:
            text = (pane.get("surface") or {}).get("text") or pane.get("text") or ""
            out[pane.get("pane")] = (bool(pane.get("focused")), text)
    return out


def main():
    os.makedirs(opts.out, exist_ok=True)
    app = perf_gate.App(opts.app, opts.out)
    rows, failed = [], 0
    try:
        app.launch()
        pid = app.process.pid
        windows = cua("list_windows", {"pid": pid}).get("windows") or []
        area = lambda w: (w.get("bounds") or {}).get("width", 0) * (w.get("bounds") or {}).get("height", 0)
        if not windows:
            raise SystemExit("no window for the app's pid")
        window = max(windows, key=area)["window_id"]
        key = lambda name: cua("press_key", {"pid": pid, "window_id": window, "key": name, "delivery_mode": "background"})
        for n in range(1, opts.rounds + 1):
            marker = f"tk{n}"
            before = panes(app)
            cua("hotkey", {"pid": pid, "window_id": window, "keys": ["cmd", "d"], "delivery_mode": "background"})
            for ch in "echo " + marker:
                key("space" if ch == " " else ch)
            key("return")
            row = {"round": n, "marker": marker}
            deadline = time.monotonic() + 8
            while True:  # bounded: the shell starts and prints the line
                now = panes(app)
                new = [p for p in now if p not in before]
                shows = {p: [line.strip() for line in text.splitlines()].count(marker) for p, (_, text) in now.items()}
                if new and shows.get(new[0]) == 1 or time.monotonic() > deadline:
                    break
                time.sleep(0.1)  # test script: polls the live app's viewport
            row.update(new=new, focused=[p for p, (f, _) in now.items() if f],
                       elsewhere=sorted(p for p, (_, text) in now.items() if marker in text and p not in new))
            row["ok"] = len(new) == 1 and shows.get(new[0]) == 1 and not row["elsewhere"] and row["focused"] == new
            if not row["ok"]:
                failed += 1
                row["new_text"] = [l for l in now.get(new[0], (False, ""))[1].splitlines() if l.strip()][-6:] if new else []
            print(json.dumps(row), flush=True)
            rows.append(row)
            if n % 2 == 0:  # back to one pane (an action, not input), so panes stay wide enough for a line
                while len(panes(app)) > 1:
                    count = len(panes(app))
                    app.action("closePane", {})
                    if not perf_gate.wait(lambda: len(panes(app)) < count, 15):
                        raise SystemExit("closePane did not close a pane")
    finally:
        app.stop()
    with open(os.path.join(opts.out, "split-typeahead-input.json"), "w") as f:
        json.dump(rows, f, indent=1)
    print(f"split-typeahead-input: {len(rows) - failed}/{len(rows)} rounds ok", flush=True)
    return 1 if failed or not rows else 0


if __name__ == "__main__":
    sys.exit(main())
