#!/usr/bin/env python3
"""play.py against a fake app and a fake clock (no app, no macOS): the schedule keeps absolute deadlines (bounded
lateness, no drift, checkpoints and topology reads move the schedule), socket events are pipelined so a slow app does
not make the player late, checkpoint digests ignore ids and load but see which workspace shows, a digest mismatch
fails with the first diverging checkpoint, references (workspaces, panes, tabs, groups, windows) resolve against the
live topology, every event kind reaches its socket call with its send stamp, the PTY and agent tracks start at the
input origin, the web replay and agent install go through wpr.py's and agent_replay.py's real functions, the window
hook wraps the input track only, the series land in result-v1 records, and --verify / --all report as specified.

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
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
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
AGENT_REPLAY = REPO_ROOT / "scripts" / "perf-lab" / "corpus" / "agent_replay.py"

MS = play.NS_PER_MS
EVENT_CLOCK_OFFSET_S = 5000.0  # NSEvent's clock is not the signposts' clock: the fake keeps them apart


def wpr_fixtures():
    """test_corpus_wpr.py's fake wpr build and certificate (task 113's own fixtures)."""
    name = "perf_lab_test_corpus_wpr_fixtures"
    if name not in sys.modules:
        fixture_spec = importlib.util.spec_from_file_location(name, HERE / "test_corpus_wpr.py")
        module = importlib.util.module_from_spec(fixture_spec)
        sys.modules[name] = module
        fixture_spec.loader.exec_module(module)
    return sys.modules[name]


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
    """Enough of the control socket for play.py: a main window that shows one workspace at a time, more windows, a
    workspace group, panes with terminal tabs, a few actions, debug.key/mouse/agent_pane, debug.focus/surfaces with
    ids and load-dependent fields that change per instance, debug.frames, and the signposts the calls would write
    (ndjson lines, timebase 1/1). `handle` answers a request at a given app time; `rpc` is a blocking call that takes
    `cost_ms` of the fake clock."""

    def __init__(self, clock, cost_ms=1.0, missed=2, tabs=(2, 1)):
        self.clock, self.cost_ms, self.missed = clock, cost_ms, missed
        self.windows = [new_id()]
        self.groups = [{"id": new_id(), "name": "g"}]
        self.workspaces = []
        for count in tabs:
            pane = {"id": new_id(), "tabs": [new_id() for _ in range(count)]}
            pane["selected"] = pane["tabs"][0]
            self.workspaces.append({"id": new_id(), "key": new_id(), "panes": [pane]})
        self.shown, self.calls, self.lines = 0, [], []
        self.signpost_id = 0

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
        reply = self.handle(method, params or {}, self.clock.signpost_s())
        self.clock.advance_ms(self.cost_ms)
        return reply

    def handle(self, method, params, now):
        self.calls.append((method, copy.deepcopy(params)))
        if method == "snapshot.get":
            return {"topology": {
                "windows": [{"id": f"win_{key}", "key": key,
                             "workspace": self.workspaces[self.shown]["id"] if index == 0 else None}
                            for index, key in enumerate(self.windows)],
                "workspace_groups": self.groups,
                "workspaces": [
                    {"id": w["id"], "key": w["key"], "screens": [{"panes": [
                        {"id": p["id"], "selected_tab": p["selected"],
                         "tabs": [{"id": t, "kind": "terminal"} for t in p["tabs"]]} for p in w["panes"]]}]}
                    for w in self.workspaces]}}
        if method in ("debug.key", "debug.mouse") and params.get("window") not in self.windows:
            return {"error": "no window"}
        if method == "debug.key":
            if params.get("key") == "t" and params.get("modifiers") == ["cmd"]:
                pane = self.focused_pane()
                pane["tabs"].append(new_id())
                pane["selected"] = pane["tabs"][-1]
            self.interval("key", "key.frame", now, 2.0, "target=terminal age_ms=1.00")
            return {"handled_by": "responder", "injected_at": params.get("timestamp")}
        if method == "debug.mouse":
            return {"ok": True}
        if method == "debug.agent_pane":
            return {"pane": params.get("pane"), "result": {"sent": True}}
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
            elif params["action"] == "newWindow":
                self.windows.append(new_id())
            elif params["action"] == "terminal.sendText":
                return {"ok": True}
            elif params["action"] == "refuse":
                return {"error": {"code": "refused"}}
            self.interval("action", "action.commit", now, 4.0, f"id={params['action']} origin=socket input_age_ms=-1")
            return {"ok": True}
        if method == "debug.focus":
            shown = self.workspaces[self.shown]
            pane = self.focused_pane()
            return {"windows": [{"id": self.windows[0], "workspace": shown["key"], "consistent": True,
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


class FakeChannel:
    """One pipelined control connection: a send takes `write_ms` (the socket write) and never waits; the app serves
    the connection's requests in order, each `app.cost_ms` long, and a reply waits for its request's end."""

    def __init__(self, app, clock, write_ms=0.0):
        self.app, self.clock, self.write_ms = app, clock, write_ms
        self.free_ns, self.replies, self.sent, self.closed = clock.now_ns(), {}, [], False

    def send(self, method, params):
        self.clock.advance_ms(self.write_ms)
        self.sent.append((method, copy.deepcopy(dict(params)), self.clock.now_ns()))
        start = max(self.clock.now_ns(), self.free_ns)
        reply = self.app.handle(method, dict(params), start / 1e9)
        self.free_ns = start + round(self.app.cost_ms * MS)
        self.replies[len(self.sent)] = (self.free_ns, reply)
        return len(self.sent)

    def reply(self, ticket, timeout):
        ready, reply = self.replies.pop(ticket)
        self.clock.sleep_until(ready)
        return reply

    def close(self):
        self.closed = True


class FakeProcess:
    pid = 7


class FakeBench:
    def __init__(self, app, out, env, session, launch_error=None, config=None):
        self.app, self.out, self.env, self.session, self.config = app, Path(out), env, session, config
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
    """A spawned CLI. Its commands are daemon resource ops (workspace.move), so like the real one it writes no app
    signpost."""

    def __init__(self, argv, code=0):
        self.argv, self.code = list(argv), code

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


class FakeGate:
    """A PTY track's go signal: records when the origin releases it."""

    def __init__(self, clock, path):
        self.clock, self.path, self.ready, self.released_ns, self.closed = clock, Path(path), False, None, False

    def wait_ready(self, timeout_s):
        self.ready = True

    def release(self):
        assert self.ready
        self.released_ns = self.clock.now_ns()

    def close(self):
        self.closed = True


