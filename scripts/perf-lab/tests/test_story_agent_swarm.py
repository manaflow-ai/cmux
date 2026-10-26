"""Tests for the generated agent-swarm corpus story (scripts/perf-lab/corpus/stories/agent_swarm.py, task 117).

Run: python3 -m unittest scripts/perf-lab/tests/test_story_agent_swarm.py
"""

import copy
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[2]
CORPUS = HERE.parent / "corpus"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


swarm = load("story_agent_swarm_under_test", CORPUS / "stories" / "agent_swarm.py")
cm = swarm.corpus_manifest()
BLOBS = swarm.sources()
COMMITTED = json.loads((REPO_ROOT / swarm.MANIFEST_PATH).read_text(encoding="utf-8"))
EVENTS = [json.loads(line) for line in BLOBS["input"].decode().splitlines()]
SWITCHES = ("nextSidebarTab", "prevSidebarTab")


def downs(events, *, cmd):
    return [e for e in events if e["kind"] == "key" and e["payload"]["phase"] == "down"
            and ("cmd" in e["payload"]["modifiers"]) == cmd]


class GeneratorTest(unittest.TestCase):
    def test_splitmix64_reference_value(self):
        self.assertEqual(swarm.Rng(0).next(), 0xE220A8397B1DCDAF)

    def test_sources_are_the_same_bytes_every_run(self):
        self.assertEqual(swarm.sources(), BLOBS)

    def test_the_committed_manifest_is_what_the_generator_makes(self):
        self.assertEqual(swarm.main(["check"], out=lambda _: None), 0)
        self.assertEqual(COMMITTED, swarm.manifest(BLOBS, COMMITTED))

    def test_check_fails_on_a_changed_manifest(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / swarm.MANIFEST_PATH
            path.parent.mkdir()
            changed = copy.deepcopy(COMMITTED)
            changed["duration_ms"] = 1
            path.write_text(json.dumps(changed))
            with redirect_stderr(io.StringIO()):
                self.assertEqual(swarm.main(["check", "--root", root], out=lambda _: None), 1)

    def test_write_puts_every_blob_into_the_cache(self):
        with tempfile.TemporaryDirectory() as root, tempfile.TemporaryDirectory() as cache:
            (Path(root) / "perf-corpus").mkdir()
            self.assertEqual(swarm.main(["write", "--root", root, "--cache", cache], out=lambda _: None), 0)
            written = json.loads((Path(root) / swarm.MANIFEST_PATH).read_text())
            refs = [written["layout"]["snapshot"], written["input"]["blob"]] + [a["transcript"] for a in written["agents"]]
            store = cm.BlobCache(Path(cache), lambda digest: self.fail(f"fetched {digest}"))
            self.assertEqual(sorted(store.get(ref) for ref in refs), sorted(BLOBS.values()))


class ManifestTest(unittest.TestCase):
    def test_validates_with_its_input_blob(self):
        schema, vocabulary = cm.load_schema(), cm.load_vocabulary()
        self.assertEqual(cm.validation_errors(COMMITTED, schema=schema, vocabulary=vocabulary), [])
        self.assertEqual(cm.event_errors(EVENTS, COMMITTED["duration_ms"], schema, vocabulary), [])
        self.assertLessEqual(len(BLOBS["input"]), 16 * 1024 * 1024)

    def test_digests_stay_while_the_sources_stay(self):
        previous = copy.deepcopy(COMMITTED)
        for checkpoint in previous["checkpoints"]:
            checkpoint["focus"], checkpoint["surfaces"] = "a" * 64, "b" * 64
        kept = swarm.manifest(BLOBS, previous)
        self.assertEqual(kept["status"], "recorded")
        self.assertNotIn("planned", kept)
        self.assertEqual(cm.validation_errors(kept), [])
        changed = dict(BLOBS, input=BLOBS["input"] + b"\n")
        dropped = swarm.manifest(changed, previous)
        self.assertEqual(dropped["status"], "planned")
        self.assertTrue(all(c["focus"] is None and c["surfaces"] is None for c in dropped["checkpoints"]))

    def test_metrics_are_the_story_series(self):
        names = [m["name"] for m in COMMITTED["metrics"]]
        for series in ("key_to_frame", "switch_to_frame", "dropped_frames", "main_turn", "hangs"):
            self.assertIn(rf"corpus\.agent_swarm\.{series}", names)


class LayoutTest(unittest.TestCase):
    def test_forty_workspaces_with_a_chat_under_each_agent_track(self):
        io_module = swarm.session_io()
        snapshot = json.loads(BLOBS["layout"])
        self.assertEqual(io_module.validate(snapshot), [])
        self.assertEqual(io_module.importable(snapshot), [])
        self.assertEqual(len(snapshot["workspaces"]), 40)
        self.assertEqual(COMMITTED["layout"]["workspaces"], 40)
        self.assertEqual(len(COMMITTED["agents"]), 12)
        for agent in COMMITTED["agents"]:
            workspace, pane, tab = (int(part[1:]) for part in agent["surface"][1:].split("."))
            leaf = io_module.leaves(snapshot["workspaces"][workspace]["tree"])[pane]
            self.assertEqual(leaf["tabs"][tab], "chat", agent["surface"])
            self.assertEqual(agent["agent"], "acp-replay")


def sidebar_items(workspaces=40, top_items=("home", "appStore")):
    """SidebarItemOrder.items under the default sidebar settings (numbering and stepping `allItems`): the top items,
    then the workspace rows (SidebarItem.swift)."""
    return list(top_items) + [f"@w{n}" for n in range(workspaces)]


def walk(events, items):
    """What each workspace-switching action selects, the way the app resolves it: (t_ms, the item before, the item
    after) per action that changes the sidebar selection. Steps walk `items` (SidebarItemOrder.step), Cmd-N picks
    items[N - 1] (SidebarItemOrder.pick) and pane.focus selects the pane's workspace (reveal)."""
    selected, changes = "@w0", []
    for event in events:
        if event["kind"] != "action":
            continue
        payload, before = event["payload"], selected
        if payload["id"] in ("nextSidebarTab", "prevSidebarTab"):
            step = 1 if payload["id"] == "nextSidebarTab" else -1
            selected = items[(items.index(selected) + step) % len(items)]
        elif payload["id"] == "selectWorkspaceByNumber":
            selected = items[payload["args"]["index"] - 1]
        elif payload["id"] == "pane.focus":
            selected = payload["args"]["target"].split(".")[0]
        if selected != before:
            changes.append((event["t_ms"], before, selected))
    return changes


class InputTrackTest(unittest.TestCase):
    def test_one_switch_to_a_workspace_every_three_seconds(self):
        # The app's walk, with Home and the App Store as top items: each 3 s slot switches exactly once, always
        # from one workspace to another (never to a top item, never twice through a following pane focus).
        changes = walk(EVENTS, sidebar_items())
        self.assertEqual([t for t, _, _ in changes], list(range(3000, 180000, 3000)))
        for t, before, after in changes:
            self.assertTrue(before.startswith("@w") and after.startswith("@w"), (t, before, after))
        # The same switches with any number of top items: the track does not depend on what the top section holds.
        for top in ((), ("home",), ("home", "appStore", "link")):
            self.assertEqual(walk(EVENTS, sidebar_items(top_items=top)), changes, top)

    def test_no_cmd_number_selects(self):
        # Cmd-1...9 count the top items first under the default sidebar.numbering, so they are not in the track.
        self.assertFalse(any(e["payload"].get("id") == "selectWorkspaceByNumber" for e in EVENTS if e["kind"] == "action"))
        self.assertFalse(any(e["payload"].get("key_code") in range(18, 30) for e in downs(EVENTS, cmd=True)))

    def test_a_step_is_followed_by_its_workspaces_terminal_pane(self):
        actions = [e for e in EVENTS if e["kind"] == "action"]
        steps = [e for e in actions if e["payload"]["id"] in SWITCHES]
        jumps = [e for e in actions if e["payload"]["id"] == "pane.focus" and e["t_ms"] % 3000 == 0]
        self.assertEqual(sorted(e["t_ms"] for e in steps + jumps), list(range(3000, 180000, 3000)))
        self.assertGreater(len(steps), 20)
        self.assertGreater(len(jumps), 10)
        selected = {t: after for t, _, after in walk(EVENTS, sidebar_items())}
        for step in steps:
            follow = [e for e in actions if e["t_ms"] == step["t_ms"] + 40]
            self.assertEqual([e["payload"] for e in follow],
                             [{"id": "pane.focus", "args": {"target": f"{selected[step['t_ms']]}.p0"}}])
        for jump in jumps:
            self.assertEqual(jump["payload"]["args"]["target"], f"{selected[jump['t_ms']]}.p0")
            self.assertFalse(any(e["t_ms"] == jump["t_ms"] + 40 for e in actions))
        self.assertGreater(len({after for _, _, after in walk(EVENTS, sidebar_items())}), 20, "jumps reach far rows")

    def test_typing_runs_at_eight_keys_a_second(self):
        typed = downs(EVENTS, cmd=False)
        typing_ms = 60 * 2700 - 12 * 1100  # every slot types 200-2900 ms, the pair slots not 900-2000 ms
        rate = len(typed) / (typing_ms / 1000)
        self.assertTrue(7.5 <= rate <= 8.5, rate)
        self.assertTrue(any(e["payload"]["class"] == "named" for e in typed))
        self.assertFalse(any("key_code" in e["payload"] for e in typed if e["payload"]["class"] != "named"))

    def test_cmd_t_cmd_w_pairs_every_fifteen_seconds(self):
        shortcuts = downs(EVENTS, cmd=True)
        self.assertEqual([e["payload"]["key_code"] for e in shortcuts], [swarm.KEY_T, swarm.KEY_W] * 12)
        opens = [e["t_ms"] for e in shortcuts[0::2]]
        self.assertEqual(opens, [7000 + 15000 * n for n in range(12)])
        for opened, closed in zip(shortcuts[0::2], shortcuts[1::2]):
            self.assertEqual(closed["t_ms"] - opened["t_ms"], 800)
            between = [e for e in EVENTS if opened["t_ms"] < e["t_ms"] < closed["t_ms"]
                       and e["kind"] in ("key", "action") and e["payload"].get("phase") == "down"]
            self.assertEqual(between, [], "nothing is typed into the New Tab page")

    def test_the_sidebar_ticks_every_half_second_round_all_rows(self):
        ticks = [e for e in EVENTS if e["kind"] == "cli"]
        self.assertEqual([e["t_ms"] for e in ticks], list(range(250, 180000, 500)))
        self.assertEqual({e["payload"]["argv"][1] for e in ticks}, {f"@w{n}" for n in range(40)})

    def test_events_are_in_time_order_inside_the_window(self):
        times = [e["t_ms"] for e in EVENTS]
        self.assertEqual(times, sorted(times))
        self.assertTrue(0 <= times[0] and times[-1] <= swarm.DURATION_MS)


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
            for n, (name, _) in enumerate(swarm.CHECKPOINTS)}


