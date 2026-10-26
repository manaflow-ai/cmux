#!/usr/bin/env python3
"""record.py (the corpus recorder, task p12-perf-process-116) against a fake bench app (no app): what it refuses,
the privacy fixture (a journal that carries typed characters stores none), the checkpoint digests, the PTY tap
and a whole recording into a valid manifest.

  python3 -m unittest scripts/perf-lab/tests/test_record.py
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import plistlib
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

TESTS = Path(__file__).resolve().parent
LAB = TESTS.parent


def load(name, path):
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name]


record = load("corpus_record_under_test", LAB / "corpus" / "record.py")
fixtures = load("test_session_io_fixtures", TESTS / "test_session_io.py")
manifest_module = record.corpus_manifest()
pty_replay = record.pty_replay()
SECRET = "hunter2"
BENCH_MARKER = b"CMUX_BENCH_HOOKS_BUILD"


def bundle(folder, name="cmux DEV rec.app", bundle_id="com.cmuxterm.app.debug.rec", marker=True, debug=False):
    app = Path(folder) / name
    (app / "Contents/MacOS").mkdir(parents=True)
    with open(app / "Contents/Info.plist", "wb") as handle:
        plistlib.dump({"CFBundleIdentifier": bundle_id}, handle)
    (app / "Contents/MacOS/cmux DEV").write_bytes(b"\0binary\0" + (BENCH_MARKER if marker else b"") + b"\0")
    if debug:
        (app / "Contents/MacOS/cmux DEV.debug.dylib").write_bytes(b"\0")
    return str(app)


class NsClock:
    """The recorder's monotonic clock and its sleep: a sleep advances it."""

    def __init__(self):
        self.ns = 1_000_000_000_000

    def __call__(self):
        return self.ns

    def sleep(self, seconds):
        self.ns += max(int(seconds * 1e9), 1_000_000)


def key(phase, key_class, code, modifiers=0, characters=None):
    return {"key": {"_0": {"phase": phase, "keyClass": key_class, "keyCode": code, "modifiers": modifiers,
                           "isRepeat": False, **({"characters": characters} if characters is not None else {})}}}


def typed(text, start_ms, step_ms=100):
    """Key-down records of TEXT as a debug build with the characters opt-in journals them: key codes and characters."""
    codes = {"h": 4, "u": 32, "n": 45, "t": 17, "e": 14, "r": 15, "2": 19}
    return [(start_ms + i * step_ms, None, key("down", "digit" if c.isdigit() else "letter", codes[c], 0, c))
            for i, c in enumerate(text)]