class FakeWebReplay:
    def __init__(self):
        self.served = []

    def require(self):
        pass

    @contextlib.contextmanager
    def __call__(self, archive, spki, out, app):
        self.served.append((archive.read_bytes(), spki, app))
        yield {"CMUX_NEXT_BENCH_CEF_SWITCHES": f"host-resolver-rules=MAP *:443 127.0.0.1:8443\n"
                                               f"ignore-certificate-errors-spki-list={spki}"}
        self.served.append("stopped")


class FakeAgents:
    def __init__(self):
        self.staged = []

    def require(self):
        pass

    def __call__(self, out, agents, fetch, app):
        self.staged.append((out, [fetch(agent["transcript"]).read_bytes() for agent in agents]))
        return {"CMUX_NEXT_ACPMUX_ROOT": str(out / "acpmux"), "ACPMUX_AGENT_LAUNCH": None}


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


def blob(data):
    return {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}


def connect(app, clock):
    """A Refs and a Sender over one fake pipelined connection to `app`, its main window pinned."""
    channel = FakeChannel(app, clock)
    refs = play.Refs(lambda method, params: play.call(channel, method, params))
    refs.pin()
    clis = []

    def spawn(argv):
        clis.append(FakeCli(argv))
        return clis[-1]

    return channel, refs, play.Sender(channel, refs, clock, spawn), clis


def send_all(sender, timeline):
    for item in timeline:
        if isinstance(item, play.Step):
            sender.send(item, sender.prepare(item)[0])
    sender.collect()


def recorded_digests(events=EVENTS, checkpoints=CHECKPOINTS):
    """What the recorder (task 116) stores: the digests a fresh app reaches at each checkpoint when the events are
    sent in order through the player's own Sender (no schedule)."""
    clock = FakeClock()
    app = FakeApp(clock)
    manifest = {"checkpoints": [{"t_ms": t, "name": n, "focus": None, "surfaces": None} for n, t in checkpoints]}
    timeline, _ = play.plan(manifest, events, play.corpus_manifest().TYPING_CLASSES)
    channel, _, sender, _ = connect(app, clock)
    digests = {}
    for item in timeline:
        if isinstance(item, play.Checkpoint):
            sender.collect()
            focus, surfaces, order = play.read_checkpoint(lambda method: play.call(channel, method))
            digests[item.name] = (play.focus_digest(focus, order), play.surfaces_digest(surfaces))
        else:
            sender.send(item, sender.prepare(item)[0])
    return digests


class Fixture:
    """A recorded manifest whose layout snapshot is a blob in a temporary cache, and a Player over fakes."""

    def __init__(self, test, events=EVENTS, digests=None, app_cost_ms=1.0, write_ms=0.0, **player_options):
        self.dir = Path(tempfile.mkdtemp(prefix="play-test-"))
        test.addCleanup(lambda: __import__("shutil").rmtree(self.dir, ignore_errors=True))
        data = json.dumps(SNAPSHOT, sort_keys=True, separators=(",", ":")).encode()
        self.blobs = {hashlib.sha256(data).hexdigest(): data}
        digests = digests or recorded_digests(events)
        self.manifest = {
            "schema": "cmux-perf-corpus-story/v1", "id": "fixture-play", "tier": "T1", "status": "recorded",
            "description": "A fixture.", "owner": "PL-perf-lab", "duration_ms": 1000,
            "layout": {"snapshot": blob(data), "workspaces": 2},
            "input": {"events": copy.deepcopy(events)}, "pty": [], "web_archive": None, "agents": [],
            "checkpoints": [{"t_ms": t, "name": n, "focus": digests[n][0], "surfaces": digests[n][1]}
                            for n, t in CHECKPOINTS],
            "metrics": copy.deepcopy(METRICS)}
        self.clock = FakeClock()
        self.app_cost_ms, self.write_ms = app_cost_ms, write_ms
        self.apps, self.benches, self.recordings, self.clis, self.windows = [], [], [], [], []
        self.channels, self.gates = [], []
        self.launch_error = None
        self.web, self.agents = FakeWebReplay(), FakeAgents()
        options = {"settle_s": 0.2, **player_options}
        self.player = play.Player(root=REPO_ROOT, clock=self.clock, fetch=self.fetch, make_bench=self.make_bench,
                                  import_layout=self.import_layout, signposts=self.signposts, spawn=self.spawn,
                                  open_channel=self.open_channel, pty_gate=self.pty_gate, web_replay=self.web,
                                  agents=self.agents, **options)

    def add_blob(self, data):
        self.blobs[hashlib.sha256(data).hexdigest()] = data
        return blob(data)

    def fetch(self, ref):
        path = self.dir / ref["sha256"]
        path.write_bytes(self.blobs[ref["sha256"]])
        return path

    def make_bench(self, app, *, out, env, session, config=None):
        fake = FakeApp(self.clock, cost_ms=self.app_cost_ms)
        self.apps.append(fake)
        bench = FakeBench(fake, out, env, session, self.launch_error, config)
        self.benches.append(bench)
        return bench

    def open_channel(self, bench):
        self.channels.append(FakeChannel(bench.app, self.clock, self.write_ms))
        return self.channels[-1]

    def pty_gate(self, path):
        self.gates.append(FakeGate(self.clock, path))
        return self.gates[-1]

    def import_layout(self, rpc, snapshot):
        self.imported = snapshot
        return FakeBuilder()

    def signposts(self, pid):
        recording = FakeRecording(self.apps[-1])
        self.recordings.append(recording)
        return recording

    def spawn(self, argv):
        cli = FakeCli(argv)
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
    def run_track(self, timeline, cost_ms, slow=None, checkpoint_ms=0.0, read_ms=None):
        clock = FakeClock()
        sent = []

        def prepare(step):
            took = (read_ms or {}).get(step.index)
            if took is not None:
                clock.advance_ms(took)
            return None, took is not None

        def send(step, _prepared):
            sent.append((step.index, clock.now_ns()))
            clock.advance_ms((slow or {}).get(step.index, cost_ms))

        def checkpoint(item):
            clock.advance_ms(checkpoint_ms)
            return {"name": item.name}

        origin = clock.now_ns()
        track = play.play_track(timeline, prepare=prepare, send=send, checkpoint=checkpoint, clock=clock)
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

    def test_a_topology_read_past_its_deadline_moves_the_schedule_and_is_not_lateness(self):
        track, sent, origin = self.run_track(steps([0, 10, 20, 30]), cost_ms=1, read_ms={1: 25})
        self.assertEqual(track.lateness_ms, [0.0] * 4)
        self.assertEqual(track.waited_ms, 16.0)  # the read began at 1 ms and ended at 26 ms, 16 ms past 10 ms
        self.assertEqual([at - origin for _, at in sent], [0, 26 * MS, 36 * MS, 46 * MS])

    def test_a_topology_read_before_its_deadline_moves_nothing(self):
        track, sent, origin = self.run_track(steps([0, 50]), cost_ms=1, read_ms={1: 20})
        self.assertEqual(track.waited_ms, 0.0)
        self.assertEqual(sent[1][1] - origin, 50 * MS)

    def test_at_origin_runs_once_at_the_origin(self):
        clock, starts = FakeClock(), []
        track = play.play_track(steps([0, 10]), prepare=lambda step: (None, False), send=lambda step, _: None,
                                checkpoint=lambda item: {}, clock=clock, at_origin=lambda: starts.append(clock.now_ns()))
        self.assertEqual(starts, [track.origin_ns])

    def test_a_checkpoint_runs_before_the_events_of_its_own_time(self):
        manifest = {"checkpoints": [{"t_ms": 100, "name": "c", "focus": None, "surfaces": None}]}
        timeline, _ = play.plan(manifest, EVENTS, play.corpus_manifest().TYPING_CLASSES)
        names = [(i.t_ms, type(i).__name__) for i in timeline if i.t_ms == 100]
        self.assertEqual(names, [(100.0, "Checkpoint"), (100.0, "Step")])

    def test_a_slow_app_does_not_make_the_replay_late_and_it_records_its_results(self):
        fixture = Fixture(self, app_cost_ms=120)  # each reply takes longer than the gaps between events
        result = fixture.replay()
        self.assertEqual(result.schedule["lateness_ms"]["max"], 0)
        self.assertGreater(result.schedule["waited_ms"], 0)  # the reads of the tab Cmd-T opened waited for the app
        self.assertEqual(len(result.checkpoints), 4)
        metrics = {r["metric"] for r in fixture.benches[0].records}
        self.assertIn("corpus.fixture_play.key_to_frame", metrics)
        sent = [at for method, _, at in fixture.channels[0].sent if method == "debug.key"]
        self.assertEqual(sent[1] - sent[0], 60 * MS)  # written on the recorded spacing, not after each reply

    def test_a_player_that_cannot_write_on_time_raises_and_records_nothing(self):
        fixture = Fixture(self, max_late_ms=5, write_ms=30)  # each socket write blocks 30 ms (back-pressure)
        with self.assertRaises(play.ScheduleError) as caught:
            fixture.replay()
        self.assertIn("late at p95", str(caught.exception))
        self.assertEqual(fixture.benches[0].records, [])
        self.assertTrue(fixture.benches[0].stopped)


