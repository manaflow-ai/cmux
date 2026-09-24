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
SMALL = "blacksmith-6vcpu-macos-26"
LARGE = "blacksmith-12vcpu-macos-26"


def e2e_run(runner, run_id, *, status="in_progress"):
    """An in-flight test-e2e.yml run as the Actions runs listing returns it."""
    return {
        "id": run_id, "status": status, "name": "E2E test with video recording",
        "path": ".github/workflows/test-e2e.yml", "event": "workflow_dispatch",
        "display_title": f"cmuxTests/Other{run_id} on {runner} @ {'c' * 40} [x{run_id}]",
    }


def queue(*, small=0, large_running=0, large_queued=0, reserved=0):
    """A runs listing, keyed by status, with this much demand per pool."""
    in_progress = [e2e_run(SMALL, 100 + n) for n in range(small)]
    in_progress += [e2e_run(LARGE, 200 + n) for n in range(large_running)]
    in_progress += [{
        "id": 300 + n, "status": "in_progress", "name": "Nightly",
        "path": ".github/workflows/nightly.yml", "event": "schedule",
        "display_title": "Nightly",
    } for n in range(reserved)]
    queued = [e2e_run(LARGE, 400 + n, status="queued") for n in range(large_queued)]
    return {"in_progress": in_progress, "queued": queued}


BACKED_UP = json.dumps(queue(small=4))
FAKE_GH =r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
root = pathlib.Path(os.environ["LAUNCHER_TEST_DIR"])
with (root / "calls.jsonl").open("a") as f:
    f.write(json.dumps(args) + "\n")
if args[0] == "api" and "/actions/runs?" in args[-1]:
    # The runner-pool decision's queue read: one page per run status.
    if os.environ.get("LAUNCHER_QUEUE_FAIL"):
        sys.exit(1)
    status = args[-1].split("status=", 1)[1].split("&", 1)[0]
    queue = json.loads(os.environ.get("LAUNCHER_QUEUE", "{}"))
    print(json.dumps({"workflow_runs": queue.get(status, [])}))
