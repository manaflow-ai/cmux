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


OLD = "blacksmith-6vcpu-macos-15"


def e2e_run(runner, run_id, *, status="in_progress"):
    """A test-e2e.yml run as the Actions runs listing returns it."""
    return {
        "id": run_id, "status": status, "name": "E2E test with video recording",
        "path": ".github/workflows/test-e2e.yml", "event": "workflow_dispatch",
        "display_title": f"cmuxTests/Other{run_id} on {runner} @ {'c' * 40} [x{run_id}]",
    }


def pr_run(run_id, *, status="in_progress"):
    """A pull request ci.yml run as the Actions runs listing returns it."""
    return {"id": run_id, "status": status, "name": "CI", "event": "pull_request",
            "path": ".github/workflows/ci.yml", "display_title": "fix something"}


def queue(*, small=0, large=0, old=0, small_running=10, large_running=0, old_running=10,
          large_reserved=0, small_reserved=0, e2e_since=(), pr_since=0, age=5):
    """What the pool reads cost: the janitor's per-pool snapshot and the runs since it.

    The 6vcpu macOS 26 and macOS 15 pools run full by default, like on
    2026-09-24; the 12vcpu pool is idle unless told otherwise.
    """
    return {
        "age": age,
        "pools": {
            SMALL: {"queued": small, "running": small_running, "reserved_queued": small_reserved},
            LARGE: {"queued": large, "running": large_running, "reserved_queued": large_reserved},
            OLD: {"queued": old, "running": old_running},
        },
        "e2e_runs": [e2e_run(runner, 500 + n) for n, runner in enumerate(e2e_since)],
        "pr_runs": [pr_run(600 + n) for n in range(pr_since)],
    }


IDLE = json.dumps(queue())
BUSY_LARGE = json.dumps(queue(large=3))
FAKE_GH =r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
root = pathlib.Path(os.environ["LAUNCHER_TEST_DIR"])
with (root / "calls.jsonl").open("a") as f:
    f.write(json.dumps(args) + "\n")
if args[0] == "api" and "/actions/" in args[-1]:
    # The runner-pool decision's queue reads: the janitor snapshot and the
    # runs since it. No LAUNCHER_QUEUE means the janitor published nothing.
    if os.environ.get("LAUNCHER_QUEUE_FAIL"):
        sys.exit(1)
    import datetime, io, zipfile
    queue = json.loads(os.environ.get("LAUNCHER_QUEUE", "null"))
    now = datetime.datetime.now(datetime.timezone.utc)
    stamp = lambda minutes: (now - datetime.timedelta(minutes=minutes)).strftime("%Y-%m-%dT%H:%M:%SZ")
    endpoint = args[-1]
    if "/actions/artifacts?" in endpoint:
        artifacts = [] if queue is None else [{
            "id": 77, "expired": False, "created_at": stamp(queue["age"] - 1),
            "archive_download_url": "https://api.github.com/unused",
            "workflow_run": {"head_branch": "main", "repository_id": 1, "head_repository_id": 1},
        }]
        print(json.dumps({"artifacts": artifacts}))
    elif "/actions/artifacts/77/zip" in endpoint:
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, "w") as bundle:
            bundle.writestr("macos-pool-load.json", json.dumps(
                {"version": 1, "generated_at": stamp(queue["age"]), "pools": queue["pools"]}))
        sys.stdout.buffer.write(archive.getvalue())
    elif "/workflows/test-e2e.yml/runs?" in endpoint:
        print(json.dumps({"workflow_runs": queue["e2e_runs"]}))
    elif "/workflows/ci.yml/runs?" in endpoint:
        print(json.dumps({"workflow_runs": queue["pr_runs"]}))
    else:
        sys.exit(2)
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