# ---------------------------------------------------------------- digests

def digests_of(app):
    order = play.workspace_order(app.rpc("snapshot.get"))
    return play.focus_digest(app.rpc("debug.focus"), order), play.surfaces_digest(app.rpc("debug.surfaces"))


class Digests(unittest.TestCase):
    def test_same_state_in_two_apps_with_other_ids_and_load_has_one_digest(self):
        first, second = FakeApp(FakeClock()), FakeApp(FakeClock())
        second.calls = [("x", {})] * 7  # other generation, counters and phases
        self.assertEqual(digests_of(first), digests_of(second))

    def test_pane_order_and_window_order_do_not_change_the_digest(self):
        app = FakeApp(FakeClock())
        report = app.rpc("debug.surfaces")
        report["windows"][0]["panes"].reverse()
        self.assertEqual(play.surfaces_digest(report), play.surfaces_digest(app.rpc("debug.surfaces")))

    def test_focus_on_another_tab_or_workspace_changes_the_focus_digest(self):
        app = FakeApp(FakeClock())
        digests = {digests_of(app)[0]}
        pane = app.focused_pane()
        pane["selected"] = pane["tabs"][1]
        digests.add(digests_of(app)[0])
        app.shown = 1
        digests.add(digests_of(app)[0])
        self.assertEqual(len(digests), 3)

    def test_showing_another_workspace_of_the_same_shape_changes_the_focus_digest(self):
        app = FakeApp(FakeClock(), tabs=(1, 1))
        before = digests_of(app)
        app.shown = 1
        after = digests_of(app)
        self.assertNotEqual(before[0], after[0])
        self.assertEqual(before[1], after[1])  # the surfaces digest leaves which workspace shows to the focus digest
        self.assertEqual(play.focus_view(app.rpc("debug.focus"),
                                         play.workspace_order(app.rpc("snapshot.get")))["windows"][0]["workspace"], 1)

    def test_a_pane_that_shows_nothing_changes_the_surfaces_digest(self):
        app = FakeApp(FakeClock())
        report = app.rpc("debug.surfaces")
        before = play.surfaces_digest(report)
        report["windows"][0]["panes"][0]["blank"] = True
        report["blank_panes"] = 1
        self.assertNotEqual(play.surfaces_digest(report), before)


# ---------------------------------------------------------------- references and sending

