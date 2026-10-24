#!/usr/bin/env python3
"""Command + scroll pans the columns strip at full refresh (layout.scrollModifier, Lawrence 2026-10-24).

Launches a tagged DEV app (bench_launch.py) and, light (one workspace) and STRESS (perf-stress-session.py),
gives the active workspace strip columns that overflow the window (`newColumn`, --columns more). Then per
round it pans the strip with one trackpad gesture over a pane, Command held (`debug.mouse` scroll with
`modifiers: ["cmd"]`: began, --steps changes of --dx points one display frame apart, ended), and records the
display frames from the gesture's start until the strip's spring rests (`debug.frames`): intervals p50/p95/max,
missed vsyncs (an interval over 1.5 refresh periods) and the refresh rate. Rounds alternate the direction.

The pointer stays at one window point per session (the focused pane's center when the session starts, from
`debug.mouse hover`), as a person's pointer does while the strip moves under it. Each event's reply says who
took it (`delivered_to`): every Command event must reach the layout (LayoutRootView), and a control gesture
with no Command at that point must reach none of it (the pane keeps a plain scroll). Either check failing
fails the run, so a pan that never moved is never a frame number.

Base rounds (same build, same session): `layout.scrollModifier` set to `none` (settings.set) and plain
gestures, the strip pan before this setting existed. Command and base rounds alternate in an ABBA order, so
a drift during the session falls on both alike; the setting ends at `command`. Rows `"mode": "command"` and
`"mode": "base"`; compare their p95 and missed frames.

--target picks the pane under the pointer:
  terminal  (default) the terminal that newColumn made: the layout's own window path.
  chromium  a Chromium page opened in that pane (openBrowser.chromium on a local page); the events go to the
            page's own child window (`debug.mouse` scroll with `target: "page"`), the route a real gesture
            over a Chromium page takes (LayoutRootView's page-window routing, CEFSwipeNavigation). Before
            any number, `debug.cef` must show no unavailable state and no WebKit fallback, or the run fails.

--dry-run launches nothing: it parses the arguments and checks every call this script makes on BenchApp
(bench_launch.py), on the STRESS builder and on its module (perf-stress-session.py) against their real
signatures, read from this file's syntax tree. Exit 1 names each call that would raise a TypeError. Run it,
with `python3 -I -m py_compile`, before a fleet submit (a wrong keyword failed one 120 Hz step after a full
app build).

Usage: bench-command-pan.py --app APP --out DIR [--json PATH] [--sessions light,stress] [--rounds 6]
       [--steps 40] [--dx 24] [--columns 3] [--target terminal|chromium]
       bench-command-pan.py --dry-run
Fleet: scripts/measure/split-spring.sh --suite=command-pan --vdisplay=120 [--sessions=...] [--rounds=N]
"""
import argparse, ast, importlib.util, inspect, json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import BenchApp  # noqa: E402

parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
parser.add_argument("--dry-run", action="store_true", help="check the calls against the real signatures; launch nothing")
parser.add_argument("--app")
parser.add_argument("--out")
parser.add_argument("--json")
parser.add_argument("--tag")  # split-spring passes it; the app's name carries the tag
parser.add_argument("--sessions", default="light,stress")
parser.add_argument("--rounds", type=int, default=6)
parser.add_argument("--steps", type=int, default=40)
parser.add_argument("--dx", type=float, default=24)
parser.add_argument("--columns", type=int, default=3, help="strip columns added to the measured workspace")
parser.add_argument("--settle", type=float, default=1.0, help="seconds after the gesture for the spring to rest")
parser.add_argument("--target", choices=("terminal", "chromium"), default="terminal", help="what the pointer is over")
opts, _unknown = parser.parse_known_args()
if not opts.dry_run and not (opts.app and opts.out):
    parser.error("--app and --out are required (or --dry-run)")


