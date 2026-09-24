#!/usr/bin/env python3
"""Exercise the focused-run launcher against a fake GitHub CLI."""
import importlib.util
import json
import re
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RUNNER = re.search(
    r"vars\.MACOS_RUNNER_TESTS \|\| '([^']+)'",
    (ROOT / ".github/workflows/test-e2e.yml").read_text(),
).group(1)
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
elif args[:2] == ["variable", "list"]:
    print(os.environ.get("LAUNCHER_VARIABLES", "[]"))
elif args[:2] == ["run", "list"]:
    if "conclusion" in " ".join(args):
        # The pre-dispatch repeat guard asks for conclusions; the post-dispatch
        # correlation does not. Key on that rather than on call ordering.
        print(os.environ.get("LAUNCHER_PRIOR_RUNS", "[]"))
        sys.exit(0)
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

    def test_explicit_runner_reaches_the_workflow_dispatch(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/test-e2e.yml").read_text())
        choices = workflow["on" if "on" in workflow else True]["workflow_dispatch"]["inputs"]["runner"]["options"]
        for runner in choices:
            with self.subTest(runner=runner):
                result = self.launch("cmuxTests/ExampleTests", "--runner", runner)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.dispatch()["runner"], runner)

    def test_default_runner_keeps_the_workflow_default(self):
        result = self.launch("cmuxTests/ExampleTests")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("runner", self.dispatch())

    def test_odd_commits_compile_on_the_large_sku(self):
        # REMOTE_HEAD ends in b, so it is routed; HEAD ends in a, so it is not.
        result = self.launch("cmuxTests/ExampleTests", "--ref", "topic/fix")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dispatch()["runner"], "blacksmith-12vcpu-macos-26")

    def test_an_explicit_runner_is_never_rerouted(self):
        result = self.launch(
            "cmuxTests/ExampleTests", "--ref", "topic/fix",
            "--runner", "blacksmith-6vcpu-macos-26",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dispatch()["runner"], "blacksmith-6vcpu-macos-26")

    def test_an_admin_runner_variable_is_never_split(self):
        result = self.launch(
            "cmuxTests/ExampleTests", "--ref", "topic/fix",
            LAUNCHER_VARIABLES=json.dumps([
                {"name": "MACOS_RUNNER_TESTS", "value": "blacksmith-6vcpu-macos-15"},
            ]),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("runner", self.dispatch())

    def test_a_routed_commit_reuses_its_in_flight_run_on_the_large_sku(self):
        result = self.launch(
            "cmuxTests/ExampleTests", "--ref", "topic/fix",
            LAUNCHER_PRIOR_RUNS=self._live(
                commit=REMOTE_HEAD, runner="blacksmith-12vcpu-macos-26",
            ),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("reusing that run", result.stdout)
        self.assertFalse((self.root / "dispatch.json").exists())

    def test_invalid_runner_is_rejected_before_github_access(self):
        result = self.launch("cmuxTests/ExampleTests", "--runner", "macos-15")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

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

    def test_batched_filters_dispatch_one_run_against_one_compile(self):
        result = self.launch("cmuxTests/AlphaTests", "cmuxTests/BetaTests")
        self.assertEqual(result.returncode, 0, result.stderr)
        # One dispatch, one comma-joined filter: the workflow expands it into
        # several -only-testing: flags and compiles once.
        self.assertEqual(self.dispatch()["test_filter"], "cmuxTests/AlphaTests,cmuxTests/BetaTests")
        self.assertEqual(self.dispatch()["ref"], HEAD)
        self.assertEqual(self.dispatch()["record_video"], "false")

    def test_batched_ui_filters_keep_video_recording(self):
        result = self.launch("cmuxUITests/AlphaUITests", "BetaUITests")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dispatch()["test_filter"], "cmuxUITests/AlphaUITests,BetaUITests")
        self.assertEqual(self.dispatch()["record_video"], "true")

    def test_rejects_batches_that_mix_targets_or_repeat_entries(self):
        for entries in (
            ("cmuxTests/AlphaTests", "cmuxUITests/BetaUITests"),
            ("cmuxTests/AlphaTests", "BetaUITests"),
            ("cmuxTests/AlphaTests", "cmuxTests/AlphaTests"),
            ("cmuxTests/AlphaTests", "cmuxTests/"),
        ):
            with self.subTest(entries=entries):
                self.assertNotEqual(self.launch(*entries).returncode, 0)
        self.assertFalse((self.root / "dispatch.json").exists())

    def test_rejects_invalid_or_missing_options(self):
        for args in (("--timeout", "0"), ("--timeout", "bad"), ("--ref",), ("--unknown",)):
            with self.subTest(args=args):
                self.assertNotEqual(self.launch("ExampleTests", *args).returncode, 0)
        self.assertFalse((self.root / "dispatch.json").exists())
    def _prior(self, conclusion, *, selector="cmuxTests/ExampleTests", commit=HEAD, runner="mac"):
        return json.dumps([{
            "displayTitle": f"{selector} on {runner} @ {commit} [deadbeef]",
            "conclusion": conclusion,
            "status": "completed",
            "url": "https://github.com/manaflow-ai/cmux/actions/runs/555",
        }])

    def _live(self, *, selector="cmuxTests/ExampleTests", commit=HEAD,
              runner=DEFAULT_RUNNER, status="in_progress"):
        return json.dumps([{
            "databaseId": 777,
            "displayTitle": f"{selector} on {runner} @ {commit} [deadbeef]",
            "conclusion": None,
            "status": status,
            "url": "https://github.com/manaflow-ai/cmux/actions/runs/777",
        }])

    def test_failure_on_another_runner_allows_explicit_runner_proof(self):
        result = self.launch(
            "cmuxTests/ExampleTests", "--runner", "blacksmith-6vcpu-macos-26",
            LAUNCHER_PRIOR_RUNS=self._prior("failure", runner="blacksmith-6vcpu-macos-15"),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dispatch()["runner"], "blacksmith-6vcpu-macos-26")

    def test_same_runner_failure_is_not_overridden_by_other_runner_success(self):
        prior = json.loads(self._prior("failure", runner="blacksmith-6vcpu-macos-26"))
        prior += json.loads(self._prior("success", runner="blacksmith-6vcpu-macos-15"))
        result = self.launch(
            "cmuxTests/ExampleTests", "--runner", "blacksmith-6vcpu-macos-26",
            LAUNCHER_PRIOR_RUNS=json.dumps(prior),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already failed", result.stderr)
        self.assertFalse((self.root / "dispatch.json").exists())

    def test_explicit_auto_preserves_existing_repeat_guard(self):
        result = self.launch(
            "cmuxTests/ExampleTests", "--runner", "auto",
            LAUNCHER_PRIOR_RUNS=self._prior("failure", runner="blacksmith-6vcpu-macos-15"),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already failed", result.stderr)
        self.assertFalse((self.root / "dispatch.json").exists())

    def test_repeat_of_a_failed_selector_at_the_same_commit_is_refused(self):
        result = self.launch(
            "cmuxTests/ExampleTests", LAUNCHER_PRIOR_RUNS=self._prior("failure")
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already failed", result.stderr)
        self.assertIn("actions/runs/555", result.stderr)
        self.assertFalse((self.root / "dispatch.json").exists(), "must not dispatch")

    def test_batch_is_refused_when_any_entry_already_failed(self):
        # The batch shares one compile, so a single known-red selector makes
        # the whole dispatch a reprint of an answer we already have.
        result = self.launch(
            "cmuxTests/AlphaTests", "cmuxTests/ExampleTests",
            LAUNCHER_PRIOR_RUNS=self._prior("failure"),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cmuxTests/ExampleTests already failed", result.stderr)
        self.assertFalse((self.root / "dispatch.json").exists(), "must not dispatch")

    def test_an_earlier_batch_counts_as_a_prior_attempt_for_each_entry(self):
        # A prior run named several selectors before " on ". Matching only a
        # title prefix would let batching bypass the guard entirely.
        prior = self._prior("failure", selector="cmuxTests/AlphaTests,cmuxTests/ExampleTests")
        result = self.launch("cmuxTests/ExampleTests", LAUNCHER_PRIOR_RUNS=prior)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already failed", result.stderr)
        self.assertFalse((self.root / "dispatch.json").exists(), "must not dispatch")

    def test_force_dispatches_despite_an_earlier_failure(self):
        result = self.launch(
            "cmuxTests/ExampleTests", "--force",
            LAUNCHER_PRIOR_RUNS=self._prior("failure"),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dispatch()["test_filter"], "cmuxTests/ExampleTests")

    def test_earlier_success_does_not_block_a_repeat(self):
        result = self.launch(
            "cmuxTests/ExampleTests", LAUNCHER_PRIOR_RUNS=self._prior("success")
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_failure_of_a_different_selector_does_not_block(self):
        result = self.launch(
            "cmuxTests/ExampleTests",
            LAUNCHER_PRIOR_RUNS=self._prior("failure", selector="cmuxTests/OtherTests"),
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_failure_at_a_different_commit_does_not_block(self):
        result = self.launch(
            "cmuxTests/ExampleTests",
            LAUNCHER_PRIOR_RUNS=self._prior("failure", commit="c" * 40),
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_identical_run_in_flight_is_reused_instead_of_dispatched(self):
        # Dispatching here would match the workflow's concurrency group and
        # cancel the run already compiling, restarting that compile from cold.
        result = self.launch(
            "cmuxTests/ExampleTests", LAUNCHER_PRIOR_RUNS=self._live()
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("actions/runs/777", result.stdout)
        self.assertFalse((self.root / "dispatch.json").exists(), "must not dispatch")

    def test_queued_identical_run_is_reused(self):
        result = self.launch(
            "cmuxTests/ExampleTests",
            LAUNCHER_PRIOR_RUNS=self._live(status="queued"),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "dispatch.json").exists(), "must not dispatch")

    def test_reused_run_is_watched_and_reports_its_result(self):
        result = self.launch(
            "cmuxTests/ExampleTests", "--wait",
            LAUNCHER_PRIOR_RUNS=self._live(), LAUNCHER_WATCH_STATUS="1",
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn(["run", "watch", "--repo", "manaflow-ai/cmux", "777", "--exit-status"],
                      self.calls())
        self.assertFalse((self.root / "dispatch.json").exists(), "must not dispatch")

    def test_identical_batch_in_flight_is_reused_regardless_of_order(self):
        live = self._live(selector="cmuxTests/ExampleTests,cmuxTests/AlphaTests")
        result = self.launch(
            "cmuxTests/AlphaTests", "cmuxTests/ExampleTests",
            LAUNCHER_PRIOR_RUNS=live,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "dispatch.json").exists(), "must not dispatch")

    def test_overlapping_in_flight_batch_is_refused_rather_than_duplicated(self):
        # A different batch does not share the concurrency group, so this would
        # pay a second full compile of identical source for an answer already
        # in flight. There is no single run to attach to, so refuse instead.
        live = self._live(selector="cmuxTests/ExampleTests,cmuxTests/OtherTests")
        result = self.launch("cmuxTests/ExampleTests", LAUNCHER_PRIOR_RUNS=live)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already in_progress", result.stderr)
        self.assertIn("actions/runs/777", result.stderr)
        self.assertFalse((self.root / "dispatch.json").exists(), "must not dispatch")

    def test_force_dispatches_over_an_in_flight_run(self):
        result = self.launch(
            "cmuxTests/ExampleTests", "--force", LAUNCHER_PRIOR_RUNS=self._live()
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dispatch()["test_filter"], "cmuxTests/ExampleTests")

    def test_in_flight_run_at_a_different_commit_does_not_block(self):
        result = self.launch(
            "cmuxTests/ExampleTests",
            LAUNCHER_PRIOR_RUNS=self._live(commit="c" * 40),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dispatch()["ref"], HEAD)

    def test_in_flight_run_on_another_runner_does_not_block_explicit_runner(self):
        result = self.launch(
            "cmuxTests/ExampleTests", "--runner", "blacksmith-6vcpu-macos-26",
            LAUNCHER_PRIOR_RUNS=self._live(runner="blacksmith-6vcpu-macos-15"),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dispatch()["runner"], "blacksmith-6vcpu-macos-26")

    def test_a_run_on_another_runner_is_never_reused_as_the_answer(self):
        # The concurrency groups differ, so nothing would have been cancelled,
        # and under --wait attaching would report macOS 15's result to someone
        # who asked the default pool. Dispatch instead.
        result = self.launch(
            "cmuxTests/ExampleTests", "--wait",
            LAUNCHER_PRIOR_RUNS=self._live(runner="tart-canary"),
            LAUNCHER_WATCH_STATUS="0",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dispatch()["test_filter"], "cmuxTests/ExampleTests")
        self.assertNotIn("actions/runs/777", result.stdout)

    def test_the_repository_variable_decides_which_runner_auto_means(self):
        variables = json.dumps([{"name": "MACOS_RUNNER_TESTS", "value": "warp-macos-15-arm64-6x"}])
        # The workflow literal is now the wrong answer, so a run named for it
        # must not be attached to...
        result = self.launch(
            "cmuxTests/ExampleTests",
            LAUNCHER_PRIOR_RUNS=self._live(), LAUNCHER_VARIABLES=variables,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "dispatch.json").exists())
        # ...while a run named for the variable's value is.
        self.setUp()
        result = self.launch(
            "cmuxTests/ExampleTests",
            LAUNCHER_PRIOR_RUNS=self._live(runner="warp-macos-15-arm64-6x"),
            LAUNCHER_VARIABLES=variables,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "dispatch.json").exists(), "must not dispatch")

    def test_a_run_without_a_dispatch_id_is_still_seen(self):
        # A run started from the GitHub UI shares the concurrency group and its
        # compile is just as real. Requiring the trailing "[" hid exactly the
        # runs these guards exist to protect.
        live = json.dumps([{
            "databaseId": 777,
            "displayTitle": f"cmuxTests/ExampleTests on {DEFAULT_RUNNER} @ {HEAD}",
            "conclusion": None, "status": "in_progress",
            "url": "https://github.com/manaflow-ai/cmux/actions/runs/777",
        }])
        result = self.launch("cmuxTests/ExampleTests", LAUNCHER_PRIOR_RUNS=live)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("actions/runs/777", result.stdout)
        self.assertFalse((self.root / "dispatch.json").exists(), "must not dispatch")

    def test_an_unattachable_entry_dispatches_rather_than_blocking(self):
        # These guards are an economy measure, never a gate. An entry with no
        # id cannot be watched, so the caller gets the run they asked for.
        live = json.dumps([{
            "displayTitle": f"cmuxTests/ExampleTests on {DEFAULT_RUNNER} @ {HEAD} [deadbeef]",
            "conclusion": None, "status": "in_progress", "url": "",
        }])
        result = self.launch("cmuxTests/ExampleTests", LAUNCHER_PRIOR_RUNS=live)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dispatch()["test_filter"], "cmuxTests/ExampleTests")

    def test_an_unknown_status_is_not_treated_as_occupying_a_runner(self):
        result = self.launch(
            "cmuxTests/ExampleTests", LAUNCHER_PRIOR_RUNS=self._live(status="")
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "dispatch.json").exists())

    def test_unreadable_variables_dispatch_rather_than_guess_a_runner(self):
        result = self.launch(
            "cmuxTests/ExampleTests",
            LAUNCHER_PRIOR_RUNS=self._live(), LAUNCHER_VARIABLES="not json",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "dispatch.json").exists())

    def test_a_malformed_history_payload_never_blocks_a_dispatch(self):
        for payload in ("null", '{"runs": []}', '[null, 3]'):
            with self.subTest(payload=payload):
                self.setUp()
                result = self.launch("cmuxTests/ExampleTests", LAUNCHER_PRIOR_RUNS=payload)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue((self.root / "dispatch.json").exists())

    def test_one_history_read_serves_every_selector_in_a_batch(self):
        # The guards used to re-list runs once per entry, spending shared
        # GitHub API budget to receive the same page back.
        result = self.launch(
            "cmuxTests/AlphaTests", "cmuxTests/ExampleTests",
            LAUNCHER_PRIOR_RUNS="[]",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        guard_reads = [
            call for call in self.calls()
            if call[:2] == ["run", "list"] and any("conclusion" in arg for arg in call)
        ]
        self.assertEqual(len(guard_reads), 1, guard_reads)




class RunDiscoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location(
            "focused_dispatch", ROOT / "scripts/ci/dispatch-focused-test.py"
        )
        cls.dispatch = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.dispatch)

    def test_runner_choices_match_the_workflow(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/test-e2e.yml").read_text())
        choices = workflow["on" if "on" in workflow else True]["workflow_dispatch"]["inputs"]["runner"]["options"]
        self.assertEqual(list(self.dispatch.RUNNERS), choices)

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

    def test_cancellation_terminates_inflight_command(self):
        cancelled = threading.Event()
        timer = threading.Timer(0.1, cancelled.set)
        timer.start()
        try:
            with self.assertRaisesRegex(ValueError, "cancelled"):
                self.dispatch.output(
                    self.dispatch.sys.executable,
                    "-c",
                    "import time; time.sleep(30)",
                    timeout=60,
                    cancel_event=cancelled,
                )
        finally:
            timer.cancel()

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
