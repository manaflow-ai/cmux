#!/usr/bin/env python3
"""Type-ahead after Cmd+D with real key events (cx-8w027.14 item 3; GUI host, `--needs input`).

The optimistic split shows its pane and takes the keyboard in the frame of Cmd+D; the daemon
confirms the pane later. Keys typed in between must reach the new pane, once, in order, and no
other pane. Unlike typeahead-compare.py (keys through `debug.key`, the app's router), every key
here is a real key-down posted to the app's process by CuaDriver (`hotkey`, `press_key`,
background delivery: the window is never brought to the front).

Each round: Cmd+D, then at once `echo tk<N>` + Return, key by key. Then (bounded wait) the new
terminal's daemon screen (`read-screen` on the daemon socket) must hold the output line `tk<N>` exactly
once, and no other terminal may show `tk<N>`, and only the new pane has focus. Odd rounds keep their pane,
so the next round splits a pane that was itself a provisional split; even rounds close back to one.

Usage (fleet-built Debug app, launched and quit by this script):
  nx-remote --needs input --input-reason "type-ahead after split" --app-from-fleet cmux --tag T --ref SHA \\
    -- 'python3 scripts/cmux-next/split-typeahead-input-e2e.py --app "$NX_APP" --out "$NX_ARTIFACTS" --rounds 8'
Exit 0 when every round passes.
"""
import argparse, glob, importlib.util, json, os, socket, stat, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True, help="the `cmux DEV <tag>.app` bundle")
parser.add_argument("--out", default="/tmp")
parser.add_argument("--rounds", type=int, default=8)
parser.add_argument("--cua", default=os.path.expanduser("~/.local/bin/cua-driver"))
parser.add_argument("--diag", action="store_true")
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
    """{pane key: focused} of every pane the app shows."""
    return {pane.get("pane"): bool(pane.get("focused"))
            for window in (app.rpc("debug.surfaces") or {}).get("windows") or [] for pane in window.get("panes") or []}


def daemon(app, request):
    """One request on the app's cmux-tui daemon socket (as cmd-t-focus-e2e.py finds it)."""
    # perf-gate's App gives the app TMPDIR (or /tmp); its daemon makes the socket under it.
    temps = [os.environ.get("TMPDIR", "/tmp"), "/tmp",
             subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()]
    found = [p for t in temps for p in glob.glob(os.path.join(t, f"cmux-tui-{os.getuid()}", f"cmux-app-{app.tag}*")) if stat.S_ISSOCK(os.stat(p).st_mode)]
    if not found:
        raise SystemExit(f"no daemon socket cmux-app-{app.tag}* under {temps}")
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(10)
    conn.connect(found[0])
    conn.sendall((json.dumps(dict(request, id=1)) + "\n").encode())
    buf = b""
    while b"\n" not in buf:
        chunk = conn.recv(1 << 22)
        if not chunk:
            break
        buf += chunk
    conn.close()
    return json.loads(buf.split(b"\n")[0]).get("data") or {}


def screens(app):
    """{surface: lines of its daemon screen} of every confirmed terminal tab the app shows: what the shells got."""
    tabs = [tab for w in app.topology().get("workspaces") or [] for sc in w.get("screens") or []
            for pane in sc.get("panes") or [] for tab in pane.get("tabs") or [] if tab.get("kind") == "terminal"]
    # A provisional split's surface (>= 2^62) is the app's own until the daemon confirms the pane.
    surfaces = [int(t["surface"]) for t in tabs if str(t.get("surface", "")).isdigit() and int(t["surface"]) < 1 << 62]
    return {s: [line.strip() for line in (daemon(app, {"cmd": "read-screen", "surface": s}).get("text") or "").splitlines()]
            for s in surfaces}


def main():
    os.makedirs(opts.out, exist_ok=True)
    app = perf_gate.App(opts.app, opts.out)
    rows, failed = [], 0
    try:
        app.launch()
        if opts.diag:  # data shapes only (no input): a split by action, then what the reads see
            app.action("splitRight", {})
            perf_gate.wait(lambda: len(panes(app)) > 1, 15)
            time.sleep(2)  # test script: the new shell starts
            tabs = [t for w in app.topology().get("workspaces") or [] for sc in w.get("screens") or []
                    for p in sc.get("panes") or [] for t in p.get("tabs") or []]
            print(json.dumps(tabs)[:1500], flush=True)
            print(json.dumps({str(k): v[-4:] for k, v in screens(app).items()})[:1500], flush=True)
            return 0
        pid = app.process.pid
        # Cmd+D from a terminal splits a terminal (from a page it opens the New Tab page): a new workspace.
        app.rpc("action.run", {"action": "workspace.newAtBottom", "focus": True, "wait": True})
        if not perf_gate.wait(lambda: screens(app) and any(panes(app).values()), 30):
            raise SystemExit("the new workspace's terminal never showed")
        baseline = len(panes(app))
        windows = cua("list_windows", {"pid": pid}).get("windows") or []
        area = lambda w: (w.get("bounds") or {}).get("width", 0) * (w.get("bounds") or {}).get("height", 0)
        if not windows:
            raise SystemExit("no window for the app's pid")
        window = max(windows, key=area)["window_id"]
        key = lambda name: cua("press_key", {"pid": pid, "window_id": window, "key": name, "delivery_mode": "background"})
        for n in range(1, opts.rounds + 1):
            marker = f"tk{n}"
            before, terms_before = panes(app), set(screens(app))
            cua("hotkey", {"pid": pid, "window_id": window, "keys": ["cmd", "d"], "delivery_mode": "background"})
            for ch in "echo " + marker:
                key("space" if ch == " " else ch)
            key("return")
            row = {"round": n, "marker": marker}
            deadline = time.monotonic() + 8
            while True:  # bounded: the shell starts and prints the line
                now, text = panes(app), screens(app)
                new = [p for p in now if p not in before]
                made = [t for t in text if t not in terms_before]
                if made and text[made[0]].count(marker) == 1 or time.monotonic() > deadline:
                    break
                time.sleep(0.2)  # test script: polls the daemon's screens
            if not text:
                print(f"no terminal tabs: {json.dumps(app.topology())[:600]}", flush=True)
            row.update(new=new, terminal=made, focused=[p for p, f in now.items() if f],
                       elsewhere=sorted(t for t, lines in text.items() if t not in made and any(marker in l for l in lines)))
            row["ok"] = (len(new) == 1 and len(made) == 1 and text[made[0]].count(marker) == 1
                         and not row["elsewhere"] and row["focused"] == new)
            if not row["ok"]:
                failed += 1
                row["screen"] = [l for l in text.get(made[0], []) if l][-6:] if made else []
                row["tabs"] = [{k: t.get(k) for k in ("id", "kind", "surface", "terminal", "title")}
                               for w in app.topology().get("workspaces") or [] for sc in w.get("screens") or []
                               for p in sc.get("panes") or [] if p.get("id") in new for t in p.get("tabs") or []]
                row["surfaces"] = sorted(text)
            print(json.dumps(row), flush=True)
            rows.append(row)
            if n % 2 == 0:  # back to one pane (an action, not input), so panes stay wide enough for a line
                while len(panes(app)) > baseline:
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