def real_swift_testing_method():
    """One argument-free @Test method this checkout declares, found fresh."""
    spec = importlib.util.spec_from_file_location(
        "focused_test_selectors", ROOT / "scripts/ci/focused_test_selectors.py"
    )
    selectors = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(selectors)
    suite_re = re.compile(r"^(?:@\w+\s+)*(?:final\s+)?struct\s+(\w+Tests)\b", re.M)
    test_re = re.compile(r"^\s*@Test\s+func\s+(\w+)\(\)", re.M)
    for path in sorted((ROOT / "cmuxTests").glob("*.swift")):
        source = path.read_text(encoding="utf-8", errors="replace")
        suites, tests = suite_re.findall(source), test_re.findall(source)
        if len(suites) == 1 and tests:
            if f"{suites[0]}/{tests[0]}()" in selectors.source_inventory(ROOT, suites[0]):
                return suites[0], tests[0]
    raise AssertionError("no argument-free @Test method found under cmuxTests")


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
                if call[:1] == ["api"] and "/actions/" in call[-1]]

    def routed(self, state, *args, **env):
        result = self.launch("cmuxTests/ExampleTests", *args, LAUNCHER_QUEUE=json.dumps(state), **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLessEqual(len(self.queue_reads()), 4)
        return self.dispatch()["runner"], result.stderr

    def test_an_idle_12vcpu_pool_takes_e2e_whatever_the_commit(self):
        # Every Blacksmith pool is sponsored, so 12vcpu comes first, as for
        # pull requests, and the commit plays no part.
        for ref in ("topic/fix", "main"):
            with self.subTest(ref=ref):
                self.setUp()
                self.assertEqual(self.routed(queue(), "--ref", ref)[0], LARGE)

    def test_e2e_follows_the_pull_request_headroom_rule(self):
        cases = [
            (queue(large=2), LARGE),                       # under CI_PR_POOL_MAX_QUEUED (3)
            (queue(large=3), SMALL),                       # 12vcpu backed up, 6vcpu has headroom
            (queue(large=0, large_running=10), LARGE),     # full but nothing waits yet
            (queue(large=5, small=4), SMALL),              # neither has headroom: fewest queued
            (queue(large=4, small=9), LARGE),
        ]
        for state, expected in cases:
            with self.subTest(pools=state["pools"]):
                self.setUp()
                self.assertEqual(self.routed(state)[0], expected)

    def test_only_a_queued_release_or_nightly_job_holds_12vcpu_back(self):
        self.assertEqual(self.routed(queue(large=1, large_reserved=1))[0], SMALL)
        # A release or nightly job merely running there is not waiting on E2E.
        self.setUp()
        self.assertEqual(self.routed(queue(large_running=6))[0], LARGE)
        # Both macOS 26 pools reserved: stay on the default rather than guess.
        self.setUp()
        runner, stderr = self.routed(queue(large=1, large_reserved=1, small=1, small_reserved=1))
        self.assertEqual(runner, SMALL)
        self.assertIn("staying on", stderr)

    def test_e2e_never_takes_the_macos_15_pool(self):
        # Both macOS 26 pools backed up and macOS 15 idle: a pull request
        # would spill there; E2E takes the macOS 26 pool with fewer queued.
        state = queue(large=30, small=20, old=0, old_running=0)
        self.assertEqual(self.routed(state)[0], SMALL)

    def test_runs_since_the_snapshot_fill_the_12vcpu_pool_first(self):
        # 8 running leaves 2 idle slots; 3 more queued reach the threshold.
        base = dict(large_running=8)
        self.assertEqual(self.routed(queue(**base, e2e_since=[LARGE] * 4))[0], LARGE)
        self.setUp()
        self.assertEqual(self.routed(queue(**base, e2e_since=[LARGE] * 5))[0], SMALL)
        # E2E runs on another pool do not count against 12vcpu.
        self.setUp()
        self.assertEqual(self.routed(queue(**base, e2e_since=[SMALL] * 9))[0], LARGE)
        # Pull request runs replay through their own rule, 12vcpu first.
        self.setUp()
        self.assertEqual(self.routed(queue(**base, pr_since=5))[0], SMALL)
        self.setUp()
        self.assertEqual(self.routed(queue(**base, pr_since=4))[0], LARGE)

    def test_an_unreadable_or_stale_queue_keeps_e2e_on_6vcpu(self):
        result = self.launch("cmuxTests/ExampleTests", LAUNCHER_QUEUE=IDLE, LAUNCHER_QUEUE_FAIL="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dispatch()["runner"], SMALL)
        self.assertIn("staying on", result.stderr)
        for state in (queue(age=60), None):
            with self.subTest(state=state):
                self.setUp()
                result = self.launch("cmuxTests/ExampleTests",
                                     **({"LAUNCHER_QUEUE": json.dumps(state)} if state else {}))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.dispatch()["runner"], SMALL)
                self.assertIn("no readable pool snapshot", result.stderr)

    def test_the_pull_request_order_and_threshold_are_repository_variables(self):
        variables = lambda **values: json.dumps([{"name": k, "value": v} for k, v in values.items()])
        self.assertEqual(self.routed(queue(), LAUNCHER_VARIABLES=variables(
            CI_PR_POOL_ORDER=f"{SMALL},{LARGE}"))[0], SMALL)
        self.setUp()
        self.assertEqual(self.routed(queue(large=4), LAUNCHER_VARIABLES=variables(
            CI_PR_POOL_MAX_QUEUED="5"))[0], LARGE)
        # An order without a macOS 26 pool, or an invalid one, never reads the queue.
        for order in (OLD, "not-a-pool"):
            with self.subTest(order=order):
                self.setUp()
                result = self.launch("cmuxTests/ExampleTests", LAUNCHER_QUEUE=IDLE,
                                     LAUNCHER_VARIABLES=variables(CI_PR_POOL_ORDER=order))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.dispatch()["runner"], SMALL)
                self.assertEqual(self.queue_reads(), [])

    def test_an_explicit_runner_is_never_rerouted(self):
        result = self.launch(
            "cmuxTests/ExampleTests", "--ref", "topic/fix",
            "--runner", SMALL, LAUNCHER_QUEUE=IDLE,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dispatch()["runner"], SMALL)
        self.assertEqual(self.queue_reads(), [])

    def test_an_admin_runner_variable_is_never_overflowed(self):
        result = self.launch(
            "cmuxTests/ExampleTests", "--ref", "topic/fix", LAUNCHER_QUEUE=IDLE,
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
            for queue_state in (BUSY_LARGE, IDLE):
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

    def test_swift_testing_call_suffixes_are_accepted_as_written(self):
        for selector in (
            "cmuxTests/ExampleTests/plain()",
            "cmuxTests/ExampleTests/parameterized(value:)",
            "cmuxTests/ExampleTests/unlabeled(_:_:)",
        ):
            with self.subTest(selector=selector):
                result = self.launch(selector)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.dispatch()["test_filter"], selector)

    def test_malformed_call_suffixes_are_rejected_before_dispatch(self):
        for selector in ("cmuxTests/ExampleTests/plain(value)", "cmuxTests/ExampleTests/plain(value:",
                         "cmuxTests/ExampleTests/plain(:)"):
            with self.subTest(selector=selector):
                result = self.launch(selector)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Suite/method()", result.stderr)
        self.assertFalse((self.root / "dispatch.json").exists())

    def test_a_declared_swift_testing_method_is_dispatched_with_its_suffix(self):
        # `Suite/method` matches no Swift Testing test, and xcodebuild reports
        # that as a successful run of zero tests. Use a real declaration so the
        # launcher is proven against the tree it actually reads.
        suite, method = real_swift_testing_method()
        result = self.launch(f"cmuxTests/{suite}/{method}")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dispatch()["test_filter"], f"cmuxTests/{suite}/{method}()")
        self.assertIn(f"cmuxTests/{suite}/{method}()", result.stderr)

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
    def _prior(self, conclusion, *, selector="cmuxTests/ExampleTests", commit=HEAD, runner="mac",
               workflow_ref="main"):
        return json.dumps([{
            "displayTitle": f"{selector} on {runner} @ {commit} [deadbeef]",
            "headBranch": workflow_ref,
            "conclusion": conclusion,
            "status": "completed",
            "url": "https://github.com/manaflow-ai/cmux/actions/runs/555",
        }])

    def _live(self, *, selector="cmuxTests/ExampleTests", commit=HEAD,
              runner=DEFAULT_RUNNER, status="in_progress", workflow_ref="main"):
        return json.dumps([{
            "databaseId": 777,
            "displayTitle": f"{selector} on {runner} @ {commit} [deadbeef]",
            "headBranch": workflow_ref,
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

    def test_runs_of_another_workflow_definition_are_neither_reused_nor_refusing(self):
        # --workflow-ref tests a workflow change. A run of the same selector at
        # the same commit under another definition answers a different
        # question: attaching to it, or refusing because it failed, means the
        # definition under test never runs.
        for history in (
            self._live(workflow_ref="ci/other-definition"),
            self._live(selector="cmuxTests/ExampleTests,cmuxTests/OtherTests",
                       workflow_ref="ci/other-definition"),
            self._prior("failure", workflow_ref="ci/other-definition"),
        ):
            with self.subTest(history=history):
                (self.root / "dispatch.json").unlink(missing_ok=True)
                result = self.launch("cmuxTests/ExampleTests", "--workflow-ref", "ci/under-test",
                                     LAUNCHER_PRIOR_RUNS=history)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("reusing", result.stdout)
                self.assertEqual(self.dispatch()["test_filter"], "cmuxTests/ExampleTests")
        # The same definition still gets the guards, including the default one.
        result = self.launch("cmuxTests/ExampleTests", "--workflow-ref", "ci/under-test",
                             LAUNCHER_PRIOR_RUNS=self._live(workflow_ref="ci/under-test"))
        self.assertIn("reusing", result.stdout)
        result = self.launch("cmuxTests/ExampleTests",
                             LAUNCHER_PRIOR_RUNS=self._live(workflow_ref="ci/other-definition"))
        self.assertNotIn("reusing", result.stdout)

    def test_history_is_filtered_by_workflow_definition_on_the_server(self):
        # Dispatches from other refs must not push this definition's runs off
        # the one page the guards read.
        for extra, expected in (((), "main"), (("--workflow-ref", "ci/under-test"), "ci/under-test")):
            with self.subTest(workflow_ref=expected):
                (self.root / "calls.jsonl").unlink(missing_ok=True)
                result = self.launch("cmuxTests/ExampleTests", *extra, LAUNCHER_PRIOR_RUNS="[]")
                self.assertEqual(result.returncode, 0, result.stderr)
                guard_reads = [
                    call for call in self.calls()
                    if call[:2] == ["run", "list"] and any("conclusion" in arg for arg in call)
                ]
                self.assertEqual(len(guard_reads), 1, guard_reads)
                branch = guard_reads[0].index("--branch")
                self.assertEqual(guard_reads[0][branch + 1], expected)

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
        # The kill switch, order and threshold too: without them the wrapper
        # would route on defaults after an admin changed them.
        for name in ("CI_E2E_LARGE_POOL_OVERFLOW", "CI_PR_POOL_ORDER", "CI_PR_POOL_MAX_QUEUED"):
            self.assertEqual(wrapper["env"].get("CMUX_" + name), "${{ vars.%s }}" % name)
        self.assertNotIn("SPLIT", json.dumps(wrapper["env"]))

    def test_the_kill_switch_keeps_e2e_on_6vcpu_without_reading_the_queue(self):
        result = self.launch(
            "cmuxTests/ExampleTests", LAUNCHER_QUEUE=IDLE,
            LAUNCHER_VARIABLES=json.dumps([
                {"name": "CI_E2E_LARGE_POOL_OVERFLOW", "value": "0"},
            ]),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dispatch()["runner"], SMALL)
        self.assertEqual(self.queue_reads(), [])

    def test_a_workflow_job_passes_the_overflow_variables_it_cannot_list(self):
        result = self.launch(
            "cmuxTests/ExampleTests", LAUNCHER_QUEUE=IDLE,
            LAUNCHER_VARIABLES="not json",
            CMUX_MACOS_RUNNER_TESTS="", CMUX_CI_E2E_LARGE_POOL_OVERFLOW="0",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dispatch()["runner"], SMALL)
        self.assertNotIn(["variable", "list"], [call[:2] for call in self.calls()])
        self.setUp()
        result = self.launch(
            "cmuxTests/ExampleTests", LAUNCHER_QUEUE=IDLE,
            LAUNCHER_VARIABLES="not json",
            CMUX_MACOS_RUNNER_TESTS="", CMUX_CI_PR_POOL_ORDER=f"{SMALL},{LARGE}",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dispatch()["runner"], SMALL)
        self.assertNotIn(["variable", "list"], [call[:2] for call in self.calls()])

    def test_a_run_without_a_dispatch_id_is_still_seen(self):
        # A run started from the GitHub UI shares the concurrency group and its
        # compile is just as real. Requiring the trailing "[" hid exactly the
        # runs these guards exist to protect.
        live = json.dumps([{
            "databaseId": 777,
            "displayTitle": f"cmuxTests/ExampleTests on {DEFAULT_RUNNER} @ {HEAD}",
            "headBranch": "main",
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
            "headBranch": "main",
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

    def test_normalize_entry_repairs_only_what_the_checkout_declares(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "cmuxTests").mkdir()
            (root / "cmuxTests/ModernTests.swift").write_text(
                "struct ModernTests {\n"
                "    @Test func plain() {}\n"
                "    @Test(arguments: [1]) func parameterized(value: Int) {}\n"
                "    @Test func run(a: Int) {}\n"
                "    @Test func run(b: Int) {}\n"
                "}\n"
            )
            normalize = self.dispatch.normalize_entry
            self.assertEqual(normalize("cmuxTests/ModernTests/plain", root)[0],
                             "cmuxTests/ModernTests/plain()")
            self.assertEqual(normalize("cmuxTests/ModernTests/parameterized", root)[0],
                             "cmuxTests/ModernTests/parameterized(value:)")
            self.assertEqual(normalize("cmuxTests/ModernTests/plain()", root),
                             ("cmuxTests/ModernTests/plain()", None))
            self.assertEqual(normalize("cmuxTests/ModernTests", root),
                             ("cmuxTests/ModernTests", None))
            # A name this checkout does not declare may exist at --ref; the
            # workflow's built inventory decides, so it passes through.
            for entry in ("cmuxTests/ModernTests/elsewhere", "cmuxTests/OtherTests/method",
                          "cmuxUITests/ModernTests/plain", "ModernTests/plain"):
                with self.subTest(entry=entry):
                    self.assertEqual(normalize(entry, root)[0], entry)
            with self.assertRaises(self.dispatch.selectors.AmbiguousSelector):
                normalize("cmuxTests/ModernTests/run", root)

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


NOW = __import__("datetime").datetime(2026, 9, 24, 12, 0, tzinfo=__import__("datetime").timezone.utc)


def snapshot_of(state, now=NOW):
    generated = now - __import__("datetime").timedelta(minutes=state["age"])
    return {"version": 1, "generated_at": generated.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "pools": state["pools"]}


class FakeActions:
    """Serves the janitor snapshot and the runs since it, and counts every request."""

    def __init__(self, state=None, *, fail=False):
        self.state = state
        self.fail = fail
        self.paths = []

    def _call(self, path):
        self.paths.append(path)
        if self.fail:
            raise RuntimeError(f"GET {path} failed (503)")

    def snapshot(self, *, now):
        self._call("artifacts")
        if self.state is None:
            return None
        self._call("artifact zip")
        return snapshot_of(self.state, now)

    def runs_since(self, workflow, since, **filters):
        self._call(f"{workflow} runs")
        return self.state["e2e_runs"]

    def pull_request_runs_since(self, since, *, exclude_run_id):
        self._call("ci.yml runs")
        return self.pool.pr_runner_pool.count_in_flight(self.state["pr_runs"], exclude_run_id=exclude_run_id)


class WorkflowRunnerPoolTests(unittest.TestCase):
    """E2E takes a macOS 26 pool by pull request CI's rule.

    #14132 kept `auto` on 6vcpu unless four other E2E runs waited there and
    12vcpu was idle. Every Blacksmith pool is sponsored, so E2E now prefers
    12vcpu like pull requests do, yields only to a queued release or nightly
    job, and still fails safe to 6vcpu.
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
        # dataclasses resolves a field's module through sys.modules.
        __import__("sys").modules.setdefault("e2e_runner_pool", cls.pool)
        spec.loader.exec_module(cls.pool)
        FakeActions.pool = cls.pool
        spec = importlib.util.spec_from_file_location(
            "focused_dispatch_pool", ROOT / "scripts/ci/dispatch-focused-test.py"
        )
        cls.dispatch = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.dispatch)

    def decide(self, state, *, variable="", overflow="", order="", max_queued="",
               requested="auto", fail=False, exclude_run_id=None):
        client = FakeActions(state, fail=fail)
        calls = []

        def measure():
            calls.append(1)
            return self.pool.measure_load(client, now=NOW, exclude_run_id=exclude_run_id)

        label = self.pool.resolve(
            requested, variable, overflow=overflow, order=order, max_queued=max_queued,
            measure=measure, now=NOW,
        )
        return label, calls, client

    def test_the_rule_matches_pull_requests(self):
        pr = self.pool.pr_runner_pool
        self.assertEqual(self.pool.settings("", ""), pr.Settings())
        self.assertEqual(pr.Settings().order[:2], (LARGE, SMALL))
        self.assertEqual(set(self.pool.E2E_POOLS), {LARGE, SMALL})
        cases = [
            (queue(), LARGE),
            (queue(large=2), LARGE),
            (queue(large=3), SMALL),
            (queue(large=3, small=3), LARGE),           # neither has headroom; a tie takes the earlier pool
            (queue(large=6, small=4), SMALL),
            (queue(large=1, large_reserved=1), SMALL),
            (queue(large_running=10), LARGE),
            (None, SMALL),                               # no snapshot
        ]
        for state, expected in cases:
            with self.subTest(state=state and state["pools"]):
                self.assertEqual(self.decide(state)[0], expected)

    def test_it_is_the_pull_request_decision_limited_to_macos_26(self):
        # Same answer as pr_runner_pool for the same queue, except that a
        # pull request may spill to macOS 15 and E2E may not.
        pr = self.pool.pr_runner_pool
        for state in (queue(), queue(large=3), queue(large=9, small=9, old=0, old_running=0)):
            with self.subTest(pools=state["pools"]):
                ours = self.decide(state)[0]
                theirs = pr.decide(snapshot_of(state), pr.Settings(), now=NOW, xcode_pins={},
                                   auto_xcode=True).runner
                if theirs in self.pool.E2E_POOLS:
                    self.assertEqual(ours, theirs)
                else:
                    self.assertEqual(theirs, OLD)
                    self.assertIn(ours, self.pool.E2E_POOLS)

    def test_settings_are_the_pull_request_variables_and_invalid_values_fail_safe(self):
        self.assertEqual(self.decide(queue(), order=f"{SMALL},{LARGE}")[0], SMALL)
        self.assertEqual(self.decide(queue(large=4), max_queued="5")[0], LARGE)
        self.assertEqual(self.decide(queue(large=1), max_queued="1")[0], SMALL)
        for order, max_queued in (("nope", ""), (f"{LARGE},{LARGE}", ""), ("", "0"), ("", "x"), (OLD, "")):
            with self.subTest(order=order, max_queued=max_queued):
                label, calls, _ = self.decide(queue(), order=order, max_queued=max_queued)
                self.assertEqual(label, SMALL)
                self.assertEqual(calls, [], "an unusable setting must not read the queue")

    def test_the_kill_switch_never_reads_the_queue(self):
        label, calls, _ = self.decide(queue(), overflow="0")
        self.assertEqual((label, calls), (SMALL, []))
        for value in ("", "1", "yes"):
            with self.subTest(value=value):
                self.assertEqual(self.decide(queue(), overflow=value)[0], LARGE)

    def test_any_measurement_error_fails_safe(self):
        label, calls, client = self.decide(queue(), fail=True)
        self.assertEqual((label, len(calls), len(client.paths)), (SMALL, 1, 1))
        for error in (RuntimeError("503"), ValueError("bad json"), KeyError("workflow_runs")):
            with self.subTest(error=error):
                def measure(error=error):
                    raise error
                self.assertEqual(self.pool.resolve("auto", "", overflow="", order="", max_queued="",
                                                   measure=measure, now=NOW), SMALL)

    def test_an_explicit_choice_or_admin_variable_is_never_rerouted(self):
        for requested in (SMALL, LARGE, "tart-canary"):
            with self.subTest(requested=requested):
                label, calls, _ = self.decide(queue(), requested=requested)
                self.assertEqual((label, calls), (requested, []))
        label, calls, _ = self.decide(queue(), variable=OLD)
        self.assertEqual((label, calls), (OLD, []))

    def test_the_commit_does_not_decide(self):
        for commit in self.COMMITS:
            with self.subTest(commit=commit):
                self.assertEqual(self.decide(queue())[0], LARGE)
                self.assertEqual(self.decide(queue(large=3))[0], SMALL)

    def test_measurement_costs_at_most_four_api_calls(self):
        self.assertEqual(self.pool.MAX_API_CALLS, 4)
        for state in (queue(), queue(e2e_since=[LARGE] * 9, pr_since=9), None):
            with self.subTest(state=state and state["pools"]):
                _, _, client = self.decide(state)
                self.assertLessEqual(len(client.paths), self.pool.MAX_API_CALLS)

    def test_runs_since_the_snapshot_are_replayed(self):
        load = self.pool.measure_load(FakeActions(queue(
            e2e_since=[LARGE, LARGE, SMALL, "tart-small"], pr_since=3)), now=NOW)
        self.assertEqual(dict(load.e2e_since), {LARGE: 2, SMALL: 1, "tart-small": 1})
        self.assertEqual(load.pull_requests_since, 3)
        # Finished runs hold no pool, and the deciding run is not its own demand.
        state = queue(e2e_since=[LARGE, LARGE])
        state["e2e_runs"][0]["status"] = "completed"
        load = self.pool.measure_load(FakeActions(state), now=NOW, exclude_run_id=501)
        self.assertEqual(dict(load.e2e_since), {})
        # Replayed pull request runs spill to an idle macOS 15 pool, as they
        # would for real. Replayed over macOS 26 alone they would push 12vcpu
        # to 5 queued against 6vcpu's 4 and send E2E to 6vcpu.
        crowded = queue(large=3, small=4, old=0, old_running=0, pr_since=2)
        self.assertEqual(self.decide(crowded)[0], LARGE)

    def test_pull_request_runs_stay_on_their_lane_when_routing_is_off(self):
        pr = self.pool.pr_runner_pool
        snap = snapshot_of(queue(large_running=8))
        load = self.pool.PoolLoad(snap, {}, 5)
        self.assertEqual(self.pool.decide(load, pr.Settings(), now=NOW).runner, SMALL)
        for settings in ({"lane": SMALL, "overflow": "0"}, {"lane": OLD, "overflow": ""}):
            with self.subTest(settings=settings):
                load = self.pool.PoolLoad({**snap, "settings": settings}, {}, 5)
                self.assertEqual(self.pool.decide(load, pr.Settings(), now=NOW).runner, LARGE)

    def test_a_malformed_snapshot_keeps_the_default_instead_of_failing(self):
        state = queue()
        bad = dict(snapshot_of(state), generated_at="2026-09-24T11:55:00")  # no zone

        class Client(FakeActions):
            def snapshot(self, *, now):
                return bad

        label = self.pool.resolve("auto", "", overflow="", order="", max_queued="",
                                  measure=lambda: self.pool.measure_load(Client(state), now=NOW), now=NOW)
        self.assertEqual(label, SMALL)

    def test_the_dispatcher_reads_the_queue_through_the_pull_request_client(self):
        # One rule, one client shape: run-e2e.sh subclasses pull request CI's
        # pool client and only swaps its transport for `gh api`.
        self.assertTrue(issubclass(self.dispatch.GhApi, self.pool.pr_runner_pool.GitHub))
        state = queue()
        now = __import__("datetime").datetime.now(__import__("datetime").timezone.utc)
        artifact = {"id": 77, "expired": False, "created_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "archive_download_url": "https://api.github.com/unused",
                    "workflow_run": {"head_branch": "main", "repository_id": 1, "head_repository_id": 1}}
        archive = __import__("io").BytesIO()
        with __import__("zipfile").ZipFile(archive, "w") as bundle:
            bundle.writestr("macos-pool-load.json", json.dumps(snapshot_of(state, now)))

        def gh(*command, **kwargs):
            endpoint = command[-1]
            if "/actions/artifacts?" in endpoint:
                return json.dumps({"artifacts": [artifact]})
            return json.dumps({"workflow_runs": []})

        variables = {"CMUX_MACOS_RUNNER_TESTS": "", "CMUX_CI_E2E_LARGE_POOL_OVERFLOW": ""}
        with mock.patch.dict(os.environ, variables), \
                mock.patch.object(self.dispatch, "output", side_effect=gh) as output, \
                mock.patch.object(self.dispatch.subprocess, "check_output",
                                  return_value=archive.getvalue()) as download:
            label = self.dispatch.routed_runner(SMALL)
        self.assertEqual(label, LARGE)
        self.assertEqual(output.call_count + download.call_count, 4)
        for call in output.call_args_list + download.call_args_list:
            command = call.args if call.args and isinstance(call.args[0], str) else call.args[0]
            self.assertEqual(tuple(command[:4]), ("gh", "api", "--method", "GET"))
            self.assertTrue(command[4].startswith("repos/manaflow-ai/cmux/actions/"), command)
        with mock.patch.dict(os.environ, variables), mock.patch.object(
                self.dispatch, "output", side_effect=subprocess.CalledProcessError(1, "gh")):
            self.assertEqual(self.dispatch.routed_runner(SMALL), SMALL)

    # Workflow wiring ------------------------------------------------------

    def pool_step(self):
        steps = self.jobs["runner"]["steps"]
        return next(step for step in steps if "e2e_runner_pool.py" in step.get("run", ""))

    def run_pool_step(self, *, requested="auto", variable="", overflow="", order="",
                      max_queued=""):
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
            "${{ vars.CI_PR_POOL_ORDER }}": order,
            "${{ vars.CI_PR_POOL_MAX_QUEUED }}": max_queued,
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
        self.assertEqual(self.run_pool_step(order=OLD)[0], SMALL)
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
        self.assertEqual(sorted(paths), ["scripts/ci/e2e_runner_pool.py", "scripts/ci/pr_runner_pool.py"])
        self.assertIs(checkout["with"]["persist-credentials"], False)
        # No other job gained write access for this.
        for name, other in self.jobs.items():
            for scope, level in (other.get("permissions") or {}).items():
                with self.subTest(job=name, scope=scope):
                    self.assertEqual(level, "read")

    def test_the_pool_helper_explains_the_release_priority(self):
        source = (ROOT / "scripts/ci/e2e_runner_pool.py").read_text()
        for phrase in ("sponsored", "release or nightly job actually queued", "at most four requests",
                       "never goes to macOS 15"):
            self.assertIn(phrase, source)
        comment = (ROOT / ".github/workflows/test-e2e.yml").read_text()
        self.assertIn("only a queued release or nightly job holds 12vcpu", comment)
        self.assertNotIn("reserved first for release", comment)

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
