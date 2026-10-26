#!/usr/bin/env python3
"""play.py against a fake app and a fake clock (no app, no macOS): the schedule keeps absolute deadlines (bounded
lateness, no drift, checkpoints move the schedule), checkpoint digests ignore ids and load, a digest mismatch fails
with the first diverging checkpoint, references resolve against the live topology, every event kind reaches its
socket call with its send stamp, the window hook wraps the input track only, the series land in result-v1 records,
and --verify / --all report as specified.

  python3 -m unittest scripts/perf-lab/tests/test_play.py
"""
from __future__ import annotations

import contextlib
import copy
import hashlib
import importlib.util
import inspect
import io
import json
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[2]
spec = importlib.util.spec_from_file_location("perf_lab_corpus_play_under_test", HERE.parent / "corpus" / "play.py")
play = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = play
spec.loader.exec_module(play)
bench_launch = play.bench_launch()

MS = play.NS_PER_MS
EVENT_CLOCK_OFFSET_S = 5000.0  # NSEvent's clock is not the signposts' clock: the fake keeps them apart


class FakeClock:
    """Time moves only by sleeps and by the work the fake app and the test say took time."""

    def __init__(self):
        self.ns = 1_000 * MS

    def now_ns(self):
        return self.ns

    def sleep_until(self, deadline_ns):
        self.ns = max(self.ns, deadline_ns)

    def advance_ms(self, ms):
        self.ns += round(ms * MS)

    def event_s(self):
        return self.ns / 1e9 + EVENT_CLOCK_OFFSET_S

    def signpost_s(self):
        return self.ns / 1e9


def new_id():
    return uuid.uuid4().hex[:12]


class FakeApp:
    """Enough of the control socket for play.py: a window that shows one workspace at a time, panes with terminal
    tabs, a few actions, debug.key/mouse, debug.focus/surfaces with ids and load-dependent fields that change per
    instance, debug.frames, and the signposts the calls would write (ndjson lines, timebase 1/1)."""

    def __init__(self, clock, cost_ms=1.0, missed=2):
        self.clock, self.cost_ms, self.missed = clock, cost_ms, missed
        self.window = new_id()
        self.workspaces = []
        for tabs in (2, 1):
            pane = {"id": new_id(), "tabs": [new_id() for _ in range(tabs)]}
            pane["selected"] = pane["tabs"][0]
            self.workspaces.append({"id": new_id(), "panes": [pane]})
        self.shown, self.calls, self.lines, self.marks = 0, [], [], []
        self.signpost_id = 0
        self.slow = {}  # call number -> extra ms that call takes

    # Signposts.

    def interval(self, category, name, begin_s, ms, message=""):
        self.signpost_id += 1
        for kind, at, text in (("begin", begin_s, message), ("end", begin_s + ms / 1000, "")):
            self.lines.append(json.dumps({"eventType": "signpostEvent", "subsystem": "com.cmuxterm.app.next",
                                          "category": category, "signpostName": name, "signpostID": self.signpost_id,
                                          "signpostType": kind, "processID": 7, "machTimestamp": round(at * 1e9),
                                          "timestamp": "2026-10-26 00:00:00.000000-0700", "eventMessage": text}))

    # State.

    def find_tab(self, tab):
        for w_index, workspace in enumerate(self.workspaces):
            for pane in workspace["panes"]:
                if tab in pane["tabs"]:
                    return w_index, pane
        return None, None

    def focused_pane(self):
        return self.workspaces[self.shown]["panes"][0]

    # The socket.

    def rpc(self, method, params=None, timeout=60):
        params = params or {}
        self.calls.append((method, copy.deepcopy(params)))
        extra = self.slow.get(len(self.calls), 0)
        now = self.clock.signpost_s()
        self.clock.advance_ms(self.cost_ms + extra)
        if method == "snapshot.get":
            return {"topology": {"workspaces": [
                {"id": w["id"], "screens": [{"panes": [{"id": p["id"], "selected_tab": p["selected"],
                                                         "tabs": [{"id": t, "kind": "terminal"} for t in p["tabs"]]}
                                                        for p in w["panes"]]}]}
                for w in self.workspaces]}}
        if method == "debug.key":
            if params.get("key") == "t" and params.get("modifiers") == ["cmd"]:
                pane = self.focused_pane()
                pane["tabs"].append(new_id())
                pane["selected"] = pane["tabs"][-1]
            self.interval("key", "key.frame", now, 2.0, "target=terminal age_ms=1.00")
            return {"handled_by": "responder", "injected_at": params.get("timestamp")}
        if method == "debug.mouse":
            return {"ok": True}
        if method == "action.run":
            target = params.get("target", "")
            if params["action"] == "tab.focus" and target.startswith("tab:"):
                w_index, pane = self.find_tab(target[4:])
                if pane is None:
                    return {"error": {"code": "not_found"}}
                pane["selected"], self.shown = target[4:], w_index
                self.interval("switch", "switch.tab", now, 5.0, "kind=warm")
            elif params["action"] == "nextSidebarTab":
                self.shown = (self.shown + 1) % len(self.workspaces)
                self.interval("switch", "switch.workspace", now, 6.0)
            elif params["action"] == "terminal.sendText":
                return {"ok": True}
            elif params["action"] == "refuse":
                return {"error": {"code": "refused"}}
            self.interval("action", "action.commit", now, 4.0, f"id={params['action']} origin=socket input_age_ms=-1")
            return {"ok": True}
        if method == "debug.focus":
            shown = self.workspaces[self.shown]
            pane = self.focused_pane()
            return {"windows": [{"id": self.window, "workspace": shown["id"], "consistent": True,
                                 "recent_events": [new_id()],
                                 "model": {"resolved": "terminal", "resolved_pane": pane["id"],
                                           "resolved_tab": pane["selected"], "overlays": [], "sidebar_hidden": False,
                                           "generation": len(self.calls)},
                                 "topology": [{"pane": p["id"], "selected": p["selected"],
                                               "tabs": [f"{t}:terminal" for t in p["tabs"]]} for p in shown["panes"]]}],
                    "context": {"terminal_focused": True, "browser_focused": False, "agent_focused": False,
                                "palette_open": False}, "consistent": True, "app_active": False,
                    "new_tab_key_log": [new_id()]}
        if method == "debug.surfaces":
            rows = [{"pane": p["id"], "workspace": w["id"], "visible": index == self.shown, "presence":
                     "visible" if index == self.shown else "hidden", "kind": "terminal", "content_installed": True,
                     "content_in_window": index == self.shown, "content_size": "800x600", "blank": False,
                     "collapsed": False, "focused": True, "selected_tab": p["selected"], "shown_tab": p["selected"],
                     "phase": "live" if len(self.calls) % 2 else "restoring", "snapshots": len(self.calls)}
                    for index, w in enumerate(self.workspaces) for p in w["panes"]]
            return {"windows": [{"window": "41", "panes": rows}], "blank_panes": 0, "collapsed_panes": 0,
                    "live_terminals": len(self.calls)}
        if method == "debug.frames":
            return {"frames": 60, "missed": self.missed} if params.get("action") == "stop" else {"running": True}
        return {"error": {"code": "method_not_found"}}