class Sending(unittest.TestCase):
    def test_window_refs_send_to_that_window_and_events_without_one_to_the_main_window(self):
        clock = FakeClock()
        app = FakeApp(clock)
        events = [{"t_ms": 0, "kind": "action", "payload": {"id": "newWindow"}},
                  {"t_ms": 10, "kind": "key", "payload": {"phase": "down", "class": "named", "key_code": 36,
                                                          "modifiers": [], "window": "@win1"}},
                  {"t_ms": 20, "kind": "mouse", "payload": {"phase": "down", "button": 0, "x": 1, "y": 2,
                                                            "window": "@win1"}},
                  {"t_ms": 30, "kind": "key", "payload": {"phase": "down", "class": "named", "key_code": 36,
                                                          "modifiers": []}}]
        timeline, _ = play.plan({"checkpoints": []}, events, play.corpus_manifest().TYPING_CLASSES)
        _, _, sender, _ = connect(app, clock)
        send_all(sender, timeline)
        windows = [params["window"] for method, params in app.calls if method in ("debug.key", "debug.mouse")]
        self.assertEqual(windows, [app.windows[1], app.windows[1], app.windows[0]])

    def test_a_window_ref_with_no_window_fails_naming_its_event(self):
        clock = FakeClock()
        events = [{"t_ms": 0, "kind": "key", "payload": {"phase": "down", "class": "named", "key_code": 36,
                                                         "modifiers": [], "window": "@win1"}}]
        timeline, _ = play.plan({"checkpoints": []}, events, play.corpus_manifest().TYPING_CLASSES)
        _, _, sender, _ = connect(FakeApp(clock), clock)
        with self.assertRaises(play.PlayError) as caught:
            sender.prepare(timeline[0])
        self.assertIn("event 0 (key at 0 ms): @win1: there is no window 0", str(caught.exception))

    def test_every_vocabulary_cli_command_plays_with_its_references_resolved(self):
        vocabulary = play.corpus_manifest().load_vocabulary(REPO_ROOT)
        clock = FakeClock()
        app = FakeApp(clock)
        values = {"integer": "3", "number": "1.5", "boolean": "true"}

        def value(shape, after):
            if "enum" in shape:
                return shape["enum"][0]
            if shape["type"] == "ref":
                return "@g0" if after == "group" else "@w1"
            return values[shape["type"]]

        events, wanted = [], []
        for index, command in enumerate(vocabulary["cli"]):
            argv, resolved, previous = [], [], None
            for part in command["argv"]:
                word = part if isinstance(part, str) else value(part, previous)
                argv.append(word)
                previous = part if isinstance(part, str) else None
            for flag, shape in command["flags"].items():
                if shape != {"type": "switch"}:
                    argv += [flag, value(shape, None)]
            ids = {"@w1": app.workspaces[1]["id"], "@g0": app.groups[0]["id"]}
            resolved = [ids.get(word, word) for word in argv]
            events.append({"t_ms": index * 10, "kind": "cli", "payload": {"argv": argv}})
            wanted.append(resolved)
        self.assertEqual(play.corpus_manifest().event_errors(events, 10_000, play.corpus_manifest().load_schema(REPO_ROOT),
                                                             vocabulary), [])
        timeline, _ = play.plan({"checkpoints": []}, events, play.corpus_manifest().TYPING_CLASSES)
        _, _, sender, clis = connect(app, clock)
        send_all(sender, timeline)
        self.assertEqual([cli.argv for cli in clis], wanted)
        self.assertTrue(any("@g0" in event["payload"]["argv"] for event in events))

    def test_a_group_ref_is_not_an_action_target(self):
        clock = FakeClock()
        _, refs, _, _ = connect(FakeApp(clock), clock)
        with self.assertRaises(play.PlayError) as caught:
            refs.target("@g0")
        self.assertIn("is a group, not an action target", str(caught.exception))

    def test_typing_keys_and_scrolls_read_the_topology_once_shortcuts_and_clicks_again(self):
        clock = FakeClock()
        app = FakeApp(clock)
        typing = {"t_ms": 0, "kind": "key", "payload": {"phase": "down", "class": "letter", "modifiers": []}}
        scroll = {"t_ms": 0, "kind": "mouse", "payload": {"phase": "scroll", "button": 0, "x": 1, "y": 1, "dy": 3}}
        focus = {"t_ms": 0, "kind": "action", "payload": {"id": "tab.focus", "args": {"target": "@w0.p0.t1"}}}
        click = {"t_ms": 0, "kind": "mouse", "payload": {"phase": "down", "button": 0, "x": 1, "y": 1}}
        events = [focus, typing, scroll, focus, click, focus]
        timeline, _ = play.plan({"checkpoints": []}, events, play.corpus_manifest().TYPING_CLASSES)
        _, _, sender, _ = connect(app, clock)
        reads = []
        for step in timeline:
            prepared, read = sender.prepare(step)
            reads.append(read)
            sender.send(step, prepared)
        self.assertEqual(reads, [False, False, False, True, False, True])  # focus invalidates; typing and scroll do not

    def test_a_refused_event_fails_at_the_next_checkpoint_naming_it(self):
        clock = FakeClock()
        app = FakeApp(clock)
        events = [{"t_ms": 0, "kind": "action", "payload": {"id": "refuse"}}]
        timeline, _ = play.plan({"checkpoints": []}, events, play.corpus_manifest().TYPING_CLASSES)
        _, _, sender, _ = connect(app, clock)
        sender.send(timeline[0], sender.prepare(timeline[0])[0])  # the write does not wait for the refusal
        with self.assertRaises(play.PlayError) as caught:
            sender.collect()
        self.assertIn("event 0 (action at 0 ms): refused", str(caught.exception))


class Socket(unittest.TestCase):
    def test_requests_are_pipelined_and_replies_kept_by_id(self):
        folder = tempfile.mkdtemp(prefix="play-sock-")
        self.addCleanup(lambda: __import__("shutil").rmtree(folder, ignore_errors=True))
        path = os.path.join(folder, "s")
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(path)
        server.listen(1)
        go = threading.Event()

        def serve():
            connection, _ = server.accept()
            reader = connection.makefile("rb")
            go.wait(5)  # the app is busy: nothing is answered until the client wrote every request
            for line in reader:
                request = json.loads(line)
                ok = request["method"] != "bad"
                reply = {"id": request["id"], "ok": ok, **({"result": {"n": request["id"]}} if ok else {"error": "no"})}
                connection.sendall((json.dumps(reply) + "\n").encode())
            connection.close()

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        channel = play.SocketChannel(path)
        began = time.monotonic()
        tickets = [channel.send("a", {}), channel.send("bad", {}), channel.send("c", {})]
        self.assertLess(time.monotonic() - began, 1.0)  # the writes did not wait for replies
        go.set()
        self.assertEqual(channel.reply(tickets[2], 5), {"n": 3})
        self.assertEqual(channel.reply(tickets[0], 5), {"n": 1})
        self.assertEqual(channel.reply(tickets[1], 5), {"error": "no"})
        channel.close()
        thread.join(5)
        server.close()


