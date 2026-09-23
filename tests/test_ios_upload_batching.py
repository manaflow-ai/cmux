#!/usr/bin/env python3
"""Pin count-plus-age batching of the scheduled iOS TestFlight uploads.

ios-testflight.yml (CMUX INTERNAL, 20-minute polls) and ios-appstore-upload.yml
(cmux.app, hourly) upload only when at least one relevant commit is waiting
AND (N are waiting OR the oldest is T minutes old). The rule lives in
scripts/ci/ios_upload_batch_decision.py; these tests cover the rule, the git
history reader against a real repository, and the workflow wiring.
"""

import importlib.util
import ast
import textwrap
import os
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/ios_upload_batch_decision.py"
INTERNAL = ROOT / ".github/workflows/ios-testflight.yml"
OFFICIAL = ROOT / ".github/workflows/ios-appstore-upload.yml"
NOTES_GENERATOR = ROOT / "ios/scripts/generate-testflight-notes.sh"

spec = importlib.util.spec_from_file_location("ios_upload_batch_decision", SCRIPT)
batch = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = batch
spec.loader.exec_module(batch)

NOW = 1_800_000_000
DEFAULTS = batch.Thresholds(min_commits=5, max_age_minutes=180)


def minutes_ago(*minutes):
    return [NOW - minute * 60 for minute in minutes]


class DecisionRuleTests(unittest.TestCase):
    def test_below_both_thresholds_skips(self):
        decision = batch.decide("schedule", minutes_ago(45, 10), NOW, DEFAULTS)
        self.assertFalse(decision.upload)
        self.assertEqual(decision.reason, "skipped: 2/5 iOS commits, oldest 45/180 min")

    def test_count_reached_uploads(self):
        decision = batch.decide("schedule", minutes_ago(30, 20, 15, 10, 5), NOW, DEFAULTS)
        self.assertTrue(decision.upload)
        self.assertEqual(
            decision.reason, "upload: 5/5 iOS commits, oldest 30/180 min (count reached)"
        )

    def test_age_reached_with_one_commit_uploads(self):
        decision = batch.decide("schedule", minutes_ago(180), NOW, DEFAULTS)
        self.assertTrue(decision.upload)
        self.assertEqual(
            decision.reason, "upload: 1/5 iOS commits, oldest 180/180 min (age reached)"
        )

    def test_zero_commits_skip_regardless_of_age(self):
        for thresholds in (DEFAULTS, batch.Thresholds(min_commits=1, max_age_minutes=0)):
            with self.subTest(thresholds=thresholds):
                decision = batch.decide("schedule", [], NOW, thresholds)
                self.assertFalse(decision.upload)
                self.assertTrue(decision.reason.startswith("skipped: 0/"))

    def test_dispatch_always_uploads(self):
        for times in ([], minutes_ago(1)):
            with self.subTest(times=times):
                decision = batch.decide("workflow_dispatch", times, NOW, DEFAULTS)
                self.assertEqual(decision, batch.Decision(True, "upload: manual dispatch"))

    def test_oldest_commit_sets_the_age_not_the_newest(self):
        decision = batch.decide("schedule", minutes_ago(5, 200, 30), NOW, DEFAULTS)
        self.assertTrue(decision.upload)
        self.assertIn("oldest 200/180 min", decision.reason)