class FakeProcess:
    pid = 7


class FakeBench:
    def __init__(self, app, out, env, session, launch_error=None):
        self.app, self.out, self.env, self.session = app, Path(out), env, session
        self.launch_error = launch_error
        self.process, self.cli, self.socket = FakeProcess(), "/x/cmux DEV t.app/Contents/Resources/bin/cmux", "/tmp/s"
        self.records, self.launched, self.stopped = [], False, False

    def rpc(self, method, params=None, timeout=60):
        return self.app.rpc(method, params, timeout)

    def launch(self):
        if self.launch_error:
            raise self.launch_error
        self.launched = True
        (self.out / "host-env-full-7.json").write_text('{"ok": true}')

    def stop(self):
        self.stopped = True

    def record(self, story, metric, unit, samples, better, engine):
        self.records.append({"story": story, "metric": metric, "unit": unit, "samples": list(samples),
                             "better": better, "engine": engine, "session": self.session})
        return self.out / f"{metric}.ndjson"


class FakeCli:
    """A spawned CLI: the app commits its action 2 ms after the send stamp, for 3 ms (cli_to_frame 5 ms)."""

    def __init__(self, app, clock, argv, code=0):
        self.argv, self.code = list(argv), code
        app.interval("action", "action.commit", clock.signpost_s() + 0.002, 3.0, "id=workspace.move origin=cli")

    def wait(self, timeout):
        return self.code, "" if self.code == 0 else "boom"


class FakeBuilder:
    """session_io.import_layout's builder: the player only closes it."""

    def close(self):
        pass


class FakeRecording:
    def __init__(self, app):
        self.app, self.stops = app, 0

    def stop(self):
        self.stops += 1
        return ["#timebase 1/1", *self.app.lines]


SNAPSHOT = {"schema": "cmux-layout-snapshot/v1", "window": [1440, 900], "shown": 0, "focused_pane": 0, "busy": [],
            "workspaces": [{"tree": {"tabs": ["terminal", "terminal"], "selected": 0}, "even": True},
                           {"tree": {"tabs": ["terminal"], "selected": 0}, "even": True}]}