class PtyGo(unittest.TestCase):
    def test_the_pty_clock_starts_at_the_players_go(self):
        folder = Path(tempfile.mkdtemp(prefix="play-go-"))
        self.addCleanup(lambda: __import__("shutil").rmtree(folder, ignore_errors=True))
        gate = play.FifoGate(folder / "pty-0.go")

        class Base:
            def now_ns(self):
                return time.monotonic_ns()

        started = []
        clock = play.GatedClock(Base(), gate.path)
        thread = threading.Thread(target=lambda: started.append(clock.now_ns()), daemon=True)
        thread.start()
        gate.wait_ready(5)
        time.sleep(0.05)  # test: the PTY process would start now without the gate
        self.assertEqual(started, [])
        released = time.monotonic_ns()
        gate.release()
        thread.join(5)
        self.assertEqual(len(started), 1)
        self.assertGreaterEqual(started[0], released)
        self.assertFalse(gate.path.exists())

    def test_the_pty_track_command_writes_nothing_before_go_then_its_recording(self):
        folder = Path(tempfile.mkdtemp(prefix="play-go-"))
        self.addCleanup(lambda: __import__("shutil").rmtree(folder, ignore_errors=True))
        source = folder / "x.vt"
        source.write_bytes(b"hello world")
        gate = play.FifoGate(folder / "pty-0.go")
        argv = [sys.executable, "-I", str(HERE.parent / "corpus" / "play.py"), "pty-track", "--go", str(gate.path),
                "--", str(source), "--timing-json", str(folder / "timing.json")]
        process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(process.kill)
        gate.wait_ready(20)
        time.sleep(0.1)  # test: a track that did not wait would have written and exited by now
        self.assertIsNone(process.poll())
        gate.release()
        out, err = process.communicate(timeout=20)
        self.assertEqual((process.returncode, out), (0, b"hello world"), err)
        self.assertEqual(json.loads((folder / "timing.json").read_text())["bytes"], 11)

    def test_a_gate_whose_process_never_starts_fails(self):
        folder = Path(tempfile.mkdtemp(prefix="play-go-"))
        self.addCleanup(lambda: __import__("shutil").rmtree(folder, ignore_errors=True))
        gate = play.FifoGate(folder / "pty-0.go")
        with self.assertRaises(play.PlayError) as caught:
            gate.wait_ready(0.05)
        self.assertIn("did not start", str(caught.exception))
        gate.close()


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
        self.assertTrue(fixture.channels[0].closed)

        keys = [params for method, params in app.calls if method == "debug.key"]
        self.assertEqual([(k["key"], k["modifiers"]) for k in keys], [("t", []), ("H", []), ("t", ["cmd"])])
        self.assertTrue(all(k["timestamp"] > EVENT_CLOCK_OFFSET_S for k in keys))  # stamped on NSEvent's clock
        self.assertEqual({k["window"] for k in keys}, {app.windows[0]})
        actions = [params for method, params in app.calls if method == "action.run"]
        tab = app.workspaces[0]["panes"][0]["tabs"]
        self.assertEqual(actions[0]["target"], f"tab:{tab[1]}")
        self.assertEqual(actions[1]["target"], f"workspace:{app.workspaces[0]['id']}")
        self.assertEqual(actions[2]["target"], f"tab:{tab[2]}")  # the tab Cmd-T opened during the replay
        self.assertEqual(fixture.clis[0].argv, [bench.cli, "--app-socket", bench.socket, "workspace",
                                                app.workspaces[1]["id"], "move", "--index", "0"])
        mice = [params for method, params in app.calls if method == "debug.mouse"]
        self.assertEqual(mice[1], {"action": "drag", "x": 10, "y": 20, "to_x": 30, "to_y": 25, "steps": 1,
                                   "press": False, "release": False, "button": "left", "modifiers": [],
                                   "window": app.windows[0]})

        by_metric = {r["metric"]: r for r in bench.records}

        def samples(series):
            return sorted(round(v, 6) for v in by_metric[f"corpus.fixture_play.{series}"]["samples"])

        self.assertEqual(samples("key_to_frame"), [3.0, 3.0, 3.0])  # key.frame 2 ms plus the key's 1 ms age
        self.assertEqual(samples("action_to_frame"), [4.0, 4.0, 4.0])
        self.assertEqual(samples("switch_to_frame"), [5.0, 5.0, 6.0])
        self.assertEqual(by_metric["corpus.fixture_play.dropped_frames"]["samples"], [2])
        self.assertEqual(by_metric["corpus.fixture_play.dropped_frames"]["unit"], "count")
        self.assertNotIn("corpus.fixture_play.tab_switch_to_frame", by_metric)  # not declared, not written
        self.assertEqual({r["engine"] for r in bench.records}, {"none"})
        self.assertEqual({r["story"] for r in bench.records}, {"corpus-fixture-play"})
        self.assertEqual(result.unmeasured, ["corpus\\.fixture_play\\.cli_to_frame", "corpus\\.fixture_play\\.main_turn"])
        self.assertEqual(result.units["corpus.fixture_play.dropped_frames"], "count")
        self.assertEqual(result.skipped_events, 2)  # the key up and the flags change
        self.assertEqual([c["name"] for c in result.checkpoints], ["start", "midpoint", "late", "end"])
        self.assertEqual(result.schedule["sent"], 10)
        self.assertEqual(result.schedule["lateness_ms"]["max"], 0)
        summary = json.loads((fixture.dir / "out" / "corpus-play-fixture-play.json").read_text())
        self.assertEqual(summary["results"], [str(bench.out / f"{r['metric']}.ndjson") for r in bench.records])
        self.assertTrue((fixture.dir / "out" / "host-env-full-7.json").is_file())
        self.assertTrue(bench.stopped)

    def test_a_cli_op_is_never_paired_with_an_unrelated_commit(self):
        # A real `workspace move` is the daemon's workspace.move: it writes no action.commit. The socket action at
        # 400 ms commits right after the CLI send at 300 ms; it is an action_to_frame sample, never cli_to_frame.
        fixture = Fixture(self)
        result = fixture.replay()
        self.assertNotIn("corpus.fixture_play.cli_to_frame", result.series)
        self.assertIn("corpus\\.fixture_play\\.cli_to_frame", result.unmeasured)

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

    def test_a_replay_that_shows_the_wrong_workspace_of_the_same_shape_fails_its_checkpoint(self):
        events = [{"t_ms": 100, "kind": "action", "payload": {"id": "nextSidebarTab", "args": {"target": "@w0"}}}]
        reference = FakeApp(FakeClock(), tabs=(1, 1))
        recorded = {name: digests_of(reference) for name, _ in CHECKPOINTS}
        reference.shown = 1
        recorded["midpoint"] = recorded["late"] = recorded["end"] = digests_of(reference)
        fixture = Fixture(self, events=events, digests=recorded)
        original = fixture.make_bench

        def same_shape(app, **kwargs):
            bench = original(app, **kwargs)
            pane = bench.app.workspaces[0]["panes"][0]
            pane["tabs"] = pane["tabs"][:1]
            pane["selected"] = pane["tabs"][0]
            real = bench.app.handle

            def handle(method, params, now):
                if method == "action.run" and params["action"] == "nextSidebarTab":
                    return {"ok": True}  # the switch is lost: the first workspace still shows
                return real(method, params, now)

            bench.app.handle = handle
            return bench

        fixture.player.make_bench = same_shape
        with self.assertRaises(play.DigestMismatch) as caught:
            fixture.replay()
        self.assertEqual((caught.exception.checkpoint, caught.exception.which), ("midpoint", "focus"))

    def test_a_checkpoint_waits_for_state_that_lands_late(self):
        fixture = Fixture(self, settle_s=1.0)
        original = fixture.make_bench

        def lagging(app, **kwargs):
            bench = original(app, **kwargs)
            fake, real, held = bench.app, bench.app.handle, {"reads": 0}

            def handle(method, params, now):
                report = real(method, params, now)
                if method == "debug.surfaces" and held["reads"] < 3:
                    held["reads"] += 1
                    report["blank_panes"] = 1  # the first reads come before the state settles
                return report

            fake.handle = handle
            return bench

        fixture.player.make_bench = lagging
        result = fixture.replay()
        self.assertEqual(len(result.checkpoints), 4)

    def test_a_missing_reference_fails_the_replay_naming_its_event(self):
        events = [*EVENTS[:5], {"t_ms": 200, "kind": "action", "payload": {"id": "tab.focus", "args": {"target": "@w0.p0.t9"}}}]
        fixture = Fixture(self, events=events, digests=recorded_digests(EVENTS))
        with self.assertRaises(play.PlayError) as caught:
            fixture.replay()
        self.assertIn("event 5 (action at 200 ms)", str(caught.exception))
        self.assertIn("no tab 9", str(caught.exception))

    def test_the_manifest_config_launches_the_bench(self):
        fixture = Fixture(self)
        fixture.replay()
        self.assertIsNone(fixture.benches[0].config, "no config: BenchApp keeps its default")
        fixture = Fixture(self)
        fixture.manifest["config"] = {"sidebar.numbering": "workspacesOnly", "browser.omnibar.remoteSuggestions": False}
        fixture.replay()
        self.assertEqual(fixture.benches[0].config, fixture.manifest["config"])

    def test_bench_config_sets_the_story_settings_over_the_default(self):
        base = {"appearance": {"backgroundOpacity": 1}, "browser": {"hibernation": "off"}}
        written = play.bench_config(base, {"browser.omnibar.remoteSuggestions": False, "sidebar.numbering": "workspacesOnly"})
        self.assertEqual(written, {"appearance": {"backgroundOpacity": 1},
                                   "browser": {"hibernation": "off", "omnibar": {"remoteSuggestions": False}},
                                   "sidebar": {"numbering": "workspacesOnly"}})
        self.assertEqual(base, {"appearance": {"backgroundOpacity": 1}, "browser": {"hibernation": "off"}})
        self.assertEqual(play.bench_config(bench_launch.DEFAULT_CONFIG, {})["appearance"], {"backgroundOpacity": 1})

    def test_a_manifest_config_that_is_not_a_setting_is_refused_before_launch(self):
        fixture = Fixture(self)
        fixture.manifest["config"] = {"sidebar.numberingg": "workspacesOnly"}
        with self.assertRaises(play.PlayError) as caught:
            fixture.replay()
        self.assertIn("$.config.sidebar.numberingg: not a cmux-next.json setting", str(caught.exception))
        self.assertEqual(fixture.benches, [])

    def test_a_failed_launch_raises_bench_launchs_launch_error(self):
        fixture = Fixture(self)
        fixture.launch_error = bench_launch.LaunchError("no-gui-session", {"detail": "nobody on the console"})
        with self.assertRaises(bench_launch.LaunchError) as caught:
            fixture.replay(window=fixture.window)
        self.assertEqual(caught.exception.reason, "no-gui-session")
        self.assertEqual(fixture.windows, [])

    def test_a_failed_cli_event_fails_the_replay(self):
        fixture = Fixture(self)
        fixture.player.spawn = lambda argv: FakeCli(argv, code=2)
        with self.assertRaises(play.PlayError) as caught:
            fixture.replay()
        self.assertIn("event 6 (cli at 300 ms): exit 2", str(caught.exception))

    def test_web_replay_and_agent_tracks_reach_the_app_environment(self):
        fixture = Fixture(self)
        wprgo, transcript = b"wpr archive", b'{"frame": 1}\n'
        spki = "A" * 43 + "="
        fixture.manifest["web_archive"] = {"wprgo": fixture.add_blob(wprgo), "spki": spki}
        fixture.manifest["agents"] = [{"surface": "@w0.p0.t0", "agent": "acp-replay",
                                       "transcript": fixture.add_blob(transcript)}]
        fixture.replay()
        env = fixture.benches[0].env
        self.assertEqual(fixture.web.served, [(wprgo, spki, "/x/cmux DEV t.app"), "stopped"])
        self.assertEqual(env["CMUX_NEXT_BENCH_CEF_SWITCHES"],
                         f"host-resolver-rules=MAP *:443 127.0.0.1:8443\nignore-certificate-errors-spki-list={spki}")
        self.assertEqual(fixture.agents.staged, [(fixture.dir / "out", [transcript])])
        self.assertEqual(env["CMUX_NEXT_ACPMUX_ROOT"], str(fixture.dir / "out" / "acpmux"))
        self.assertIsNone(env["ACPMUX_AGENT_LAUNCH"])  # launch_env's None unsets the variable in BenchApp
        self.assertEqual({r["engine"] for r in fixture.benches[0].records}, {"chromium"})

    def test_pty_and_agent_tracks_start_at_the_input_origin(self):
        fixture = Fixture(self)
        transcript = b'{"schema": "cmux-perf-acp-transcript/v1"}\n'
        fixture.manifest["pty"] = [{"surface": "@w0.p0.t1", "speed": 1, "loop": False,
                                    "source": fixture.add_blob(b"\x1b[2Jhello")}]
        fixture.manifest["agents"] = [{"surface": "@w0.p0.t0", "agent": "acp-replay",
                                       "transcript": fixture.add_blob(transcript)}]
        fixture.replay()
        input_channel, side = fixture.channels
        first_key = next(at for method, _, at in input_channel.sent if method == "debug.key")
        (gate,) = fixture.gates
        self.assertIsNotNone(gate.released_ns)
        self.assertLessEqual(abs(first_key - gate.released_ns) / MS, play.MAX_LATE_P95_MS)
        (prompt,) = side.sent
        app = fixture.apps[0]
        self.assertEqual(prompt[:2], ("debug.agent_pane", {"action": "send_prompt",
                                                           "pane": app.workspaces[0]["panes"][0]["id"],
                                                           "text": f"replay {hashlib.sha256(transcript).hexdigest()}"}))
        self.assertLessEqual(abs(first_key - prompt[2]) / MS, play.MAX_LATE_P95_MS)

    def test_pty_tracks_start_the_pty_player_in_their_terminal_behind_a_go_fifo(self):
        fixture = Fixture(self)
        app = FakeApp(FakeClock())
        bench = FakeBench(app, fixture.dir, {}, "corpus:fixture-play")
        manifest = {**fixture.manifest, "pty": [{"surface": "@w0.p0.t1", "source": None, "speed": 1, "loop": True}]}
        story = play.Story(manifest, fixture.dir / "fixture-play.json", SNAPSHOT, [], 0, "none")
        fixture.player.cache_dir = fixture.dir / "cache dir"
        gates = fixture.player.start_pty(story, bench, play.Refs(lambda m, p: app.rpc(m, p)), fixture.dir)
        (method, params), = [call for call in app.calls if call[0] == "action.run"]
        self.assertEqual((params["action"], params["target"], params["focus"]),
                         ("terminal.sendText", f"tab:{app.workspaces[0]['panes'][0]['tabs'][1]}", False))
        text = params["args"]["text"]
        self.assertTrue(text.startswith(f"CMUX_PERF_CORPUS_CACHE='{fixture.dir / 'cache dir'}' "))
        self.assertIn(f"play.py pty-track --go {fixture.dir / 'pty-0.go'} -- --manifest "
                      f"{fixture.dir / 'fixture-play.json'} --track 0 --root", text)
        self.assertTrue(text.endswith("\n"))
        self.assertEqual([gate.ready for gate in gates], [True])

    def test_replay_takes_the_window_hook_by_keyword(self):
        parameters = inspect.signature(play.replay).parameters
        self.assertEqual(parameters["window"].kind, inspect.Parameter.KEYWORD_ONLY)
        self.assertIsNone(parameters["window"].default)
        self.assertEqual([p for p in parameters][:3], ["manifest", "app", "out"])