elif args[0] == "api":
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
                # `auto` is decided here and named, so the title is exact.
                expected = SMALL if runner == "auto" else runner
                self.assertEqual(self.dispatch()["runner"], expected)

    def queue_reads(self):
        return [call for call in self.calls()
                if call[:1] == ["api"] and "/actions/runs?" in call[-1]]

    def test_an_idle_queue_keeps_the_6vcpu_pool_whatever_the_commit(self):
        # The large pool is reserved first for release and nightly builds, so
        # no commit goes there by default: REMOTE_HEAD ends in b, which the
        # earlier parity split sent to the 12vcpu pool.
        for ref in ("topic/fix", "main"):
            with self.subTest(ref=ref):
                self.setUp()
                result = self.launch("cmuxTests/ExampleTests", "--ref", ref)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.dispatch()["runner"], SMALL)

    def test_a_backed_up_6vcpu_pool_overflows_to_an_idle_12vcpu_pool(self):
        result = self.launch("cmuxTests/ExampleTests", LAUNCHER_QUEUE=BACKED_UP)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dispatch()["runner"], LARGE)
        self.assertLessEqual(len(self.queue_reads()), 2)

    def test_a_busy_12vcpu_pool_keeps_e2e_on_6vcpu(self):
        for busy in (
            queue(small=9, large_queued=1),
            queue(small=9, large_running=2),
            queue(small=9, reserved=1),
        ):
            with self.subTest(queue=busy):
                self.setUp()
                result = self.launch("cmuxTests/ExampleTests", LAUNCHER_QUEUE=json.dumps(busy))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.dispatch()["runner"], SMALL)
                self.assertLessEqual(len(self.queue_reads()), 2)

    def test_an_unreadable_queue_keeps_e2e_on_6vcpu(self):
        result = self.launch(
            "cmuxTests/ExampleTests", LAUNCHER_QUEUE=BACKED_UP, LAUNCHER_QUEUE_FAIL="1",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dispatch()["runner"], SMALL)
        self.assertIn("staying on", result.stderr)

    def test_the_overflow_thresholds_are_repository_variables(self):
        result = self.launch(
            "cmuxTests/ExampleTests",
            LAUNCHER_QUEUE=json.dumps(queue(small=2)),
            LAUNCHER_VARIABLES=json.dumps([
                {"name": "CI_E2E_OVERFLOW_MIN_QUEUED", "value": "2"},
            ]),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dispatch()["runner"], LARGE)
        self.setUp()
        result = self.launch(
            "cmuxTests/ExampleTests", LAUNCHER_QUEUE=BACKED_UP,
            LAUNCHER_VARIABLES=json.dumps([
                {"name": "CI_E2E_OVERFLOW_MAX_LARGE_RUNNING", "value": "0"},
            ]),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dispatch()["runner"], SMALL)

    def test_an_explicit_runner_is_never_rerouted(self):
        result = self.launch(
            "cmuxTests/ExampleTests", "--ref", "topic/fix",
            "--runner", SMALL, LAUNCHER_QUEUE=BACKED_UP,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dispatch()["runner"], SMALL)
        self.assertEqual(self.queue_reads(), [])

    def test_an_admin_runner_variable_is_never_overflowed(self):
        result = self.launch(
            "cmuxTests/ExampleTests", "--ref", "topic/fix", LAUNCHER_QUEUE=BACKED_UP,
            LAUNCHER_VARIABLES=json.dumps([
                {"name": "MACOS_RUNNER_TESTS", "value": "blacksmith-6vcpu-macos-15"},
            ]),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("runner", self.dispatch())
        self.assertEqual(self.queue_reads(), [])

    def test_an_unpinned_dispatch_reuses_an_in_flight_run_on_either_macos_26_pool(self):
        # Where auto lands depends on the queue at dispatch time, so the same
        # commit and filter may already be running on the other pool. Reusing
        # it costs no compile and no queue read.
        for runner in (SMALL, LARGE):
            for queue_state in ("{}", BACKED_UP):
                with self.subTest(runner=runner, queue=queue_state):
                    self.setUp()
                    result = self.launch(
                        "cmuxTests/ExampleTests",
                        LAUNCHER_PRIOR_RUNS=self._live(runner=runner),
                        LAUNCHER_QUEUE=queue_state,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("reusing that run", result.stdout)
                    self.assertIn(f"on {runner}", result.stdout)
                    self.assertFalse((self.root / "dispatch.json").exists())
                    self.assertEqual(self.queue_reads(), [])

    def test_an_overlapping_run_on_the_other_macos_26_pool_is_refused(self):
        live = self._live(selector="cmuxTests/ExampleTests,cmuxTests/OtherTests", runner=LARGE)
        result = self.launch("cmuxTests/ExampleTests", LAUNCHER_PRIOR_RUNS=live)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"already in_progress at {HEAD} on {LARGE}", result.stderr)
        self.assertFalse((self.root / "dispatch.json").exists(), "must not dispatch")

    def test_a_failure_on_the_12vcpu_pool_refuses_an_unpinned_repeat(self):
        result = self.launch(
            "cmuxTests/ExampleTests", LAUNCHER_PRIOR_RUNS=self._prior("failure", runner=LARGE),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already failed", result.stderr)
        self.assertFalse((self.root / "dispatch.json").exists(), "must not dispatch")

    def test_a_pinned_pool_ignores_a_run_on_the_other_macos_26_pool(self):
        result = self.launch(
            "cmuxTests/ExampleTests", "--runner", SMALL,
            LAUNCHER_PRIOR_RUNS=self._live(runner=LARGE),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dispatch()["runner"], SMALL)

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

    def test_a_batch_too_long_for_the_concurrency_group_is_refused_before_dispatch(self):
        # test-e2e.yml keys its concurrency group on runner, ref and the whole
        # filter. GitHub rejects a group over 400 characters as a workflow file
        # issue: the run starts with no jobs and nothing says why.
        workflow = (ROOT / ".github/workflows/test-e2e.yml").read_text()
        self.assertIn(
            "group: e2e-${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || "
            "((!inputs.runner || inputs.runner == 'auto') && (vars.MACOS_RUNNER_TESTS || '"
            "blacksmith-6vcpu-macos-26') || inputs.runner) }}-${{ inputs.ref || github.ref_name }}-${{ inputs.test_filter }}",
            workflow,
            "the dispatcher's length check copies this group; update both together",
        )
        suite = "cmuxTests/AppDelegateEqualizeSplitsShortcutTests/"
        selectors = [suite + f"testConfigurationReloadCase{n}RemainsActiveUntilAsyncReconciliationCompletes()" for n in range(3)]
        # Three selectors: the filter alone is 377 characters, under 400, but
        # the whole group is 448. A check on the filter alone would let it through.
        result = self.launch(*selectors)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("split", result.stderr)
        self.assertFalse((self.root / "dispatch.json").exists())

        result = self.launch(*selectors[:2])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dispatch()["test_filter"], ",".join(selectors[:2]))

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

    def test_a_workflow_job_passes_the_variable_it_cannot_list(self):
        # A job token cannot list variables. Passed in, the variable still
        # decides the runner, and the in-flight guard still attaches.
        result = self.launch(
            "cmuxTests/ExampleTests",
            LAUNCHER_PRIOR_RUNS=self._live(runner="warp-macos-15-arm64-6x"),
            LAUNCHER_VARIABLES="not json",
            CMUX_MACOS_RUNNER_TESTS="warp-macos-15-arm64-6x",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "dispatch.json").exists(), "must not dispatch")
        self.assertNotIn(["variable", "list"], [call[:2] for call in self.calls()])
        # An unset variable arrives empty, and the workflow literal decides.
        self.setUp()
        result = self.launch(
            "cmuxTests/ExampleTests",
            LAUNCHER_PRIOR_RUNS=self._live(), LAUNCHER_VARIABLES="not json",
            CMUX_MACOS_RUNNER_TESTS="",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "dispatch.json").exists(), "must not dispatch")

    def test_the_focused_suite_job_passes_the_runner_variable(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/test-macos-suite.yml").read_text())
        steps = workflow["jobs"]["focused"]["steps"]
        wrapper = next(step for step in steps if "run-e2e.sh" in step.get("run", ""))
        self.assertEqual(
            wrapper["env"].get("CMUX_MACOS_RUNNER_TESTS"), "${{ vars.MACOS_RUNNER_TESTS }}"
        )
        # The overflow switch and thresholds too: without them the wrapper
        # would overflow on defaults after an admin turned overflow off.
        for name in ("CI_E2E_LARGE_POOL_OVERFLOW", "CI_E2E_OVERFLOW_MIN_QUEUED",
                     "CI_E2E_OVERFLOW_MAX_LARGE_RUNNING"):
            self.assertEqual(wrapper["env"].get("CMUX_" + name), "${{ vars.%s }}" % name)
        self.assertNotIn("SPLIT", json.dumps(wrapper["env"]))

    def test_the_overflow_switch_keeps_e2e_on_6vcpu_without_reading_the_queue(self):
        result = self.launch(
            "cmuxTests/ExampleTests", LAUNCHER_QUEUE=BACKED_UP,
            LAUNCHER_VARIABLES=json.dumps([
                {"name": "CI_E2E_LARGE_POOL_OVERFLOW", "value": "0"},
            ]),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dispatch()["runner"], SMALL)
        self.assertEqual(self.queue_reads(), [])

    def test_a_workflow_job_passes_the_overflow_variables_it_cannot_list(self):
        result = self.launch(
            "cmuxTests/ExampleTests", LAUNCHER_QUEUE=BACKED_UP,
            LAUNCHER_VARIABLES="not json",
            CMUX_MACOS_RUNNER_TESTS="", CMUX_CI_E2E_LARGE_POOL_OVERFLOW="0",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dispatch()["runner"], SMALL)
        self.assertNotIn(["variable", "list"], [call[:2] for call in self.calls()])
        self.setUp()
        result = self.launch(
            "cmuxTests/ExampleTests", LAUNCHER_QUEUE=json.dumps(queue(small=1)),
            LAUNCHER_VARIABLES="not json",
            CMUX_MACOS_RUNNER_TESTS="", CMUX_CI_E2E_OVERFLOW_MIN_QUEUED="1",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dispatch()["runner"], LARGE)

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


class FakeActions:
    """Serves one runs page per status and counts every request."""

    def __init__(self, pages=None, *, fail=False):
        self.pages = pages or {}
        self.fail = fail
        self.paths = []

    def request(self, method, path, body=None):
        self.paths.append((method, path))
        if self.fail:
            raise RuntimeError("GET /repos/x/actions/runs failed (503)")
        status = path.split("status=", 1)[1].split("&", 1)[0]
        return {"workflow_runs": self.pages.get(status, [])}


class WorkflowRunnerPoolTests(unittest.TestCase):
    """E2E overflows to the 12vcpu pool only when 6vcpu is backed up.

    The 12vcpu macOS 26 pool is reserved first for release and nightly
    builds. The earlier parity split sent half of all commits there however
    busy it was; `auto` now stays on 6vcpu unless the 6vcpu pool is backed up
    and the 12vcpu pool has spare room, and fails safe to 6vcpu.
    """

    COMMITS = ["0123456789abcdef0123456789abcdef0123456" + digit for digit in "0123456789abcdef"]

    @classmethod
    def setUpClass(cls):
        cls.workflow = yaml.safe_load((ROOT / ".github/workflows/test-e2e.yml").read_text())
        cls.jobs = cls.workflow["jobs"]
        spec = importlib.util.spec_from_file_location(
            "e2e_runner_pool", ROOT / "scripts/ci/e2e_runner_pool.py"
        )
        cls.pool = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.pool)
        spec = importlib.util.spec_from_file_location(
            "focused_dispatch_pool", ROOT / "scripts/ci/dispatch-focused-test.py"
        )
        cls.dispatch = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.dispatch)

    def load(self, small=0, large_queued=0, large_running=0):
        return self.pool.PoolLoad(small, large_queued, large_running)

    def decide(self, load, *, variable="", overflow="", min_queued="", max_large_running="",
               requested="auto"):
        calls = []

        def measure(limits):
            calls.append(limits)
            if isinstance(load, Exception):
                raise load
            return load

        label = self.pool.resolve(
            requested, variable, overflow=overflow, min_queued=min_queued,
            max_large_running=max_large_running, measure=measure,
        )
        return label, calls

    def test_the_rule(self):
        defaults = self.pool.Thresholds()
        self.assertEqual((defaults.min_queued, defaults.max_large_running), (4, 2))
        cases = [
            (self.load(4, 0, 0), LARGE),
            (self.load(4, 0, 1), LARGE),
            (self.load(9, 0, 1), LARGE),
            (self.load(3, 0, 0), SMALL),   # 6vcpu not backed up
            (self.load(9, 1, 0), SMALL),   # something already waits on 12vcpu
            (self.load(9, 0, 2), SMALL),   # 12vcpu already has its share of E2E
            (None, SMALL),                 # unknown load
        ]
        for load, expected in cases:
            with self.subTest(load=load):
                self.assertEqual(self.decide(load)[0], expected)

    def test_the_thresholds_are_variables_and_invalid_values_fail_safe(self):
        self.assertEqual(self.decide(self.load(2), min_queued="2")[0], LARGE)
        self.assertEqual(self.decide(self.load(9, 0, 3), max_large_running="4")[0], LARGE)
        self.assertEqual(self.decide(self.load(9), max_large_running="0")[0], SMALL)
        for min_queued, max_running in (("x", ""), ("0", ""), ("-1", ""), ("", "-1"), ("", "two")):
            with self.subTest(min_queued=min_queued, max_running=max_running):
                label, calls = self.decide(self.load(99), min_queued=min_queued,
                                           max_large_running=max_running)
                self.assertEqual(label, SMALL)
                self.assertEqual(calls, [], "an invalid threshold must not read the queue")

    def test_the_kill_switch_never_reads_the_queue(self):
        label, calls = self.decide(self.load(99), overflow="0")
        self.assertEqual((label, calls), (SMALL, []))
        for value in ("", "1", "yes"):
            with self.subTest(value=value):
                self.assertEqual(self.decide(self.load(99), overflow=value)[0], LARGE)

    def test_any_measurement_error_fails_safe(self):
        for error in (RuntimeError("503"), ValueError("bad json"), KeyError("workflow_runs")):
            with self.subTest(error=error):
                self.assertEqual(self.decide(error)[0], SMALL)

    def test_an_explicit_choice_or_admin_variable_is_never_rerouted(self):
        for requested in (SMALL, LARGE, "tart-canary"):
            with self.subTest(requested=requested):
                self.assertEqual(self.decide(self.load(99), requested=requested), (requested, []))
        self.assertEqual(self.decide(self.load(99), variable="blacksmith-6vcpu-macos-15"),
                         ("blacksmith-6vcpu-macos-15", []))

    def test_the_commit_no_longer_decides(self):
        # Every commit gets the same answer for the same queue; the parity
        # split sent odd commits to 12vcpu even when it was busy.
        for commit in self.COMMITS:
            with self.subTest(commit=commit):
                self.assertEqual(self.decide(self.load(0))[0], SMALL)
                self.assertEqual(self.decide(self.load(9, 1))[0], SMALL)

    def measure(self, pages, *, workflows_dir=None, exclude_run_id=None):
        client = FakeActions(pages)
        load = self.pool.measure_load(
            client, "manaflow-ai/cmux", self.pool.Thresholds(),
            workflows_dir=workflows_dir or ROOT / ".github/workflows",
            exclude_run_id=exclude_run_id,
        )
        return load, client

    def test_measurement_costs_at_most_two_api_calls(self):
        for pages in (
            {},
            queue(small=4),
            queue(small=60, large_queued=3),
            {"in_progress": [e2e_run(SMALL, n) for n in range(99)]},
        ):
            with self.subTest(pages=len(pages.get("in_progress", []))):
                _, client = self.measure(pages)
                self.assertLessEqual(len(client.paths), self.pool.MAX_API_CALLS)
                self.assertLessEqual(self.pool.MAX_API_CALLS, 2)
                for method, path in client.paths:
                    self.assertEqual(method, "GET")
                    self.assertRegex(
                        path, r"^/repos/manaflow-ai/cmux/actions/runs\?status=(in_progress|queued)&per_page=100$")

    def test_a_busy_12vcpu_pool_stops_after_one_call(self):
        for pages in (queue(small=9, large_running=2), queue(small=9, reserved=1)):
            with self.subTest(pages=pages):
                load, client = self.measure(pages)
                self.assertEqual(len(client.paths), 1)
                self.assertFalse(self.pool.overflows(load, self.pool.Thresholds()))

    def test_measurement_attributes_runs_to_pools(self):
        pages = queue(small=5, large_running=1, large_queued=1)
        pages["in_progress"].append({"id": 9, "status": "in_progress", "name": "CI",
                                     "path": ".github/workflows/ci.yml", "display_title": "fix"})
        load, _ = self.measure(pages)
        self.assertEqual(load, self.load(5, 1, 1))
        # The run deciding is not its own demand.
        load, _ = self.measure(queue(small=4), exclude_run_id=100)
        self.assertEqual(load.small_queued, 3)

    def test_a_full_page_is_unknown(self):
        load, client = self.measure({"in_progress": [e2e_run(SMALL, n) for n in range(100)]})
        self.assertIsNone(load)
        self.assertEqual(len(client.paths), 1)

    def test_reserved_workflows_that_never_use_macos_do_not_block(self):
        with tempfile.TemporaryDirectory() as temp:
            workflows = Path(temp)
            (workflows / "nightly.yml").write_text("jobs:\n  b:\n    runs-on: blacksmith-12vcpu-macos-26\n")
            (workflows / "release-notes.yml").write_text("jobs:\n  b:\n    runs-on: ubuntu-latest\n")
            notes = {"id": 7, "status": "in_progress", "name": "Release notes",
                     "path": ".github/workflows/release-notes.yml", "display_title": "notes"}
            load, _ = self.measure({"in_progress": [notes] + queue(small=4)["in_progress"]},
                                   workflows_dir=workflows)
            self.assertEqual(load, self.load(4))
            load, _ = self.measure(queue(small=4, reserved=1), workflows_dir=workflows)
            self.assertEqual(load.large_queued, 1)

    def test_an_api_error_fails_safe_end_to_end(self):
        client = FakeActions(fail=True)
        label = self.pool.resolve(
            "auto", "", overflow="", min_queued="", max_large_running="",
            measure=lambda limits: self.pool.measure_load(client, "manaflow-ai/cmux", limits),
        )
        self.assertEqual(label, SMALL)
        self.assertEqual(len(client.paths), 1)

    def test_the_dispatcher_reads_the_queue_through_the_janitor_client(self):
        # One rule, one client shape: run-e2e.sh subclasses the queue
        # janitor's GitHub client and only swaps its transport for `gh api`.
        self.assertTrue(issubclass(self.dispatch.GhApi, self.pool.queue_janitor.GitHub))
        # A workflow job passes the variables, so only queue reads remain.
        variables = {"CMUX_MACOS_RUNNER_TESTS": "", "CMUX_CI_E2E_LARGE_POOL_OVERFLOW": ""}
        with mock.patch.dict(os.environ, variables), mock.patch.object(
                self.dispatch, "output", return_value=json.dumps(
                    {"workflow_runs": queue(small=4)["in_progress"]})) as output:
            label = self.dispatch.routed_runner(SMALL)
        self.assertEqual(label, LARGE)
        self.assertLessEqual(output.call_count, 2)
        for call in output.call_args_list:
            self.assertEqual(call.args[:4], ("gh", "api", "--method", "GET"))
        with mock.patch.dict(os.environ, variables), mock.patch.object(
                self.dispatch, "output", side_effect=subprocess.CalledProcessError(1, "gh")):
            self.assertEqual(self.dispatch.routed_runner(SMALL), SMALL)

    # Workflow wiring ------------------------------------------------------

    def pool_step(self):
        steps = self.jobs["runner"]["steps"]
        return next(step for step in steps if "e2e_runner_pool.py" in step.get("run", ""))

    def run_pool_step(self, *, requested="auto", variable="", overflow="", min_queued="",
                      max_large_running=""):
        """Run the workflow's own step script with the values GitHub would pass.

        No token reaches it, so a decision that reads the queue fails safe.
        """
        step = self.pool_step()
        env = {k: v for k, v in os.environ.items() if k not in ("GH_TOKEN", "GITHUB_TOKEN")}
        values = {
            "${{ github.token }}": "",
            "${{ github.repository }}": "manaflow-ai/cmux",
            "${{ inputs.runner }}": requested,
            "${{ vars.MACOS_RUNNER_TESTS }}": variable,
            "${{ vars.CI_E2E_LARGE_POOL_OVERFLOW }}": overflow,
            "${{ vars.CI_E2E_OVERFLOW_MIN_QUEUED }}": min_queued,
            "${{ vars.CI_E2E_OVERFLOW_MAX_LARGE_RUNNING }}": max_large_running,
        }
        for name, expression in step["env"].items():
            self.assertIn(expression, values, f"unexpected input {name}: {expression}")
            env[name] = values[expression]
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "output"
            output.write_text("")
            env["GITHUB_OUTPUT"] = str(output)
            result = subprocess.run(["bash", "-e", "-c", step["run"]], cwd=ROOT, env=env, check=True,
                                    capture_output=True, text=True)
            lines = dict(line.split("=", 1) for line in output.read_text().splitlines() if "=" in line)
        return lines["label"], result.stderr

    def test_the_workflow_step_resolves_through_the_rule(self):
        self.assertEqual(self.run_pool_step()[0], SMALL)
        label, stderr = self.run_pool_step()
        self.assertIn("could not read the runner queue", stderr)
        self.assertEqual(self.run_pool_step(overflow="0")[0], SMALL)
        self.assertEqual(self.run_pool_step(requested="tart-small")[0], "tart-small")
        self.assertEqual(self.run_pool_step(requested=LARGE)[0], LARGE)
        self.assertEqual(self.run_pool_step(variable="blacksmith-6vcpu-macos-15")[0],
                         "blacksmith-6vcpu-macos-15")

    def test_the_pool_job_reads_actions_and_nothing_else(self):
        self.assertEqual(self.workflow["permissions"], {"contents": "read"})
        job = self.jobs["runner"]
        self.assertEqual(job["permissions"], {"contents": "read", "actions": "read"})
        self.assertIn("ubuntu", job["runs-on"])
        self.assertEqual(
            job["outputs"]["label"],
            "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || steps.pool.outputs.label }}",
        )
        step = self.pool_step()
        self.assertEqual(step["id"], "pool")
        self.assertEqual(step["env"]["GH_TOKEN"], "${{ github.token }}")
        self.assertNotIn("SPLIT", yaml.safe_dump(job))
        checkout = next(step for step in job["steps"] if "actions/checkout" in step.get("uses", ""))
        paths = checkout["with"]["sparse-checkout"].split()
        for path in ("scripts/ci/e2e_runner_pool.py", "scripts/ci/queue_janitor.py", ".github/workflows/"):
            self.assertIn(path, paths)
        self.assertIs(checkout["with"]["persist-credentials"], False)
        # No other job gained write access for this.
        for name, other in self.jobs.items():
            for scope, level in (other.get("permissions") or {}).items():
                with self.subTest(job=name, scope=scope):
                    self.assertEqual(level, "read")

    def test_the_pool_helper_explains_the_release_priority(self):
        source = (ROOT / "scripts/ci/e2e_runner_pool.py").read_text()
        for phrase in ("reserved", "release and nightly", "at most two requests"):
            self.assertIn(phrase, source)
        comment = (ROOT / ".github/workflows/test-e2e.yml").read_text()
        self.assertIn("reserved first for release and nightly", comment)

    def test_macos_jobs_run_on_the_resolved_pool(self):
        label = "${{ needs.runner.outputs.label }}"
        for name in ("build", "test"):
            with self.subTest(job=name):
                job = self.jobs[name]
                self.assertIn("runner", job["needs"])
                self.assertEqual(job["runs-on"], label)
                tart = next(step for step in job["steps"]
                            if step.get("name") == "Validate Tart canary identity")
                self.assertEqual(tart["if"], "${{ startsWith(needs.runner.outputs.label, 'tart-') }}")
                self.assertEqual(tart["env"]["REQUESTED_RUNNER"], label)
                # Nothing in a macOS job may resolve the pool a second way.
                text = yaml.safe_dump(job)
                self.assertNotIn("inputs.runner", text)
                self.assertNotIn("vars.MACOS_RUNNER_TESTS", text)
        self.assertEqual(self.jobs["build"]["env"]["CMUX_PRODUCT_RUNNER"], label)


class SuiteWorkflowForwardsFocusedRuns(unittest.TestCase):
    def test_focused_selectors_never_compile_in_the_suite_workflow(self):
        jobs = yaml.safe_load((ROOT / ".github/workflows/test-macos-suite.yml").read_text())["jobs"]
        focused, tests = jobs["focused"]["if"], jobs["tests"]["if"]
        condition = focused.removeprefix("${{ ").removesuffix(" }}")
        self.assertEqual(tests, "${{ !(" + condition + ") }}")
        for clause in ("github.repository == 'manaflow-ai/cmux'", "inputs.unit_test_suites != ''",
                       "inputs.skip_ui_tests", "!inputs.skip_unit_tests"):
            self.assertIn(clause, condition)
        run = jobs["focused"]["steps"][-1]["run"]
        self.assertIn("./scripts/run-e2e.sh", run)
        # It hands off and exits; waiting would hold a runner for the whole test.
        self.assertNotIn("--wait", run)
        self.assertTrue(run.rstrip().endswith("exit 1"))
        self.assertIn('"cmuxTests/$suite"', run)
        self.assertEqual(jobs["focused"]["permissions"], {"actions": "write", "contents": "read"})


if __name__ == "__main__":
    unittest.main()
