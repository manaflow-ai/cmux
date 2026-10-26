#!/usr/bin/env python3
"""Views an input turn dirties outside the event's target (p04-input-093, MQ-input-dirty-views).

Launches the tagged DEBUG (or bench) app itself on a GUI host (bench_launch.py: a scratch cmux.json, an isolated
Chief home, the app frontmost for real keys), installs the input-turn dirty-view recorder (`debug.input` action
`dirty`, InputDirtyRecorder in CmuxNextInput) and types --samples real keys (CGEventPost at the HID event tap, a
person's path) into each surface:

  home       the native Home composer (the Home fixture in a workspace of its own)
  omnibar    the omnibar of a Chromium tab
  terminal   a zsh prompt (`zsh -f`); in the stress session the measured workspace's last pane of STRESS
             (perf-stress-session.py: 60 workspaces, a 14-pane grid, 10 printing terminals)

Per surface it reads the recorder's report: every view or layer that got needsDisplay / setNeedsDisplay(_:) /
needsLayout / needsUpdateConstraints (NSView) or setNeedsDisplay / setNeedsLayout (CALayer) during a key's dispatch
or before that pass's commit, with its placement against the key's target (inside its subtree, outside it, in
another window), its stack, and the turn's dispatch and commit times. It then resets the recorder (`debug.input`
action `reset`, which removes the hooks). Frames in cmux's own images are resolved to function and file:line with
atos against the build's dSYM.

Writes --json (default artifacts/input-dirty-views.json): per run the surface, session, keys, turns and the
recorder's sites; and `rows`, the MQ-input-dirty-views rows: one per off-target (view class, first cmux frame),
with calls, turns, the surfaces and sessions it showed in and its stack. Each row is one fix task: the view should
not be dirtied by a key that does not change it.

  input-dirty-views.py --app APP --tag TAG --out DIR [--json FILE] [--surfaces home,omnibar,terminal]
      [--sessions light,stress] [--samples 60] [--input real|debug]
  input-dirty-views.py --self-test

--input debug types through `debug.key` (no input grant needed). Those keys reach the app through the control
socket, not the event queue, so the input tap may not see them as a person's turn: never publish its rows.

Fleet (an owned mini with a console and the input grant):
  nx-remote --needs input --app-from-fleet cmux --tag TAG --ref SHA -- \\
    python3 scripts/cmux-next/input-dirty-views.py --app "$NX_APP" --tag TAG --out "$NX_ARTIFACTS" \\
      --json "$NX_ARTIFACTS/input-dirty-views.json"
"""
import argparse
import collections
import glob
import json
import os
import re
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
WINDOW = (40, 40, 1400, 900)
CMUX_IMAGE = re.compile(r"^(CmuxNext|cmux|libcmux)", re.I)
# ANSI virtual key codes (Carbon kVK_ANSI_*) of the typed keys.
KEYCODES = {"a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
            "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45,
            "m": 46}
KEYS = "asdfghjklqwertyuiopzxcvbnm"


# ---------------------------------------------------------------- pure parts (self-tested)
def is_cmux_image(name):
    return bool(name) and bool(CMUX_IMAGE.match(name))


def first_cmux_frame(frames):
    """Index of the first frame in cmux's own images, or None."""
    for index, frame in enumerate(frames or []):
        if is_cmux_image(frame.get("image")):
            return index
    return None


def frame_label(frame, resolved):
    """`function (file:line)` from atos when resolved, else the dladdr symbol, else image+offset."""
    key = (frame.get("image"), frame.get("offset"))
    if key in resolved:
        return resolved[key]
    if frame.get("symbol"):
        return frame["symbol"]
    return f"{frame.get('image') or '?'}+{hex(frame.get('offset') or 0)}"


