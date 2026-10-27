"""Tests for the generated stress-recorded corpus story (scripts/perf-lab/corpus/stories/stress_recorded.py, task 120)
and the story kit it is made with (story_kit.py).

Run: python3 -m unittest scripts/perf-lab/tests/test_story_stress_recorded.py
"""

import copy
import importlib.util
import io
import json
import re
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[2]
LAB = HERE.parent
CORPUS = LAB / "corpus"
TRACE_PY = REPO_ROOT / "scripts" / "cmux-next" / "trace.py"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


story = load("story_stress_recorded_under_test", CORPUS / "stories" / "stress_recorded.py")
kit = story.kit
cm = kit.corpus_manifest()
BLOBS = story.sources()
COMMITTED = json.loads((REPO_ROOT / story.STORY.manifest_path).read_text(encoding="utf-8"))
EVENTS = [json.loads(line) for line in BLOBS["input"].decode().splitlines()]
LAYOUT = json.loads(BLOBS["layout"])


def key_downs(events=EVENTS):
    return [e for e in events if e["kind"] == "key" and e["payload"]["phase"] == "down"]


def chord_downs(events=EVENTS):
    return [e for e in key_downs(events) if "key_code" in e["payload"]]


def cli_calls(events=EVENTS):
    return [e for e in events if e["kind"] == "cli"]


CHORD_ACTIONS = {(code, tuple(mods)): action for pair in story.CHORDS for code, _, mods, action in pair}


def action_of(event):
    return CHORD_ACTIONS[(event["payload"]["key_code"], tuple(event["payload"]["modifiers"]))]