EVENTS = [
    {"t_ms": 0, "kind": "key", "payload": {"phase": "down", "class": "letter", "modifiers": []}},
    {"t_ms": 40, "kind": "key", "payload": {"phase": "up", "class": "letter", "modifiers": []}},
    {"t_ms": 60, "kind": "key", "payload": {"phase": "down", "class": "letter", "modifiers": ["shift"]}},
    {"t_ms": 100, "kind": "key", "payload": {"phase": "down", "class": "letter", "key_code": 17, "modifiers": ["cmd"]}},
    {"t_ms": 150, "kind": "key", "payload": {"phase": "flags", "class": "modifier", "modifiers": []}},
    {"t_ms": 200, "kind": "action", "payload": {"id": "tab.focus", "args": {"target": "@w0.p0.t1"}}},
    {"t_ms": 300, "kind": "cli", "payload": {"argv": ["workspace", "@w1", "move", "--index", "0"]}},
    {"t_ms": 400, "kind": "action", "payload": {"id": "nextSidebarTab", "args": {"target": "@w0"}}},
    {"t_ms": 500, "kind": "mouse", "payload": {"phase": "down", "button": 0, "x": 10, "y": 20, "click_count": 1}},
    {"t_ms": 520, "kind": "mouse", "payload": {"phase": "drag", "button": 0, "x": 30, "y": 25}},
    {"t_ms": 540, "kind": "mouse", "payload": {"phase": "up", "button": 0, "x": 30, "y": 25}},
    {"t_ms": 700, "kind": "action", "payload": {"id": "tab.focus", "args": {"target": "@w0.p0.t2"}}},
]
CHECKPOINTS = [("start", 0), ("midpoint", 350), ("late", 600), ("end", 1000)]
METRICS = [{"name": f"corpus\\.fixture_play\\.{name}", "unit": unit, "better": "lower"} for name, unit in
           (("key_to_frame", "ms"), ("action_to_frame", "ms"), ("cli_to_frame", "ms"), ("switch_to_frame", "ms"),
            ("dropped_frames", "count"), ("main_turn", "ms"))]


def recorded_digests(events=EVENTS, checkpoints=CHECKPOINTS):
    """What the recorder (task 116) stores: the digests a fresh app reaches at each checkpoint when the events are
    sent in order through the player's own Sender (no schedule)."""
    clock = FakeClock()
    app = FakeApp(clock)
    bench = FakeBench(app, tempfile.mkdtemp(), {}, "corpus:fixture-play")
    manifest = {"checkpoints": [{"t_ms": t, "name": n, "focus": None, "surfaces": None} for n, t in checkpoints]}
    timeline, _ = play.plan(manifest, events, play.corpus_manifest().TYPING_CLASSES)
    sender = play.Sender(bench, play.Refs(bench.rpc), clock, lambda argv: FakeCli(app, clock, argv))
    digests = {}
    for item in timeline:
        if isinstance(item, play.Checkpoint):
            focus, surfaces = play.read_checkpoint(bench.rpc)
            digests[item.name] = (play.focus_digest(focus), play.surfaces_digest(surfaces))
        else:
            sender.send(item)
    return digests


class Fixture:
    """A recorded manifest whose layout snapshot is a blob in a temporary cache, and a Player over fakes."""

    def __init__(self, test, events=EVENTS, digests=None, **player_options):
        self.dir = Path(tempfile.mkdtemp(prefix="play-test-"))
        test.addCleanup(lambda: __import__("shutil").rmtree(self.dir, ignore_errors=True))
        data = json.dumps(SNAPSHOT, sort_keys=True, separators=(",", ":")).encode()
        self.blobs = {hashlib.sha256(data).hexdigest(): data}
        digests = digests or recorded_digests(events)
        self.manifest = {
            "schema": "cmux-perf-corpus-story/v1", "id": "fixture-play", "tier": "T1", "status": "recorded",
            "description": "A fixture.", "owner": "PL-perf-lab", "duration_ms": 1000,
            "layout": {"snapshot": {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}, "workspaces": 2},
            "input": {"events": copy.deepcopy(events)}, "pty": [], "web_archive": None, "agents": [],
            "checkpoints": [{"t_ms": t, "name": n, "focus": digests[n][0], "surfaces": digests[n][1]}
                            for n, t in CHECKPOINTS],
            "metrics": copy.deepcopy(METRICS)}
        self.clock = FakeClock()
        self.apps, self.benches, self.recordings, self.clis, self.windows = [], [], [], [], []
        self.launch_error = None
        options = {"settle_s": 0.2, **player_options}
        self.player = play.Player(root=REPO_ROOT, clock=self.clock, fetch=self.fetch, make_bench=self.make_bench,
                                  import_layout=self.import_layout, signposts=self.signposts, spawn=self.spawn,
                                  **options)

    def fetch(self, ref):
        path = self.dir / ref["sha256"]
        path.write_bytes(self.blobs[ref["sha256"]])
        return path

    def make_bench(self, app, *, out, env, session):
        fake = FakeApp(self.clock)
        self.apps.append(fake)
        bench = FakeBench(fake, out, env, session, self.launch_error)
        self.benches.append(bench)
        return bench

    def import_layout(self, rpc, snapshot):
        self.imported = snapshot
        return FakeBuilder()

    def signposts(self, pid):
        recording = FakeRecording(self.apps[-1])
        self.recordings.append(recording)
        return recording

    def spawn(self, argv):
        cli = FakeCli(self.apps[-1], self.clock, argv)
        self.clis.append(cli)
        return cli

    def window(self, bench):
        app = bench.app

        @contextlib.contextmanager
        def measured():
            self.windows.append(bench)
            app.calls.append(("<window enter>", {}))
            yield
            app.calls.append(("<window exit>", {}))

        return measured()

    def replay(self, **kwargs):
        return self.player.replay(self.manifest, app="/x/cmux DEV t.app", out=self.dir / "out", **kwargs)


