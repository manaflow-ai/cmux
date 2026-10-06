#!/usr/bin/env python3
"""The feat-cmux-next batch queue: selection, debounce, stacking, bisect.

scripts/ci/next_batch.py stacks eligible PRs on feat-cmux-next, rebuilds
conflicted generated files instead of resolving them by hand, drops PRs with
real conflicts, and bisects a red stack to one culprit. The stacking tests
run real git merges in a scratch repository.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import subprocess
import sys
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import next_batch as nb  # noqa: E402

WORKFLOW = ROOT / ".github/workflows/cmux-next-batch.yml"
NOW = dt.datetime(2026, 10, 6, 5, 0, tzinfo=dt.timezone.utc)
PANE = "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/pane.js"


def pr(number: int, **fields) -> nb.PullRequest:
    defaults = dict(sha=f"{number:040x}", title=f"PR {number}", author="teamleaderleo",
                    committed_at="2026-10-06T04:00:00Z", head_ref=f"lane-{number}")
    defaults.update(fields)
    return nb.PullRequest(number=number, **defaults)


class Classify(unittest.TestCase):
    def test_generated_paths_by_generator(self):
        cases = {
            PANE: "web",
            "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages/settings/locales/ko.js": "web",
            "webviews/src/pages/settings/generated/strings.json": "web",
            "schemas/settings/settings-schema.json": "swift",
            "plans/cmux-next/action-surfaces.json": "swift",
            "cmux-tui/bindings/python/cmux/raw/_generated/models.py": "sdk",
            "cmux-tui/bindings/java/src/com/cmux/raw/Client.java": "sdk",
            "cmux-tui/spec/sdk-schema.json": "spec",
            "Resources/Localizable.xcstrings": "xcstrings",
            "cmux.xcodeproj/project.pbxproj": "pbxproj",
            "Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Views/SidebarListView.swift": "source",
            "plans/cmux-next/inventory.md": "source",
        }
        for path, kind in cases.items():
            with self.subTest(path=path):
                self.assertEqual(nb.classify(path), kind)


class Eligibility(unittest.TestCase):
    def reason(self, item: nb.PullRequest) -> str | None:
        return nb.ineligible_reason(item, NOW, authors=frozenset({"teamleaderleo"}))

    def test_green_or_pending_fast_checks_are_eligible(self):
        self.assertIsNone(self.reason(pr(1, checks=[("lint", "completed", "success"),
                                                     ("tests", "in_progress", "")])))

    def test_red_fast_check_is_not(self):
        self.assertEqual(self.reason(pr(1, checks=[("lint", "completed", "failure")])), "red check lint")

    def test_red_or_pending_heavy_check_does_not_block(self):
        # The batch runs the heavy tier once on the stack.
        self.assertIsNone(self.reason(pr(1, checks=[("cmux-next swift test", "completed", "failure"),
                                                     ("cmux app scheme compile (Debug)", "queued", "")])))

    def test_hold_draft_fork_stale_and_batch_branch(self):
        self.assertEqual(self.reason(pr(1, labels=["hold"])), "label hold")
        self.assertEqual(self.reason(pr(1, labels=["exploration", "needs a call"])), "label exploration, needs a call")
        self.assertEqual(self.reason(pr(1, draft=True)), "draft")
        self.assertEqual(self.reason(pr(1, same_repo=False)), "head is in a fork")
        self.assertIn("older than", self.reason(pr(1, committed_at="2026-09-20T00:00:00Z")))
        self.assertEqual(self.reason(pr(1, head_ref="next-batch/1-1")), "a batch integration branch")

    def test_other_authors_opt_in_with_a_label(self):
        self.assertIn("has not opted in", self.reason(pr(1, author="lawrencecchen")))
        self.assertIsNone(self.reason(pr(1, author="lawrencecchen", labels=["batch-queue"])))

    def test_select_orders_by_number_and_caps_the_batch(self):
        prs = [pr(n) for n in (30, 10, 20, 40)] + [pr(5, labels=["hold"])]
        with mock.patch.dict(os.environ, {"CMUX_NEXT_BATCH_AUTHORS": ""}):
            eligible, skipped = nb.select(prs, NOW, limit=3)
        self.assertEqual([item.number for item in eligible], [10, 20, 30])
        self.assertEqual(skipped, {5: "label hold", 40: "batch is full (3); next batch"})


class Debounce(unittest.TestCase):
    def test_waits_for_quiet_but_not_past_the_hard_max(self):
        self.assertEqual(nb.debounce_wait(NOW, NOW), 120)
        self.assertEqual(nb.debounce_wait(NOW, NOW - dt.timedelta(seconds=530)), 70)
        self.assertEqual(nb.debounce_wait(NOW, NOW - dt.timedelta(minutes=30)), 0)

    def test_first_trigger_counts_from_the_last_batch_dispatch(self):
        def run(event: str, minutes: int, title: str = "debounce 1") -> dict:
            return {"event": event, "display_title": title,
                    "created_at": (NOW - dt.timedelta(minutes=minutes)).isoformat()}
        runs = [run("pull_request", 1), run("push", 6), run("workflow_dispatch", 8, "batch "),
                run("pull_request", 9), run("workflow_dispatch", 3, "build x")]
        self.assertEqual(nb.first_trigger_since_dispatch(runs, NOW), NOW - dt.timedelta(minutes=6))
        self.assertEqual(nb.first_trigger_since_dispatch([], NOW), NOW)


class JsonMerge(unittest.TestCase):
    def test_different_keys_merge(self):
        base = {"commands": {"a": 1}}
        merged = nb.json_merge(base, {"commands": {"a": 1, "b": 2}}, {"commands": {"a": 1, "c": 3}})
        self.assertEqual(merged, {"commands": {"a": 1, "b": 2, "c": 3}})

    def test_appended_lists_merge(self):
        self.assertEqual(nb.json_merge([1], [1, 2], [1, 3]), [1, 2, 3])

    def test_same_key_changed_both_ways_conflicts(self):
        with self.assertRaises(nb.JsonConflict):
            nb.json_merge({"a": 1}, {"a": 2}, {"a": 3})

    def test_text_keeps_the_files_indent(self):
        base = '{\n    "a": 1\n}\n'
        text = nb.json_merge_text(base, '{\n    "a": 1,\n    "b": 2\n}\n', '{\n    "a": 1,\n    "c": 3\n}\n')
        self.assertEqual(text, '{\n    "a": 1,\n    "b": 2,\n    "c": 3\n}\n')


class Stacking(unittest.TestCase):
    """Real merges: base commit plus PR branches in a scratch repository."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "repo"
        self.root.mkdir()
        self.env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
        self.git("init", "-q", "-b", "base")
        self.write({"app.swift": "let a = 1\nlet b = 2\n", PANE: "bundle v0\n",
                    "cmux-tui/spec/sdk-schema.json": '{\n  "commands": {\n    "a": 1\n  }\n}\n'})
        self.base = self.commit("base")

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=self.root, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def write(self, files: dict[str, str]) -> None:
        for path, text in files.items():
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)

    def commit(self, message: str) -> str:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def branch(self, number: int, files: dict[str, str]) -> nb.PullRequest:
        self.git("checkout", "-q", "-B", f"pr{number}", self.base)
        self.write(files)
        sha = self.commit(f"pr {number}")
        self.git("checkout", "-q", "--detach", self.base)
        return pr(number, sha=sha)

    def stack(self, prs: list[nb.PullRequest]) -> nb.Stack:
        with mock.patch.dict(os.environ, self.env):
            return nb.build_stack(self.root, self.base, prs, regen=False)

    def test_clean_prs_stack_in_order(self):
        one = self.branch(1, {"one.swift": "1\n"})
        two = self.branch(2, {"two.swift": "2\n"})
        stack = self.stack([one, two])
        self.assertEqual([item.number for item in stack.included], [1, 2])
        self.assertFalse(stack.dropped)
        self.assertEqual(self.git("log", "--format=%s", "-2", stack.head).splitlines(),
                         ["next-batch: merge #2", "next-batch: merge #1"])

    def test_generated_conflict_keeps_the_stack_copy_and_asks_for_regeneration(self):
        one = self.branch(1, {PANE: "bundle one\n", "pane-src-1.ts": "1\n"})
        two = self.branch(2, {PANE: "bundle two\n", "pane-src-2.ts": "2\n"})
        stack = self.stack([one, two])
        self.assertEqual([item.number for item in stack.included], [1, 2])
        self.assertIn("web", stack.regen)
        self.assertEqual(self.git("show", f"{stack.head}:{PANE}"), "bundle one")

    def test_source_conflict_drops_the_later_pr(self):
        one = self.branch(1, {"app.swift": "let a = 10\nlet b = 2\n"})
        two = self.branch(2, {"app.swift": "let a = 20\nlet b = 2\n"})
        three = self.branch(3, {"three.swift": "3\n"})
        stack = self.stack([one, two, three])
        self.assertEqual([item.number for item in stack.included], [1, 3])
        self.assertEqual([(item.number, [b["path"] for b in blocking]) for item, blocking in stack.dropped],
                         [(2, ["app.swift"])])
        self.assertEqual(self.git("status", "--porcelain", "--untracked-files=no"), "")

    def test_spec_json_merges_by_key_and_regenerates_the_sdk(self):
        spec = "cmux-tui/spec/sdk-schema.json"
        one = self.branch(1, {spec: '{\n  "commands": {\n    "a": 1,\n    "b": 2\n  }\n}\n'})
        two = self.branch(2, {spec: '{\n  "commands": {\n    "a": 1,\n    "c": 3\n  }\n}\n'})
        stack = self.stack([one, two])
        self.assertEqual([item.number for item in stack.included], [1, 2])
        self.assertEqual(json.loads(self.git("show", f"{stack.head}:{spec}")),
                         {"commands": {"a": 1, "b": 2, "c": 3}})
        self.assertIn("sdk", stack.regen)

    def test_generated_file_both_sides_changed_cleanly_is_still_rebuilt(self):
        self.git("checkout", "-q", "--detach", self.base)
        self.write({PANE: "line1\nline2\nline3\nline4\nline5\nline6\n"})
        self.base = self.commit("longer bundle")
        one = self.branch(1, {PANE: "line1 one\nline2\nline3\nline4\nline5\nline6\n"})
        two = self.branch(2, {PANE: "line1\nline2\nline3\nline4\nline5\nline6 two\n"})
        stack = self.stack([one, two])
        self.assertEqual(len(stack.included), 2)
        self.assertIn("web", stack.regen)