class GeneratorTest(unittest.TestCase):
    def test_splitmix64_reference_value(self):
        self.assertEqual(kit.Rng(0).next(), 0xE220A8397B1DCDAF)

    def test_sources_are_the_same_bytes_every_run(self):
        self.assertEqual(story.sources(), BLOBS)

    def test_the_committed_manifest_is_what_the_generator_makes(self):
        self.assertEqual(story.main(["check"], out=lambda _: None), 0)
        self.assertEqual(COMMITTED, story.manifest(BLOBS, COMMITTED))

    def test_check_fails_on_a_changed_manifest(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / story.STORY.manifest_path
            path.parent.mkdir()
            changed = copy.deepcopy(COMMITTED)
            changed["duration_ms"] = 1
            path.write_text(json.dumps(changed))
            with redirect_stderr(io.StringIO()) as err:
                self.assertEqual(story.main(["check", "--root", root], out=lambda _: None), 1)
            self.assertIn("stress_recorded.py write", err.getvalue())

    def test_write_puts_every_blob_into_the_cache(self):
        with tempfile.TemporaryDirectory() as root, tempfile.TemporaryDirectory() as cache:
            (Path(root) / "perf-corpus").mkdir()
            self.assertEqual(story.main(["write", "--root", root, "--cache", cache], out=lambda _: None), 0)
            written = json.loads((Path(root) / story.STORY.manifest_path).read_text())
            refs = [written["layout"]["snapshot"], written["input"]["blob"]]
            store = cm.BlobCache(Path(cache), lambda digest: self.fail(f"fetched {digest}"))
            self.assertEqual(sorted(store.get(ref) for ref in refs), sorted(BLOBS.values()))


class ManifestTest(unittest.TestCase):
    def test_validates_with_its_input_blob(self):
        schema, vocabulary = cm.load_schema(), cm.load_vocabulary()
        self.assertEqual(cm.validation_errors(COMMITTED, schema=schema, vocabulary=vocabulary), [])
        self.assertEqual(cm.event_errors(EVENTS, COMMITTED["duration_ms"], schema, vocabulary), [])

    def test_no_source_lives_in_git(self):
        self.assertEqual(COMMITTED["pty"], [])
        self.assertLess(len(kit.render(COMMITTED)), 4096, "the input track is a blob, not inline events")

    def test_digests_stay_while_the_sources_stay(self):
        previous = copy.deepcopy(COMMITTED)
        for checkpoint in previous["checkpoints"]:
            checkpoint["focus"], checkpoint["surfaces"] = "a" * 64, "b" * 64
        kept = story.manifest(BLOBS, previous)
        self.assertEqual(kept["status"], "recorded")
        self.assertNotIn("planned", kept)
        self.assertEqual(cm.validation_errors(kept), [])
        changed = dict(BLOBS, input=BLOBS["input"] + b"\n")
        dropped = story.manifest(changed, previous)
        self.assertEqual(dropped["status"], "planned")
        self.assertTrue(all(c["focus"] is None and c["surfaces"] is None for c in dropped["checkpoints"]))
        longer = dict(previous, duration_ms=story.DURATION_MS + 1)
        self.assertEqual(story.manifest(BLOBS, longer)["status"], "planned", "a source field change drops digests")

    def test_metrics_are_the_series_the_player_and_the_lab_measure(self):
        names = [m["name"] for m in COMMITTED["metrics"]]
        for series in ("key_to_frame", "action_to_frame", "switch_to_frame", "dropped_frames",
                       "main_turn", "hangs"):
            self.assertIn(rf"corpus\.stress_recorded\.{series}", names)

    def test_checkpoints_at_the_start_the_middle_and_the_end(self):
        self.assertEqual([(c["name"], c["t_ms"]) for c in COMMITTED["checkpoints"]],
                         [("layout-imported", 0), ("midpoint", 30_000), ("end", 60_000)])


def focus_quiet_pane(builder):
    """What trace.py's build_stress does after the builder (focus_quiet_terminal): focuses the last measured pane
    whose selected tab is a terminal that is not busy. Returns that pane's id."""
    busy = set(builder.busy)
    panes = builder.panes(builder.workspace(builder.measured))
    quiet = next(pane for pane in reversed(panes)
                 if any(tab["id"] == pane["selected_tab"] and tab["kind"] == "terminal" and tab["id"] not in busy
                        for tab in pane["tabs"]))
    builder.focus_pane(quiet["id"])
    return quiet["id"]


def stress_export():
    """STRESS built by perf-stress-session.py into test_session_io's fake app, its typing moved to the quiet pane
    as trace.py's stress-storm does, exported by session_io."""
    fake = load("test_session_io_for_stress_recorded", LAB / "tests" / "test_session_io.py")
    app = fake.fresh_app()
    builder = fake.stress.Stress(app.rpc, log=lambda line: None, settle=0,
                                 web_dev_config=str(LAB / "no-such-web-dev.json"))
    try:
        builder.build(check=False)
        focus_quiet_pane(builder)
        return fake.session_io.export_layout(app.rpc, builder=builder)
    finally:
        builder.close()


class LayoutTest(unittest.TestCase):
    def test_the_layout_is_stress_as_the_builder_makes_it(self):
        exported = stress_export()
        session_io = kit.session_io()
        self.assertEqual(session_io.digest(exported), session_io.digest(LAYOUT),
                         session_io.first_difference(exported, LAYOUT))

    def test_the_measured_workspace_is_last_shown_and_busy(self):
        self.assertEqual(len(LAYOUT["workspaces"]), 60)
        self.assertEqual(LAYOUT["shown"], story.MEASURED)
        self.assertEqual(story.MEASURED, 59)
        self.assertEqual({w for w, _, _ in LAYOUT["busy"]}, {story.MEASURED})
        self.assertEqual(kit.session_io().importable(LAYOUT), [])

    def test_keys_go_to_a_quiet_terminal(self):
        """The typed pane is the one trace.py's stress-storm types into: its selected tab a terminal, not busy."""
        leaves = kit.session_io().leaves(LAYOUT["workspaces"][LAYOUT["shown"]]["tree"])
        typed = LAYOUT["focused_pane"]
        selected = leaves[typed]["selected"]
        self.assertEqual(leaves[typed]["tabs"][selected], "terminal")
        self.assertNotIn([LAYOUT["shown"], typed, selected], LAYOUT["busy"])
        self.assertEqual(typed, len(leaves) - 1, "the last pane, as focus_quiet_terminal walks them in reverse")


class StormTest(unittest.TestCase):
    def test_a_call_every_hundred_ms_through_the_window(self):
        times = [e["t_ms"] for e in cli_calls()]
        self.assertEqual(times, list(range(100, 60_000, 100)))

    def test_kinds_cycle_as_trace_py_with_the_group_slot_a_pill(self):
        kinds = [e["payload"]["argv"][2] for e in cli_calls()]
        self.assertEqual(kinds[:8], ["move", "update", "status", "status"] * 2)
        for call, event in enumerate(cli_calls(), 1):
            argv = event["payload"]["argv"]
            if argv[2] == "move":
                self.assertEqual(argv[3:], ["--index", "0"])
            elif argv[2] == "update":
                self.assertIn(argv[4], story.STATUSES)
            else:
                self.assertEqual(argv[3:], ["set", "trace", str(call)], "a pill carries its call number")

    def test_targets_spare_the_measured_workspace_and_the_step_row(self):
        targets = {int(e["payload"]["argv"][1][2:]) for e in cli_calls()}
        self.assertEqual(targets, set(range(story.STORM_ROWS)), "every other row is churned")

    def test_rows_58_and_59_keep_their_workspaces_through_every_move(self):
        order = list(range(story.WORKSPACES))
        for event in cli_calls():
            argv = event["payload"]["argv"]
            if argv[2] == "move":
                order.insert(0, order.pop(int(argv[1][2:])))
            self.assertEqual(order[story.STEP_TARGET:], [story.STEP_TARGET, story.MEASURED])


class TypistTest(unittest.TestCase):
    def test_letters_every_120_ms_carry_no_key_code(self):
        letters = [e for e in key_downs() if "key_code" not in e["payload"]]
        self.assertTrue(all(e["payload"] == {"phase": "down", "class": "letter", "modifiers": []} for e in letters))
        gaps = [b["t_ms"] - a["t_ms"] for a, b in zip(letters, letters[1:])]
        self.assertEqual(min(gaps), story.KEY_INTERVAL_MS)
        self.assertGreater(len(letters), 250)

    def test_every_key_down_has_its_up_at_the_same_time(self):
        keys = [e for e in EVENTS if e["kind"] == "key"]
        for down, up in zip(keys[::2], keys[1::2]):
            self.assertEqual(up, {**down, "payload": {**down["payload"], "phase": "up"}})

    def test_a_chord_pair_before_every_tenth_letter_350_ms_apart(self):
        downs, chords = key_downs(), chord_downs()
        self.assertEqual(len(chords) % 2, 0)
        for first, second in zip(chords[::2], chords[1::2]):
            self.assertEqual(second["t_ms"] - first["t_ms"], story.CHORD_GAP_MS)
        # Exactly CHORD_EVERY letters before the first pair and between two pairs.
        runs, count = [], 0
        for event in downs:
            if "key_code" in event["payload"]:
                if count:
                    runs.append(count)
                count = 0
            else:
                count += 1
        self.assertTrue(all(run == story.CHORD_EVERY for run in runs), runs)
        self.assertGreaterEqual(len(chords) // 2, 24)

    def test_pairs_cycle_new_tab_split_and_a_step_back_and_forward(self):
        actions = [action_of(e) for e in chord_downs()]
        pairs = list(zip(actions[::2], actions[1::2]))
        want = [("newTab.default", "closeTab"), ("splitRight", "closeTab"), ("prevSidebarTab", "nextSidebarTab")]
        self.assertEqual(pairs, [want[n % 3] for n in range(len(pairs))])

    def test_the_step_pair_leaves_from_the_last_row_and_comes_back(self):
        """The sidebar as the app walks it: the storm's moves and the step keys, in time order."""
        order, shown = list(range(story.WORKSPACES)), story.MEASURED
        for event in EVENTS:
            payload = event["payload"]
            if event["kind"] == "cli" and payload["argv"][2] == "move":
                order.insert(0, order.pop(int(payload["argv"][1][2:])))
            elif event["kind"] == "key" and payload["phase"] == "down" and "key_code" in payload:
                action = action_of(event)
                position = order.index(shown)
                if action == "prevSidebarTab":
                    self.assertGreater(position, 0)
                    shown = order[position - 1]
                    self.assertEqual(shown, story.STEP_TARGET)
                elif action == "nextSidebarTab":
                    self.assertLess(position, story.WORKSPACES - 1, "a step forward from the last row leaves the rows")
                    shown = order[position + 1]
                    self.assertEqual(shown, story.MEASURED)
                else:
                    self.assertEqual(shown, story.MEASURED, "tab chords land in the measured workspace")
        self.assertEqual(shown, story.MEASURED)

    def test_no_chord_runs_into_a_checkpoint(self):
        chords = chord_downs()
        for first in chords[::2]:
            for _, checkpoint in story.CHECKPOINTS:
                self.assertFalse(first["t_ms"] < checkpoint <= first["t_ms"] + story.CHORD_QUIET_MS,
                                 (first["t_ms"], checkpoint))

    def test_the_last_second_has_no_key(self):
        self.assertLess(key_downs()[-1]["t_ms"], story.DURATION_MS - story.END_QUIET_MS)

    def test_no_key_waits_for_a_cli_spawn(self):
        """The player spawns a CLI process before it sends the next step: no key is due at a call's time after it,
        and the next key after a call is at least 10 ms later, so the spawn does not make keys late."""
        for index, event in enumerate(EVENTS):
            if event["kind"] != "cli":
                continue
            after = [e for e in EVENTS[index + 1:] if e["kind"] == "key"]
            if after:
                self.assertGreaterEqual(after[0]["t_ms"] - event["t_ms"], 10, (event, after[0]))

    def test_events_are_in_time_order_inside_the_window(self):
        times = [e["t_ms"] for e in EVENTS]
        self.assertEqual(times, sorted(times))
        self.assertTrue(0 < times[0] and times[-1] < story.DURATION_MS)


class TracePyTest(unittest.TestCase):
    """The story is trace.py's stress-storm: its chords, statuses, storm kinds and defaults."""

    @classmethod
    def setUpClass(cls):
        try:
            cls.trace = load("trace_py_for_stress_recorded", TRACE_PY)
        except Exception as error:  # noqa: BLE001  (trace.py's own imports: report, do not fail this suite)
            raise unittest.SkipTest(f"trace.py does not load here: {error}")

    def test_chords_are_trace_py_chords_with_the_step_pair_reversed(self):
        names = {"t": story.KEY_T, "w": story.KEY_W, "d": story.KEY_D, "[": story.KEY_LEFT_BRACKET,
                 "]": story.KEY_RIGHT_BRACKET}
        theirs = [[(names[key], tuple(mods), action) for key, mods, action in pair] for pair in self.trace.CHORDS]
        ours = [[(code, mods, action) for code, _, mods, action in pair] for pair in story.CHORDS]
        self.assertEqual(ours[:2], theirs[:2])
        self.assertEqual(ours[2], theirs[2][::-1])

    def test_statuses_are_the_storms(self):
        self.assertEqual(list(story.STATUSES), self.trace.Storm.STATUSES)

    def test_storm_kinds_and_defaults(self):
        text = TRACE_PY.read_text(encoding="utf-8")
        self.assertIn(f'kinds = {list(story.STORM_KINDS)!r}'.replace("'", '"'), text)

        def default(flag):
            return float(re.search(rf'"{flag}", type=\w+, default=([0-9.]+)\)', text).group(1))

        self.assertEqual(default("--storm-hz"), 1000 / story.STORM_PERIOD_MS)
        self.assertEqual(default("--key-interval"), story.KEY_INTERVAL_MS / 1000)
        self.assertEqual(default("--chord-every"), story.CHORD_EVERY)
        self.assertIn(f"self.stop_flag.wait({story.CHORD_GAP_MS / 1000})", text)


class PlayerTest(unittest.TestCase):
    def setUp(self):
        if not (CORPUS / "play.py").is_file():
            self.skipTest("play.py (p12-perf-process-115) is not on this branch yet")
        self.play = kit.play_module()

    def test_the_player_plans_every_event(self):
        timeline, skipped = self.play.plan(COMMITTED, EVENTS, cm.TYPING_CLASSES)
        steps = [item for item in timeline if isinstance(item, self.play.Step)]
        self.assertEqual(len(steps) + skipped, len(EVENTS))
        self.assertEqual(skipped, len(key_downs()), "every key up is skipped")
        keys = [s.params for s in steps if s.kind == "key"]
        self.assertIn({"key": "[", "modifiers": ["ctrl", "cmd"]}, keys)
        self.assertIn({"key": "t", "modifiers": ["cmd"]}, keys)
        self.assertEqual(sum(1 for s in steps if s.kind == "cli"), len(cli_calls()))


class FakeClock:
    def __init__(self):
        self.ns = 0

    def now_ns(self):
        return self.ns

    def sleep_until(self, deadline_ns):
        self.ns = max(self.ns, deadline_ns)


class FakeRun:
    def __init__(self, checkpoints):
        self.checkpoints = checkpoints


class FakePlayer:
    """Replays that read the given digests per run; keeps what it was asked to play."""

    def __init__(self, *runs):
        self.runs, self.played = list(runs), []

    def replay(self, manifest, *, app, out):
        self.played.append((copy.deepcopy(manifest), app, out))
        digests = self.runs.pop(0)
        return FakeRun([{"name": c["name"], **digests[c["name"]]} for c in manifest["checkpoints"]])


def digests(seed):
    return {name: {"focus": f"{seed}{n}".ljust(64, "f"), "surfaces": f"{seed}{n}".ljust(64, "5")}
            for n, (name, _) in enumerate(story.CHECKPOINTS)}


class CaptureTest(unittest.TestCase):
    def test_settle_returns_the_state_read_twice_in_a_row(self):
        reads = iter([{"focus": "a"}, {"focus": "b"}, {"focus": "b"}, {"focus": "c"}])
        clock = FakeClock()
        self.assertEqual(kit.settle(lambda: next(reads), clock, 5.0, 0.05), {"focus": "b"})
        self.assertEqual(clock.ns, 100_000_000)

    def test_settle_fails_on_a_state_that_keeps_changing(self):
        counter = iter(range(10_000))
        with self.assertRaisesRegex(kit.CaptureError, "did not settle in 5 s"):
            kit.settle(lambda: {"focus": str(next(counter))}, FakeClock(), 5.0, 0.05)

    def test_two_agreeing_runs_record_the_story(self):
        player = FakePlayer(digests("a"), digests("a"))
        doc = kit.capture(story.STORY, BLOBS, app="APP", out=Path("/out"), player=player)
        self.assertEqual(doc["status"], "recorded")
        self.assertNotIn("planned", doc)
        self.assertEqual({c["name"]: {"focus": c["focus"], "surfaces": c["surfaces"]} for c in doc["checkpoints"]},
                         digests("a"))
        self.assertEqual(cm.validation_errors(doc), [])
        self.assertEqual(story.manifest(BLOBS, doc), doc, "write keeps captured digests")
        self.assertEqual([out for _, _, out in player.played], [Path("/out/run-1"), Path("/out/run-2")])
        played = player.played[0][0]
        self.assertEqual(played["status"], "recorded", "the player loads only recorded stories")
        self.assertEqual(cm.validation_errors(played), [])
        self.assertEqual({k: v for k, v in played.items() if k not in ("status", "checkpoints")},
                         {k: v for k, v in COMMITTED.items() if k not in ("status", "checkpoints", "planned")})

    def test_runs_that_disagree_record_nothing(self):
        with self.assertRaisesRegex(kit.CaptureError, "checkpoint layout-imported: run 1 read a0"):
            kit.capture(story.STORY, BLOBS, app="APP", out=Path("/out"), player=FakePlayer(digests("a"), digests("b")))

    def test_capture_writes_the_recorded_manifest_and_check_accepts_it(self):
        with tempfile.TemporaryDirectory() as root, tempfile.TemporaryDirectory() as cache:
            path = Path(root) / story.STORY.manifest_path
            path.parent.mkdir()
            path.write_text(kit.render(COMMITTED))
            argv = ["capture", "--root", root, "--cache", cache, "--app", "APP", "--out", str(Path(root) / "out")]
            with redirect_stderr(io.StringIO()) as err:
                self.assertEqual(story.main(argv, out=lambda _: None, player=FakePlayer(digests("a"), digests("c"))), 1)
            self.assertIn("run 2 c0", err.getvalue())
            self.assertEqual(json.loads(path.read_text()), COMMITTED, "a failed capture leaves the manifest")
            self.assertEqual(story.main(argv, out=lambda _: None, player=FakePlayer(digests("a"), digests("a"))), 0)
            self.assertEqual(json.loads(path.read_text())["status"], "recorded")
            self.assertEqual(story.main(["check", "--root", root], out=lambda _: None), 0)

    def test_capture_needs_an_app_and_an_out_dir(self):
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            story.main(["capture"], out=lambda _: None)

    def test_the_capture_player_reads_the_settled_checkpoint(self):
        if not (CORPUS / "play.py").is_file():
            self.skipTest("play.py (p12-perf-process-115) is not on this branch yet")
        play = kit.play_module()
        with tempfile.TemporaryDirectory() as cache, tempfile.TemporaryDirectory() as out:
            store = cm.BlobCache(kit.cache_blobs(BLOBS, Path(cache)), lambda digest: self.fail(f"fetched {digest}"))

            def fetch(ref):
                store.get(ref)
                return store.path(ref)

            player = kit.capture_player(play, root=REPO_ROOT, fetch=fetch, clock=FakeClock())
            recorder = FakePlayer(digests("a"), digests("a"))
            kit.capture(story.STORY, BLOBS, app="APP", out=Path(out), player=recorder)
            loaded = player.load(recorder.played[0][0], Path(out))  # the player accepts what capture plays
            item = next(i for i in loaded.timeline if isinstance(i, play.Checkpoint))
            snapshot = {"topology": {"workspaces": [{"id": "w-a"}, {"id": "w-b"}]}}
            focus = {"windows": [{"workspace": "w-b"}], "context": {}, "consistent": True}
            surfaces = [{"windows": [], "blank_panes": n, "collapsed_panes": 0} for n in (1, 2, 2)]
            sender = FakeSender([snapshot, focus, surfaces[0], snapshot, focus, surfaces[1],
                                 snapshot, focus, surfaces[2]])
            got = player.checkpoint(sender, item, Path(out))
            order = play.workspace_order(snapshot)
            self.assertEqual(got, {"name": item.name, "focus": play.focus_digest(focus, order),
                                   "surfaces": play.surfaces_digest(surfaces[2])})
            self.assertNotEqual(got["focus"], play.focus_digest(focus), "the shown workspace's position counts")
            self.assertEqual(sender.collected, 1, "the replies before the checkpoint are read first")
            self.assertEqual(sender.channel.methods[:3], ["snapshot.get", "debug.focus", "debug.surfaces"])
            view = json.loads((Path(out) / f"checkpoint-{item.name}.json").read_text())
            self.assertEqual(view["focus"]["windows"][0]["workspace"], 1)


class FakeChannel:
    """play.Channel with canned replies in request order."""

    def __init__(self, replies):
        self.replies, self.methods, self.answers = list(replies), [], {}

    def send(self, method, params):
        self.methods.append(method)
        self.answers[len(self.methods)] = self.replies.pop(0)
        return len(self.methods)

    def reply(self, ticket, timeout):
        return self.answers.pop(ticket)

    def close(self):
        pass


class FakeSender:
    def __init__(self, replies):
        self.channel, self.collected = FakeChannel(replies), 0

    def collect(self):
        self.collected += 1


if __name__ == "__main__":
    unittest.main()