class CaptureTest(unittest.TestCase):
    def test_settle_returns_the_state_read_twice_in_a_row(self):
        reads = iter([{"focus": "a"}, {"focus": "b"}, {"focus": "b"}, {"focus": "c"}])
        clock = FakeClock()
        self.assertEqual(swarm.settle(lambda: next(reads), clock, 5.0, 0.05), {"focus": "b"})
        self.assertEqual(clock.ns, 100_000_000)

    def test_settle_fails_on_a_state_that_keeps_changing(self):
        counter = iter(range(10_000))
        with self.assertRaisesRegex(swarm.CaptureError, "did not settle in 5 s"):
            swarm.settle(lambda: {"focus": str(next(counter))}, FakeClock(), 5.0, 0.05)

    def test_two_agreeing_runs_record_the_story(self):
        player = FakePlayer(digests("a"), digests("a"))
        doc = swarm.capture(BLOBS, app="APP", out=Path("/out"), player=player)
        self.assertEqual(doc["status"], "recorded")
        self.assertNotIn("planned", doc)
        self.assertEqual({c["name"]: {"focus": c["focus"], "surfaces": c["surfaces"]} for c in doc["checkpoints"]},
                         digests("a"))
        self.assertEqual(cm.validation_errors(doc), [])
        self.assertEqual(swarm.manifest(BLOBS, doc), doc, "write keeps captured digests")
        self.assertEqual([out for _, _, out in player.played], [Path("/out/run-1"), Path("/out/run-2")])
        played = player.played[0][0]
        self.assertEqual(played["status"], "recorded", "the player loads only recorded stories")
        self.assertEqual(cm.validation_errors(played), [])
        self.assertEqual({k: v for k, v in played.items() if k not in ("status", "checkpoints")},
                         {k: v for k, v in COMMITTED.items() if k not in ("status", "checkpoints", "planned")})

    def test_runs_that_disagree_record_nothing(self):
        with self.assertRaisesRegex(swarm.CaptureError, "checkpoint layout-imported: run 1 read a0"):
            swarm.capture(BLOBS, app="APP", out=Path("/out"), player=FakePlayer(digests("a"), digests("b")))

    def test_capture_writes_the_recorded_manifest_and_check_accepts_it(self):
        with tempfile.TemporaryDirectory() as root, tempfile.TemporaryDirectory() as cache:
            path = Path(root) / swarm.MANIFEST_PATH
            path.parent.mkdir()
            path.write_text(swarm.render(COMMITTED))
            argv = ["capture", "--root", root, "--cache", cache, "--app", "APP", "--out", str(Path(root) / "out")]
            with redirect_stderr(io.StringIO()) as err:
                self.assertEqual(swarm.main(argv, out=lambda _: None, player=FakePlayer(digests("a"), digests("c"))), 1)
            self.assertIn("run 2 c0", err.getvalue())
            self.assertEqual(json.loads(path.read_text()), COMMITTED, "a failed capture leaves the manifest")
            self.assertEqual(swarm.main(argv, out=lambda _: None, player=FakePlayer(digests("a"), digests("a"))), 0)
            self.assertEqual(json.loads(path.read_text())["status"], "recorded")
            self.assertEqual(swarm.main(["check", "--root", root], out=lambda _: None), 0)

    def test_capture_needs_an_app_and_an_out_dir(self):
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            swarm.main(["capture"], out=lambda _: None)

    def test_the_capture_player_reads_the_settled_checkpoint(self):
        if not (CORPUS / "play.py").is_file():
            self.skipTest("play.py (p12-perf-process-115) is not on this branch yet")
        play = swarm.play_module()
        with tempfile.TemporaryDirectory() as cache, tempfile.TemporaryDirectory() as out:
            store = cm.BlobCache(swarm.cache_blobs(BLOBS, Path(cache)), lambda digest: self.fail(f"fetched {digest}"))

            def fetch(ref):
                store.get(ref)
                return store.path(ref)

            player = swarm.capture_player(play, root=REPO_ROOT, fetch=fetch, clock=FakeClock())
            recorder = FakePlayer(digests("a"), digests("a"))
            swarm.capture(BLOBS, app="APP", out=Path(out), player=recorder)
            story = player.load(recorder.played[0][0], Path(out))  # the player accepts what capture plays
            item = next(i for i in story.timeline if isinstance(i, play.Checkpoint))
            focus = {"windows": [], "context": {}, "consistent": True}
            surfaces = [{"windows": [], "blank_panes": n, "collapsed_panes": 0} for n in (1, 2, 2)]
            replies = iter([focus, surfaces[0], focus, surfaces[1], focus, surfaces[2]])
            got = player.checkpoint(lambda method, params, timeout: next(replies), item, Path(out))
            self.assertEqual(got, {"name": item.name, "focus": play.focus_digest(focus),
                                   "surfaces": play.surfaces_digest(surfaces[2])})
            self.assertTrue((Path(out) / f"checkpoint-{item.name}.json").is_file())