class ThresholdTests(unittest.TestCase):
    def test_zero_disables_each_threshold_and_both_disable_batching(self):
        for count, age, times, upload in (
            (0, 180, minutes_ago(1), False),
            (0, 180, minutes_ago(181), True),
            (5, 0, minutes_ago(1000), False),
            (5, 0, minutes_ago(1, 2, 3, 4, 5), True),
            (0, 0, minutes_ago(1), True),
            (0, 0, [], False),
        ):
            with self.subTest(count=count, age=age, times=times):
                thresholds = batch.resolve_thresholds(str(count), str(age), 5, 180)
                self.assertEqual(thresholds, batch.Thresholds(count, age))
                self.assertEqual(batch.decide("schedule", times, NOW, thresholds).upload, upload)

    def test_unset_variables_use_defaults(self):
        for unset in (None, "", "  "):
            with self.subTest(value=unset):
                self.assertEqual(batch.resolve_thresholds(unset, unset, 5, 180), DEFAULTS)
                self.assertEqual(
                    batch.resolve_thresholds(unset, unset, 10, 360),
                    batch.Thresholds(min_commits=10, max_age_minutes=360),
                )

    def test_set_variables_override_defaults(self):
        self.assertEqual(
            batch.resolve_thresholds("3", "0", 5, 180),
            batch.Thresholds(min_commits=3, max_age_minutes=0),
        )

    def test_invalid_variables_warn_and_use_defaults(self):
        warnings = []
        for bad_count, bad_age in (("-1", "-5"), ("five", "1.5")):
            with self.subTest(values=(bad_count, bad_age)):
                self.assertEqual(
                    batch.resolve_thresholds(bad_count, bad_age, 5, 180, warnings.append),
                    DEFAULTS,
                )
        self.assertEqual(len(warnings), 4)


class PathFilterTests(unittest.TestCase):
    def test_reads_the_internal_workflow_filter(self):
        paths = batch.workflow_path_filter(INTERNAL.read_text(encoding="utf-8"))
        # The notes generator carries the same contract (pinned by
        # test_ios_testflight_main_push_filter.py), so compare against it.
        assignment = next(
            line for line in NOTES_GENERATOR.read_text(encoding="utf-8").splitlines()
            if line.startswith("PATHS=")
        )
        notes_paths = shlex.split(assignment.removeprefix("PATHS="))[0].split()
        self.assertEqual(tuple(path.rstrip("/") for path in paths), tuple(notes_paths))
        self.assertIn("ios/", paths)
        self.assertIn("ghostty", paths)

    def test_matches_like_the_decide_script(self):
        paths = ("ios/", "ghostty", "ghostty.h")
        self.assertTrue(batch.touches("ios/cmux/App.swift", paths))
        self.assertTrue(batch.touches("ghostty", paths))
        self.assertFalse(batch.touches("ghostty-extra/file", paths))
        self.assertFalse(batch.touches("iosx/file", paths))
        self.assertFalse(batch.touches("web/app/page.tsx", paths))

    def test_missing_array_is_an_error(self):
        with self.assertRaises(ValueError):
            batch.workflow_path_filter("const somethingElse = ['ios/'];")


def git(repo, *args, when=None):
    env = dict(os.environ)
    env.update(
        GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
        GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com",
        GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
    )
    if when is not None:
        env["GIT_AUTHOR_DATE"] = env["GIT_COMMITTER_DATE"] = f"@{when} +0000"
    return subprocess.run(
        ["git", *args], cwd=repo, env=env, check=True, capture_output=True, text=True
    ).stdout.strip()