# ---------------------------------------------------------------- the real track modules

class TrackModules(unittest.TestCase):
    def test_web_replay_runs_wpr_replay_and_gives_the_app_its_switches(self):
        fixtures, wpr = wpr_fixtures(), play.wpr_module()
        folder = Path(tempfile.mkdtemp(prefix="play-wpr-"))
        self.addCleanup(lambda: __import__("shutil").rmtree(folder, ignore_errors=True))
        directory = fixtures.make_wpr_dir(folder, commit=wpr.wpr_commit())
        archive = folder / "story.wprgo"
        archive.write_bytes(b"archive")
        Path(str(archive) + ".log").write_text("")
        chromium = folder / "Chromium"
        chromium.mkdir()
        replay = play.WebReplay(wpr_dir=directory, bundle_id=lambda app: "com.cmuxterm.app.debug.t",
                                chromium_root=lambda bundle: chromium)
        replay.require()
        with replay(archive, fixtures.CERT_SPKI, folder, "/x/cmux DEV t.app") as env:
            self.assertEqual(env, {"CMUX_NEXT_BENCH_CEF_SWITCHES": wpr.bench_switches(41001, 41002, fixtures.CERT_SPKI)})
        self.assertFalse(chromium.exists())  # moved aside: no cached subresource bypasses the replay
        self.assertTrue((folder / "wpr-replay.log").is_file())

    def test_web_replay_refuses_an_archive_of_another_wpr_certificate(self):
        fixtures, wpr = wpr_fixtures(), play.wpr_module()
        folder = Path(tempfile.mkdtemp(prefix="play-wpr-"))
        self.addCleanup(lambda: __import__("shutil").rmtree(folder, ignore_errors=True))
        replay = play.WebReplay(wpr_dir=fixtures.make_wpr_dir(folder, commit=wpr.wpr_commit()),
                                bundle_id=lambda app: "com.cmuxterm.app.debug.t", chromium_root=lambda b: folder / "C")
        with self.assertRaises(play.PlayError) as caught:
            with replay(folder / "a.wprgo", fixtures.RSA_SPKI, folder, "/x/a.app"):
                pass
        self.assertIn("is not this wpr build's certificate", str(caught.exception))

    @unittest.skipIf(AGENT_REPLAY.is_file(), "agent_replay.py (task 114) is in this checkout")
    def test_agent_tracks_need_agent_replay_before_launch(self):
        fixture = Fixture(self)
        fixture.player.agents = play.AgentTracks()
        fixture.manifest["agents"] = [{"surface": "@w0.p0.t0", "agent": "acp-replay",
                                       "transcript": fixture.add_blob(b"{}\n")}]
        with self.assertRaises(play.PlayError) as caught:
            fixture.replay()
        self.assertIn("agent_replay.py (p12-perf-process-114) is missing", str(caught.exception))
        self.assertEqual(fixture.benches, [])

    @unittest.skipUnless(AGENT_REPLAY.is_file(), "agent_replay.py (task 114) is not in this checkout")
    def test_agent_tracks_install_the_replay_harness_with_agent_replays_functions(self):
        folder = Path(tempfile.mkdtemp(prefix="play-agents-"))
        self.addCleanup(lambda: __import__("shutil").rmtree(folder, ignore_errors=True))
        transcript = b'{"schema": "cmux-perf-acp-transcript/v1"}\n{"t_ms": 0, "kind": "end", "stop": "end_turn"}\n'
        source = folder / "blob"
        source.write_bytes(transcript)
        tracks = play.AgentTracks(bundle_id=lambda app: "com.cmuxterm.app.debug.t")
        tracks.require()
        digest = hashlib.sha256(transcript).hexdigest()
        env = tracks(folder, [{"surface": "@w0.p0.t0", "agent": "acp-replay", "transcript": blob(transcript)}],
                     lambda ref: source, "/x/cmux DEV t.app")
        self.assertEqual(env, play.agent_replay().launch_env(folder / "acpmux", folder / "agent-config"))
        self.assertEqual(env["CMUX_NEXT_ACPMUX_ROOT"], str(folder / "acpmux"))
        self.assertEqual(env["XDG_CONFIG_HOME"], str(folder / "agent-config"))
        self.assertEqual((folder / "agent-transcripts" / digest).read_bytes(), transcript)
        self.assertTrue((folder / "agent-config" / "cmux" / "harnesses" / "replay.toml").is_file())
        home = folder / "acpmux" / "builds" / "com.cmuxterm.app.debug.t"
        self.assertEqual(json.loads((home / "config.json").read_text())["defaultHarness"], "replay")


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

    def test_a_click_count_debug_mouse_cannot_send_is_refused(self):
        fixture = Fixture(self)
        fixture.manifest["input"]["events"].append(
            {"t_ms": 900, "kind": "mouse", "payload": {"phase": "down", "button": 0, "x": 5, "y": 5, "click_count": 2}})
        self.assert_refused(fixture, "event 12: a mouse down with click_count 2")

    def test_a_layout_with_another_workspace_count_is_refused(self):
        fixture = Fixture(self)
        fixture.manifest["layout"]["workspaces"] = 3
        self.assert_refused(fixture, "the snapshot has 2 workspaces")

    def test_an_agent_track_on_a_hidden_chat_tab_is_refused(self):
        fixture = Fixture(self)
        fixture.manifest["agents"] = [{"surface": "@w1.p0.t0", "agent": "acp-replay",
                                       "transcript": fixture.add_blob(b"{}\n")}]
        self.assert_refused(fixture, "no socket method sends a prompt to a hidden chat tab")

    def test_a_web_archive_needs_wpr_before_launch(self):
        fixture = Fixture(self)
        fixture.player.web_replay = play.WebReplay()
        fixture.manifest["web_archive"] = {"wprgo": fixture.add_blob(b"archive"), "spki": "A" * 43 + "="}
        original = play.WPR_API
        play.WPR_API = (*original, "no_such_function")
        self.addCleanup(setattr, play, "WPR_API", original)
        sys.modules.pop("perf_lab_corpus_wpr", None)
        self.addCleanup(sys.modules.pop, "perf_lab_corpus_wpr", None)
        self.assert_refused(fixture, "wpr.py (p12-perf-process-113) has no no_such_function")