def rows_from_runs(runs, resolved=None):
    """The MQ rows: off-target sites of every run grouped by (view class, first cmux frame), worst first."""
    resolved = resolved or {}
    rows = {}
    for run in runs:
        for site in (run.get("report") or {}).get("sites") or []:
            if not site.get("off_target"):
                continue
            frames = site.get("frames") or []
            first = first_cmux_frame(frames)
            where = frame_label(frames[first], resolved) if first is not None else "(no cmux frame)"
            owner = site.get("view_class") or site.get("layer_class") or "?"
            row = rows.setdefault((owner, where), {
                "view_class": owner, "site": where, "count": 0, "turns": 0, "calls": set(), "placements": set(),
                "phases": set(), "surfaces": set(), "sessions": set(), "layer_classes": set(), "stack": [],
            })
            row["count"] += site.get("count") or 0
            row["turns"] += site.get("turns") or 0
            row["calls"].update(site.get("calls") or [])
            row["placements"].add(site.get("placement"))
            row["phases"].update(site.get("phases") or [])
            row["surfaces"].add(run.get("surface"))
            row["sessions"].add(run.get("session"))
            if site.get("layer_class"):
                row["layer_classes"].add(site["layer_class"])
            if not row["stack"]:
                row["stack"] = [frame_label(f, resolved) for f in frames[:12]]
    out = []
    for row in rows.values():
        out.append({k: sorted(x for x in v if x) if isinstance(v, set) else v for k, v in row.items()})
    out.sort(key=lambda r: (-r["turns"], -r["count"], r["view_class"], r["site"]))
    return out


def wanted_offsets(runs):
    """Per cmux image, the frame offsets to resolve."""
    wanted = collections.defaultdict(set)
    for run in runs:
        for site in (run.get("report") or {}).get("sites") or []:
            for frame in site.get("frames") or []:
                if is_cmux_image(frame.get("image")) and frame.get("offset") is not None:
                    wanted[frame["image"]].add(frame["offset"])
    return wanted


def summarize(run):
    report = run.get("report") or {}
    turns = report.get("turns") or {}
    return {
        "turns": turns.get("closed"), "dirty_calls": report.get("dirty_calls"),
        "off_target_calls": report.get("off_target_calls"), "dropped_calls": report.get("dropped_calls"),
        "off_target_sites": sum(1 for s in report.get("sites") or [] if s.get("off_target")),
        "dispatch_ms": turns.get("dispatch_ms"), "commit_ms": turns.get("commit_ms"),
    }


def self_test():
    frame = lambda image, offset, symbol=None: {"image": image, "offset": offset, "symbol": symbol}
    site = lambda view, off, frames, count=1, turns=1, placement="outside": {
        "view_class": view, "layer_class": None, "placement": placement, "off_target": off, "calls": ["view.needsLayout"],
        "turn_kinds": ["key"], "phases": ["dispatch"], "count": count, "turns": turns, "frames": frames}
    sidebar = [frame("AppKit", 16), frame("cmux DEV.debug.dylib", 0x1234, "SidebarRow.update()"), frame("cmux DEV.debug.dylib", 0x99)]
    runs = [
        {"surface": "home", "session": "light", "report": {"sites": [
            site("Sidebar.RowView", True, sidebar, count=5, turns=4),
            site("Composer.TextView", False, [frame("cmux DEV.debug.dylib", 0x10)], count=40, turns=40, placement="inside"),
        ]}},
        {"surface": "terminal", "session": "stress", "report": {"sites": [
            site("Sidebar.RowView", True, sidebar, count=3, turns=3),
            site("Strip.TabCell", True, [frame("AppKit", 4)], count=9, turns=2, placement="other_window"),
        ]}},
    ]
    resolved = {("cmux DEV.debug.dylib", 0x1234): "SidebarRow.update() (SidebarRow.swift:88)"}
    rows = rows_from_runs(runs, resolved)
    assert [r["view_class"] for r in rows] == ["Sidebar.RowView", "Strip.TabCell"], rows
    first = rows[0]
    assert first["site"] == "SidebarRow.update() (SidebarRow.swift:88)", first
    assert (first["count"], first["turns"]) == (8, 7), first
    assert first["surfaces"] == ["home", "terminal"] and first["sessions"] == ["light", "stress"], first
    assert first["stack"][0] == "AppKit+0x10", first["stack"]
    assert rows[1]["site"] == "(no cmux frame)" and rows[1]["placements"] == ["other_window"], rows[1]
    assert all(r["view_class"] != "Composer.TextView" for r in rows), "an inside site is no row"
    wanted = wanted_offsets(runs)
    assert set(wanted) == {"cmux DEV.debug.dylib"} and wanted["cmux DEV.debug.dylib"] == {0x1234, 0x99, 0x10}, wanted
    assert first_cmux_frame([frame("libswiftCore.dylib", 1)]) is None
    assert parse_atos("f() (in cmux) (A.swift:3)\n0x100\n", [1, 2]) == {1: "f() (A.swift:3)"}
    summary = summarize({"report": {"turns": {"closed": 3, "dispatch_ms": {"p50": 1}}, "dirty_calls": 4, "off_target_calls": 2,
                                    "dropped_calls": 0, "sites": runs[1]["report"]["sites"]}})
    assert summary["turns"] == 3 and summary["off_target_sites"] == 2, summary
    print("input-dirty-views self-test: ok")


