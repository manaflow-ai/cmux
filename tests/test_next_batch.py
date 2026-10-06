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

    def test_a_red_web_format_check_does_not_block_a_webviews_pr(self):
        red = [("web / react-apps-check", "completed", "failure"), ("web / Web status", "completed", "failure")]
        self.assertIsNone(nb.ineligible_reason(pr(5, checks=red, files=["webviews/src/a.ts"]), NOW))
        self.assertIn("react-apps-check", nb.ineligible_reason(pr(5, checks=red, files=["app.swift"]), NOW))

    def test_workflow_changes_land_by_hand(self):
        # GitHub refuses the job token's push or merge of a workflow change.
        self.assertIn("lands by hand", self.reason(pr(1, files=[".github/workflows/cmux-next.yml"])))
        self.assertIsNone(self.reason(pr(1, files=["scripts/ci/x.py"])))

    def test_other_authors_opt_in_with_a_label(self):
        self.assertIn("has not opted in", self.reason(pr(1, author="lawrencecchen")))
        self.assertIsNone(self.reason(pr(1, author="lawrencecchen", labels=["batch-queue"])))

    def test_select_orders_by_number_and_caps_the_batch(self):
        prs = [pr(n) for n in (30, 10, 20, 40)] + [pr(5, labels=["hold"])]
        with mock.patch.dict(os.environ, {"CMUX_NEXT_BATCH_AUTHORS": ""}):
            eligible, skipped = nb.select(prs, NOW, limit=3)
        self.assertEqual([item.number for item in eligible], [10, 20, 30])
        self.assertEqual(skipped, {5: "label hold", 40: "batch is full (3); next batch"})


class OpenPrsQuery(unittest.TestCase):
    """One 100-PR query with files and checks times out (HTTP 504): page it."""

    def node(self, number: int) -> dict:
        return {"number": number, "title": "t", "url": "u", "isDraft": False, "headRefName": f"b{number}",
                "headRefOid": "a" * 40, "authorAssociation": "MEMBER", "author": {"login": "teamleaderleo"},
                "files": {"nodes": []}, "isCrossRepository": False, "labels": {"nodes": []},
                "commits": {"nodes": []}}

    def test_pages_through_every_open_pr(self):
        gh = nb.GitHub("o/r")
        pages = [
            {"repository": {"pullRequests": {"nodes": [self.node(1), self.node(2)],
                                              "pageInfo": {"hasNextPage": True, "endCursor": "c1"}}}},
            {"repository": {"pullRequests": {"nodes": [self.node(3)],
                                              "pageInfo": {"hasNextPage": False, "endCursor": None}}}},
        ]
        seen = []
        gh.graphql = lambda query, **variables: seen.append(variables.get("after")) or pages[len(seen) - 1]
        self.assertEqual([item.number for item in nb.open_prs(gh)], [1, 2, 3])
        self.assertEqual(seen, [None, "c1"])
        self.assertLessEqual(nb.PRS_PAGE, 40)

    def test_a_gateway_timeout_is_retried_once(self):
        gh = nb.GitHub("o/r")
        replies = [subprocess.CompletedProcess([], 1, "", "gh: HTTP 504"),
                   subprocess.CompletedProcess([], 0, '{"data": {"ok": 1}}', "")]
        with mock.patch.object(nb.subprocess, "run", side_effect=replies), mock.patch.object(nb.time, "sleep"):
            self.assertEqual(gh.graphql("query { x }"), {"ok": 1})


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


class ServeDebounce(unittest.TestCase):
    """The big-red serve loop: quiet after the eligible set changes, capped."""

    def at(self, seconds: int) -> dt.datetime:
        return NOW + dt.timedelta(seconds=seconds)

    def test_runs_after_quiet_and_not_again_for_the_same_set(self):
        debouncer = nb.Debouncer()
        heads = ((1, "a"), (2, "b"))
        self.assertFalse(debouncer.observe(heads, self.at(0)))
        self.assertFalse(debouncer.observe(heads, self.at(60)))
        self.assertTrue(debouncer.observe(heads, self.at(120)))
        debouncer.ran(heads)
        self.assertFalse(debouncer.observe(heads, self.at(600)))

    def test_constant_pushes_still_run_at_the_hard_max(self):
        debouncer = nb.Debouncer()
        fired = [seconds for seconds in range(0, 900, 60)
                 if debouncer.observe(((1, f"sha{seconds}"),), self.at(seconds))]
        self.assertEqual(fired[0], 600)

    def test_nothing_eligible_never_runs(self):
        debouncer = nb.Debouncer()
        self.assertFalse(debouncer.observe((), self.at(0)))
        self.assertFalse(debouncer.observe((), self.at(3600)))

    def test_a_new_push_after_a_batch_starts_a_new_wait(self):
        debouncer = nb.Debouncer()
        debouncer.observe(((1, "a"),), self.at(0))
        debouncer.ran(((1, "a"),))
        self.assertFalse(debouncer.observe(((1, "b"),), self.at(1000)))
        self.assertTrue(debouncer.observe(((1, "b"),), self.at(1120)))


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


