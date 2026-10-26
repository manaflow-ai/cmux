"""Tests for scripts/perf-lab/corpus/manifest.py and schemas/perf/corpus-story-v1.schema.json (task 110).

Run: python3 -m unittest scripts/perf-lab/tests/test_corpus_manifest.py
"""

import copy
import hashlib
import importlib.util
import io
import json
import shutil
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[2]
spec = importlib.util.spec_from_file_location("corpus_manifest_under_test", HERE.parent / "corpus" / "manifest.py")
cm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cm)
SCHEMA = cm.load_schema()
PLANNED = {"agent-swarm", "dev-loop", "browse-heavy", "stress-recorded", "launch-restore", "long-day-soak"}
HEX = "ab" * 32


def recorded_story():
    vt = REPO_ROOT / "schemas/terminal-corpus/alt-screen-editor.vt"
    data = vt.read_bytes()
    return {
        "schema": "cmux-perf-corpus-story/v1",
        "id": "fixture",
        "tier": "T1",
        "status": "recorded",
        "description": "A fixture.",
        "owner": "PL-perf-lab",
        "duration_ms": 1000,
        "layout": {"snapshot": {"sha256": HEX, "bytes": 10}, "workspaces": 2},
        "input": {"events": [
            {"t_ms": 0, "kind": "key", "payload": {"phase": "down", "class": "letter", "modifiers": []}},
            {"t_ms": 10, "kind": "key", "payload": {"phase": "down", "class": "letter", "key_code": 17,
                                                     "modifiers": ["cmd"]}},
            {"t_ms": 20, "kind": "key", "payload": {"phase": "down", "class": "named", "key_code": 36,
                                                     "modifiers": []}},
            {"t_ms": 30, "kind": "mouse", "payload": {"phase": "down", "button": 0, "x": 10.5, "y": 4,
                                                       "click_count": 1, "window": "@w0"}},
            {"t_ms": 40, "kind": "action", "payload": {"id": "workspace.select", "args": {"index": 1, "ref": "@w1"}}},
            {"t_ms": 50, "kind": "cli", "payload": {"argv": ["workspace", "@w1", "move", "--index", "0"]}},
        ]},
        "pty": [{"surface": "@w0.p0.t0", "speed": 1, "loop": False,
                 "source": {"path": "schemas/terminal-corpus/alt-screen-editor.vt",
                            "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}}],
        "web_archive": {"wprgo": {"sha256": HEX, "bytes": 5}, "spki": "A" * 43 + "="},
        "agents": [{"surface": "@w1.p0.t0", "agent": "acp-replay", "transcript": {"sha256": HEX, "bytes": 3}}],
        "checkpoints": [{"t_ms": 0, "name": "start", "focus": HEX, "surfaces": HEX},
                        {"t_ms": 1000, "name": "end", "focus": HEX, "surfaces": HEX}],
        "metrics": [{"name": r"corpus\.fixture\.key_to_frame", "unit": "ms", "better": "lower"}],
    }


def errors_of(story, **kwargs):
    return cm.validation_errors(story, schema=SCHEMA, **kwargs)


def with_event(payload, kind="key"):
    story = recorded_story()
    story["input"]["events"].append({"t_ms": 60, "kind": kind, "payload": payload})
    return story


class CheckedInStoriesTest(unittest.TestCase):
    def test_the_six_planned_stories_validate(self):
        paths = sorted((REPO_ROOT / "perf-corpus").glob("*.json"))
        self.assertEqual({path.stem for path in paths}, PLANNED)
        self.assertEqual(cm.validate_paths(paths, REPO_ROOT), [])

    def test_the_cli_validates_them(self):
        paths = [str(path) for path in sorted((REPO_ROOT / "perf-corpus").glob("*.json"))]
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(cm.main(["--validate", *paths]), 0)
        self.assertIn("ok: 6 corpus stories", out.getvalue())

    def test_no_corpus_file_is_over_256_kb(self):
        self.assertEqual(cm.oversized_files(REPO_ROOT), [])


class TextPayloadTest(unittest.TestCase):
    def test_the_fixture_is_valid(self):
        self.assertEqual(errors_of(recorded_story()), [])

    def test_a_typing_key_with_its_key_code_is_rejected(self):
        for key_class in ("letter", "digit", "punctuation", "space", "other"):
            errors = errors_of(with_event({"phase": "down", "class": key_class, "key_code": 0,
                                           "modifiers": ["shift"]}))
            self.assertTrue(any("typed text" in error for error in errors), (key_class, errors))

    def test_characters_on_a_key_are_rejected(self):
        errors = errors_of(with_event({"phase": "down", "class": "letter", "modifiers": [], "characters": "a"}))
        self.assertTrue(any("characters" in error for error in errors), errors)

    def test_a_text_argument_of_an_action_is_rejected(self):
        for args in ({"text": "ls"}, {"title": "abc"}, {"query": 1}):
            errors = errors_of(with_event({"id": "workspace.rename", "args": args}, kind="action"))
            self.assertTrue(any("text key" in error for error in errors), (args, errors))

    def test_a_string_with_spaces_is_rejected(self):
        errors = errors_of(with_event({"id": "workspace.status", "args": {"status": "step 3"}}, kind="action"))
        self.assertTrue(any("does not match" in error for error in errors), errors)
        errors = errors_of(with_event({"argv": ["workspace", "@w1", "status", "set", "trace", "step 3"]}, kind="cli"))
        self.assertTrue(errors, errors)

    def test_text_bearing_cli_words_and_flags_are_rejected(self):
        for argv in (["send", "ls"], ["workspace", "@w1", "rename", "x"], ["new-workspace", "--title=foo"],
                     ["new-workspace", "--cwd", "home"]):
            errors = errors_of(with_event({"argv": argv}, kind="cli"))
            self.assertTrue(any("carries text" in error for error in errors), (argv, errors))

    def test_a_text_event_in_an_input_blob_is_rejected(self):
        events = [{"t_ms": 0, "kind": "cli", "payload": {"argv": ["send", "secret"]}}]
        data = "".join(json.dumps(event) + "\n" for event in events).encode()
        with tempfile.TemporaryDirectory() as directory:
            cache = cm.BlobCache(Path(directory), fetch=lambda digest: data)
            story = recorded_story()
            story["input"] = {"blob": cm.blob_ref(data)}
            self.assertEqual(errors_of(story), [])
            errors = cm.blob_input_errors(story, cache, SCHEMA)
        self.assertTrue(any("carries text" in error for error in errors), errors)


class StoryRulesTest(unittest.TestCase):
    def test_a_recorded_story_needs_every_source_and_digest(self):
        story = recorded_story()
        story["agents"][0]["transcript"] = None
        story["web_archive"]["spki"] = None
        story["checkpoints"][1]["focus"] = None
        errors = errors_of(story)
        for where in ("$.agents[0].transcript", "$.web_archive.spki", "$.checkpoints[1]"):
            self.assertTrue(any(error.startswith(where) for error in errors), (where, errors))

    def test_a_planned_story_says_what_records_it(self):
        story = recorded_story()
        story["status"] = "planned"
        self.assertTrue(any("$.planned" in error for error in errors_of(story)))
        story["planned"] = "task 116"
        story["layout"]["snapshot"] = None
        self.assertEqual(errors_of(story), [])

    def test_times_are_ordered_and_inside_the_duration(self):
        story = recorded_story()
        story["input"]["events"][1]["t_ms"] = 2000
        story["checkpoints"].reverse()
        errors = errors_of(story)
        self.assertTrue(any("$.input.events[1].t_ms: after" in error for error in errors), errors)
        self.assertTrue(any("$.input.events[2].t_ms: before" in error for error in errors), errors)
        self.assertTrue(any("$.checkpoints[1].t_ms" in error for error in errors), errors)

    def test_a_repository_source_must_match_its_digest(self):
        story = recorded_story()
        story["pty"][0]["source"]["sha256"] = HEX
        self.assertTrue(any("does not match its sha256" in error for error in errors_of(story)))

    def test_a_repository_source_over_256_kb_is_rejected(self):
        path = "schemas/terminal-corpus/scrollback.vt"
        data = (REPO_ROOT / path).read_bytes()
        self.assertGreater(len(data), cm.MAX_GIT_BYTES)
        story = recorded_story()
        story["pty"][0]["source"] = {"path": path, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
        self.assertTrue(errors_of(story))
        self.assertTrue(any("over 262144" in e for e in cm._file_errors("$", story["pty"][0]["source"], REPO_ROOT)))

    def test_owner_metric_and_compose_are_checked(self):
        story = recorded_story()
        story["owner"] = "someone"
        story["metrics"][0]["name"] = "corpus\\.("
        story["compose"] = {"stories": ["fixture", "missing"], "idle_gap_ms": 0}
        errors = errors_of(story, owners=frozenset({"PL-perf-lab"}), stories=frozenset({"fixture"}))
        self.assertTrue(any(error.startswith("$.owner") for error in errors), errors)
        self.assertTrue(any(error.startswith("$.metrics[0].name") for error in errors), errors)
        self.assertEqual(sum(error.startswith("$.compose") for error in errors), 2, errors)


class TreeTest(unittest.TestCase):
    def tree(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        (root / "schemas/perf").mkdir(parents=True)
        shutil.copy(REPO_ROOT / cm.SCHEMA_PATH, root / cm.SCHEMA_PATH)
        (root / "perf-corpus").mkdir()
        return root

    def test_an_oversized_corpus_file_and_manifest_are_rejected(self):
        root = self.tree()
        (root / "perf-corpus/big.bin").write_bytes(b"\0" * (cm.MAX_GIT_BYTES + 1))
        story = recorded_story()
        story["id"], story["status"], story["planned"] = "big", "planned", "fixture"
        story["pty"] = []
        story["input"]["events"] *= 2000
        for index, event in enumerate(story["input"]["events"]):
            event["t_ms"] = 0
        (root / "perf-corpus/big.json").write_text(json.dumps(story))
        problems = cm.validate_paths([root / "perf-corpus/big.json"], root)
        self.assertTrue(any("big.bin" in problem for problem in problems), problems)
        self.assertTrue(any("move its events into an input blob" in problem for problem in problems), problems)

    def test_the_id_is_the_file_name_and_the_cli_fails(self):
        root = self.tree()
        story = recorded_story()
        story["pty"] = []
        (root / "perf-corpus/other.json").write_text(json.dumps(story))
        err = io.StringIO()
        with redirect_stderr(err):
            self.assertEqual(cm.main(["--root", str(root), "--validate", str(root / "perf-corpus/other.json")]), 1)
        self.assertIn("is not the file name", err.getvalue())


class BlobCacheTest(unittest.TestCase):
    def test_a_fetched_blob_is_verified_and_cached(self):
        data, calls = b"vt bytes", []
        with tempfile.TemporaryDirectory() as directory:
            cache = cm.BlobCache(Path(directory), fetch=lambda digest: calls.append(digest) or data)
            ref = cm.blob_ref(data)
            self.assertEqual(cache.get(ref), data)
            self.assertEqual(cache.get(ref), data)
            self.assertEqual(len(calls), 1)
            cache.path(ref).write_bytes(b"corrupt")
            self.assertEqual(cache.get(ref), data)
            self.assertEqual(len(calls), 2)

    def test_wrong_bytes_from_r2_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = cm.BlobCache(Path(directory), fetch=lambda digest: b"other")
            with self.assertRaises(cm.CorpusError):
                cache.get(cm.blob_ref(b"expected"))
            self.assertFalse(any(Path(directory).iterdir()))

    def test_upload_is_write_once(self):
        class Store:
            def __init__(self):
                self.objects = {}

            def size(self, key):
                return len(self.objects[key]) if key in self.objects else None

            def put(self, key, data, content_type):
                self.objects[key] = data

        with tempfile.TemporaryDirectory() as directory:
            cache = cm.BlobCache(Path(directory), fetch=lambda digest: self.fail("not cached"))
            story = recorded_story()
            story["layout"]["snapshot"] = cache.add(b"layout")
            story["web_archive"] = None
            story["agents"] = []
            store = Store()
            self.assertEqual(len(cm.upload([story], cache, store)), 1)
            self.assertEqual(store.objects, {cm.R2_PREFIX + story["layout"]["snapshot"]["sha256"]: b"layout"})
            self.assertEqual(cm.upload([story], cache, store), [])


class SchemaTest(unittest.TestCase):
    def test_the_evaluator_agrees_with_jsonschema(self):
        try:
            import jsonschema
        except ImportError:
            self.skipTest("jsonschema is not installed")
        validator = jsonschema.Draft202012Validator(SCHEMA)
        bad = recorded_story()
        bad["input"]["events"][0]["payload"]["characters"] = "a"
        bad["tier"] = "T9"
        cases = [recorded_story(), bad] + [json.loads(p.read_text()) for p in (REPO_ROOT / "perf-corpus").glob("*.json")]
        for case in cases:
            ours = cm.schema_errors(copy.deepcopy(case), SCHEMA, SCHEMA)
            self.assertEqual(bool(ours), any(True for _ in validator.iter_errors(case)), ours)

    def test_units_and_better_are_result_v1s(self):
        result = json.loads((REPO_ROOT / "schemas/perf/result-v1.schema.json").read_text())
        metric = SCHEMA["properties"]["metrics"]["items"]["properties"]
        self.assertEqual(metric["unit"]["enum"], result["properties"]["unit"]["enum"])
        self.assertEqual(metric["better"]["enum"], result["properties"]["better"]["enum"])


if __name__ == "__main__":
    unittest.main()
