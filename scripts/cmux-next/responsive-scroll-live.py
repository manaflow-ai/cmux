#!/usr/bin/env python3
"""A main-thread stall during momentum still scrolls the sidebar and the palette results (p03-rendering-110).

Launches the tagged app twice (bench_launch.BenchApp), once with feature `responsiveScrolling` on and once off (a
Labs local choice), and per target (`sidebar`: the workspace list grown to --workspaces rows; `palette`: the command
palette's results) posts real trackpad gestures at the HID tap (hid_input.HidPoster.scroll_gesture: began, changed
events, ended, decaying momentum) at the list's center while the app reads the list's composited frames off its main
thread (`debug.scroll_frames`):

  travel   one gesture, no stall: the clip's travel. The on arm must travel what the off arm does (within
           --travel-slack points), so the held start of a gesture railed vertical reaches the list once.
  stall    the same gesture with `debug.stall --stall-ms` on the main thread from the third momentum event. A
           frame read inside the stall (after one display frame of it, before its end; both CLOCK_UPTIME_RAW) that
           differs from the frame before it shows the list moved while the main thread was blocked.

Passes (exit 0) when, on the on arm, every measured target moved during the stall and traveled as on the off arm.
The off arm is the red: its sidebar scrolls on the main thread and must not move during the stall (a mismatch is
reported, `off_arm_red`, and fails the run, since then the check would prove nothing). The palette's results have
no scrollWheel override, so AppKit scrolls them responsively on both arms; the off arm reports them only.

Real input needs the GUI session and the Accessibility grant, as scroll-jank-bench.py's.

  responsive-scroll-live.py --app APP --out DIR [--json FILE] [--tag TAG] [--targets sidebar,palette]
      [--workspaces 200] [--stall-ms 50] [--rate 120] [--changes 30] [--momentum 24] [--delta 12]
  responsive-scroll-live.py --self-test

Fleet (builds the app at SHA, then runs this):
  cmux-ci run --class exclusive --label measure --script scripts/measure/split-spring.sh --ref SHA \\
    --artifact artifacts/split-spring/report.json --arg=--suite=responsive-scroll
"""
import argparse, json, os, sys, tempfile, threading, time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hid_input  # noqa: E402

FEATURE = "responsiveScrolling"
TARGETS = ("sidebar", "palette")
WINDOW = (40, 40, 1400, 900)
# A frame differs from the one before when this share of its pixels changed (rows moved, not noise).
CHANGED = 0.01
# The first display frame of a stall may still show what was committed before it.
FRAME_NS = 17_000_000


def expected_travel(opts):
    """The points one gesture posts (hid_input.HidPoster.scroll_gesture's changed and momentum deltas)."""
    momentum = sum(abs(round(opts.delta * 0.9 ** (index + 1))) for index in range(opts.momentum))
    return opts.changes * opts.delta + momentum


def stall_offset(opts):
    """Seconds from a gesture's first event to its third momentum event."""
    return (1 + opts.changes + 1 + 2) / opts.rate


def moved_during(frames, started_ns, ended_ns):
    """{frames, moved}: the frames read inside the stall (one display frame after its start, up to its end) and
    whether one of them differs from the frame before it."""
    inside = [f for f in frames if started_ns + FRAME_NS <= f["ns"] <= ended_ns]
    return {"frames": len(inside), "moved": any(f["changed"] >= CHANGED for f in inside)}


def judge(arms, opts):
    """The verdict of both arms' rows: {ok, failures}."""
    failures = []
    on, off = arms.get("on") or {}, arms.get("off") or {}
    for target in opts.targets:
        a, b = on.get(target) or {}, off.get(target) or {}
        if a.get("status") != "ok":
            failures.append(f"on {target}: {a.get('status')} {a.get('reason') or ''}".strip())
            continue
        if not a["stall"]["frames"]:
            failures.append(f"on {target}: no frame was read inside the stall")
        elif not a["stall"]["moved"]:
            failures.append(f"on {target}: the list did not move while the main thread was stalled")
        if b.get("status") == "ok" and abs(a["travel"] - b["travel"]) > opts.travel_slack:
            failures.append(f"{target}: traveled {a['travel']} pt with the feature on, {b['travel']} pt off")
    sidebar_off = off.get("sidebar") or {}
    if "sidebar" in opts.targets and sidebar_off.get("status") == "ok" and sidebar_off["stall"]["moved"]:
        failures.append("off_arm_red: the main-thread sidebar moved during the stall, so the check proves nothing")
    return {"ok": not failures, "failures": failures}