def parse_atos(text, offsets):
    """atos output lines for `offsets`, in order: offset -> `function (file:line)`; unresolved lines left out."""
    resolved = {}
    for offset, line in zip(offsets, text.splitlines()):
        line = line.strip()
        if not line or line.startswith("0x"):
            continue
        resolved[offset] = re.sub(r" \(in [^)]+\)", "", line)
    return resolved


# ---------------------------------------------------------------- the live run
def app_images(app):
    images = {}
    for pattern in ("Contents/MacOS/*", "Contents/Frameworks/*.dylib", "Contents/Frameworks/*.framework/Versions/A/*"):
        for path in glob.glob(os.path.join(app, pattern)):
            if os.path.isfile(path) and is_cmux_image(os.path.basename(path)):
                images.setdefault(os.path.basename(path), path)
    return images


def symbolicate(app, runs):
    """(image, offset) -> `function (file:line)` for cmux frames: one atos run per image, against its dSYM when the
    build has one (any load address works: the offsets are from the image's header)."""
    images = app_images(app)
    dsyms = {os.path.basename(p): p for p in glob.glob(os.path.join(os.path.dirname(app), "*.dSYM/Contents/Resources/DWARF/*"))}
    dsyms.update({os.path.basename(p): p for p in glob.glob(os.path.join(app, "Contents/**/*.dSYM/Contents/Resources/DWARF/*"),
                                                             recursive=True)})
    resolved = {}
    base = 0x100000000
    for image, offsets in wanted_offsets(runs).items():
        binary = dsyms.get(image) or images.get(image)
        if not binary:
            continue
        offsets = sorted(offsets)
        run = subprocess.run(["atos", "-o", binary, "-l", hex(base)] + [hex(base + o) for o in offsets],
                             capture_output=True, text=True, timeout=300)
        resolved.update({(image, o): name for o, name in parse_atos(run.stdout, offsets).items()})
    return resolved