# ---------------------------------------------------------------- the schedule

def steps(times_ms):
    return [play.Step(float(t), index, "key", {}) for index, t in enumerate(times_ms)]


class Schedule(unittest.TestCase):
    def run_track(self, timeline, cost_ms, slow=None, checkpoint_ms=0.0):
        clock = FakeClock()
        sent = []

        def send(step):
            sent.append((step.index, clock.now_ns()))
            clock.advance_ms((slow or {}).get(step.index, cost_ms))

        def checkpoint(item):
            clock.advance_ms(checkpoint_ms)
            return {"name": item.name}

        origin = clock.now_ns()
        track = play.play_track(timeline, send=send, checkpoint=checkpoint, clock=clock)
        return track, sent, origin

    def test_sends_keep_absolute_deadlines_with_no_drift(self):
        track, sent, origin = self.run_track(steps(range(0, 10_000, 10)), cost_ms=3)
        self.assertEqual(len(sent), 1000)
        self.assertEqual(max(track.lateness_ms), 0)
        self.assertEqual(sent[-1][1] - origin, 9_990 * MS)  # 1000 sends of 3 ms each moved nothing

    def test_a_slow_send_makes_only_the_next_sends_late_and_is_bounded_by_its_own_time(self):
        track, sent, origin = self.run_track(steps(range(0, 1000, 10)), cost_ms=1, slow={10: 25})
        late = track.lateness_ms
        self.assertEqual(late[11:14], [15.0, 6.0, 0.0])  # catches up on the recorded deadlines
        self.assertEqual(max(late), 15.0)  # never more than the slow send minus the gap after it
        self.assertEqual(late[14:], [0.0] * len(late[14:]))
        self.assertEqual(sent[-1][1] - origin, 990 * MS)

    def test_a_checkpoint_moves_the_schedule_so_the_spacing_after_it_stays(self):
        timeline = [*steps([0, 50]), play.Checkpoint(50.0, "mid", "f", "s"), *steps([60, 70])]
        timeline = sorted(timeline, key=lambda i: (i.t_ms, 0 if isinstance(i, play.Checkpoint) else 1))
        track, sent, origin = self.run_track(timeline, cost_ms=1, checkpoint_ms=40)
        self.assertEqual(track.paused_ms, 40.0)
        self.assertEqual([t for t in track.lateness_ms], [0.0] * 4)
        self.assertEqual(sent[1][1] - sent[0][1], 90 * MS)  # the 50 ms step waits for the 40 ms checkpoint read
        self.assertEqual(sent[2][1] - sent[1][1], 10 * MS)  # then the recorded spacing again
        self.assertEqual(sent[3][1] - sent[2][1], 10 * MS)

    def test_a_checkpoint_runs_before_the_events_of_its_own_time(self):
        manifest = {"checkpoints": [{"t_ms": 100, "name": "c", "focus": None, "surfaces": None}]}
        timeline, _ = play.plan(manifest, EVENTS, play.corpus_manifest().TYPING_CLASSES)
        names = [(i.t_ms, type(i).__name__) for i in timeline if i.t_ms == 100]
        self.assertEqual(names, [(100.0, "Checkpoint"), (100.0, "Step")])

    def test_a_replay_later_than_its_bound_raises_and_records_nothing(self):
        fixture = Fixture(self, max_late_ms=0.5)
        original = fixture.make_bench

        def slow_bench(app, **kwargs):
            bench = original(app, **kwargs)
            bench.app.cost_ms = 120  # each reply takes longer than the gaps between events
            return bench

        fixture.player.make_bench = slow_bench
        with self.assertRaises(play.ScheduleError) as caught:
            fixture.replay()
        self.assertIn("late at p95", str(caught.exception))
        self.assertEqual(fixture.benches[0].records, [])
        self.assertTrue(fixture.benches[0].stopped)