def load_stress():
    spec = importlib.util.spec_from_file_location("perf_stress_session", os.path.join(HERE, "perf-stress-session.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def pct(values, q):
    values = sorted(v for v in values if isinstance(v, (int, float)))
    if not values:
        return None
    return round(values[min(len(values) - 1, int(round((len(values) - 1) * q)))], 2)


class Session:
    def __init__(self, app, stress_module):
        self.app = app
        self.stress_module = stress_module
        self.stress = stress_module.Stress(lambda m, p=None, timeout=60: app.rpc(m, p, timeout))

    def workspace(self):
        return self.stress.workspace(self.stress.focused_workspace())

    def overflow(self):
        """Adds --columns strip columns to the shown workspace: the strip overflows the window."""
        before = len(self.stress.panes(self.workspace()))
        for _ in range(opts.columns):
            self.stress.action("newColumn", settle=0.5)  # test script: the new column's motion lands first
        after = self.stress.panes(self.workspace())
        if len(after) < before + opts.columns:
            raise RuntimeError(f"newColumn made {len(after) - before} of {opts.columns} columns: {self.stress.refusals[-3:]}")
        return after

    def chromium_page(self, pane):
        """Opens a Chromium page in `pane` (selected) and checks debug.cef; raises when it is not Chromium."""
        workspace = self.stress.focused_workspace()
        self.stress.add_tab(workspace, pane, "chromium")
        problems = self.stress_module.cef_problems(self.app.rpc("debug.cef"), self.stress_module.WEB_DEV_CONFIG)
        if problems:
            raise RuntimeError(f"the page is not Chromium: {problems}")
        return problems

    def point(self, pane):
        """The window point (top-left points) of `pane`'s center now; the gestures keep it."""
        reply = self.app.rpc("debug.mouse", {"action": "hover", "pane": pane}) or {}
        if not isinstance(reply.get("x"), (int, float)) or not isinstance(reply.get("y"), (int, float)):
            raise RuntimeError(f"no point for pane {pane}: {str(reply)[:160]}")
        return {"x": reply["x"], "y": reply["y"]}

    def gesture(self, point, dx, command):
        """One trackpad gesture at the window `point`; returns the `delivered_to` of each event."""
        modifiers = ["cmd"] if command else []
        page = {"target": "page"} if opts.target == "chromium" else {}
        period = 1 / 120  # test harness: one event per 120 Hz frame, like a trackpad
        delivered = []

        def send(phase, delta, hover=True):
            reply = self.app.rpc("debug.mouse", {"action": "scroll", **point, "dx": delta, "dy": 0, "phase": phase,
                                                  "modifiers": modifiers, "hover": hover, **page}) or {}
            delivered.append(reply.get("delivered_to") or reply.get("error") or "?")

        send("began", dx)
        for _ in range(opts.steps):
            time.sleep(period)
            send("changed", dx, hover=False)
        send("ended", 0, hover=False)
        return delivered


def pan_round(app, name, mode, index, session, point):
    """One pan at `point`: with Command (`command`), or plain under `layout.scrollModifier: none` (`base`).
    Returns the round's record."""
    dx = opts.dx if index % 2 == 0 else -opts.dx
    app.rpc("debug.frames", {"action": "start"})
    delivered = session.gesture(point, dx, command=mode == "command")
    time.sleep(opts.settle)  # bench harness: the frames run until the strip's spring rests
    frames = app.rpc("debug.frames", {"action": "stop"}) or {}
    taken = sum(1 for d in delivered if d == "LayoutRootView")
    run = {"session": name, "mode": mode, "round": index, "dx": dx, "events": len(delivered), "layout_took": taken,
           "frames": frames.get("frames"), "refresh_ms": frames.get("refresh_ms"), "p50_ms": frames.get("p50_ms"),
           "p95_ms": frames.get("p95_ms"), "max_ms": frames.get("max_ms"), "missed": frames.get("missed"),
           "missed_at_ms": frames.get("missed_at_ms")}
    print(f"  {name:<6} {mode:<7} #{index} dx {dx:+.0f}: layout took {taken}/{len(delivered)}, {run['frames']} frames, "
          f"p95 {run['p95_ms']} max {run['max_ms']} ms, missed {run['missed']} (refresh {run['refresh_ms']} ms)", flush=True)
    return run


def summarize(name, mode, runs, report):
    """The row of one mode's rounds, checked: every event reached the layout and frames were drawn."""
    report["runs"].extend(runs)
    row = {"session": name, "mode": mode, "target": opts.target, "rounds": len(runs),
           "refresh_ms": pct([r["refresh_ms"] for r in runs], 0.5),
           "missed_total": sum(r["missed"] or 0 for r in runs), "frames_total": sum(r["frames"] or 0 for r in runs),
           "p95_ms": pct([r["p95_ms"] for r in runs], 0.5), "max_ms": pct([r["max_ms"] for r in runs], 1.0),
           "events_to_layout": sum(r["layout_took"] for r in runs), "events": sum(r["events"] for r in runs)}
    report["summary"].append(row)
    if row["events_to_layout"] != row["events"]:
        report["problems"].append(f"{name} {mode}: {row['events'] - row['events_to_layout']} events missed the layout")
    if not row["frames_total"]:
        report["problems"].append(f"{name} {mode}: no frames drawn")
    print("COMMAND-PAN " + json.dumps(row), flush=True)
    return row


def set_modifier(app, value):
    """Sets `layout.scrollModifier` in the bench app's own scratch config (settings.set)."""
    reply = app.rpc("settings.set", {"path": "layout.scrollModifier", "value": value}) or {}
    if isinstance(reply, dict) and reply.get("error"):
        raise RuntimeError(f"settings.set layout.scrollModifier {value}: {str(reply['error'])[:160]}")


def measure(app, name, session, panes, report):
    # Over the focused pane's center (the newest column, on screen), kept for the whole session; the pan moves
    # every column under it (STRESS: the 14-pane grid too).
    pane = (session.stress.topology().get("focus") or {}).get("pane") or panes[-1]["id"]
    if opts.target == "chromium":
        report.setdefault("cef_checked", []).append({"session": name, "pane": pane, "problems": session.chromium_page(pane)})
    point = session.point(pane)
    control = session.gesture(point, opts.dx, command=False)
    time.sleep(opts.settle)  # bench harness: a control that wrongly panned rests before the next gesture
    control_taken = sum(1 for d in control if d == "LayoutRootView")
    report["summary"].append({"session": name, "mode": "control", "plain_events_to_layout": control_taken,
                              "plain_events": len(control)})
    if control_taken:
        report["problems"].append(f"{name}: the layout took {control_taken} plain events over a pane")
    # The two modes alternate in an ABBA order (command, base, base, command, ...), so a drift during the
    # session (a warming cache, a host getting busy) falls on both modes alike instead of on the one that ran last.
    runs = {"command": [], "base": []}
    try:
        for index in range(opts.rounds):
            for mode in (("command", "base") if index % 2 == 0 else ("base", "command")):
                set_modifier(app, "command" if mode == "command" else "none")
                runs[mode].append(pan_round(app, name, mode, index, session, point))
    finally:
        set_modifier(app, "command")
    for mode in ("command", "base"):
        summarize(name, mode, runs[mode], report)


def dry_run():
    """Binds every call on BenchApp, the STRESS builder and its module in this file to the real signature.

    Receivers are named by how this file reaches them: `app.m(...)` and `BenchApp(...)` (bench_launch.BenchApp),
    `<x>.stress.m(...)` (perf_stress_session.Stress), `<x>.stress_module.f(...)` / `stress_module.f(...)` (the
    module). A call with *args or **kwargs is skipped (it cannot be bound statically) and counted."""
    stress_module = load_stress()
    tree = ast.parse(open(os.path.abspath(__file__)).read())
    problems, checked, skipped = [], 0, 0

    def target(call):
        func = call.func
        if isinstance(func, ast.Name) and func.id == "BenchApp":
            return "BenchApp", BenchApp.__init__, True
        if not isinstance(func, ast.Attribute):
            return None
        owner = func.value
        name = owner.id if isinstance(owner, ast.Name) else owner.attr if isinstance(owner, ast.Attribute) else None
        if name == "app" and hasattr(BenchApp, func.attr):
            return f"BenchApp.{func.attr}", getattr(BenchApp, func.attr), True
        if name == "stress" and hasattr(stress_module.Stress, func.attr):
            member = inspect.getattr_static(stress_module.Stress, func.attr)
            return f"Stress.{func.attr}", getattr(stress_module.Stress, func.attr), not isinstance(member, staticmethod)
        if name == "stress_module" and hasattr(stress_module, func.attr) and callable(getattr(stress_module, func.attr)):
            value = getattr(stress_module, func.attr)
            return f"perf_stress_session.{func.attr}", value.__init__ if inspect.isclass(value) else value, inspect.isclass(value)
        return None

    for call in (node for node in ast.walk(tree) if isinstance(node, ast.Call)):
        found = target(call)
        if not found:
            continue
        label, function, bound = found
        if any(isinstance(a, ast.Starred) for a in call.args) or any(k.arg is None for k in call.keywords):
            skipped += 1
            continue
        args = ([None] if bound else []) + [None] * len(call.args)
        try:
            inspect.signature(function).bind(*args, **{k.arg: None for k in call.keywords})
            checked += 1
        except TypeError as error:
            problems.append(f"line {call.lineno}: {label}: {error}")
    for line in problems:
        print("DRY-RUN " + line, flush=True)
    print(f"DRY-RUN {'FAIL' if problems else 'PASS'}: {checked} calls bound, {skipped} skipped, {len(problems)} wrong", flush=True)
    return 1 if problems or not checked else 0


def main():
    if opts.dry_run:
        return dry_run()
    os.makedirs(opts.out, exist_ok=True)
    report = {"runs": [], "summary": [], "problems": []}
    app = BenchApp(opts.app, out=opts.out, window=(40, 40, 1600, 1000))
    stress_module = load_stress()
    try:
        app.launch(timeout=180)
        session = Session(app, stress_module)
        for name in opts.sessions.split(","):
            if name == "stress":
                report["stress_session"] = session.stress.build()
            panes = session.overflow()
            measure(app, name, session, panes, report)
    except Exception as error:  # the run fails with the reason in the report
        report["problems"].append(f"{type(error).__name__}: {error}")
    finally:
        app.stop()
        if opts.json:
            with open(opts.json, "w") as f:
                json.dump(report, f, indent=1)
    print("RESULT " + ("PASS" if report["summary"] and not report["problems"] else "FAIL " + json.dumps(report["problems"])), flush=True)
    return 0 if report["summary"] and not report["problems"] else 1


if __name__ == "__main__":
    sys.exit(main())
