#!/usr/bin/env python3
"""Command + scroll pans the columns strip at full refresh (layout.scrollModifier, Lawrence 2026-10-24).

Launches a tagged DEV app (bench_launch.py) and, light (one workspace) and STRESS (perf-stress-session.py),
gives the active workspace strip columns that overflow the window (`newColumn`, --columns more). Then per
round it pans the strip with one trackpad gesture over a pane, Command held (`debug.mouse` scroll with
`modifiers: ["cmd"]`: began, --steps changes of --dx points one display frame apart, ended), and records the
display frames from the gesture's start until the strip's spring rests (`debug.frames`): intervals p50/p95/max,
missed vsyncs (an interval over 1.5 refresh periods) and the refresh rate. Rounds alternate the direction.

Each event's reply says who took it (`delivered_to`): every Command event must reach the layout
(LayoutRootView), and a control gesture with no Command over the same pane must reach none of it (the pane
keeps a plain scroll). Either check failing fails the run, so a pan that never moved is never a frame number.

Usage: bench-command-pan.py --app APP --out DIR [--json PATH] [--sessions light,stress] [--rounds 6]
       [--steps 40] [--dx 24] [--columns 3]
Fleet: scripts/measure/split-spring.sh --suite=command-pan --vdisplay=120 [--sessions=...] [--rounds=N]
"""
import argparse, importlib.util, json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import BenchApp  # noqa: E402

parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
parser.add_argument("--app", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--json")
parser.add_argument("--tag")  # split-spring passes it; the app's name carries the tag
parser.add_argument("--sessions", default="light,stress")
parser.add_argument("--rounds", type=int, default=6)
parser.add_argument("--steps", type=int, default=40)
parser.add_argument("--dx", type=float, default=24)
parser.add_argument("--columns", type=int, default=3, help="strip columns added to the measured workspace")
parser.add_argument("--settle", type=float, default=1.0, help="seconds after the gesture for the spring to rest")
opts, _unknown = parser.parse_known_args()


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

    def gesture(self, pane, dx, command):
        """One trackpad gesture over `pane`; returns the `delivered_to` of each event."""
        modifiers = ["cmd"] if command else []
        period = 1 / 120  # test harness: one event per 120 Hz frame, like a trackpad
        delivered = []

        def send(phase, delta, hover=True):
            reply = self.app.rpc("debug.mouse", {"action": "scroll", "pane": pane, "dx": delta, "dy": 0, "phase": phase,
                                                  "modifiers": modifiers, "hover": hover}) or {}
            delivered.append(reply.get("delivered_to") or reply.get("error") or "?")

        send("began", dx)
        for _ in range(opts.steps):
            time.sleep(period)
            send("changed", dx, hover=False)
        send("ended", 0, hover=False)
        return delivered


def measure(app, name, session, panes, report):
    # Over the focused pane: the newest column, on screen; the pan moves every column (STRESS: the 14-pane grid too).
    pane = (session.stress.topology().get("focus") or {}).get("pane") or panes[-1]["id"]
    control = session.gesture(pane, opts.dx, command=False)
    time.sleep(opts.settle)
    control_taken = sum(1 for d in control if d == "LayoutRootView")
    runs = []
    for index in range(opts.rounds):
        dx = opts.dx if index % 2 == 0 else -opts.dx
        app.rpc("debug.frames", {"action": "start"})
        delivered = session.gesture(pane, dx, command=True)
        time.sleep(opts.settle)
        frames = app.rpc("debug.frames", {"action": "stop"}) or {}
        taken = sum(1 for d in delivered if d == "LayoutRootView")
        run = {"session": name, "round": index, "dx": dx, "events": len(delivered), "layout_took": taken,
               "frames": frames.get("frames"), "refresh_ms": frames.get("refresh_ms"), "p50_ms": frames.get("p50_ms"),
               "p95_ms": frames.get("p95_ms"), "max_ms": frames.get("max_ms"), "missed": frames.get("missed"),
               "missed_at_ms": frames.get("missed_at_ms")}
        runs.append(run)
        print(f"  {name:<6} #{index} dx {dx:+.0f}: layout took {taken}/{len(delivered)}, {run['frames']} frames, "
              f"p95 {run['p95_ms']} max {run['max_ms']} ms, missed {run['missed']} (refresh {run['refresh_ms']} ms)", flush=True)
    report["runs"].extend(runs)
    row = {"session": name, "rounds": len(runs), "refresh_ms": pct([r["refresh_ms"] for r in runs], 0.5),
           "missed_total": sum(r["missed"] or 0 for r in runs), "frames_total": sum(r["frames"] or 0 for r in runs),
           "p95_ms": pct([r["p95_ms"] for r in runs], 0.5), "max_ms": pct([r["max_ms"] for r in runs], 1.0),
           "command_events_to_layout": sum(r["layout_took"] for r in runs), "command_events": sum(r["events"] for r in runs),
           "plain_events_to_layout": control_taken, "plain_events": len(control)}
    report["summary"].append(row)
    problems = []
    if row["command_events_to_layout"] != row["command_events"]:
        problems.append(f"{name}: {row['command_events'] - row['command_events_to_layout']} Command events missed the layout")
    if control_taken:
        problems.append(f"{name}: the layout took {control_taken} plain events over a pane")
    if not row["frames_total"]:
        problems.append(f"{name}: no frames drawn")
    report["problems"].extend(problems)
    print("COMMAND-PAN " + json.dumps(row), flush=True)


def main():
    os.makedirs(opts.out, exist_ok=True)
    report = {"runs": [], "summary": [], "problems": []}
    app = BenchApp(opts.app, out=opts.out, window=(40, 40, 1600, 1000))
    stress_module = load_stress()
    try:
        app.launch(timeout=180, settle=3)
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
