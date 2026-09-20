#!/usr/bin/env python3
"""Exercise the focused-run launcher against a fake GitHub CLI."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
HEAD = "a" * 40
REMOTE_HEAD = "b" * 40
FAKE_GH = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
root = pathlib.Path(os.environ["LAUNCHER_TEST_DIR"])
with (root / "calls.jsonl").open("a") as f:
    f.write(json.dumps(args) + "\n")
if args[0] == "api":
    if os.environ.get("LAUNCHER_MISSING_COMMIT"):
        sys.exit(1)
    print(json.dumps({"sha": "b" * 40 if "topic%2Ffix" in args[1] else "a" * 40}))
elif args[:2] == ["workflow", "run"]:
    fields = dict(arg.split("=", 1) for arg in args if "=" in arg)
    (root / "dispatch.json").write_text(json.dumps(fields))
elif args[:2] == ["run", "list"]:
    fields = json.loads((root / "dispatch.json").read_text())
    print(json.dumps([
        {"databaseId": 999, "displayTitle": "someone else's newer run", "url": "https://github.com/manaflow-ai/cmux/actions/runs/999"},
        {"databaseId": 123, "displayTitle": fields["test_filter"] + " on mac @ " + fields.get("ref", "main") + " [" + fields.get("dispatch_id", "") + "]", "url": "https://github.com/manaflow-ai/cmux/actions/runs/123"}
    ]))
elif args[:2] == ["run", "watch"]:
    sys.exit(int(os.environ.get("LAUNCHER_WATCH_STATUS", "0")))
elif args[:2] == ["run", "view"]:
    print("failure")
else:
    sys.exit(2)
'''


class FocusedLauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name, source in {
            "gh": FAKE_GH,
            "git": '#!/bin/sh\ncase "$*" in\n*status*) printf "%s" "${LAUNCHER_DIRTY:-}";;\n*) printf "%s\\n" "' + HEAD + '";;\nesac\n',
            "sleep": "#!/bin/sh\nexit 0\n",
        }.items():
            path = self.bin / name
            path.write_text(source)
            path.chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "LAUNCHER_TEST_DIR": str(self.root),
        }

    def launch(self, *args, **env):
        return subprocess.run(
            ["bash", str(ROOT / "scripts/run-e2e.sh"), *args],
            env={**self.env, **env}, text=True, capture_output=True,
        )

    def calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def dispatch(self):
        return json.loads((self.root / "dispatch.json").read_text())

    def test_default_dispatches_exact_local_commit_and_finds_its_own_run(self):
        result = self.launch("cmuxTests/ExampleTests")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dispatch()["ref"], HEAD)
        self.assertTrue(self.dispatch()["dispatch_id"])
        self.assertEqual(self.dispatch()["record_video"], "false")
        self.assertIn("/actions/runs/123", result.stdout)
        self.assertNotIn("/actions/runs/999", result.stdout)

    def test_explicit_remote_ref_is_resolved_before_dispatch(self):
        result = self.launch("cmuxTests/ExampleTests/testOne", "--ref", "topic/fix")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dispatch()["ref"], REMOTE_HEAD)

    def test_dirty_default_checkout_does_not_dispatch(self):
        result = self.launch("cmuxTests/ExampleTests", LAUNCHER_DIRTY=" M Sources/App.swift")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "dispatch.json").exists())

    def test_explicit_remote_ref_does_not_claim_to_test_dirty_local_files(self):
        result = self.launch("ExampleUITests", "--ref", "topic/fix", LAUNCHER_DIRTY=" M local.txt")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dispatch()["ref"], REMOTE_HEAD)
        self.assertEqual(self.dispatch()["record_video"], "true")

    def test_unpushed_commit_does_not_dispatch(self):
        result = self.launch("cmuxTests/ExampleTests", LAUNCHER_MISSING_COMMIT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "dispatch.json").exists())

    def test_wait_preserves_failure_and_watches_matching_run(self):
        result = self.launch("cmuxTests/ExampleTests", "--wait", LAUNCHER_WATCH_STATUS="1")
        self.assertEqual(result.returncode, 1, result.stderr)
        watch = next(call for call in self.calls() if call[:2] == ["run", "watch"])
        self.assertIn("123", watch)
        self.assertNotIn("999", watch)

    def test_rejects_invalid_selectors_before_dispatch(self):
        for selector in ("", "cmuxTests/", "cmuxTests/Example/extra/method", "cmuxTests/A\ndispatch_id=bad", "cmuxTests/A;echo bad"):
            with self.subTest(selector=selector):
                self.assertNotEqual(self.launch(selector).returncode, 0)
        self.assertFalse((self.root / "dispatch.json").exists())

    def test_rejects_invalid_or_missing_options(self):
        for args in (("--timeout", "0"), ("--timeout", "bad"), ("--ref",), ("--unknown",)):
            with self.subTest(args=args):
                self.assertNotEqual(self.launch("ExampleTests", *args).returncode, 0)
        self.assertFalse((self.root / "dispatch.json").exists())


class RunDiscoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location(
            "focused_dispatch", ROOT / "scripts/ci/dispatch-focused-test.py"
        )
        cls.dispatch = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.dispatch)

    def test_waits_for_matching_dispatch_without_choosing_another_run(self):
        other = {"databaseId": 999, "displayTitle": "Other on mac @ " + HEAD + " [other]"}
        own = {"databaseId": 123, "displayTitle": "cmuxTests/Example on mac @ " + HEAD + " [mine]"}
        with mock.patch.object(self.dispatch, "output", side_effect=[json.dumps([other]), json.dumps([other, own])]), mock.patch.object(self.dispatch, "wait_for_retry", return_value=False) as wait:
            result = self.dispatch.find_run(HEAD, "cmuxTests/Example", "mine")
        self.assertEqual(result["databaseId"], 123)
        wait.assert_called_once_with(mock.ANY, 1)

    def test_missing_dispatch_fails_without_redispatching(self):
        with mock.patch.object(self.dispatch, "output", return_value="[]") as output, mock.patch.object(self.dispatch, "wait_for_retry", return_value=False) as wait:
            with self.assertRaisesRegex(ValueError, "before dispatching again"):
                self.dispatch.find_run(HEAD, "cmuxTests/Example", "mine")
        self.assertEqual(output.call_count, 12)
        self.assertEqual(wait.call_count, 11)
        self.assertTrue(all(call.args[1:3] == ("run", "list") for call in output.call_args_list))

    def test_cancellation_interrupts_discovery(self):
        cancelled = threading.Event()
        cancelled.set()
        with mock.patch.object(self.dispatch, "output", return_value="[]"):
            with self.assertRaisesRegex(ValueError, "cancelled"):
                self.dispatch.find_run(
                    HEAD, "cmuxTests/Example", "mine", cancel_event=cancelled
                )

    def test_cancellation_scope_handles_sigint_and_restores_handlers(self):
        original = self.dispatch.signal.getsignal(self.dispatch.signal.SIGINT)
        with self.dispatch.cancellation_scope() as cancelled:
            self.dispatch.signal.raise_signal(self.dispatch.signal.SIGINT)
            self.assertTrue(cancelled.is_set())
        self.assertIs(self.dispatch.signal.getsignal(self.dispatch.signal.SIGINT), original)

    def test_ambiguous_dispatch_fails(self):
        run = {"databaseId": 123, "displayTitle": "cmuxTests/Example on mac @ " + HEAD + " [mine]"}
        with mock.patch.object(self.dispatch, "output", return_value=json.dumps([run, run])):
            with self.assertRaisesRegex(ValueError, "refusing to guess"):
                self.dispatch.find_run(HEAD, "cmuxTests/Example", "mine")


if __name__ == "__main__":
    unittest.main()