class Bisect(unittest.TestCase):
    def controller(self, red_from: int) -> nb.Controller:
        controller = nb.Controller.__new__(nb.Controller)
        controller.validations = []
        probes = []

        def validate(prs, name):
            probes.append([item.number for item in prs])
            stack = nb.Stack(base="b", head="h", included=list(prs))
            validation = nb.Validation(name=name, stack=stack, build={"ok": True})
            if any(item.number >= red_from for item in prs):
                validation.heavy_failed = ["cmux-next swift test"]
            controller.validations.append(validation)
            return validation

        controller.validate = validate
        controller.probes = probes
        return controller

    def test_finds_the_first_pr_that_turns_the_stack_red(self):
        prs = [pr(n) for n in range(1, 9)]
        for red_from in range(1, 9):
            with self.subTest(red_from=red_from):
                controller = self.controller(red_from)
                red = nb.Validation(name="batch", stack=nb.Stack(base="b", included=prs),
                                    heavy_failed=["x"], build={"ok": True})
                self.assertEqual(controller.bisect(red).number, red_from)
                self.assertLessEqual(len(controller.probes), 3)  # log2(8)


class StickyBody(unittest.TestCase):
    def test_newest_on_top_and_history_bounded(self):
        body = ""
        for index in range(12):
            body = nb.sticky_body(f"batch {index}", body, keep=3)
        self.assertTrue(body.startswith(nb.STICKY_MARKER + "\nbatch 11\n"))
        self.assertIn("batch 10", body)
        self.assertIn("batch 8", body)
        self.assertNotIn("batch 7", body)