class JournalApp(fixtures.TreeApp):
    """TreeApp (test_session_io.py) with the input journal, debug.focus, debug.surfaces, system.identify and a PTY tap
    that `terminal.sendText` starts. `script`: (ms after the start marker, window, journal kind) entries that appear
    once the clock reaches them."""

    def __init__(self, clock, script=(), descending_ids=False, **options):
        self.descending_ids = descending_ids
        super().__init__(**options)
        self.ns, self.script = clock, list(script)
        self.ring, self.seq, self.start_ns, self.cleared = [], 0, None, False
        self.stats = {"enabled": True, "recordsCharacters": False, "capacity": 4096}
        self.capacity = 4096  # the ring: the oldest entries go when it is full
        self.tap_frames = []  # (ms after the tap starts, bytes) the fake tap writes
        self.tap_frames_of = {}  # tap file name: its own tap_frames
        self.tap_lines, self.tap_stops = [], []
        self.delay_ns = {"clear": 0, "marker": 0}  # how long the app takes before it clears or appends a marker
        self.after_marker = None  # a record another thread appends right after each marker, before the read

    def ident(self, prefix):
        if not self.descending_ids:
            return super().ident(prefix)
        self.next += 1
        return f"{prefix}_{10**6 - self.next}"

    def append(self, uptime, window, kind):
        self.seq += 1
        entry = {"seq": self.seq, "uptimeNanos": uptime, "window": window, "kind": kind}
        self.ring = (self.ring + [entry])[-self.capacity:]

    def journal(self, params):
        if self.start_ns is not None:
            while self.script and self.start_ns + self.script[0][0] * 1_000_000 <= self.ns():
                at, window, kind = self.script.pop(0)
                self.append(self.start_ns + at * 1_000_000, window, kind)
        if "marker" in params:
            self.ns.ns += self.delay_ns["marker"]
            self.append(self.ns(), None, {"marker": {"_0": params["marker"]}})
            if self.start_ns is None and self.cleared:
                self.start_ns = self.ns()
            if self.after_marker is not None:
                self.append(self.ns(), None, self.after_marker)
        if params.get("clear"):
            self.ns.ns += self.delay_ns["clear"]
            self.ring, self.cleared = [], True
        last = params.get("last", 200)
        return {"stats": {**self.stats, "count": len(self.ring), "lastSeq": self.seq},
                "entries": self.ring[-last:] if last else []}

    def focus(self):
        workspace = next(w for w in self.workspaces if w["id"] == self.shown)
        pane = self.panes.get(self.focused_pane) if self.focused_pane in self.leaves(workspace["tree"]) else None
        model = {"resolved": "terminal" if pane else "none", "resolved_pane": pane and pane["id"],
                 "resolved_tab": pane and pane["selected"], "overlays": [], "sidebar_hidden": False,
                 "generation": self.ns() % 977}
        return {"windows": [{"id": "win_1", "model": model, "recent_events": [str(self.ns())]}],
                "context": {"terminal_focused": bool(pane), "palette_open": False}}

    def surfaces(self):
        workspace = next(w for w in self.workspaces if w["id"] == self.shown)
        shown = set(self.leaves(workspace["tree"]))
        panes = [{"pane": pane_id, "kind": "terminal", "visible": pane_id in shown,
                  "presence": "visible" if pane_id in shown else "hidden", "selected_tab": pane["selected"],
                  "shown_tab": pane["selected"] if pane_id in shown else None, "phase": "live"}
                 for pane_id, pane in sorted(self.panes.items()) if self.owner(pane_id)]
        return {"windows": [{"window": "1", "panes": panes}], "live_terminals": len(panes)}

    def start_tap(self, text):
        argv = shlex.split(text.rstrip("\r"))
        out, stop = argv[argv.index("--out") + 1], argv[argv.index("--stop-file") + 1]
        self.tap_lines.append(argv)
        self.tap_stops.append(stop)
        header = pty_replay.TTYREC_HEADER
        data = b""
        for at_ms, chunk in self.tap_frames_of.get(Path(out).name, self.tap_frames):
            stamp = self.ns() + int(at_ms * 1_000_000)
            data += header.pack(stamp // 1_000_000_000, (stamp // 1000) % 1_000_000, len(chunk)) + chunk
        Path(out).write_bytes(data)
        Path(out + ".done").write_text("0")
        self.tap_stop = stop

    def rpc(self, method, params=None, timeout=60):
        params = params or {}
        if method == "debug.journal":
            return self.journal(params)
        if method == "debug.focus":
            return self.focus()
        if method == "debug.surfaces":
            return self.surfaces()
        if method == "system.identify":
            return {"bundle_id": "com.cmuxterm.app.debug.rec", "pid": 4242, "app_bundle_path": "/tmp/x"}
        if method == "action.run" and params.get("action") == "terminal.sendText" \
                and "pty-tap" in params["args"]["text"]:
            self.start_tap(params["args"]["text"])
        return super().rpc(method, params, timeout)


def template(duration_ms=3000, pty=()):
    return {"schema": "cmux-perf-corpus-story/v1", "id": "record-fixture", "tier": "T1", "status": "planned",
            "planned": "the recorder fixture", "description": "A recorder test story.", "owner": "PL-perf-lab",
            "duration_ms": duration_ms, "layout": {"snapshot": None, "workspaces": 1}, "input": {"blob": None},
            "pty": list(pty), "web_archive": None, "agents": [],
            "checkpoints": [{"t_ms": 0, "name": "start", "focus": None, "surfaces": None},
                            {"t_ms": 1500, "name": "midpoint", "focus": None, "surfaces": None}],
            "metrics": [{"name": "corpus\\.fixture\\.key_to_frame", "unit": "ms", "better": "lower"}]}


class Case(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp(prefix="record-test-"))
        self.cache = manifest_module.BlobCache(self.folder / "cache", lambda digest: self.fail(f"fetch {digest}"))
        self.clock = NsClock()

    def app(self, script=(), **options):
        made = JournalApp(self.clock, script, **options)
        made.clock = fixtures.stress.time = fixtures.FakeClock()  # the layout export's waits end at once
        return made

    def recording(self, app, story=None, **options):
        return record.Recording(app.rpc, story or template(), cache=self.cache, folder=self.folder / "out",
                                clock=self.clock, private=["/home/someone-private"], **options)

    def stored(self):
        """Every byte the recording wrote: the cache's blobs and the out folder's files."""
        return b"".join(path.read_bytes() for path in sorted(self.folder.rglob("*")) if path.is_file())


class RefusalTests(Case):
    def test_the_persons_cmux_is_refused(self):
        self.assertIn("person's cmux", record.bundle_refusal("/Applications/cmux.app"))
        self.assertIn("person's cmux", record.bundle_refusal(bundle(self.folder, name="cmux.app")))

    def test_the_persons_bundle_id_is_refused(self):
        app = bundle(self.folder, bundle_id="com.cmuxterm.app")
        self.assertIn("com.cmuxterm.app", record.bundle_refusal(app))
        bench = bundle(self.folder / "b")
        self.assertIn("com.cmuxterm.app", record.bundle_refusal(bench, reported_id="com.cmuxterm.app"))

    def test_a_non_bench_bundle_is_refused(self):
        for options, reason in [({"marker": False}, "release build"), ({"debug": True}, "debug build"),
                                ({"bundle_id": "com.example.other"}, "not a com.cmuxterm.app.debug"),
                                ({"name": "Other.app"}, "not a tagged")]:
            with self.subTest(options):
                folder = Path(tempfile.mkdtemp(dir=self.folder))
                self.assertIn(reason, record.bundle_refusal(bundle(folder, **options)))

    def test_a_tagged_bench_bundle_may_be_recorded(self):
        app = bundle(self.folder)
        self.assertIsNone(record.bundle_refusal(app))
        self.assertIsNone(record.bundle_refusal(app, reported_id="com.cmuxterm.app.debug.rec"))
        self.assertIn("running app says", record.bundle_refusal(app, reported_id="com.cmuxterm.app.debug.other"))

    def test_the_characters_switch_is_refused_whatever_its_value(self):
        for value in ("1", "0", ""):
            self.assertIn(record.CHARACTERS_KEY, record.env_refusal({record.CHARACTERS_KEY: value}))
        self.assertIsNone(record.env_refusal({record.ENABLE_KEY: "1"}))

    def test_a_running_apps_environment_is_read_and_fails_closed(self):
        def ps(output, code=0):
            return lambda *a, **k: subprocess.CompletedProcess(a, code, stdout=output, stderr="")

        self.assertIsNone(record.process_env_refusal(1, ps("cmux DEV HOME=/x CMUX_NEXT_INPUT_JOURNAL=1")))
        self.assertIn(record.CHARACTERS_KEY,
                      record.process_env_refusal(1, ps(f"cmux DEV {record.CHARACTERS_KEY}=0 HOME=/x")))
        self.assertIn("cannot read", record.process_env_refusal(1, ps("", 1)))
        self.assertIn("cannot read", record.process_env_refusal(None, ps("cmux DEV")))

    def test_a_ps_output_without_an_environment_is_refused(self):
        """macOS ps -E prints only the command when it cannot read the process's environment."""
        command = "/x/cmux DEV rec.app/Contents/MacOS/cmux DEV"
        done = subprocess.CompletedProcess([], 0, stdout=command + "\n", stderr="")
        self.assertIn("no environment", record.process_env_refusal(1, lambda *a, **k: done))
        done = subprocess.CompletedProcess([], 0, stdout=f"{command} --flag CMUX_NEXT_INPUT_JOURNAL=1\n", stderr="")
        self.assertIsNone(record.process_env_refusal(1, lambda *a, **k: done))

    def test_a_journal_that_is_off_or_records_characters_is_refused(self):
        self.assertIn(record.ENABLE_KEY, record.journal_refusal({"enabled": False, "recordsCharacters": False}))
        self.assertIn("records characters", record.journal_refusal({"enabled": True, "recordsCharacters": True}))
        self.assertIsNone(record.journal_refusal({"enabled": True, "recordsCharacters": False}))

    def test_the_cli_refuses_before_it_launches_anything(self):
        bench = bundle(self.folder)
        cases = [(["--app", "/Applications/cmux.app"], {}), (["--app", bench], {record.CHARACTERS_KEY: "1"})]
        for target, env in cases:
            with self.subTest(target), mock.patch.dict(os.environ, env), \
                    mock.patch.object(record.bench_launch(), "BenchApp", side_effect=AssertionError("launched")):
                err = io.StringIO()
                with contextlib.redirect_stderr(err):
                    code = record.main(["record", *target, "--story", "dev-loop", "--out", str(self.folder / "o")])
                self.assertEqual(code, 2)
                self.assertIn("refused", err.getvalue())


class PrivacyFixtureTests(Case):
    """The acceptance fixture: the journal carries what a characters-mode debug journal holds (key codes and
    characters of typing); the recording stores no typed character."""

    def script(self):
        return typed(SECRET, 200) + [
            (1000, None, key("down", "letter", 17, 1, "t")),  # Cmd-T: a shortcut keeps its key code
            (1100, None, key("down", "named", 36, 0, "\r")),
            (1200, "win_2", {"mouse": {"_0": {"phase": "down", "button": 0, "x": 10.26, "y": 20, "clickCount": 1,
                                               "modifiers": 0, "count": 1, "dx": 0, "dy": 0}}}),
            (1250, None, {"focus": {"_0": {"generation": 3}, "after": {"resolved": "terminal"}}}),
            (1300, None, {"marker": {"_0": SECRET}}),
        ]

    def test_a_recording_stores_no_typed_character(self):
        app = self.app(self.script())
        recording = self.recording(app)
        recording.start(sleep=self.clock.sleep)
        manifest = recording.run(sleep=self.clock.sleep)
        record.write_manifest(manifest, self.folder / "out")
        stored = self.stored()
        self.assertNotIn(SECRET.encode(), stored)
        self.assertNotIn(b"characters", stored)
        for text in fixtures.PRIVATE:
            self.assertNotIn(text.encode(), stored)
        events = manifest["input"]["events"]
        typing = [e for e in events if e["kind"] == "key" and e["payload"]["class"] in ("letter", "digit")
                  and not {"cmd", "ctrl"} & set(e["payload"]["modifiers"])]
        self.assertEqual([e["payload"]["class"] for e in typing], ["letter"] * 6 + ["digit"])
        self.assertTrue(all("key_code" not in e["payload"] for e in typing))
        shortcut = next(e for e in events if e["payload"].get("modifiers") == ["cmd"])
        self.assertEqual(shortcut["payload"]["key_code"], 17)
        self.assertEqual([e["kind"] for e in events], ["key"] * 9 + ["mouse"], "focus records and markers are no input")
        self.assertEqual(events[0]["t_ms"], 200)
        self.assertEqual(events[-1]["payload"]["window"], "@win1")
        self.assertEqual(events[-1]["payload"]["x"], 10.3)
        self.assertEqual(manifest["status"], "recorded")
        self.assertNotIn("planned", manifest)
        self.assertEqual([(c["name"], c["t_ms"]) for c in manifest["checkpoints"]],
                         [("start", 0), ("midpoint", 1500), ("end", 3000)])
        self.assertEqual(manifest_module.validation_errors(manifest), [])
        layout = self.cache.get(manifest["layout"]["snapshot"])
        self.assertEqual(json.loads(layout)["schema"], "cmux-layout-snapshot/v1")

    def test_a_long_input_track_is_an_ndjson_blob_that_passes_the_text_check(self):
        script = [(10 + i, None, key("down", "letter", 4, 0, "h")) for i in range(record.INLINE_EVENTS + 5)]
        app = self.app(script)
        recording = self.recording(app)
        recording.start(sleep=self.clock.sleep)
        manifest = recording.run(sleep=self.clock.sleep)
        blob = self.cache.get(manifest["input"]["blob"])
        self.assertEqual(len(blob.splitlines()), record.INLINE_EVENTS + 5)
        self.assertNotIn(b"key_code", blob)
        self.assertEqual(manifest_module.blob_input_errors(manifest, self.cache, manifest_module.load_schema(),
                                                           manifest_module.load_vocabulary()), [])

    def test_a_journal_that_starts_recording_characters_stops_the_recording(self):
        app = self.app(typed(SECRET, 100))
        recording = self.recording(app)
        recording.start(sleep=self.clock.sleep)
        app.stats["recordsCharacters"] = True
        with self.assertRaisesRegex(record.RecordError, "records characters"):
            recording.run(sleep=self.clock.sleep)

    def test_entries_the_ring_dropped_stop_the_recording(self):
        app = self.app([(100, None, key("down", "named", 36))] * 5)
        recording = self.recording(app)
        recording.start(sleep=self.clock.sleep)
        app.capacity = 2
        with self.assertRaisesRegex(record.RecordError, "dropped entries"):
            recording.run(sleep=self.clock.sleep)


class CheckpointDigestTests(Case):
    def built(self, **options):
        app = self.app(**options)
        made = record.session_io().import_layout(app.rpc, fixtures.MIXED)
        self.addCleanup(made.close)
        return app

    def test_the_digests_do_not_depend_on_ids_or_timing(self):
        first, second = self.built(), self.built(descending_ids=True)
        a = record.checkpoint_digests(first.rpc)
        self.clock.sleep(5)  # another generation and recent events in debug.focus
        self.assertEqual(a, record.checkpoint_digests(second.rpc))
        self.assertEqual(a, record.checkpoint_digests(first.rpc))

    def test_a_focus_or_tab_change_changes_its_digest(self):
        app = self.built()
        focus, surfaces = record.checkpoint_digests(app.rpc)
        workspace = next(w for w in app.workspaces if w["id"] == app.shown)
        app.focused_pane = app.leaves(workspace["tree"])[0]
        moved = record.checkpoint_digests(app.rpc)
        self.assertNotEqual(moved[0], focus)
        pane = app.panes[app.leaves(workspace["tree"])[-1]]
        pane["selected"] = pane["tabs"][0]["id"]
        self.assertNotEqual(record.checkpoint_digests(app.rpc)[1], surfaces)

    def test_layout_refs_name_the_shown_and_one_pane_workspaces(self):
        app = self.built()
        topology = app.topology()["topology"]
        refs = record.layout_refs(topology, record.shown_orders(app.rpc, topology))
        shown = next(w for w in app.workspaces if w["id"] == app.shown)
        self.assertEqual(refs["@w2"], shown["id"])
        self.assertEqual(refs["@w2.p0"], app.leaves(shown["tree"])[0], "leaf order: the snapshot's pane order")
        self.assertIn("@w0.p0.t0", refs)
        self.assertNotIn("@w3.p0", {r for r in refs if r.startswith("@w3.p1")})


class PtyTests(Case):
    def test_trim_keeps_the_frames_of_the_measured_window_from_its_start(self):
        header = pty_replay.TTYREC_HEADER
        start = 5_000_000_000

        def frame(ns, data):
            return header.pack(ns // 1_000_000_000, (ns // 1000) % 1_000_000, len(data)) + data

        data = frame(start - 1_000_000, b"before") + frame(start + 250_000_000, b"a") + \
            frame(start + 1_000_000_000, b"b") + frame(start + 3_000_000_000, b"after")
        recording = pty_replay.decode_ttyrec(record.trim_tap(data, start, start + 2_000_000_000))
        self.assertEqual([(f.offset_ns, f.data) for f in recording.frames],
                         [(0, b""), (250_000_000, b"a"), (1_000_000_000, b"b")])

    def test_the_tap_shows_and_keeps_the_commands_output_and_sends_it_nothing(self):
        out, stop = self.folder / "tap.ttyrec", self.folder / "tap.stop"
        read_end, write_end = os.pipe()
        command = ["/bin/sh", "-c", "printf hello; sleep 0.1; printf world; read line || printf ' no-input'"]
        self.assertEqual(record.tap(command, str(out), str(stop), output_fd=write_end), 0)
        os.close(write_end)
        with os.fdopen(read_end, "rb") as shown:
            self.assertEqual(shown.read(), b"helloworld no-input")
        self.assertEqual(pty_replay.decode_ttyrec(out.read_bytes()).data, b"helloworld no-input")
        self.assertTrue(Path(f"{out}.done").exists())

    def test_a_recorded_pty_track_is_a_blob_of_the_measured_window(self):
        planned = [{"surface": "@w0.p0.t0", "source": None, "speed": 2, "loop": True}]
        app = self.app()
        app.tap_frames = [(-5, b"setup\n"), (1000, b"build line 1\n"), (2000, b"build line 2\n"), (99_000, b"late\n")]
        recording = self.recording(app, template(pty=planned))
        recording.start(["@w0.p0.t0=python3 -I scripts/perf-lab/corpus/pty_replay.py build.vt"], sleep=self.clock.sleep)
        manifest = recording.run(sleep=self.clock.sleep)
        self.assertTrue(Path(app.tap_stop).exists(), "the recorder stops the tap")
        (track,) = manifest["pty"]
        self.assertEqual((track["surface"], track["speed"], track["loop"]), ("@w0.p0.t0", 2, True))
        frames = pty_replay.decode_ttyrec(self.cache.get(track["source"])).frames
        self.assertEqual([(f.offset_ns // 1_000_000, f.data) for f in frames],
                         [(0, b""), (1000, b"build line 1\n"), (2000, b"build line 2\n")])
        self.assertEqual(manifest["status"], "recorded")

    def test_a_pty_track_with_the_accounts_text_is_refused(self):
        private = ["/home/someone-private"]
        self.assertIn(private[0], record.pty_privacy_problem(b"cd /home/someone-private/x", private))
        self.assertIsNone(record.pty_privacy_problem(b"build line", ["/home/someone-private", "ab"]))
        app = self.app()
        app.tap_frames = [(100, b"$ ls /home/someone-private\n")]
        recording = self.recording(app)
        recording.start(["@w0.p0.t0=ls"], sleep=self.clock.sleep)
        with self.assertRaisesRegex(record.RecordError, "account's"):
            recording.run(sleep=self.clock.sleep)

    def test_a_pty_ref_must_name_a_known_tab(self):
        recording = self.recording(self.app())
        for spec in ("@w0.p0.t9=ls", "@w0.p0=ls", "w0.p0.t0=ls", "@w0.p0.t0="):
            with self.subTest(spec), self.assertRaises(record.RecordError):
                recording.start([spec], sleep=self.clock.sleep)


class TimingAndMarkerTests(Case):
    def test_a_slow_clear_or_marker_rpc_keeps_one_end_at_the_duration(self):
        for step in ("clear", "marker"):
            with self.subTest(step):
                app = self.app()
                app.delay_ns[step] = 10_000_000
                recording = self.recording(app)
                recording.start(sleep=self.clock.sleep)
                manifest = recording.run(sleep=self.clock.sleep)
                self.assertEqual(manifest["checkpoints"][-1]["t_ms"], 3000)
                self.assertEqual([c["name"] for c in manifest["checkpoints"]], ["start", "midpoint", "end"])

    def test_a_record_another_thread_appends_after_the_marker_does_not_hide_it(self):
        app = self.app([(500, None, key("down", "named", 36))])
        app.after_marker = {"attach": {"_0": {"event": "input", "bytes": 1}}}
        recording = self.recording(app)
        recording.start(sleep=self.clock.sleep)
        self.assertEqual(recording.t0_ns, app.start_ns, "the zero is the marker, not the attach record")
        manifest = recording.run(sleep=self.clock.sleep)
        self.assertEqual([(e["kind"], e["t_ms"]) for e in manifest["input"]["events"]], [("key", 500)])
        self.assertEqual([c["name"] for c in manifest["checkpoints"]], ["start", "midpoint", "end"])

    def test_an_older_marker_is_not_taken_for_a_new_one(self):
        reader = record.JournalReader(lambda method, params: {
            "stats": {"enabled": True, "recordsCharacters": False},
            "entries": [{"seq": 7, "uptimeNanos": 70, "kind": {"marker": {"_0": record.MARKER}}},
                        {"seq": 8, "uptimeNanos": 80, "kind": {"marker": {"_0": "someone else's"}}}]})
        self.assertEqual(reader.mark(), 70)
        with self.assertRaisesRegex(record.RecordError, "did not return its marker"):
            reader.mark()


class TapStopTests(Case):
    def two_taps(self, app):
        app.split(app.workspaces[0], app.focused_pane, "right")
        recording = self.recording(app)
        recording.start(["@w0.p0.t0=ls", "@w0.p1.t0=ls"], sleep=self.clock.sleep)
        self.assertEqual(len(app.tap_stops), 2)
        return recording

    def assert_every_tap_stopped(self, app):
        self.assertTrue(app.tap_stops)
        for stop in app.tap_stops:
            self.assertTrue(Path(stop).exists(), f"{stop}: the tap keeps running")

    def test_a_failed_run_stops_every_tap(self):
        app = self.app()
        recording = self.two_taps(app)
        app.stats["recordsCharacters"] = True
        with self.assertRaisesRegex(record.RecordError, "records characters"):
            recording.run(sleep=self.clock.sleep)
        self.assert_every_tap_stopped(app)

    def test_a_refused_first_track_stops_the_other_tap_too(self):
        app = self.app()
        app.tap_frames_of = {"pty-0.ttyrec": [(100, b"$ ls /home/someone-private\n")]}
        recording = self.two_taps(app)
        with self.assertRaisesRegex(record.RecordError, "@w0.p0.t0: .*account's"):
            recording.run(sleep=self.clock.sleep)
        self.assert_every_tap_stopped(app)

    def test_a_tap_that_does_not_start_stops_the_ones_that_did(self):
        app = self.app()
        app.split(app.workspaces[0], app.focused_pane, "right")
        started = app.start_tap
        app.start_tap = lambda text: started(text) if not app.tap_stops else app.tap_stops.append(
            shlex.split(text)[shlex.split(text).index("--stop-file") + 1])
        recording = self.recording(app)
        with mock.patch.object(record, "TAP_START_S", 0.0), \
                self.assertRaisesRegex(record.RecordError, r"\['@w0.p1.t0'\] did not start"):
            recording.start(["@w0.p0.t0=ls", "@w0.p1.t0=ls"], sleep=self.clock.sleep)
        self.assert_every_tap_stopped(app)

    def test_the_cli_stops_every_tap_when_the_recording_fails(self):
        app = self.app()
        story = self.folder / "story.json"
        story.write_text(json.dumps(template()))
        handlers = {number: record.signal.getsignal(number) for number in (record.signal.SIGTERM,
                                                                           record.signal.SIGHUP)}
        for number, handler in handlers.items():
            self.addCleanup(record.signal.signal, number, handler)
        with mock.patch.object(record, "attach", return_value=app.rpc), \
                mock.patch.object(record.Recording, "run", side_effect=record.RecordError("the driver failed")), \
                contextlib.redirect_stderr(io.StringIO()) as err:
            code = record.main(["record", "--socket", "/tmp/none.sock", "--template", str(story), "--out",
                                str(self.folder / "o"), "--cache", str(self.folder / "cache"), "--pty", "@w0.p0.t0=ls"])
        self.assertEqual(code, 2)
        self.assertIn("the driver failed", err.getvalue())
        self.assert_every_tap_stopped(app)

    def test_a_relative_out_folder_gives_the_taps_absolute_paths(self):
        here = os.getcwd()
        self.addCleanup(os.chdir, here)
        os.chdir(self.folder)
        app = self.app()
        recording = record.Recording(app.rpc, template(), cache=self.cache, folder=Path("rel-out"),
                                     clock=self.clock, private=[])
        recording.start(["@w0.p0.t0=ls"], sleep=self.clock.sleep)
        (argv,) = app.tap_lines
        for flag in ("--out", "--stop-file"):
            path = Path(argv[argv.index(flag) + 1])
            self.assertTrue(path.is_absolute(), f"{flag} {path}")
            self.assertEqual(path.parent, (self.folder / "rel-out").resolve())
        recording.close()


class TapResizeTests(unittest.TestCase):
    CHILD = ("import os, signal, time\n"
             "got = []\n"
             "signal.signal(signal.SIGWINCH, lambda *a: got.append(1))\n"
             "size = os.get_terminal_size(1)\n"
             "print(f'ready {size.lines} {size.columns}', flush=True)\n"
             "deadline = time.monotonic() + 10\n"
             "while not got and time.monotonic() < deadline:\n"
             "    time.sleep(0.01)\n"
             "size = os.get_terminal_size(1)\n"
             "print(f'size {size.lines} {size.columns}', flush=True)\n")

    def test_a_resized_terminal_resizes_the_tapped_command(self):
        import fcntl
        import pty
        import signal
        import struct
        import termios
        import threading

        folder = Path(tempfile.mkdtemp(prefix="record-resize-"))
        outer, terminal = pty.openpty()  # the terminal the tap runs in: the test resizes it like a pane split
        fcntl.ioctl(outer, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        shown = bytearray()

        def terminal_side():
            resized = False
            while True:
                try:
                    chunk = os.read(outer, 4096)
                except OSError:
                    return
                if not chunk:
                    return
                shown.extend(chunk)
                if not resized and b"ready" in shown:
                    resized = True
                    fcntl.ioctl(outer, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 132, 0, 0))
                    os.kill(os.getpid(), signal.SIGWINCH)  # what the kernel sends the terminal's foreground group

        reader = threading.Thread(target=terminal_side, daemon=True)
        reader.start()
        out = folder / "tap.ttyrec"
        code = record.tap([sys.executable, "-I", "-c", self.CHILD], str(out), str(folder / "tap.stop"),
                          output_fd=terminal)
        self.assertEqual(code, 0)
        os.close(terminal)
        reader.join(5)
        os.close(outer)
        data = pty_replay.decode_ttyrec(out.read_bytes()).data
        self.assertIn(b"ready 24 80", data)
        self.assertIn(b"size 50 132", data)


class ActionAndPlanTests(Case):
    def test_a_vocabulary_action_runs_on_its_target_and_is_recorded(self):
        app = self.app()
        recording = self.recording(app)
        recording.start(sleep=self.clock.sleep)
        first_pane = app.focused_pane
        self.clock.sleep(0.5)
        recording.action("splitRight", target="@w0.p0")
        workspace = app.workspaces[0]
        self.assertEqual(app.leaves(workspace["tree"])[0], first_pane)
        self.assertEqual(len(app.leaves(workspace["tree"])), 2)
        manifest = recording.run(sleep=self.clock.sleep)
        action = next(e for e in manifest["input"]["events"] if e["kind"] == "action")
        self.assertEqual(action, {"t_ms": 500.0, "kind": "action",
                                  "payload": {"id": "splitRight", "args": {"target": "@w0.p0"}}})

    def test_an_undeclared_action_or_a_text_argument_is_refused(self):
        app = self.app()
        recording = self.recording(app)
        recording.start(sleep=self.clock.sleep)
        with self.assertRaisesRegex(record.RecordError, "not an action"):
            recording.action("renameWorkspace", target="@w0")
        with self.assertRaisesRegex(record.RecordError, "not an argument"):
            recording.action("splitRight", title="my-notes")

    def test_the_plan_ends_at_the_duration(self):
        story = template(duration_ms=3000)
        self.assertEqual(record.checkpoint_plan(story, 3000), [(0, "start"), (1500, "midpoint"), (3000, "end")])
        self.assertEqual(record.checkpoint_plan(story, 1000), [(0, "start"), (1000, "end")])
        story["checkpoints"].append({"t_ms": 2000, "name": "end", "focus": None, "surfaces": None})
        self.assertEqual(record.checkpoint_plan(story, 3000)[-1], (3000, "recording-end"))

    def test_the_synthetic_text_is_fixed_per_class(self):
        a, b = record.SyntheticText(), record.SyntheticText()
        classes = ["letter", "digit", "letter", "space", "punctuation", "other"]
        self.assertEqual([a.next(c) for c in classes], [b.next(c) for c in classes])
        text = record.SyntheticText()
        self.assertEqual("".join(text.next("letter") for _ in range(3)), "eta")

    def test_the_planned_stories_are_templates(self):
        for path in sorted((LAB.parents[1] / "perf-corpus").glob("*.json")):
            with self.subTest(path.name):
                story = record.load_template(None, path)
                self.assertGreater(len(record.checkpoint_plan(story, story["duration_ms"])), 0)


if __name__ == "__main__":
    unittest.main()
