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
VOCABULARY = cm.load_vocabulary()
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
            {"t_ms": 40, "kind": "action", "payload": {"id": "selectWorkspaceByNumber", "args": {"index": 1, "target": "@w1"}}},
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
    return cm.validation_errors(story, schema=SCHEMA, vocabulary=VOCABULARY, **kwargs)


class Store:
    """An in-memory R2BlobStore: size and put."""

    def __init__(self):
        self.objects = {}

    def size(self, key):
        return len(self.objects[key]) if key in self.objects else None

    def put(self, key, data, content_type):
        self.objects[key] = data


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

    def test_an_undeclared_action_or_argument_is_rejected(self):
        # Fail closed: a word of text in any argument the vocabulary does not declare is refused.
        for payload, where in (({"id": "workspace.rename", "args": {"new_name": "hunter2"}}, "payload.id"),
                               ({"id": "renameWorkspace", "args": {"name": "SecretProject"}}, "payload.id"),
                               ({"id": "closeTab", "args": {"data": "hunter2"}}, "payload.args.data"),
                               ({"id": "closeTab", "args": {"text": "ls"}}, "payload.args.text"),
                               ({"id": "closeTab", "args": {"target": "hunter2"}}, "payload.args.target"),
                               ({"id": "selectWorkspaceByNumber", "args": {"index": "hunter2"}}, "payload.args.index"),
                               ({"id": "selectWorkspaceByNumber", "args": {"index": True}}, "payload.args.index")):
            errors = errors_of(with_event(payload, kind="action"))
            self.assertTrue(any(where in error for error in errors), (payload, errors))

    def test_declared_actions_with_their_shapes_are_valid(self):
        for payload in ({"id": "newWindow"}, {"id": "closeTab", "args": {"target": "@w3.p0.t1"}},
                        {"id": "selectWorkspaceByNumber", "args": {"target": "@w2", "index": 3}}):
            self.assertEqual(errors_of(with_event(payload, kind="action")), [], payload)

    def test_a_string_with_spaces_is_rejected(self):
        errors = errors_of(with_event({"id": "closeTab", "args": {"target": "step 3"}}, kind="action"))
        self.assertTrue(any("does not match" in error for error in errors), errors)
        errors = errors_of(with_event({"argv": ["workspace", "@w1", "status", "set", "trace", "step 3"]}, kind="cli"))
        self.assertTrue(errors, errors)

    def test_an_undeclared_cli_command_flag_or_value_is_rejected(self):
        for argv in (["send", "ls"], ["workspace", "@w1", "rename", "x"], ["rename-workspace", "SecretProject"],
                     ["rename-tab", "hunter2"], ["new-workspace", "-n", "SecretProject"],
                     ["new-workspace", "--title=foo"], ["new-workspace", "--cwd", "home"],
                     ["browser", "open", "bank.example.com"], ["workspace", "@w1", "move", "--index", "hunter2"],
                     ["workspace", "@w1", "move", "-n", "hunter2"], ["workspace", "@w1", "move", "hunter2"],
                     ["workspace", "@w1", "move", "--index"], ["workspace", "hunter2", "move"],
                     ["workspace", "@w1", "update", "--task-status", "hunter2"],
                     ["workspace", "@w1", "status", "set", "trace", "hunter2"],
                     ["workspace", "@w1", "status", "set", "secret", "3"]):
            errors = errors_of(with_event({"argv": argv}, kind="cli"))
            self.assertTrue(any("matches no command" in error for error in errors), (argv, errors))

    def test_declared_cli_commands_are_valid(self):
        for argv in (["workspace", "@w1", "move", "--index=0"], ["workspace", "@w1", "update", "--task-status", "review"],
                     ["workspace", "group", "@g2", "add", "--index", "0", "--workspace", "@w5"],
                     ["workspace", "@w1", "status", "set", "trace", "3"]):
            self.assertEqual(errors_of(with_event({"argv": argv}, kind="cli")), [], argv)

    def test_the_vocabulary_has_no_free_text_shape(self):
        for shape in ({"type": "string"}, {"type": "token"}, {"enum": ["two words"]}, {"enum": []}, {"pattern": ".*"}):
            for vocabulary in ({"actions": {"closeTab": {"note": shape}}, "cli": []},
                               {"actions": {}, "cli": [{"argv": ["workspace", shape], "flags": {}}]},
                               {"actions": {}, "cli": [{"argv": ["workspace"], "flags": {"--note": shape}}]}):
                with tempfile.TemporaryDirectory() as directory:
                    path = Path(directory) / cm.VOCABULARY_PATH
                    path.parent.mkdir(parents=True)
                    path.write_text(json.dumps({"schema": cm.VOCABULARY_ID, **vocabulary}))
                    with self.assertRaises(cm.CorpusError, msg=(shape, vocabulary)):
                        cm.load_vocabulary(Path(directory))

    def test_a_text_event_in_an_input_blob_is_rejected(self):
        events = [{"t_ms": 0, "kind": "cli", "payload": {"argv": ["send", "secret"]}}]
        data = "".join(json.dumps(event) + "\n" for event in events).encode()
        with tempfile.TemporaryDirectory() as directory:
            cache = cm.BlobCache(Path(directory), fetch=lambda digest: data)
            story = recorded_story()
            story["input"] = {"blob": cm.blob_ref(data)}
            self.assertEqual(errors_of(story), [])
            errors = cm.blob_input_errors(story, cache, SCHEMA, VOCABULARY)
        self.assertTrue(any("matches no command" in error for error in errors), errors)


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


    def test_config_keys_are_settings_with_their_default_type(self):
        story = recorded_story()
        story["config"] = {"sidebar.numbering": "workspacesOnly", "browser.omnibar.remoteSuggestions": False,
                           "browser.keepNeighborTabsAwake": 0}
        self.assertEqual(errors_of(story), [])
        story["config"] = {"sidebar.numberingg": "workspacesOnly", "browser.omnibar.remoteSuggestions": "off",
                           "browser.keepNeighborTabsAwake": True}
        errors = errors_of(story)
        self.assertTrue(any(e.startswith("$.config.sidebar.numberingg: not a cmux-next.json setting") for e in errors), errors)
        self.assertTrue(any(e.startswith("$.config.browser.omnibar.remoteSuggestions: a string") for e in errors), errors)
        self.assertTrue(any(e.startswith("$.config.browser.keepNeighborTabsAwake: a boolean") for e in errors), errors)

    def test_config_values_are_tokens(self):
        story = recorded_story()
        for config in ({"sidebar.numbering": "all items"}, {"sidebar": "workspacesOnly"},
                       {"sidebar.numbering": ["workspacesOnly"]}):
            story["config"] = config
            self.assertTrue(cm.schema_errors(story, SCHEMA, SCHEMA), config)