class Run:
    """One arm: the app's control, a HID poster, time (the self-test fakes all three)."""

    def __init__(self, opts, control, poster, sleep=time.sleep, log=print):
        self.opts, self.control, self.poster, self.sleep, self.log = opts, control, poster, sleep, log

    def frames(self, target, scroll_to, duration_ms):
        return self.control.rpc("debug.scroll_frames", {"target": target, "scroll_to": scroll_to, "duration_ms": duration_ms},
                                timeout=20)

    def gesture(self, point):
        return self.poster.scroll_gesture(point, dy=-self.opts.delta, rate_hz=self.opts.rate, changes=self.opts.changes,
                                          momentum=self.opts.momentum)

    def phase(self, target, point, middle, stall):
        """One gesture while the app reads frames; with `stall`, a main-thread stall from its third momentum event."""
        seconds = self.opts.lead + (2 + self.opts.changes + self.opts.momentum) / self.opts.rate + 0.6
        result, stalled = {}, {}
        reader = threading.Thread(target=lambda: result.update(reply=self.frames(target, middle, seconds * 1000)), daemon=True)
        reader.start()
        self.sleep(self.opts.lead)  # the reading has started
        poster = threading.Thread(target=lambda: self.gesture(point), daemon=True)
        poster.start()
        if stall:
            self.sleep(stall_offset(self.opts))
            stalled = self.control.rpc("debug.stall", {"ms": self.opts.stall_ms}, timeout=10) or {}
        poster.join(timeout=30)
        reader.join(timeout=30)
        return result.get("reply") or {}, stalled

    def measure(self, target):
        if target == "palette":
            self.control.action("commandPalette")
            self.sleep(0.8)  # the palette opens and lists its results
        probe = self.frames(target, None, 50)
        if hid_input.is_error(probe) or not probe:
            return {"status": "skipped", "reason": f"no {target} list: {json.dumps(probe)[:160]}"}
        room = probe["document_height"] - probe["visible_height"]
        if room < 2 * expected_travel(self.opts):
            return {"status": "skipped", "reason": f"the {target} list scrolls {room:.0f} pt, under two gestures' travel"}
        middle, point = room / 2 - expected_travel(self.opts) / 2, probe["point"]
        self.gesture(point)  # warm-up, not measured
        self.sleep(1.0)  # its momentum ends
        travel, _ = self.phase(target, point, middle, stall=False)
        self.sleep(0.6)
        stalled_frames, stall = self.phase(target, point, middle, stall=True)
        if hid_input.is_error(stall) or "started_ns" not in stall:
            return {"status": "failed", "reason": f"debug.stall: {json.dumps(stall)[:160]}"}
        row = {"status": "ok", "responsive": probe.get("responsive"), "point": point,
               "travel": round(travel.get("origin_after", 0) - travel.get("origin_before", 0), 1),
               "expected_travel": expected_travel(self.opts),
               "stall": dict(moved_during(stalled_frames.get("frames") or [], stall["started_ns"], stall["ended_ns"]),
                             ms=round((stall["ended_ns"] - stall["started_ns"]) / 1e6, 1)),
               "stall_travel": round(stalled_frames.get("origin_after", 0) - stalled_frames.get("origin_before", 0), 1)}
        if target == "palette":
            self.poster.key("escape")
        self.log(f"{target}: {json.dumps(row)}")
        return row


def grow_sidebar(control, count):
    reply = control.rpc("snapshot.get") or {}
    have = len(((reply.get("topology") or {}).get("workspaces") or [])) if isinstance(reply, dict) else 0
    if count > have:
        with ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda i: control.cli("workspace", "create", "--empty", "--name", f"scroll row {i:04d}"), range(count - have)))


def run_launched(opts):
    from bench_launch import BenchApp, LaunchError
    out = os.path.abspath(opts.out or tempfile.mkdtemp(prefix="responsive-scroll-"))
    os.makedirs(out, exist_ok=True)
    app_path = os.path.abspath(opts.app.rstrip("/"))
    arms, notes = {}, []
    for arm, enabled in (("on", True), ("off", False)):
        try:
            app = BenchApp(app_path, out=out, window=WINDOW, log_name=f"app-{arm}.log", local_features={FEATURE: enabled},
                           env={"CMUX_NEXT_NO_ACTIVATE": None})
            app.launch(timeout=180)
        except (LaunchError, SystemExit) as error:
            notes.append(f"{arm}: the app did not come up: {getattr(error, 'reason', None) or error}")
            arms[arm] = {t: {"status": "failed", "reason": "launch"} for t in opts.targets}
            continue
        try:
            control = hid_input.Control(app.socket, os.path.join(app_path, "Contents/Resources/bin/cmux"),
                                        os.path.join(app.scratch, "cmux.json"))
            features = control.rpc("features.list") or {}
            notes.append(f"{arm}: features.list {FEATURE}: {json.dumps([f for f in features.get('features', []) if f.get('name') == FEATURE])[:300]}")
            if "sidebar" in opts.targets:
                grow_sidebar(control, opts.workspaces)
            hid_input.bring_front(app.process.pid)
            time.sleep(1.5)  # the rows lay out and activation settles
            run = Run(opts, control, hid_input.poster_for("real"), log=lambda line, arm=arm: notes.append(f"{arm} {line}"))
            arms[arm] = {target: run.measure(target) for target in opts.targets}
        except Exception as error:  # report what was measured
            notes.append(f"{arm}: stopped: {error!r}")
            arms.setdefault(arm, {})
        finally:
            app.stop()
    return {"arms": arms, "verdict": judge(arms, opts), "log": notes,
            "options": {k: getattr(opts, k) for k in ("targets", "workspaces", "stall_ms", "rate", "changes", "momentum", "delta")}}