# ---------------------------------------------------------------- digests

class Digests(unittest.TestCase):
    def test_same_state_in_two_apps_with_other_ids_and_load_has_one_digest(self):
        first, second = FakeApp(FakeClock()), FakeApp(FakeClock())
        second.calls = [("x", {})] * 7  # other generation, counters and phases
        for method, digest in (("debug.focus", play.focus_digest), ("debug.surfaces", play.surfaces_digest)):
            self.assertEqual(digest(first.rpc(method)), digest(second.rpc(method)), method)

    def test_pane_order_and_window_order_do_not_change_the_digest(self):
        app = FakeApp(FakeClock())
        report = app.rpc("debug.surfaces")
        report["windows"][0]["panes"].reverse()
        self.assertEqual(play.surfaces_digest(report), play.surfaces_digest(app.rpc("debug.surfaces")))

    def test_focus_on_another_tab_or_workspace_changes_the_focus_digest(self):
        app = FakeApp(FakeClock())
        digests = {play.focus_digest(app.rpc("debug.focus"))}
        pane = app.focused_pane()
        pane["selected"] = pane["tabs"][1]
        digests.add(play.focus_digest(app.rpc("debug.focus")))
        app.shown = 1
        digests.add(play.focus_digest(app.rpc("debug.focus")))
        self.assertEqual(len(digests), 3)

    def test_a_pane_that_shows_nothing_changes_the_surfaces_digest(self):
        app = FakeApp(FakeClock())
        report = app.rpc("debug.surfaces")
        before = play.surfaces_digest(report)
        report["windows"][0]["panes"][0]["blank"] = True
        report["blank_panes"] = 1
        self.assertNotEqual(play.surfaces_digest(report), before)


# ---------------------------------------------------------------- one replay

