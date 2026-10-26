#!/usr/bin/env python3
"""Story launch-restore (scripts/perf-lab/corpus/launch_restore.py, task p12-perf-process-121).

1. The committed layout and manifest are what the generator makes; the manifest validates, the layout has 60
   workspaces of terminals only, can be imported through actions, and shows a terminal.
2. load() takes a launch story and refuses a manifest with tracks to replay, a second checkpoint or a layout that
   does not match it.
3. settled_digests reads until the state is the wanted one (or held for one poll), within its settle time.
4. seed() launches, imports the layout, reads the state at quit, quits keeping sessions and always stops the app.
   The seeding launch and every measured launch get one window, screen and config; place_window puts a restored
   window where seeding left it, and refuses a display that cannot hold it.
5. capture() records the digests (the manifest becomes recorded and still validates) and never records over other
   recorded digests.

Runs on any host (Linux included): no app, no fleet.

    python3 -m unittest scripts/perf-lab/tests/test_corpus_launch_restore.py
"""
from __future__ import annotations

import copy
import importlib.util
import io as io_module
import json
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

LAB = Path(__file__).resolve().parents[1]
REPO_ROOT = LAB.parents[1]


def _load(name, path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


lr = _load("corpus_launch_restore", LAB / "corpus" / "launch_restore.py")
cm = lr.corpus_manifest()
io = lr.session_io()

FOCUS, SURFACES = "a" * 64, "b" * 64


def leaf_tabs(tree):
    return [kind for leaf in io.leaves(tree) for kind in leaf["tabs"]]


class GeneratedFilesTests(unittest.TestCase):
    def test_the_committed_files_are_what_the_generator_makes(self):
        self.assertEqual(lr.stale_files(REPO_ROOT), [])

    def test_the_manifest_validates(self):
        self.assertEqual(cm.validate_paths([REPO_ROOT / lr.MANIFEST_PATH], REPO_ROOT), [])

    def test_the_layout_is_60_workspaces_of_terminals_that_actions_can_build(self):
        snapshot = io.read(REPO_ROOT / lr.LAYOUT_PATH)
        self.assertEqual(len(snapshot["workspaces"]), 60)
        tabs = [kind for workspace in snapshot["workspaces"] for kind in leaf_tabs(workspace["tree"])]
        self.assertEqual(set(tabs), {"terminal"})
        self.assertEqual(len(tabs), 106, "the manifest's description says 106 terminals")
        self.assertEqual(io.importable(snapshot), [])
        self.assertEqual(snapshot["busy"], [], "restored terminals are idle shells")

    def test_the_shown_workspace_is_the_last_one_a_grid_with_a_terminal_focused(self):
        snapshot = io.read(REPO_ROOT / lr.LAYOUT_PATH)
        self.assertEqual(snapshot["shown"], 59)
        panes = io.leaves(snapshot["workspaces"][59]["tree"])
        self.assertEqual(len(panes), 4)
        self.assertEqual(panes[snapshot["focused_pane"]]["tabs"][0], "terminal")

    def test_a_recorded_checkpoint_is_kept_while_its_layout_is_unchanged(self):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root)
        (root / "perf-corpus").mkdir()
        doc = json.loads((REPO_ROOT / lr.MANIFEST_PATH).read_text())
        doc["checkpoints"][0].update(focus=FOCUS, surfaces=SURFACES)
        (root / lr.MANIFEST_PATH).write_text(json.dumps(doc))
        made = json.loads(lr.generated_files(root)[lr.MANIFEST_PATH])
        self.assertEqual(made["status"], "recorded")
        self.assertNotIn("planned", made)
        self.assertEqual(made["checkpoints"][0]["focus"], FOCUS)
        doc["layout"]["snapshot"]["sha256"] = "0" * 64  # recorded on another layout: not kept
        (root / lr.MANIFEST_PATH).write_text(json.dumps(doc))
        made = json.loads(lr.generated_files(root)[lr.MANIFEST_PATH])
        self.assertEqual(made["status"], "planned")
        self.assertIsNone(made["checkpoints"][0]["focus"])


class LoadTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        (self.root / "perf-corpus" / lr.STORY_ID).mkdir(parents=True)
        shutil.copy(REPO_ROOT / lr.LAYOUT_PATH, self.root / lr.LAYOUT_PATH)
        self.doc = json.loads((REPO_ROOT / lr.MANIFEST_PATH).read_text())

    def write(self, doc):
        (self.root / lr.MANIFEST_PATH).write_text(json.dumps(doc))
        return self.root / lr.MANIFEST_PATH

    def test_the_committed_story_loads(self):
        story = lr.load(lr.MANIFEST_PATH)
        self.assertEqual((story.id, story.session, story.metric_root),
                         ("launch-restore", "corpus:launch-restore", "corpus.launch_restore"))
        self.assertEqual(len(story.snapshot["workspaces"]), 60)
        self.assertIsNone(story.recorded, "planned: no recorded digests yet")

    def test_recorded_digests(self):
        doc = copy.deepcopy(self.doc)
        doc["checkpoints"][0].update(focus=FOCUS, surfaces=SURFACES)
        doc["status"] = "recorded"
        del doc["planned"]
        self.assertEqual(lr.load(self.write(doc), self.root).recorded, {"focus": FOCUS, "surfaces": SURFACES})

    def test_a_story_with_input_is_no_launch_story(self):
        doc = copy.deepcopy(self.doc)
        doc["duration_ms"] = 100
        doc["input"]["events"] = [{"t_ms": 0, "kind": "key", "payload": {"phase": "down", "class": "letter",
                                                                          "modifiers": []}}]
        self.assertEqual(cm.validation_errors(doc, root=self.root, schema=cm.load_schema(),
                                              vocabulary=cm.load_vocabulary()), [])
        with self.assertRaisesRegex(lr.LaunchRestoreError, "replays nothing"):
            lr.load(self.write(doc), self.root)

    def test_one_restored_checkpoint(self):
        doc = copy.deepcopy(self.doc)
        doc["checkpoints"].append({"t_ms": 1, "name": "later", "focus": None, "surfaces": None})
        with self.assertRaisesRegex(lr.LaunchRestoreError, "one checkpoint"):
            lr.load(self.write(doc), self.root)

    def test_a_changed_layout_file_is_refused(self):
        (self.root / lr.LAYOUT_PATH).write_bytes(b"{}")
        with self.assertRaisesRegex(lr.LaunchRestoreError, "sha256"):
            lr.load(self.write(self.doc), self.root)


class FakeClock:
    def __init__(self):
        self.t = 0.0
        self.sleeps = 0

    def now(self):
        return self.t

    def sleep(self, seconds):
        self.sleeps += 1
        self.t += seconds


def reads(*states):
    """A digests() that returns `states` in turn, then the last one."""
    queue = list(states)

    def digests(read):
        return dict(queue.pop(0) if len(queue) > 1 else queue[0])
    return digests


A = {"focus": FOCUS, "surfaces": SURFACES}
B = {"focus": "c" * 64, "surfaces": SURFACES}


class SettledDigestsTests(unittest.TestCase):
    def test_with_a_wanted_state_it_returns_the_first_read_that_is_it(self):
        clock = FakeClock()
        got = lr.settled_digests(None, A, digests=reads(B, B, A), now=clock.now, sleep=clock.sleep)
        self.assertEqual(got, A)
        self.assertEqual(clock.sleeps, 2)

    def test_with_a_wanted_state_it_gives_up_after_the_settle_time(self):
        clock = FakeClock()
        got = lr.settled_digests(None, A, digests=reads(B), now=clock.now, sleep=clock.sleep)
        self.assertEqual(got, B)
        self.assertGreaterEqual(clock.t, lr.CHECKPOINT_SETTLE_S)

    def test_without_one_it_returns_a_state_that_held_for_one_poll(self):
        clock = FakeClock()
        got = lr.settled_digests(None, digests=reads(A, B, B), now=clock.now, sleep=clock.sleep)
        self.assertEqual(got, B)
        self.assertEqual(clock.sleeps, 2)


