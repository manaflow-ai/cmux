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
SWITCHES = ("nextSidebarTab", "prevSidebarTab", "selectWorkspaceByNumber")


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


class InputTrackTest(unittest.TestCase):
    def test_a_switch_every_three_seconds_then_the_terminal_pane_focused(self):
        switches = [e for e in EVENTS if e["kind"] == "action" and e["payload"]["id"] in SWITCHES]
        self.assertEqual([e["t_ms"] for e in switches], list(range(3000, 180000, 3000)))
        focuses = [e for e in EVENTS if e["kind"] == "action" and e["payload"]["id"] == "pane.focus"]
        self.assertEqual([e["t_ms"] for e in focuses], [t + 40 for t in range(3000, 180000, 3000)])
        shown = 0
        for switch, focus in zip(switches, focuses):
            action = switch["payload"]["id"]
            before = shown
            shown = shown + 1 if action == "nextSidebarTab" else shown - 1 if action == "prevSidebarTab" \
                else switch["payload"]["args"]["index"] - 1
            self.assertNotEqual(shown, before)
            self.assertTrue(0 <= shown < 40)
            self.assertEqual(focus["payload"]["args"]["target"], f"@w{shown}.p0")

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