class Replay(unittest.TestCase):
    def test_replay_sends_every_event_inside_the_window_and_records_the_declared_series(self):
        fixture = Fixture(self)
        result = fixture.replay(window=fixture.window)
        bench, app = fixture.benches[0], fixture.apps[0]
        self.assertEqual(fixture.windows, [bench])  # window(bench) once, with the replay's BenchApp
        self.assertEqual(bench.session, "corpus:fixture-play")
        self.assertEqual(fixture.imported, SNAPSHOT)
        methods = [method for method, _ in app.calls]
        enter, leave = methods.index("<window enter>"), methods.index("<window exit>")
        inside = [m for m in methods[enter:leave] if m in ("debug.key", "debug.mouse", "action.run")]
        self.assertEqual(inside, ["debug.key"] * 3 + ["action.run"] * 2 + ["debug.mouse"] * 3 + ["action.run"])
        self.assertEqual([m for m in methods[:enter] if m in ("debug.key", "debug.mouse")], [])
        self.assertLess(methods.index("debug.frames"), enter)
        self.assertGreater(len(methods) - 1 - methods[::-1].index("debug.frames"), leave)
        self.assertEqual(fixture.recordings[0].stops, 1)

        keys = [params for method, params in app.calls if method == "debug.key"]
        self.assertEqual([(k["key"], k["modifiers"]) for k in keys], [("t", []), ("H", []), ("t", ["cmd"])])
        self.assertTrue(all(k["timestamp"] > EVENT_CLOCK_OFFSET_S for k in keys))  # stamped on NSEvent's clock
        actions = [params for method, params in app.calls if method == "action.run"]
        tab = app.workspaces[0]["panes"][0]["tabs"]
        self.assertEqual(actions[0]["target"], f"tab:{tab[1]}")
        self.assertEqual(actions[1]["target"], f"workspace:{app.workspaces[0]['id']}")
        self.assertEqual(actions[2]["target"], f"tab:{tab[2]}")  # the tab Cmd-T opened during the replay
        self.assertEqual(fixture.clis[0].argv, [bench.cli, "--app-socket", bench.socket, "workspace",
                                                app.workspaces[1]["id"], "move", "--index", "0"])
        mice = [params for method, params in app.calls if method == "debug.mouse"]
        self.assertEqual(mice[1], {"action": "drag", "x": 10, "y": 20, "to_x": 30, "to_y": 25, "steps": 1,
                                   "press": False, "release": False, "button": "left", "modifiers": []})

        by_metric = {r["metric"]: r for r in bench.records}
        def samples(series):
            return sorted(round(v, 6) for v in by_metric[f"corpus.fixture_play.{series}"]["samples"])

        self.assertEqual(samples("key_to_frame"), [3.0, 3.0, 3.0])  # key.frame 2 ms plus the key's 1 ms age
        self.assertEqual(samples("action_to_frame"), [4.0, 4.0, 4.0])
        self.assertEqual(samples("cli_to_frame"), [5.0])  # send stamp to the end of the CLI's commit
        self.assertEqual(samples("switch_to_frame"), [5.0, 5.0, 6.0])
        self.assertEqual(by_metric["corpus.fixture_play.dropped_frames"]["samples"], [2])
        self.assertEqual(by_metric["corpus.fixture_play.dropped_frames"]["unit"], "count")
        self.assertNotIn("corpus.fixture_play.tab_switch_to_frame", by_metric)  # not declared, not written
        self.assertEqual({r["engine"] for r in bench.records}, {"none"})
        self.assertEqual({r["story"] for r in bench.records}, {"corpus-fixture-play"})
        self.assertEqual(result.unmeasured, ["corpus\\.fixture_play\\.main_turn"])
        self.assertEqual(result.skipped_events, 2)  # the key up and the flags change
        self.assertEqual([c["name"] for c in result.checkpoints], ["start", "midpoint", "late", "end"])
        self.assertEqual(result.schedule["sent"], 10)
        self.assertEqual(result.schedule["lateness_ms"]["max"], 0)
        summary = json.loads((fixture.dir / "out" / "corpus-play-fixture-play.json").read_text())
        self.assertEqual(summary["results"], [str(bench.out / f"{r['metric']}.ndjson") for r in bench.records])
        self.assertTrue((fixture.dir / "out" / "host-env-full-7.json").is_file())
        self.assertTrue(bench.stopped)

    def test_a_digest_mismatch_fails_with_the_first_diverging_checkpoint(self):
        digests = recorded_digests()
        digests["midpoint"] = (digests["midpoint"][0], "0" * 64)
        digests["late"] = ("1" * 64, digests["late"][1])  # a later divergence is never reached
        fixture = Fixture(self, digests=digests)
        with self.assertRaises(play.DigestMismatch) as caught:
            fixture.replay(window=fixture.window)
        self.assertEqual((caught.exception.checkpoint, caught.exception.which), ("midpoint", "surfaces"))
        self.assertIn("checkpoint midpoint (t=350 ms)", str(caught.exception))
        app = fixture.apps[0]
        sent_after = [p for m, p in app.calls if m == "action.run" and p.get("action") == "nextSidebarTab"]
        self.assertEqual(sent_after, [])  # nothing after the diverging checkpoint was sent
        kept = json.loads((fixture.dir / "out" / "checkpoint-midpoint.json").read_text())
        self.assertEqual(set(kept), {"focus", "surfaces"})
        self.assertEqual(fixture.benches[0].records, [])
        self.assertTrue(fixture.benches[0].stopped)
        self.assertEqual(fixture.recordings[0].stops, 1)

    def test_a_checkpoint_waits_for_state_that_lands_late(self):
        fixture = Fixture(self, settle_s=1.0)
        original = fixture.make_bench

        def lagging(app, **kwargs):
            bench = original(app, **kwargs)
            fake, real_rpc, held = bench.app, bench.app.rpc, {"reads": 0}

            def rpc(method, params=None, timeout=60):
                if method == "debug.surfaces" and held["reads"] < 3:
                    held["reads"] += 1
                    report = real_rpc(method, params, timeout)
                    report["blank_panes"] = 1  # the first reads come before the state settles
                    return report
                return real_rpc(method, params, timeout)

            fake.rpc = rpc
            return bench

        fixture.player.make_bench = lagging
        result = fixture.replay()
        self.assertEqual(len(result.checkpoints), 4)

    def test_a_refused_event_fails_the_replay_naming_it(self):
        events = [*EVENTS[:5], {"t_ms": 200, "kind": "action", "payload": {"id": "tab.focus", "args": {"target": "@w0.p0.t9"}}}]
        fixture = Fixture(self, events=events, digests=recorded_digests(EVENTS))
        with self.assertRaises(play.PlayError) as caught:
            fixture.replay()
        self.assertIn("event 5 (action at 200 ms)", str(caught.exception))
        self.assertIn("no tab 9", str(caught.exception))

    def test_a_failed_launch_raises_bench_launchs_launch_error(self):
        fixture = Fixture(self)
        fixture.launch_error = bench_launch.LaunchError("no-gui-session", {"detail": "nobody on the console"})
        with self.assertRaises(bench_launch.LaunchError) as caught:
            fixture.replay(window=fixture.window)
        self.assertEqual(caught.exception.reason, "no-gui-session")
        self.assertEqual(fixture.windows, [])

    def test_a_failed_cli_event_fails_the_replay(self):
        fixture = Fixture(self)
        fixture.player.spawn = lambda argv: FakeCli(fixture.apps[-1], fixture.clock, argv, code=2)
        with self.assertRaises(play.PlayError) as caught:
            fixture.replay()
        self.assertIn("event 6 (cli at 300 ms): exit 2", str(caught.exception))

    def test_web_replay_and_agent_tracks_reach_the_app_environment(self):
        fixture = Fixture(self)
        wprgo, transcript = b"wpr archive", b'{"frame": 1}\n'
        for data in (wprgo, transcript):
            fixture.blobs[hashlib.sha256(data).hexdigest()] = data
        spki = "A" * 43 + "="
        fixture.manifest["web_archive"] = {"wprgo": {"sha256": hashlib.sha256(wprgo).hexdigest(), "bytes": len(wprgo)},
                                           "spki": spki}
        fixture.manifest["agents"] = [{"surface": "@w1.p0.t0", "agent": "replay",
                                       "transcript": {"sha256": hashlib.sha256(transcript).hexdigest(),
                                                      "bytes": len(transcript)}}]
        served, staged = [], []

        @contextlib.contextmanager
        def web_replay(archive, spki_value, out):
            served.append((archive.read_bytes(), spki_value))
            yield {"host-resolver-rules": "MAP *:443 127.0.0.1:8443", "ignore-certificate-errors-spki-list": spki_value}
            served.append("stopped")

        def agents(root, tracks, fetch):
            staged.append((root, [fetch(track["transcript"]).read_bytes() for track in tracks]))

        fixture.player.web_replay, fixture.player.agents = web_replay, agents
        fixture.replay()
        env = fixture.benches[0].env
        self.assertEqual(served, [(wprgo, spki), "stopped"])
        self.assertEqual(env["CMUX_NEXT_BENCH_CEF_SWITCHES"],
                         f"host-resolver-rules=MAP *:443 127.0.0.1:8443\nignore-certificate-errors-spki-list={spki}")
        self.assertEqual(staged, [(fixture.dir / "out" / "acpmux", [transcript])])
        self.assertEqual(env["CMUX_NEXT_ACPMUX_ROOT"], str(fixture.dir / "out" / "acpmux"))
        self.assertEqual({r["engine"] for r in fixture.benches[0].records}, {"chromium"})

    def test_pty_tracks_start_the_pty_player_in_their_terminal(self):
        fixture = Fixture(self)
        app = FakeApp(FakeClock())
        bench = FakeBench(app, fixture.dir, {}, "corpus:fixture-play")
        manifest = {**fixture.manifest, "pty": [{"surface": "@w0.p0.t1", "source": None, "speed": 1, "loop": True}]}
        story = play.Story(manifest, fixture.dir / "fixture-play.json", SNAPSHOT, [], 0, "none")
        fixture.player.cache_dir = fixture.dir / "cache dir"
        fixture.player.start_pty(story, bench, play.Refs(bench.rpc))
        (method, params), = [call for call in app.calls if call[0] == "action.run"]
        self.assertEqual((params["action"], params["target"], params["focus"]),
                         ("terminal.sendText", f"tab:{app.workspaces[0]['panes'][0]['tabs'][1]}", False))
        text = params["args"]["text"]
        self.assertTrue(text.startswith(f"CMUX_PERF_CORPUS_CACHE='{fixture.dir / 'cache dir'}' "))
        self.assertIn(f"pty_replay.py --manifest {fixture.dir / 'fixture-play.json'} --track 0 --root", text)
        self.assertTrue(text.endswith("\n"))

    def test_replay_takes_the_window_hook_by_keyword(self):
        parameters = inspect.signature(play.replay).parameters
        self.assertEqual(parameters["window"].kind, inspect.Parameter.KEYWORD_ONLY)
        self.assertIsNone(parameters["window"].default)
        self.assertEqual([p for p in parameters][:3], ["manifest", "app", "out"])