class LandingRetry(unittest.TestCase):
    def test_red_heavy_check_lands_with_an_override_naming_the_batch(self):
        controller = nb.Controller.__new__(nb.Controller)
        controller.args = Namespace(repo="o/r")
        controller.run_url = "https://example.test/run/1"
        validation = nb.Validation(name="batch", stack=nb.Stack(base="b", head="c" * 40))
        calls = []

        def fake_run(command, **_):
            calls.append(command)
            if "--override" not in command:
                return subprocess.CompletedProcess(command, 1, "", "not green: 'cmux-next swift test' is not successful on abc\n")
            return subprocess.CompletedProcess(command, 0, "", "")

        with mock.patch.object(nb.subprocess, "run", fake_run):
            outcome = controller.merge_one(Path("/bin/true"), pr(7), validation)
        self.assertTrue(outcome.startswith("landed"))
        self.assertIn("https://example.test/run/1", calls[-1][calls[-1].index("--override") + 1])

    def test_github_refusal_is_reported_not_retried(self):
        controller = nb.Controller.__new__(nb.Controller)
        controller.args = Namespace(repo="o/r")
        controller.run_url = "u"
        validation = nb.Validation(name="batch", stack=nb.Stack(base="b", head="c" * 40))
        refusal = subprocess.CompletedProcess([], 1, "", "not green: GitHub refused to merge o/r#7\n")
        with mock.patch.object(nb.subprocess, "run", return_value=refusal):
            self.assertEqual(controller.merge_one(Path("/bin/true"), pr(7), validation),
                             "not landed: not green: GitHub refused to merge o/r#7")