def commit_file(repo, path, when):
    target = Path(repo, path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(f"{path} {when}\n", encoding="utf-8")
    git(repo, "add", path)
    git(repo, "commit", "-q", "-m", f"change {path}", when=when)
    return git(repo, "rev-parse", "HEAD")


class HistoryTests(unittest.TestCase):
    """A main line with a merged pull request whose branch touched iOS."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = self.tmp.name
        git(self.repo, "init", "-q", "-b", "main")
        self.base = commit_file(self.repo, "ios/base.swift", NOW - 600 * 60)
        commit_file(self.repo, "web/page.tsx", NOW - 300 * 60)
        git(self.repo, "checkout", "-q", "-b", "feature")
        commit_file(self.repo, "ios/one.swift", NOW - 250 * 60)
        commit_file(self.repo, "ios/two.swift", NOW - 240 * 60)
        git(self.repo, "checkout", "-q", "main")
        commit_file(self.repo, "docs/readme.md", NOW - 100 * 60)
        git(self.repo, "merge", "-q", "--no-ff", "-m", "Merge feature", "feature",
            when=NOW - 90 * 60)
        self.merge = git(self.repo, "rev-parse", "HEAD")
        self.head = commit_file(self.repo, "Packages/iOS/x.swift", NOW - 20 * 60)

    def tearDown(self):
        self.tmp.cleanup()

    def run_main(self, *extra):
        output = Path(self.repo, "gh-output")
        summary = Path(self.repo, "gh-summary")
        output.write_text("", encoding="utf-8")
        summary.write_text("", encoding="utf-8")
        cwd = os.getcwd()
        os.chdir(self.repo)
        try:
            batch.main([
                "--event", "schedule",
                "--paths-from-workflow", str(INTERNAL),
                "--default-min-commits", "5",
                "--default-max-age-minutes", "180",
                "--output-name", "should_build",
                "--github-output", str(output),
                "--summary", str(summary),
                "--now", str(NOW),
                *extra,
            ])
        finally:
            os.chdir(cwd)
        return output.read_text(encoding="utf-8"), summary.read_text(encoding="utf-8")

    def test_public_counts_only_relevant_commits_not_old_web_or_docs(self):
        commits = batch.first_parent_commits(self.base, cwd=self.repo)
        times = batch.relevant_commit_times(commits, None, public=True)
        self.assertEqual(sorted(times), [NOW - 90 * 60, NOW - 20 * 60])
        self.assertFalse(batch.decide("schedule", times, NOW, batch.Thresholds(3, 180)).upload)
        commit_file(self.repo, "Packages/macOS/CmuxPhonePush/Push.swift", NOW - 5 * 60)
        times = batch.relevant_commit_times(batch.first_parent_commits(self.base, cwd=self.repo), None, public=True)
        self.assertTrue(batch.decide("schedule", times, NOW, batch.Thresholds(3, 180)).upload)

    def test_public_predicate_matches_executed_compare_gate(self):
        workflow = load(OFFICIAL)
        script = step(workflow["jobs"]["decide"]["steps"], "Skip an unchanged scheduled revision")["run"]
        source = script.split("import json, sys", 1)[1].split("PYCODE", 1)[0]
        module = ast.parse(textwrap.dedent(source))
        function = next(node for node in module.body if isinstance(node, ast.FunctionDef) and node.name == "unrelated")
        namespace = {}
        exec(compile(ast.Module(body=[function], type_ignores=[]), "public_compare_filter", "exec"), namespace)
        for path in ("web/app.ts", "docs/a.md", "tests/a.py", "cmuxTests/A.swift",
                     ".github/workflows/ci.yml", ".github/workflows/ios-appstore-upload.yml",
                     ".github/workflows/ios-testflight.yml", "Packages/macOS/CmuxPhonePush/A.swift",
                     "Packages/Shared/A.swift", "ios/cmux/A.swift", "scripts/install-zig-ci.sh",
                     "unknown/new-input", "", None):
            with self.subTest(path=path):
                self.assertEqual(batch.public_path_relevant(path), not namespace["unrelated"](path))

    def test_counts_first_parent_commits_with_merge_diffs(self):
        commits = batch.first_parent_commits(self.base, cwd=self.repo)
        self.assertEqual(len(commits), 4)  # web, docs, merge, Packages/iOS
        merge = next(c for c in commits if c[0] == self.merge)
        self.assertEqual(set(merge[2]), {"ios/one.swift", "ios/two.swift"})
        paths = batch.workflow_path_filter(INTERNAL.read_text(encoding="utf-8"))
        times = batch.relevant_commit_times(commits, paths)
        self.assertEqual(sorted(times), [NOW - 90 * 60, NOW - 20 * 60])
        # Without a path filter (the official lane) every main commit counts.
        self.assertEqual(len(batch.relevant_commit_times(commits, None)), 4)

    def test_control_characters_in_paths_are_not_quoted_or_split(self):
        base = git(self.repo, "rev-parse", "HEAD")
        paths = ("ios/a\nb.swift", "ios/tab\tname.swift", 'ios/quoted"name.swift', "\nroot.swift")
        for index, path in enumerate(paths):
            commit_file(self.repo, path, NOW - index * 60)
        commits = batch.first_parent_commits(base, cwd=self.repo)
        self.assertEqual({name for _, _, files in commits for name in files}, set(paths))
        self.assertEqual(len(batch.relevant_commit_times(commits, ("ios/",))), 3)

    def test_empty_commit_keeps_the_following_record_boundaries(self):
        base = git(self.repo, "rev-parse", "HEAD")
        git(self.repo, "commit", "--allow-empty", "-qm", "empty", when=NOW - 120)
        commit_file(self.repo, "ios/after.swift", NOW - 60)
        commits = batch.first_parent_commits(base, cwd=self.repo)
        self.assertEqual(len(commits), 2)
        self.assertEqual(commits[0][2], ("ios/after.swift",))
        self.assertEqual(commits[1][2], ())

    def test_end_to_end_skip_then_age_upload(self):
        output, summary = self.run_main("--base", self.base)
        self.assertEqual(output, "should_build=false\n")
        self.assertIn("skipped: 2/5 iOS commits, oldest 90/180 min", summary)
        output, summary = self.run_main("--base", self.base, "--max-age-minutes", "90")
        self.assertEqual(output, "should_build=true\n")
        self.assertIn("(age reached)", summary)
        output, _ = self.run_main("--base", self.base, "--min-commits", "2")
        self.assertEqual(output, "should_build=true\n")

    def test_no_ios_commits_since_base_skips(self):
        output, summary = self.run_main("--base", self.merge, "--head", self.merge)
        self.assertEqual(output, "should_build=false\n")
        self.assertIn("skipped: 0/5 iOS commits", summary)

    def test_unreachable_base_fails_open(self):
        output, summary = self.run_main("--base", "0" * 40)
        self.assertEqual(output, "should_build=true\n")
        self.assertIn("fail open", summary)

    def test_truncated_first_parent_history_fails_open(self):
        # The base remains reachable through the merge's second parent, so an
        # ordinary ancestor check cannot detect this truncated main history.
        boundary = git(self.repo, "rev-parse", f"{self.merge}^1")
        Path(self.repo, ".git", "shallow").write_text(boundary + "\n")
        git(self.repo, "merge-base", "--is-ancestor", self.base, self.head)
        output, summary = self.run_main("--base", self.base)
        self.assertEqual(output, "should_build=true\n")
        self.assertIn("fail open", summary)

    def test_dispatch_uploads_without_reading_history(self):
        output, summary = self.run_main("--event", "workflow_dispatch", "--base", "0" * 40)
        self.assertEqual(output, "should_build=true\n")
        self.assertIn("manual dispatch", summary)


def load(path):
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def step(steps, name):
    return next(s for s in steps if s.get("name") == name)


class WorkflowWiringTests(unittest.TestCase):
    CASES = (
        (INTERNAL, "should_build", "Batch INTERNAL uploads by iOS commit count and age",
         "IOS_TESTFLIGHT_INTERNAL_MIN_COMMITS", "IOS_TESTFLIGHT_INTERNAL_MAX_AGE_MINUTES",
         "5", "180"),
        (OFFICIAL, "upload", "Batch official uploads by commit count and age",
         "IOS_APPSTORE_MIN_COMMITS", "IOS_APPSTORE_MAX_AGE_MINUTES", "10", "360"),
    )

    def test_batch_step_uses_repo_variables_with_defaults(self):
        for path, output, name, min_var, age_var, min_default, age_default in self.CASES:
            with self.subTest(workflow=path.name):
                decide = load(path)["jobs"]["decide"]
                steps = decide["steps"]
                batch_step = step(steps, name)
                self.assertEqual(batch_step["id"], "batch")
                self.assertEqual(batch_step["env"]["MIN_COMMITS"], f"${{{{ vars.{min_var} }}}}")
                self.assertEqual(batch_step["env"]["MAX_AGE_MINUTES"], f"${{{{ vars.{age_var} }}}}")
                run = batch_step["run"]
                self.assertIn("scripts/ci/ios_upload_batch_decision.py", run)
                self.assertIn(f"--default-min-commits {min_default}", run)
                self.assertIn(f"--default-max-age-minutes {age_default}", run)
                self.assertIn(f"--output-name {output}", run)
                self.assertIn("--summary \"$GITHUB_STEP_SUMMARY\"", run)
                self.assertIn("./ios/scripts/fetch-testflight-notes-history.sh", run)
                # Scheduled polls only, and only after the existing rules said upload.
                self.assertIn("github.event_name == 'schedule'", batch_step["if"])
                self.assertIn(f"steps.decide.outputs.{output} == 'true'", batch_step["if"])
                self.assertEqual(
                    decide["outputs"][output],
                    f"${{{{ steps.batch.outputs.{output} || steps.decide.outputs.{output} }}}}",
                )
                checkout = step(steps, "Check out the upload batching policy")
                self.assertEqual(checkout["if"], batch_step["if"])
                self.assertIn("scripts/ci/ios_upload_batch_decision.py",
                              checkout["with"]["sparse-checkout"])
                self.assertEqual(checkout["with"]["filter"], "blob:none")
                self.assertFalse(checkout["with"]["persist-credentials"])

    def test_internal_batch_skips_demo_and_reuses_the_workflow_path_filter(self):
        steps = load(INTERNAL)["jobs"]["decide"]["steps"]
        batch_step = step(steps, "Batch INTERNAL uploads by iOS commit count and age")
        self.assertIn("steps.decide.outputs.variant == 'internal'", batch_step["if"])
        self.assertIn(
            "--paths-from-workflow .github/workflows/ios-testflight.yml", batch_step["run"]
        )
        self.assertIn(
            ".github/workflows/ios-testflight.yml",
            step(steps, "Check out the upload batching policy")["with"]["sparse-checkout"],
        )

    def test_official_uses_public_filter_and_unchanged_means_uploaded(self):
        steps = load(OFFICIAL)["jobs"]["decide"]["steps"]
        self.assertNotIn(
            "--paths-from-workflow",
            step(steps, "Batch official uploads by commit count and age")["run"],
        )
        self.assertIn("--public-path-filter", step(steps, "Batch official uploads by commit count and age")["run"])
        decide = step(steps, "Skip an unchanged scheduled revision")["run"]
        self.assertIn("name=cmux-app-testflight-upload", decide)
        self.assertIn(
            '[ "$LAST_SHA" = "$HEAD_SHA" ] && [ "$LAST_UPLOAD_SHA" = "$HEAD_SHA" ]', decide
        )


class BatchingFailsOpenTests(unittest.TestCase):
    """A broken batching step must fall back to the decide job, never stop uploads."""

    STEPS = {
        ".github/workflows/ios-appstore-upload.yml": (
            "Check out the upload batching policy",
            "Batch official uploads by commit count and age",
        ),
        ".github/workflows/ios-testflight.yml": (
            "Check out the upload batching policy",
            "Batch INTERNAL uploads by iOS commit count and age",
        ),
    }

    def test_batching_steps_continue_on_error(self):
        for path, names in self.STEPS.items():
            workflow = yaml.safe_load((ROOT / path).read_text(encoding="utf-8"))
            steps = [
                step
                for job in workflow["jobs"].values()
                for step in job.get("steps", [])
                if step.get("name") in names
            ]
            self.assertEqual(sorted(step["name"] for step in steps), sorted(names), path)
            for step in steps:
                self.assertIs(step.get("continue-on-error"), True, f"{path}: {step['name']}")


if __name__ == "__main__":
    unittest.main()