# ---------------------------------------------------------------- refused before any launch

class Refusals(unittest.TestCase):
    def assert_refused(self, fixture, text):
        with self.assertRaises(play.PlayError) as caught:
            fixture.replay()
        self.assertIn(text, str(caught.exception))
        self.assertEqual(fixture.benches, [])  # nothing launched

    def test_a_planned_story_is_not_played(self):
        fixture = Fixture(self)
        fixture.manifest = json.loads((REPO_ROOT / "perf-corpus" / "dev-loop.json").read_text())
        self.assert_refused(fixture, "is planned, not recorded")

    def test_text_in_an_event_is_refused(self):
        fixture = Fixture(self)
        fixture.manifest["input"]["events"].append(
            {"t_ms": 900, "kind": "action", "payload": {"id": "renameWorkspace", "args": {"name": "secret"}}})
        self.assert_refused(fixture, "invalid manifest")

    def test_a_key_code_debug_key_cannot_send_is_refused(self):
        fixture = Fixture(self)
        fixture.manifest["input"]["events"].append(
            {"t_ms": 900, "kind": "key", "payload": {"phase": "down", "class": "named", "key_code": 200, "modifiers": []}})
        self.assert_refused(fixture, "key code 200 has no debug.key name")

    def test_a_layout_with_another_workspace_count_is_refused(self):
        fixture = Fixture(self)
        fixture.manifest["layout"]["workspaces"] = 3
        self.assert_refused(fixture, "the snapshot has 2 workspaces")

    def test_pty_tracks_need_the_pty_player(self):
        if (REPO_ROOT / "scripts/perf-lab/corpus/pty_replay.py").is_file():
            self.skipTest("pty_replay.py (task 112) is in this checkout")
        fixture = Fixture(self)
        data = b"\x1b[2Jhello"
        fixture.blobs[hashlib.sha256(data).hexdigest()] = data
        fixture.manifest["pty"] = [{"surface": "@w0.p0.t0", "speed": 1, "loop": False,
                                    "source": {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}}]
        self.assert_refused(fixture, "pty_replay.py (p12-perf-process-112)")