class Live:
    """One app launch and its socket."""

    def __init__(self, opts, out):
        sys.path.insert(0, HERE)
        from bench_launch import BenchApp  # noqa: E402 (macOS GUI hosts only)
        env = {"CMUX_NEXT_HANG_THRESHOLD_MS": "8"}
        if opts.input == "real":
            env["CMUX_NEXT_NO_ACTIVATE"] = None  # a real key goes to the frontmost app
        self.opts, self.out = opts, out
        self.bench = BenchApp(opts.app, out=out, config={"browser": {"defaultEngine": "chromium"}}, window=WINDOW,
                              log_name="app-dirty-views.log", env=env)
        self.socket = None
        self.cg = None
        self.log = []

    def note(self, text):
        print(text, flush=True)
        self.log.append(text)

    def launch(self):
        self.bench.launch(timeout=180, settle=5.0)
        self.socket = self.bench.socket
        return self.bench.process.pid

    def stop(self):
        self.bench.stop()

    def rpc(self, method, params=None, timeout=30):
        try:
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(timeout)
            conn.connect(self.socket)
            conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(1 << 22)
                if not chunk:
                    break
                buf += chunk
            conn.close()
            reply = json.loads(buf)
        except (OSError, ValueError) as error:
            return {"error": str(error)}
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}

    def action(self, name, args=None, target=None, settle=0.0, timeout=60):
        params = {"action": name, "args": args or {}, "focus": True, "origin": "script"}
        if target:
            params["target"] = target
        reply = self.rpc("action.run", params, timeout=timeout)
        if settle:
            time.sleep(settle)  # test harness: the layout settles before the next step
        return reply

    def bring_front(self):
        pid = self.bench.process.pid
        subprocess.run(["osascript", "-e",
                        f'tell application "System Events" to set frontmost of (first process whose unix id is {pid}) to true'],
                       capture_output=True, timeout=30)

    def post_key(self, key):
        """One real key press at the HID event tap (CGEventPost), as sidebar-churn-typing.py posts them."""
        import ctypes
        import ctypes.util
        if self.cg is None:
            self.cg = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreGraphics"))
            self.cg.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
            self.cg.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
            self.cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
            self.cg.CFRelease.argtypes = [ctypes.c_void_p]
        for down in (True, False):
            event = self.cg.CGEventCreateKeyboardEvent(None, KEYCODES[key], down)
            self.cg.CGEventPost(0, event)  # kCGHIDEventTap
            self.cg.CFRelease(event)

    def type_keys(self, count):
        for index in range(count):
            t0 = time.perf_counter()
            key = KEYS[index % len(KEYS)]
            if self.opts.input == "real":
                self.post_key(key)
            else:
                self.rpc("debug.key", {"key": key, "timestamp": time.clock_gettime(time.CLOCK_UPTIME_RAW)}, timeout=10)
            rest = self.opts.interval - (time.perf_counter() - t0)
            if rest > 0:
                time.sleep(rest)  # one key in flight at a time
        time.sleep(0.5)  # the last key's frame commits

    def workspace_named(self, name):
        snap = self.rpc("snapshot.get") or {}
        for w in (snap.get("topology") or snap).get("workspaces") or []:
            if (w.get("name") or w.get("title")) == name:
                panes = [p for sc in w.get("screens") or [] for p in sc.get("panes") or [] if not p.get("dock")]
                return w.get("id"), panes
        return None, []

    def new_workspace(self, name, shell=None):
        """A focused workspace named `name` through the app's own CLI, as typing-frame-bench.py makes them."""
        env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
        env["CMUX_NEXT_CONFIG_FILE"] = os.path.join(self.bench.scratch, "cmux.json")
        cli = os.path.join(os.path.abspath(self.opts.app), "Contents/Resources/bin/cmux")
        args = [cli, "--app-socket", self.socket, "workspace", "create", "--name", name, "--focus"]
        if shell:
            args += ["--shell", shell]
        subprocess.run(args, env=env, capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
        for _ in range(80):  # bounded wait for the workspace to show in the topology
            ws, panes = self.workspace_named(name)
            if ws:
                return ws, panes
            time.sleep(0.25)
        return None, []


def focus_home(live, state):
    if not state.get("home_ws"):
        state["home_ws"], _ = live.new_workspace("dirty home")
        live.action("goToWorkspace", {"workspace": state["home_ws"]}, settle=1.0)
        opened = live.rpc("debug.home_native_fixture.open", {"new": True})
        live.note(f"home fixture: {json.dumps(opened)[:160]}")
        time.sleep(2)  # the transcript lays out
    live.action("goToWorkspace", {"workspace": state["home_ws"]}, settle=0.5)
    focused = live.rpc("debug.home.drive", {"action": "focus"})
    return isinstance(focused, dict) and bool(focused.get("ok"))


def focus_omnibar(live, state):
    if not state.get("omnibar_open"):
        live.note(f"omnibar: {json.dumps(live.action('openBrowser.chromium', {'url': 'about:blank'}, settle=4.0, timeout=120))[:120]}")
        state["omnibar_open"] = True
    live.action("focusBrowserAddressBar", settle=0.5)
    return bool((live.rpc("debug.omnibar") or {}).get("field_editor_active"))


def focus_terminal(live, state):
    if not state.get("terminal_ws"):
        ws, panes = live.new_workspace("dirty typing", shell="exec /bin/zsh -f")
        state["terminal_ws"], state["terminal_pane"] = ws, (panes[0].get("id") if panes else None)
        time.sleep(2)  # the prompt draws
    live.action("goToWorkspace", {"workspace": state["terminal_ws"]})
    pane = state.get("stress_pane") or state.get("terminal_pane")
    if pane:
        live.action("pane.focus", target=f"pane:{pane}")
    time.sleep(0.5)  # focus settles
    return bool(state["terminal_ws"])


FOCUS = {"home": focus_home, "omnibar": focus_omnibar, "terminal": focus_terminal}


def build_stress(live, state):
    import importlib.util
    spec = importlib.util.spec_from_file_location("perf_stress_session", os.path.join(HERE, "perf-stress-session.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    stress = module.Stress(live.rpc, log=live.note)
    summary = stress.build()
    panes = stress.panes(stress.workspace(summary.get("measured")))
    if panes:
        last = panes[-1]
        stress.focus_pane(last["id"])
        tab = next((t for t in reversed(last.get("tabs") or []) if t.get("kind") == "terminal"), None)
        if tab:
            stress.action("tab.focus", target=f"tab:{tab['id']}")
            live.action("terminal.sendText", {"text": "exec /bin/zsh -f\r"})
            time.sleep(1)  # the prompt draws
        state["stress_pane"] = last["id"]
    state["terminal_ws"] = summary.get("measured")
    return summary


def measure(live, session, surface, state):
    if not FOCUS[surface](live, state):
        live.note(f"{session} {surface}: could not focus the surface")
        return {"session": session, "surface": surface, "error": "focus"}
    if live.opts.input == "real":
        live.bring_front()
        time.sleep(0.5)  # activation settles
    installed = live.rpc("debug.input", {"action": "dirty", "install": True})
    if isinstance(installed, dict) and installed.get("error"):
        live.note(f"{session} {surface}: debug.input dirty: {installed['error']}")
        return {"session": session, "surface": surface, "error": f"debug.input: {installed['error']}"}
    live.type_keys(live.opts.samples)
    report = live.rpc("debug.input", {"action": "dirty", "limit": 256}, timeout=60)
    live.rpc("debug.input", {"action": "reset"})
    if isinstance(report, dict) and "dirty" in report:
        report = report["dirty"]
    run = {"session": session, "surface": surface, "keys": live.opts.samples, "input": live.opts.input, "report": report}
    run["summary"] = summarize(run)
    live.note(f"{session} {surface}: {json.dumps(run['summary'])}")
    return run


def run_live(opts):
    out = os.path.abspath(opts.out)
    os.makedirs(out, exist_ok=True)
    json_path = opts.json or os.path.join(out, "input-dirty-views.json")
    results = {"tag": opts.tag, "host": os.uname().nodename, "opts": vars(opts), "runs": [], "log": []}
    for session in opts.sessions.split(","):
        live = Live(opts, out)
        state = {}
        try:
            live.launch()
            if session == "stress":
                results["stress"] = build_stress(live, state)
                time.sleep(5)  # the grid settles
            for surface in opts.surfaces.split(","):
                try:
                    results["runs"].append(measure(live, session, surface, state))
                except Exception as error:  # one surface failing must not hide the others
                    live.note(f"{session} {surface}: failed: {error!r}")
        finally:
            results["log"].extend(live.log)
            live.stop()
    resolved = symbolicate(os.path.abspath(opts.app), results["runs"])
    results["rows"] = rows_from_runs(results["runs"], resolved)
    results["publishable"] = opts.input == "real"
    with open(json_path, "w") as handle:
        json.dump(results, handle, indent=1)
    print(f"{len(results['rows'])} off-target rows -> {json_path}", flush=True)
    for row in results["rows"][:20]:
        print(f"  {row['turns']:4d} turns {row['count']:5d} calls  {row['view_class']}  at {row['site']}  "
              f"({','.join(row['surfaces'])}; {','.join(row['sessions'])})", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--app")
    parser.add_argument("--tag")
    parser.add_argument("--out")
    parser.add_argument("--json")
    parser.add_argument("--surfaces", default="home,omnibar,terminal")
    parser.add_argument("--sessions", default="light,stress")
    parser.add_argument("--samples", type=int, default=60)
    parser.add_argument("--interval", type=float, default=0.12, help="seconds between keys (one key in flight)")
    parser.add_argument("--input", choices=("real", "debug"), default="real")
    opts = parser.parse_args()
    if opts.self_test:
        self_test()
        return
    if not (opts.app and opts.tag and opts.out):
        parser.error("--app, --tag and --out are required (or --self-test)")
    unknown = set(opts.surfaces.split(",")) - set(FOCUS)
    if unknown:
        parser.error(f"unknown surfaces: {', '.join(sorted(unknown))}")
    run_live(opts)


if __name__ == "__main__":
    main()