class FakePlay:
    """play.py's checkpoint functions (task 115): views by method, digests of what they read."""

    class PlayError(RuntimeError):
        pass

    def __init__(self, answer=True):
        self.answer = answer

    def read_checkpoint(self, read):
        if not self.answer:
            raise self.PlayError("debug.focus gave no report")
        return read("debug.focus"), read("debug.surfaces"), [["w1"]]

    @staticmethod
    def focus_digest(focus, order):
        return f"focus:{focus}:{order}"

    @staticmethod
    def surfaces_digest(surfaces):
        return f"surfaces:{surfaces}"


class ReadDigestsTests(unittest.TestCase):
    def test_the_digests_are_play_py_s(self):
        got = lr.read_digests(lambda method: method, FakePlay())
        self.assertEqual(got, {"focus": "focus:debug.focus:[['w1']]", "surfaces": "surfaces:debug.surfaces"})

    def test_an_unanswered_read_is_a_launch_restore_error(self):
        with self.assertRaisesRegex(lr.LaunchRestoreError, "checkpoint read: debug.focus gave no report"):
            lr.read_digests(lambda method: method, FakePlay(answer=False))


class FakeBench:
    def __init__(self, fail_launch=False, quits=True):
        self.calls = []
        self.fail_launch, self.quits = fail_launch, quits

    def launch(self, validate_host=True):
        self.calls.append(("launch", validate_host))
        if self.fail_launch:
            raise RuntimeError("no window")

    def rpc(self, method, params=None, timeout=60):
        self.calls.append(("rpc", method))
        return {}

    def quit_keep_sessions(self):
        self.calls.append(("quit_keep_sessions",))
        return {"quit": self.quits, "error": "" if self.quits else "still runs"}

    def stop(self):
        self.calls.append(("stop",))


class FakeBuilder:
    closed = False

    def close(self):
        self.closed = True


class SeedTests(unittest.TestCase):
    def setUp(self):
        self.story = lr.load(lr.MANIFEST_PATH)
        self.out = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.out)

    def seed(self, bench, importer):
        return lr.seed(self.story, "/Apps/cmux DEV t.app", self.out, bench_factory=lambda app, out: bench,
                       importer=importer, digests=reads(A))

    def test_it_imports_reads_the_state_at_quit_and_quits_keeping_sessions(self):
        bench, builder, imported = FakeBench(), FakeBuilder(), []

        def importer(rpc, snapshot):
            imported.append(snapshot)
            return builder
        self.assertEqual(self.seed(bench, importer), A)
        self.assertEqual(imported, [self.story.snapshot])
        self.assertEqual(bench.calls[0], ("launch", False), "no lab host validation in the seeding launch")
        self.assertEqual(bench.calls[-2:], [("quit_keep_sessions",), ("stop",)])
        self.assertTrue(builder.closed)

    def test_a_failed_import_still_stops_the_app(self):
        bench = FakeBench()

        def importer(rpc, snapshot):
            raise io.LayoutSnapshotError("workspace 3 did not appear")
        with self.assertRaisesRegex(lr.LaunchRestoreError, "layout import: workspace 3"):
            self.seed(bench, importer)
        self.assertEqual(bench.calls[-1], ("stop",))
        self.assertNotIn(("quit_keep_sessions",), bench.calls)

    def test_a_seeding_launch_that_does_not_quit_fails(self):
        bench = FakeBench(quits=False)
        with self.assertRaisesRegex(lr.LaunchRestoreError, "did not quit: still runs"):
            self.seed(bench, lambda rpc, snapshot: FakeBuilder())
        self.assertEqual(bench.calls[-1], ("stop",))