# ---------------------------------------------------------------- verify and the CLI

def run(checkpoints, series, units=None):
    return play.Replay("s", checkpoints, {}, series, [], [], 0, units or {})


class Verify(unittest.TestCase):
    CHECKS = [{"name": "a", "focus": "1" * 64, "surfaces": "2" * 64}, {"name": "b", "focus": "3" * 64, "surfaces": "4" * 64}]

    def test_equal_runs_agree(self):
        self.assertEqual(play.compare_runs(run(self.CHECKS, {"m": [1, 2, 3] * 4}),
                                           run(self.CHECKS, {"m": [1, 2.1, 3] * 4})), [])

    def test_the_first_diverging_checkpoint_is_named(self):
        other = copy.deepcopy(self.CHECKS)
        other[1]["surfaces"] = "5" * 64
        problems = play.compare_runs(run(self.CHECKS, {}), run(other, {}))
        self.assertEqual(len(problems), 1)
        self.assertTrue(problems[0].startswith("checkpoint b:"))

    def test_a_metric_whose_p50_varies_over_the_cv_bound_is_named(self):
        problems = play.compare_runs(run(self.CHECKS, {"m": [10] * 10}), run(self.CHECKS, {"m": [14] * 10}))
        self.assertEqual(len(problems), 1)
        self.assertIn("m: p50 10 vs 14, cv 0.236", problems[0])

    def test_a_latency_series_with_too_few_samples_is_not_compared(self):
        self.assertEqual(play.compare_runs(run(self.CHECKS, {"m": [10, 10]}), run(self.CHECKS, {"m": [14, 14]})), [])

    def test_one_more_dropped_frame_is_within_the_count_tolerance(self):
        units = {"dropped": "count"}
        for a, b in ((0, 1), (3, 4), (0, 2)):
            self.assertEqual(play.compare_runs(run(self.CHECKS, {"dropped": [a]}, units),
                                               run(self.CHECKS, {"dropped": [b]}, units)), [], (a, b))
        problems = play.compare_runs(run(self.CHECKS, {"dropped": [0]}, units), run(self.CHECKS, {"dropped": [9]}, units))
        self.assertEqual(len(problems), 1)
        self.assertIn("dropped: p50 0 vs 9", problems[0])
        self.assertEqual(play.compare_runs(run(self.CHECKS, {"dropped": [300]}, units),
                                           run(self.CHECKS, {"dropped": [306]}, units)), [])  # within the CV bound

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