class TreeTest(unittest.TestCase):
    def tree(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        (root / "schemas/perf").mkdir(parents=True)
        shutil.copy(REPO_ROOT / cm.SCHEMA_PATH, root / cm.SCHEMA_PATH)
        shutil.copy(REPO_ROOT / cm.VOCABULARY_PATH, root / cm.VOCABULARY_PATH)
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

    def test_upload_of_a_text_bearing_input_blob_puts_nothing(self):
        root = self.tree()
        blob = json.dumps({"t_ms": 0, "kind": "cli", "payload": {"argv": ["rename-workspace", "SecretProject"]}}).encode()
        cache_dir = root / "cache"
        cache = cm.BlobCache(cache_dir, fetch=lambda digest: self.fail("not cached"))
        story = recorded_story()
        story["id"], story["pty"] = "leak", []
        story["input"] = {"blob": cache.add(blob)}
        story["layout"]["snapshot"] = cache.add(b"layout")
        story["web_archive"]["wprgo"] = cache.add(b"wprgo")
        story["agents"][0]["transcript"] = cache.add(b"transcript")
        (root / "perf-corpus/leak.json").write_text(json.dumps(story))
        store = Store()
        real_load = cm._load_sibling

        class FakeTraceQuest:
            TraceQuestError = RuntimeError

            class R2BlobStore:
                @staticmethod
                def from_env():
                    return store

        def load(name):
            return FakeTraceQuest if name == "trace_quest" else real_load(name)

        cm._load_sibling = load
        self.addCleanup(setattr, cm, "_load_sibling", real_load)
        err = io.StringIO()
        with redirect_stderr(err), redirect_stdout(io.StringIO()):
            code = cm.main(["--root", str(root), "--cache", str(cache_dir), "--upload", str(root / "perf-corpus/leak.json")])
        self.assertEqual(code, 1)
        self.assertEqual(store.objects, {})
        self.assertIn("$.input.blob", err.getvalue())
        with self.assertRaises(cm.CorpusError):
            cm.upload([story], cache, store, SCHEMA, VOCABULARY)
        self.assertEqual(store.objects, {})


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
        with tempfile.TemporaryDirectory() as directory:
            cache = cm.BlobCache(Path(directory), fetch=lambda digest: self.fail("not cached"))
            story = recorded_story()
            story["layout"]["snapshot"] = cache.add(b"layout")
            story["web_archive"] = None
            story["agents"] = []
            store = Store()
            self.assertEqual(len(cm.upload([story], cache, store, SCHEMA, VOCABULARY)), 1)
            self.assertEqual(store.objects, {cm.R2_PREFIX + story["layout"]["snapshot"]["sha256"]: b"layout"})
            self.assertEqual(cm.upload([story], cache, store, SCHEMA, VOCABULARY), [])


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