class RemoteRegeneration(unittest.TestCase):
    """Generators run the stack's code, so they run in a dispatched job and
    send back a patch; the controller never runs them on its own host."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
        self.git("init", "-q", "-b", "base")
        (self.root / "pane.js").write_text("v0\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "stack")
        self.head = self.git("rev-parse", "HEAD")
        (self.root / "pane.js").write_text("v1\n")
        self.git("commit", "-q", "-am", "next-batch: regenerate web bundles")
        self.patch = subprocess.run(["git", "format-patch", "-1", "--binary", "--stdout"], cwd=self.root,
                                    env=self.env, check=True, capture_output=True).stdout
        self.git("reset", "-q", "--hard", self.head)

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=self.root, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def controller(self, results: dict[str, dict]) -> tuple[nb.Controller, list]:
        controller = nb.Controller.__new__(nb.Controller)
        controller.worktree = self.root
        calls = []

        def mini(mode, branch, sha, extra):
            calls.append((mode, sha, extra.get("kinds")))
            return {}, results[mode]

        controller.mini = mini
        controller.git = lambda *args, cwd=None: subprocess.run(
            ["git", *args], cwd=cwd or self.root, env=self.env, check=True, capture_output=True, text=True,
        ).stdout.strip() if args[0] != "push" else calls.append(("push", args[-1], None))
        return controller, calls

    def test_web_and_sdk_on_linux_then_swift_on_a_mini_each_applied_as_a_patch(self):
        controller, calls = self.controller({"regen-linux": {"ok": True, "patch": self.patch},
                                             "regen": {"ok": True}})
        stack = nb.Stack(base="b", head=self.head, regen={"web", "sdk", "swift"})
        with mock.patch.dict(os.environ, self.env):
            self.assertTrue(controller.regenerate_remote(stack, "next-batch/x-1"))
        self.assertEqual([call[0] for call in calls], ["regen-linux", "push", "regen"])
        self.assertEqual(calls[0][2], "sdk web")
        self.assertNotEqual(stack.head, self.head)
        self.assertEqual((self.root / "pane.js").read_text(), "v1\n")
        self.assertEqual(calls[2][1], stack.head)  # swift runs on the regenerated head

    def test_a_failed_generator_is_the_stack_error(self):
        controller, _ = self.controller({"regen": {"ok": False, "error": "swift test failed"}})
        stack = nb.Stack(base="b", head=self.head, regen={"swift"})
        self.assertFalse(controller.regenerate_remote(stack, "next-batch/x-1"))
        self.assertIn("swift test failed", stack.error)

    def test_validate_never_runs_a_generator_locally(self):
        controller = nb.Controller.__new__(nb.Controller)
        controller.validations, controller.base_sha, controller.worktree = [], "", self.root
        controller.fetch = lambda prs: self.head
        seen = {}

        def build_stack(worktree, base_sha, prs, regen=True):
            seen["regen"] = regen
            return nb.Stack(base=base_sha)

        with mock.patch.object(nb, "build_stack", build_stack):
            controller.validate([pr(1)], "batch")
        self.assertIs(seen["regen"], False)


class MiniRetry(unittest.TestCase):
    """A mini refused at setup (host busy) writes no result: try once more."""

    def controller(self, outcomes: list[bool]) -> tuple[nb.Controller, list]:
        controller = nb.Controller.__new__(nb.Controller)
        controller.args = Namespace(repo="o/r", ref="feat-cmux-next")
        controller.batch_id = "b"
        attempts = []

        def once(mode, branch, sha, extra):
            wrote = outcomes[len(attempts)]
            attempts.append(mode)
            return {"html_url": f"u{len(attempts)}"}, ({"ok": True, "run": "u"} if wrote else
                                                        {"ok": False, "error": "mini run failure", "run": "u",
                                                         "no_result": True})

        controller.mini_once = once
        return controller, attempts

    def test_a_job_without_a_result_is_dispatched_once_more(self):
        controller, attempts = self.controller([False, True])
        _, result = controller.mini("regen", "next-batch/x", "c" * 40, {})
        self.assertTrue(result["ok"])
        self.assertEqual(attempts, ["regen", "regen"])

    def test_it_gives_up_after_the_second_refusal(self):
        controller, attempts = self.controller([False, False, True])
        _, result = controller.mini("regen", "next-batch/x", "c" * 40, {})
        self.assertFalse(result["ok"])
        self.assertEqual(len(attempts), 2)

    def test_a_generator_failure_is_not_retried(self):
        controller = nb.Controller.__new__(nb.Controller)
        attempts = []
        controller.mini_once = lambda *args: attempts.append(1) or ({}, {"ok": False, "error": "script failed"})
        self.assertFalse(controller.mini("regen", "next-batch/x", "c" * 40, {})[1]["ok"])
        self.assertEqual(len(attempts), 1)


class FormatBeforeLanding(unittest.TestCase):
    """Formatting never blocks a landing: the queue runs the web formatter on
    the PR's head on a runner and pushes the fix to the PR's branch."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
        self.root = root / "repo"
        self.root.mkdir()
        self.git("init", "-q", "-b", "lane")
        (self.root / "a.ts").write_text("let a=1\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "pr")
        self.head = self.git("rev-parse", "HEAD")
        (self.root / "a.ts").write_text("let a = 1;\n")
        self.git("commit", "-q", "-am", "next-batch: format webviews")
        self.patch = subprocess.run(["git", "format-patch", "-1", "--binary", "--stdout"], cwd=self.root,
                                    env=self.env, check=True, capture_output=True).stdout
        self.git("reset", "-q", "--hard", self.head)

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=self.root, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def controller(self, result: dict) -> tuple[nb.Controller, list]:
        controller = nb.Controller.__new__(nb.Controller)
        controller.worktree = Path(self.tmp.name) / "stack"
        calls = []

        def mini(mode, branch, sha, extra):
            calls.append((mode, sha, extra.get("kinds")))
            return {}, result

        def git(*args, cwd=None):
            if args[0] == "push":
                calls.append(("push", args[-1], None))
                return ""
            return subprocess.run(["git", *args], cwd=cwd or self.root, env=self.env, check=True,
                                  capture_output=True, text=True).stdout.strip()

        controller.mini, controller.git = mini, git
        return controller, calls

    def test_formats_on_a_runner_and_pushes_to_the_pr_branch(self):
        controller, calls = self.controller({"ok": True, "patch": self.patch})
        target = pr(9, sha=self.head, head_ref="lane-9", files=["webviews/a.ts"])
        with mock.patch.dict(os.environ, self.env):
            sha = controller.format_pr(target, "next-batch/x-1")
        self.assertEqual(calls[0], ("regen-linux", self.head, "format"))
        self.assertEqual(calls[1][0], "push")
        self.assertEqual(calls[1][1], f"{sha}:refs/heads/lane-9")
        self.assertNotEqual(sha, self.head)
        self.assertEqual(self.git("show", f"{sha}:a.ts"), "let a = 1;")

    def test_nothing_to_format_pushes_nothing(self):
        controller, calls = self.controller({"ok": True})
        target = pr(9, sha=self.head, head_ref="lane-9", files=["webviews/a.ts"])
        self.assertEqual(controller.format_pr(target, "next-batch/x-1"), "")
        self.assertEqual([call[0] for call in calls], ["regen-linux"])

    def test_land_formats_only_a_pr_with_a_red_format_check(self):
        controller = nb.Controller.__new__(nb.Controller)
        controller.args = Namespace(repo="o/r", dry_run=False, no_land=False)
        controller.run_url = "u"
        red = pr(1, files=["webviews/a.ts"], checks=[("web / react-apps-check", "completed", "failure")])
        clean = pr(2, files=["webviews/b.ts"])
        controller.gh = mock.Mock()
        controller.merge_green = lambda: Path("/bin/true")
        controller.comment_once = lambda *args: None
        formatted, merged = [], []
        controller.format_pr = lambda item, branch: formatted.append(item.number) or "f" * 40
        controller.merge_one = lambda helper, item, validation: merged.append(item.number) or "landed"
        validation = nb.Validation(name="batch", stack=nb.Stack(base="b", head="h", included=[red, clean]),
                                   branch="next-batch/x-1")
        with mock.patch.object(nb, "open_prs", return_value=[red, clean]):
            landed = controller.land(validation)
        self.assertEqual(formatted, [1])
        self.assertEqual(merged, [1, 2])
        self.assertEqual([text for _, text in landed], ["landed", "landed"])


class NotifyOwners(unittest.TestCase):
    """Until landing is allowed, serve posts a receipt and the owner lands."""

    def controller(self, notify: bool) -> nb.Controller:
        controller = nb.Controller.__new__(nb.Controller)
        controller.args = Namespace(repo="o/r", dry_run=False, no_land=False, land=not notify)
        controller.run_url = "u"
        controller.gh = mock.Mock()
        controller.merge_green = lambda: Path("/bin/true")
        controller.comments = []
        controller.comment_once = lambda item, kind, body: controller.comments.append((item.number, kind, body))
        controller.merged = []
        controller.merge_one = lambda helper, item, validation: controller.merged.append(item.number) or "landed"
        return controller

    def validation(self, prs, passed=("cmux-next swift test",)) -> nb.Validation:
        return nb.Validation(name="batch", stack=nb.Stack(base="b" * 40, head="h" * 40, included=prs),
                             branch="next-batch/x-1", heavy_url="https://heavy", heavy_passed=list(passed),
                             build={"ok": True, "job_id": "job-7", "link": "cmux-ci artifact job-7"})

    def test_serve_notifies_by_default(self):
        with mock.patch.object(nb, "cmd_serve", lambda args: args), mock.patch.object(nb.subprocess, "run"):
            args = nb.main(["serve", "--worktree", tempfile.mkdtemp() + "/w"])
        self.assertFalse(args.land)

    def test_a_local_run_notifies_and_an_actions_run_lands(self):
        with mock.patch.object(nb, "cmd_run", lambda args: args), mock.patch.object(nb.subprocess, "run"):
            worktree = tempfile.mkdtemp() + "/w"
            self.assertFalse(nb.main(["run", "--local", "--worktree", worktree]).land)
            self.assertTrue(nb.main(["run", "--worktree", worktree]).land)

    def test_notify_posts_a_receipt_and_merges_nothing(self):
        controller = self.controller(notify=True)
        prs = [pr(1), pr(2)]
        with mock.patch.object(nb, "open_prs", return_value=prs):
            landed = controller.land(self.validation(prs))
        self.assertEqual(controller.merged, [])
        self.assertEqual([kind for _, kind, _ in controller.comments], ["receipt", "receipt"])
        self.assertIn("job-7", controller.comments[0][2])
        self.assertIn("land it yourself", controller.comments[0][2])
        self.assertTrue(all(text.startswith("receipt posted") for _, text in landed))

    def test_a_receipt_says_when_the_heavy_tier_did_not_run(self):
        controller = self.controller(notify=True)
        prs = [pr(1)]
        with mock.patch.object(nb, "open_prs", return_value=prs):
            controller.land(self.validation(prs, passed=()))
        self.assertIn("heavy tier did not run", controller.comments[0][2])

    def test_land_flag_merges(self):
        controller = self.controller(notify=False)
        prs = [pr(1)]
        with mock.patch.object(nb, "open_prs", return_value=prs):
            controller.land(self.validation(prs))
        self.assertEqual(controller.merged, [1])


class LocalController(unittest.TestCase):
    """`serve` on a workstation: the operator's gh login, cmux-ci for the build."""

    def controller(self) -> nb.Controller:
        with mock.patch.dict(os.environ, {"GH_TOKEN": "t", "CMUX_NEXT_BATCH_STICKY": "o/hq#5"}):
            return nb.Controller(Namespace(repo="o/r", worktree="/tmp/x", ref="feat-cmux-next", local=True,
                                           dry_run=False, no_land=False, prs="", keep_branches=False))

    def test_links_the_sticky_issue_and_names_the_batch_by_time(self):
        controller = self.controller()
        self.assertEqual(controller.run_url, "https://github.com/o/hq/issues/5")
        self.assertTrue(controller.batch_id.startswith("local-"))

    def test_fleet_build_goes_through_cmux_ci_on_this_host(self):
        controller = self.controller()
        commands = []

        def fake_run(command, **_):
            commands.append(command)
            if command[1] == "build":
                Path(command[command.index("--receipt") + 1]).write_text('{"id": "job-9"}')
            if command[1] == "publish-hq":
                return subprocess.CompletedProcess(command, 0, '{"url": "https://hq.test/b/9"}\n', "")
            return subprocess.CompletedProcess(command, 0, "", "")

        with mock.patch.object(nb.subprocess, "run", fake_run):
            result = controller.fleet_build("next-batch/x-1", "c" * 40, "nb-x-1")
        build = commands[0]
        self.assertEqual(build[:3], ["cmux-ci", "build", "cmux"])
        self.assertIn("--production", build)
        self.assertNotIn("--backend-mode", build)  # cmux-ci refuses offline mode for production
        self.assertEqual(build[build.index("--ref") + 1], "c" * 40)
        self.assertEqual([command[1] for command in commands], ["build", "wait", "publish-hq"])
        self.assertTrue(result["ok"])
        self.assertIn("https://hq.test/b/9", result["link"])

    def test_failed_fleet_job_is_not_ok(self):
        controller = self.controller()

        def fake_run(command, **_):
            if command[1] == "build":
                Path(command[command.index("--receipt") + 1]).write_text('{"id": "job-9"}')
            return subprocess.CompletedProcess(command, 1 if command[1] == "wait" else 0, "", "")

        with mock.patch.object(nb.subprocess, "run", fake_run):
            result = controller.fleet_build("next-batch/x-1", "c" * 40, "nb-x-1")
        self.assertFalse(result["ok"])
        self.assertIn("job-9", result["error"])

    def test_user_token_merges_start_ci_so_nothing_is_redispatched(self):
        controller = self.controller()
        controller.gh = mock.Mock()
        controller.after_landing()
        controller.gh.dispatch.assert_not_called()


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
        controller.writer = nb.GitHub("o/r")
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
        controller.writer = nb.GitHub("o/r")
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

    def test_debounce_dispatches_only_when_enabled(self):
        step = self.jobs["debounce"]["steps"][-1]
        self.assertEqual(step["env"]["ENABLED"], "${{ vars.CMUX_NEXT_BATCH_ENABLED }}")
        self.assertIn('[[ "$ENABLED" == 1 ]]', step["run"])

    def test_batch_checkout_keeps_the_token_out_of_git_config(self):
        checkout = self.jobs["batch"]["steps"][0]
        self.assertFalse(checkout["with"]["persist-credentials"])

    def test_mini_jobs_only_touch_next_batch_branches(self):
        for job in ("regen", "regen-linux", "build"):
            with self.subTest(job=job):
                self.assertIn("startsWith(inputs.branch, 'next-batch/')", self.jobs[job]["if"])

    def test_dispatch_inputs_match_the_controller(self):
        inputs = self.workflow[True]["workflow_dispatch"]["inputs"]
        for name in ("mode", "prs", "branch", "sha", "tag", "nonce", "reason"):
            self.assertIn(name, inputs)
        self.assertIn("next-batch-regen", WORKFLOW.read_text())
        self.assertIn("next-batch-build", WORKFLOW.read_text())
        self.assertIn("kinds", inputs)

    def test_swift_generator_script_comes_from_the_workflow_ref(self):
        steps = self.jobs["regen"]["steps"]
        tools = next(step for step in steps if step.get("with", {}).get("path") == ".next-batch-tools")
        self.assertEqual(tools["with"]["ref"], "${{ github.sha }}")
        regen = next(step for step in steps if step.get("id") == "regen")
        self.assertIn(".next-batch-tools/scripts/cmux-next/regenerate-swift-exports.sh", regen["run"])

    def test_regen_linux_runs_the_web_formatter_and_lint_autofix(self):
        script = "\n".join(step.get("run", "") for step in self.jobs["regen-linux"]["steps"])
        self.assertIn('*" format "*', script)
        self.assertIn("bun run check:fix", script)

    def test_regeneration_jobs_return_a_patch_and_never_push(self):
        for job in ("regen", "regen-linux"):
            with self.subTest(job=job):
                spec = self.jobs[job]
                self.assertEqual(spec.get("permissions"), {"contents": "read"})
                script = "\n".join(step.get("run", "") for step in spec["steps"])
                self.assertNotIn("git push", script)
                self.assertNotIn("git -c", script.replace("git -c user.", ""))
                self.assertIn("format-patch", script)
                self.assertFalse(any("secrets." in json.dumps(step) for step in spec["steps"]))


if __name__ == "__main__":
    unittest.main()