class WorkflowShape(unittest.TestCase):
    def setUp(self):
        self.workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        self.jobs = self.workflow["jobs"]

    def test_debounce_cancels_but_a_running_batch_is_never_cancelled(self):
        self.assertEqual(self.jobs["debounce"]["concurrency"],
                         {"group": "cmux-next-batch-debounce", "cancel-in-progress": True})
        self.assertEqual(self.jobs["batch"]["concurrency"],
                         {"group": "cmux-next-batch", "cancel-in-progress": False})

    def test_debounce_runs_the_trusted_controller(self):
        checkout = self.jobs["debounce"]["steps"][0]
        self.assertEqual(checkout["with"]["ref"], "feat-cmux-next")
        self.assertFalse(checkout["with"]["persist-credentials"])
        self.assertIn("head.repo.full_name == github.repository", self.jobs["debounce"]["if"])

    def test_batch_checkout_keeps_the_token_out_of_git_config(self):
        checkout = self.jobs["batch"]["steps"][0]
        self.assertFalse(checkout["with"]["persist-credentials"])

    def test_mini_jobs_only_touch_next_batch_branches(self):
        for job in ("regen", "build"):
            with self.subTest(job=job):
                self.assertIn("startsWith(inputs.branch, 'next-batch/')", self.jobs[job]["if"])

    def test_dispatch_inputs_match_the_controller(self):
        inputs = self.workflow[True]["workflow_dispatch"]["inputs"]
        for name in ("mode", "prs", "branch", "sha", "tag", "nonce", "reason"):
            self.assertIn(name, inputs)
        self.assertIn("next-batch-regen", WORKFLOW.read_text())
        self.assertIn("next-batch-build", WORKFLOW.read_text())


if __name__ == "__main__":
    unittest.main()