class LaunchGeometryTests(unittest.TestCase):
    """Every launch restores into the seeding's window: an isolated launch with no frame opens 1100x720 on the last
    screen, and every shown pane's content_size (a surfaces digest field) would differ from the state at quit."""

    def setUp(self):
        self.stress = io.load_stress()

    def test_the_seeding_launch_gets_the_story_window_screen_and_config(self):
        out = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, out)
        bench = lr.seeding_bench("/Apps/cmux DEV t.app", out)
        self.addCleanup(shutil.rmtree, bench.scratch)
        env = bench.environment()
        for key, value in lr.launch_env().items():
            self.assertEqual(env[key], value, key)
        self.assertEqual(env["CMUX_NEXT_TEST_WINDOW_FRAME"], "0,0,%d,%d" % tuple(self.stress.WINDOW_SIZE))
        self.assertEqual(env["CMUX_NEXT_TEST_WINDOW_SCREEN"], "0")
        with open(env["CMUX_NEXT_CONFIG_FILE"]) as config:
            self.assertEqual(json.load(config)["layout"], lr.launch_config()["layout"])

    def test_the_config_is_the_bench_minimum_pane_size(self):
        config = lr.launch_config()
        self.assertEqual({f"layout.{key}": value for key, value in config["layout"].items()}, self.stress.MINIMUM_PANE)

    def fake_rpc(self, visible):
        calls = []

        def rpc(method, params=None):
            calls.append((method, params))
            frame = params.get("frame") or [0, 0, 1100, 720]
            width, height = min(frame[2], visible[2]), min(frame[3], visible[3])
            return {"frame": [frame[0], frame[1], width, height], "visible_frame": visible,
                    "screen_frame": [0, 0, visible[2], visible[3] + 25], "screen": 0}
        return rpc, calls

    def test_place_window_puts_the_window_where_import_layout_does(self):
        rpc, calls = self.fake_rpc([0, 0, 1920, 1055])
        reply = lr.place_window(rpc)
        width, height = self.stress.WINDOW_SIZE
        self.assertEqual(calls[0], ("debug.window_frame", {"screen": 0}))
        self.assertEqual(calls[1], ("debug.window_frame", {"frame": [(1920 - width) // 2, 1055 - height, width, height]}))
        self.assertEqual(reply["frame"][2:], [width, height])

    def test_a_display_that_cannot_hold_the_window_is_refused(self):
        rpc, _ = self.fake_rpc([0, 0, 1024, 743])
        with self.assertRaisesRegex(lr.LaunchRestoreError, "window: the window is"):
            lr.place_window(rpc)


class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        self.path = self.root / "launch-restore.json"
        shutil.copy(REPO_ROOT / lr.MANIFEST_PATH, self.path)

    def story(self):
        doc = json.loads(self.path.read_text())
        return lr.Story(self.path, doc, io.read(REPO_ROOT / lr.LAYOUT_PATH))

    def test_capture_records_the_digests(self):
        lr.capture(self.story(), A)
        doc = json.loads(self.path.read_text())
        self.assertEqual(doc["status"], "recorded")
        self.assertNotIn("planned", doc)
        self.assertEqual((doc["checkpoints"][0]["focus"], doc["checkpoints"][0]["surfaces"]), (FOCUS, SURFACES))
        self.assertEqual(cm.validation_errors(doc, root=REPO_ROOT), [])
        lr.capture(self.story(), A)  # the same digests again: no change

    def test_capture_never_records_over_other_digests(self):
        lr.capture(self.story(), A)
        with self.assertRaisesRegex(lr.LaunchRestoreError, "other digests"):
            lr.capture(self.story(), B)


class CliTests(unittest.TestCase):
    def test_check_passes_on_the_committed_files(self):
        out = io_module.StringIO()
        with redirect_stdout(out):
            self.assertEqual(lr.main(["check"]), 0)
        self.assertIn("ok: perf-corpus/launch-restore.json", out.getvalue())


if __name__ == "__main__":
    unittest.main()