# ---------------------------------------------------------------- verify and the CLI

def run(checkpoints, series):
    return play.Replay("s", checkpoints, {}, series, [], [], 0)


class Verify(unittest.TestCase):
    CHECKS = [{"name": "a", "focus": "1" * 64, "surfaces": "2" * 64}, {"name": "b", "focus": "3" * 64, "surfaces": "4" * 64}]

    def test_equal_runs_agree(self):
        self.assertEqual(play.compare_runs(run(self.CHECKS, {"m": [1, 2, 3]}), run(self.CHECKS, {"m": [1, 2.1, 3]})), [])

    def test_the_first_diverging_checkpoint_is_named(self):
        other = copy.deepcopy(self.CHECKS)
        other[1]["surfaces"] = "5" * 64
        problems = play.compare_runs(run(self.CHECKS, {}), run(other, {}))
        self.assertEqual(len(problems), 1)
        self.assertTrue(problems[0].startswith("checkpoint b:"))

    def test_a_metric_whose_p50_varies_over_the_cv_bound_is_named(self):
        problems = play.compare_runs(run(self.CHECKS, {"m": [10, 10]}), run(self.CHECKS, {"m": [14, 14]}))
        self.assertEqual(len(problems), 1)
        self.assertIn("m: p50 10 vs 14, cv 0.236", problems[0])

    def test_cli_verify_plays_twice_and_reports(self):
        fixture = Fixture(self)
        path = fixture.dir / "fixture-play.json"
        path.write_text(json.dumps(fixture.manifest))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = play.main([str(path), "--verify", "--app", "/x/cmux DEV t.app", "--out", str(fixture.dir / "o")],
                             player=fixture.player)
        report = json.loads(out.getvalue().splitlines()[-1].removeprefix("CORPUS-PLAY "))
        self.assertEqual(code, 0, report)
        self.assertTrue(report["ok"])
        self.assertEqual(len(report["runs"]), 2)
        self.assertEqual(report["problems"], [])
        self.assertEqual(len(fixture.benches), 2)
        self.assertTrue((fixture.dir / "o" / "fixture-play" / "run-2" / "corpus-play-fixture-play.json").is_file())

    def test_cli_all_skips_planned_stories_and_fails_when_nothing_played(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = play.main(["--all", "--app", "/x/cmux DEV t.app", "--out", tempfile.mkdtemp()],
                             player=Fixture(self).player)
        self.assertEqual(code, 1)
        lines = [json.loads(line.removeprefix("CORPUS-PLAY ")) for line in out.getvalue().splitlines()]
        skipped = {line["story"]: line["skipped"] for line in lines}
        self.assertEqual(skipped["dev-loop"], "planned, not recorded")
        self.assertIn("no recorded story to play", err.getvalue())

    def test_cli_reports_a_failed_launch_as_the_storys_reason(self):
        fixture = Fixture(self)
        fixture.launch_error = bench_launch.LaunchError("tag-in-use", {"detail": "another run"})
        path = fixture.dir / "fixture-play.json"
        path.write_text(json.dumps(fixture.manifest))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = play.main([str(path), "--app", "/x/a.app", "--out", str(fixture.dir / "o")], player=fixture.player)
        report = json.loads(out.getvalue().splitlines()[-1].removeprefix("CORPUS-PLAY "))
        self.assertEqual(code, 1)
        self.assertIn("tag-in-use", report["reason"])


if __name__ == "__main__":
    unittest.main()