def build_parser():
    parser = argparse.ArgumentParser(description="Responsive scrolling under a main-thread stall (p03-rendering-110).")
    parser.add_argument("--app")
    parser.add_argument("--tag", default="responsive-scroll")
    parser.add_argument("--out")
    parser.add_argument("--json")
    parser.add_argument("--targets", type=lambda v: [t for t in v.split(",") if t], default=list(TARGETS))
    parser.add_argument("--workspaces", type=int, default=200)
    parser.add_argument("--stall-ms", type=int, default=50)
    parser.add_argument("--rate", type=float, default=120.0)
    parser.add_argument("--changes", type=int, default=30)
    parser.add_argument("--momentum", type=int, default=24)
    parser.add_argument("--delta", type=float, default=12.0)
    parser.add_argument("--lead", type=float, default=0.2, help="seconds the frame reading runs before the gesture")
    parser.add_argument("--travel-slack", type=float, default=2.0)
    parser.add_argument("--self-test", action="store_true")
    return parser


# ---------------------------------------------------------------- self-test
class FakeControl:
    """An app whose list moves `per_event` points per posted event; with `stall_freezes`, a frame inside the
    stall shows no change (a main-thread scroll)."""

    def __init__(self, stall_freezes, travel=500.0):
        self.stall_freezes, self.travel, self.stall = stall_freezes, travel, None

    def rpc(self, method, params=None, timeout=30):
        if method == "debug.stall":
            self.stall = (1_000_000_000, 1_050_000_000)
            return {"started_ns": self.stall[0], "ended_ns": self.stall[1]}
        if method == "debug.scroll_frames":
            frames = [{"ns": 1_000_000_000 + i * 8_000_000, "changed": 0.0 if self.stall_freezes and 2 <= i <= 7 else 0.2}
                      for i in range(20)]
            return {"responsive": not self.stall_freezes, "point": [100, 300], "document_height": 6000, "visible_height": 700,
                    "frames": frames, "origin_before": 100.0, "origin_after": 100.0 + self.travel}
        return {}

    def action(self, *args, **kwargs):
        return {}


class FakePoster:
    def scroll_gesture(self, *args, **kwargs):
        return {"events": 56}

    def key(self, *args, **kwargs):
        return None


def self_test():
    failures = []

    def check(name, condition, detail=""):
        if not condition:
            failures.append(f"{name}: {detail}")

    opts = build_parser().parse_args(["--app", "x"])
    check("expected travel", expected_travel(opts) == 30 * 12 + sum(abs(round(12 * 0.9 ** (i + 1))) for i in range(24)))
    check("stall offset", abs(stall_offset(opts) - 34 / 120) < 1e-9)
    inside = moved_during([{"ns": 1_010_000_000, "changed": 0.5}, {"ns": 1_030_000_000, "changed": 0.0}], 1_000_000_000, 1_050_000_000)
    check("first frame of a stall is left out", inside == {"frames": 1, "moved": False}, inside)

    def arm(stall_freezes, travel=500.0):
        return {t: Run(opts, FakeControl(stall_freezes, travel), FakePoster(), sleep=lambda _: None, log=lambda _: None).measure(t)
                for t in opts.targets}

    green = {"on": arm(False), "off": arm(True)}
    check("green", judge(green, opts)["ok"], judge(green, opts))
    check("on rows", green["on"]["sidebar"]["stall"]["moved"] and green["on"]["sidebar"]["travel"] == 500.0, green["on"]["sidebar"])
    red = {"on": arm(True), "off": arm(True)}
    check("red: a stalled list fails", not judge(red, opts)["ok"] and any("did not move" in f for f in judge(red, opts)["failures"]))
    doubled = {"on": arm(False, travel=512.0), "off": arm(True)}
    check("a double-applied start fails", any("traveled" in f for f in judge(doubled, opts)["failures"]), judge(doubled, opts))
    useless = {"on": arm(False), "off": arm(False)}
    check("a moving off arm fails", any("off_arm_red" in f for f in judge(useless, opts)["failures"]))
    if failures:
        print("responsive-scroll-live self-test FAILED:\n  " + "\n  ".join(failures))
        return 1
    print("responsive-scroll-live self-test: ok")
    return 0


def main():
    parser = build_parser()
    opts = parser.parse_args()
    if opts.self_test:
        return self_test()
    if not opts.app:
        parser.error("--app is required")
    unknown = [t for t in opts.targets if t not in TARGETS]
    if unknown:
        parser.error(f"--targets: unknown {unknown} (one of {', '.join(TARGETS)})")
    document = run_launched(opts)
    path = opts.json or (os.path.join(opts.out, "report.json") if opts.out else None)
    if path:
        with open(path, "w") as handle:
            json.dump(document, handle, indent=1, default=str)
    print(json.dumps({"verdict": document["verdict"], "arms": document["arms"]}, indent=1, default=str), flush=True)
    return 0 if document["verdict"]["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