class TranscriptTest(unittest.TestCase):
    def transcripts(self):
        return [[json.loads(line) for line in BLOBS[f"agent-{n}"].decode().splitlines()] for n in range(12)]

    def test_twelve_streams_over_the_whole_window(self):
        for index, rows in enumerate(self.transcripts()):
            self.assertEqual(rows[0], {"schema": swarm.TRANSCRIPT_SCHEMA})
            records = rows[1:]
            times = [r["t_ms"] for r in records]
            self.assertEqual(times, sorted(times))
            self.assertEqual(records[0]["t_ms"], index * 150)
            self.assertEqual(records[-1], {"t_ms": 179500, "kind": "end", "stop": "end_turn"})
            self.assertGreater(sum(r["kind"] == "message" for r in records), 1000, index)
            # Streaming the whole window: never more than 6 s without a chunk or tool output (idle, a long tool).
            streamed = [r["t_ms"] for r in records if r["kind"] in ("message", "thought", "tool_update")]
            self.assertLessEqual(max(b - a for a, b in zip(streamed, streamed[1:])), 6000, index)
            self.assertGreater(streamed[-1], 170000, index)
        self.assertEqual(len({BLOBS[f"agent-{n}"] for n in range(12)}), 12)

    def test_the_replay_agent_accepts_them(self):
        path = CORPUS / "agent_replay.py"
        if not path.is_file():
            self.skipTest("agent_replay.py (p12-perf-process-114) is not on this branch yet")
        agent = load("perf_lab_corpus_agent_replay_for_swarm", path)
        for n in range(12):
            records = agent.parse_transcript(BLOBS[f"agent-{n}"])
            first, second = agent.transcript_frames(records), agent.transcript_frames(records)
            self.assertEqual(agent.frames_digest((u for _, u in first[0]), first[1]),
                             agent.frames_digest((u for _, u in second[0]), second[1]))


if __name__ == "__main__":
    unittest.main()
