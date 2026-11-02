"""cmux-next generated catch-up: a PR whose only conflicts with feat-cmux-next
are generated web bundles and strings tables gets the base merged in and those
files rebuilt by CI, so a landed UI PR no longer stops every other open PR."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/generated_catch_up.py"
# The trusted key-wise drivers .gitattributes names (scripts/install-git-hooks.sh registers them per clone).
KEYWISE_DRIVERS = {
    "xcstrings-v2": "scripts/merge-xcstrings.py",
    "pbxproj-v1": "scripts/merge-pbxproj.py",
    "cmux-baseline-v1": "scripts/merge-baseline.py",
    "cmux-capabilities-v1": "scripts/merge-daemon-capabilities.py",
}
WORKFLOW = ROOT / ".github/workflows/cmux-next-generated-catch-up.yml"


def load():
    spec = importlib.util.spec_from_file_location("generated_catch_up", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def pr(number, **overrides):
    value = {"number": number, "headRefName": f"lane-{number}", "headRefOid": f"{number:040d}",
             "isDraft": False, "isCrossRepository": False, "mergeable": "CONFLICTING",
             "author": {"login": "teamleaderleo"}, "labels": []}
    value.update(overrides)
    return value


class GeneratedPaths(unittest.TestCase):
    def setUp(self):
        self.catch_up = load()
        self.patterns = self.catch_up.generated_patterns((ROOT / ".gitattributes").read_text(encoding="utf-8"))

    def test_the_bundles_and_strings_tables_are_generated(self):
        for path in (
            "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/pane.js",
            "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/locales/zh-Hant.js",
            "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages/settings/index.html",
            "Resources/markdown-viewer/webviews-app/chunks/vendor.mjs",
            "webviews/src/agent-session/acpmux/generated/strings.json",
            "webviews/src/pages/settings/generated/strings.json",
        ):
            self.assertTrue(self.catch_up.is_generated(path, self.patterns), path)

    def test_sources_and_catalogs_are_not(self):
        for path in (
            "webviews/src/agent-session/acpmux/App.tsx",
            "webviews/src/agent-session/acpmux/Localizable.xcstrings",
            "webviews/src/protocol/generated/types.ts",
            "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AgentPaneModel.swift",
            ".gitattributes",
        ):
            self.assertFalse(self.catch_up.is_generated(path, self.patterns), path)

    def test_one_authored_conflict_leaves_the_pr_alone(self):
        unmerged = ["webviews/src/pages/settings/generated/strings.json", "webviews/src/agent-session/acpmux/App.tsx"]
        self.assertEqual(self.catch_up.authored(unmerged, self.patterns), ["webviews/src/agent-session/acpmux/App.tsx"])
        self.assertEqual(self.catch_up.authored(unmerged[:1], self.patterns), [])


class Selection(unittest.TestCase):
    def setUp(self):
        self.catch_up = load()

    def test_only_same_repo_ready_conflicting_prs_are_caught_up(self):
        prs = [pr(1), pr(2, isDraft=True), pr(3, isCrossRepository=True), pr(4, mergeable="MERGEABLE"), pr(5)]
        chosen = self.catch_up.select(prs, limit=10)
        self.assertEqual([item["number"] for item in chosen], [1, 5])
        self.assertEqual(chosen[0], {"number": 1, "branch": "lane-1", "sha": f"{1:040d}"})

    def test_fan_out_is_capped(self):
        chosen = self.catch_up.select([pr(n) for n in range(1, 30)], limit=6)
        self.assertEqual(len(chosen), 6)

    def test_main_is_never_a_head(self):
        self.assertEqual(self.catch_up.select([pr(1, headRefName="main")], limit=10), [])

    def test_only_leos_agent_prs_or_an_opted_in_pr_are_pushed_to(self):
        # The rulebook: never push to a teammate's PR without Leo's OK (2026-10-21). Leo's agents act as
        # teamleaderleo; anyone else opts in with the generated-catch-up label.
        prs = [pr(1), pr(2, author={"login": "lawrencecchen"}), pr(3, author={"login": "austinywang"},
               labels=[{"name": "generated-catch-up"}]), pr(4, author=None), pr(5, author={"login": "TeamLeaderLeo"})]
        self.assertEqual([item["number"] for item in self.catch_up.select(prs, limit=10)], [1, 3, 5])

    def test_the_listing_reads_author_and_labels(self):
        calls = []

        class Done:
            stdout = "[]"

        def run(args, **kwargs):
            calls.append(args)
            return Done()

        original = self.catch_up.subprocess.run
        self.catch_up.subprocess.run = run
        try:
            self.catch_up._list("manaflow-ai/cmux", "feat-cmux-next")
        finally:
            self.catch_up.subprocess.run = original
        fields = calls[0][calls[0].index("--json") + 1].split(",")
        self.assertIn("author", fields)
        self.assertIn("labels", fields)


class MergeabilityWait(unittest.TestCase):
    """UNKNOWN on a PR we cannot touch never warrants a 20-100 second wait."""

    def setUp(self):
        self.catch_up = load()

    def choose(self, replies):
        output = io.StringIO()
        with patch.object(self.catch_up, "_list", side_effect=replies) as listed, \
             patch.object(self.catch_up.time, "sleep") as sleep, \
             contextlib.redirect_stdout(output):
            code = self.catch_up.main(["select", "--repo", "manaflow-ai/cmux"])
        self.assertEqual(code, 0)
        return json.loads(output.getvalue()), listed.call_count, sleep.call_args_list

    def test_unknown_unowned_fork_draft_and_base_head_do_not_delay_selection(self):
        unknown = [
            pr(1, mergeable="UNKNOWN", author={"login": "someone-else"}),
            pr(2, mergeable="UNKNOWN", isCrossRepository=True),
            pr(3, mergeable="UNKNOWN", isDraft=True),
            pr(4, mergeable="UNKNOWN", headRefName="feat-cmux-next"),
            pr(5, mergeable="MERGEABLE"),
        ]
        chosen, reads, sleeps = self.choose([unknown])
        self.assertEqual(chosen, [])
        self.assertEqual(reads, 1)
        self.assertEqual(sleeps, [])

    def test_unknown_opted_in_head_still_waits_for_github_mergeability(self):
        first = [pr(7, mergeable="UNKNOWN"),
                 pr(8, mergeable="UNKNOWN", author={"login": "someone-else"})]
        second = [pr(7, mergeable="CONFLICTING"), first[1]]
        chosen, reads, sleeps = self.choose([first, second])
        self.assertEqual([item["number"] for item in chosen], [7])
        self.assertEqual(reads, 2)
        self.assertEqual(len(sleeps), 1)
        self.assertEqual(sleeps[0].args, (self.catch_up.MERGEABLE_POLL_SECONDS,))


class Workflow(unittest.TestCase):
    def setUp(self):
        self.doc = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        self.text = WORKFLOW.read_text(encoding="utf-8")

    def test_no_step_truncates_a_pipe_under_pipefail(self):
        """`git show --stat | head -40` under pipefail exits 141 (SIGPIPE) once a merge lists more
        than 40 lines, failing every catch-up job after a good merge (run 37584353594)."""
        for job in self.doc["jobs"].values():
            for step in job.get("steps", []):
                script = step.get("run", "")
                if "pipefail" in script:
                    with self.subTest(step=step.get("name")):
                        self.assertNotRegex(script, r"\|\s*head\b")

    def test_runs_when_feat_cmux_next_moves(self):
        on = self.doc[True]
        self.assertEqual(on["push"]["branches"], ["feat-cmux-next"])
        self.assertIn("workflow_dispatch", on)

    def test_a_newer_move_does_not_cancel_a_running_catch_up(self):
        """feat-cmux-next moves every few minutes and a catch-up job takes up to 20, so
        cancel-in-progress cancelled 38 of the last 40 runs (2026-10-20) and no conflicting
        PR was ever caught up. One run finishes; GitHub keeps only the newest pending one."""
        concurrency = self.doc["concurrency"]
        self.assertEqual(concurrency["group"], "cmux-next-generated-catch-up")
        self.assertIs(concurrency["cancel-in-progress"], False)

    def test_pushes_only_when_enabled(self):
        # Dry run until the repo variable turns it on: it logs what it would push.
        self.assertIn("vars.CMUX_NEXT_GENERATED_CATCH_UP == '1'", self.text)

    def test_the_write_token_is_contents_only_on_an_ephemeral_runner(self):
        job = self.doc["jobs"]["catch-up"]
        # A Blacksmith VM runs one job and is destroyed; no variable can move
        # the write token to a reused mini.
        self.assertEqual(job["runs-on"], "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-8vcpu-ubuntu-2404' || 'blacksmith-2vcpu-ubuntu-2404' }}")
        mint = next(step for step in job["steps"] if step.get("uses", "").startswith("actions/create-github-app-token"))
        self.assertEqual(mint["with"].get("permission-contents"), "write")
        self.assertNotIn("permission-pull-requests", mint["with"])
        # The PR's code builds before the token exists.
        names = [step.get("name", "") for step in job["steps"]]
        self.assertLess(names.index("Rebuild the generated files"), names.index(mint["name"]))

    def test_classifies_with_the_base_branch_copy(self):
        self.assertIn("trusted/scripts/cmux-next/generated_catch_up.py", self.text)
        self.assertIn("trusted/.gitattributes", self.text)


class SelectiveCheckout(unittest.TestCase):
    """A catch-up needs the PR head, base tip and common ancestor, not every remote branch."""

    def test_checkout_fetches_only_the_needed_history(self):
        doc = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        steps = doc["jobs"]["catch-up"]["steps"]
        checkout = next(s for s in steps if s.get("name") == "Check out the pull request")
        self.assertEqual(checkout["with"]["fetch-depth"], 1)
        self.assertEqual(checkout["with"]["filter"], "blob:none")
        self.assertEqual(checkout["with"]["ref"], "${{ matrix.pr.sha }}")
        fetch = next(s for s in steps if s.get("name") == "Fetch just the PR and base ancestry")
        self.assertLess(steps.index(checkout), steps.index(fetch))
        self.assertLess(steps.index(fetch),
                        next(i for i, s in enumerate(steps) if s.get("name") == "Merge feat-cmux-next"))
        self.assertIn('--filter=blob:none --unshallow origin "$BASE_SHA"', fetch["run"])
        self.assertIn('git merge-base HEAD "$BASE_SHA"', fetch["run"])
        self.assertIn('"$(git rev-parse HEAD)" == "$HEAD_SHA"', fetch["run"])
        merge = next(s for s in steps if s.get("name") == "Merge feat-cmux-next")["run"]
        self.assertNotIn('git fetch --quiet origin "$BASE_SHA"', merge)

    def test_unshallowing_one_base_sha_keeps_the_merge_base_without_other_refs(self):
        def git(cwd, *args):
            result = subprocess.run(["git", "-C", str(cwd), *args],
                                    capture_output=True, text=True, check=True)
            return result.stdout.strip()

        with tempfile.TemporaryDirectory(prefix="catch-up-refs-") as tmp:
            root = Path(tmp)
            remote = root / "origin.git"
            git(root, "init", "--quiet", "--bare", str(remote))
            git(remote, "config", "uploadpack.allowFilter", "true")
            maker = root / "maker"
            git(root, "clone", "-q", f"file://{remote}", str(maker))
            git(maker, "config", "user.name", "CI")
            git(maker, "config", "user.email", "ci@example.org")
            (maker / "shared").write_text("common\\n")
            git(maker, "add", ".")
            git(maker, "commit", "-qm", "common")
            git(maker, "branch", "-M", "feat-cmux-next")
            git(maker, "push", "-q", "origin", "feat-cmux-next")
            git(maker, "checkout", "-qb", "lane")
            (maker / "pr-change").write_text("one\\n")
            git(maker, "add", ".")
            git(maker, "commit", "-qm", "PR")
            head = git(maker, "rev-parse", "HEAD")
            git(maker, "push", "-q", "origin", "lane")
            git(maker, "checkout", "-q", "feat-cmux-next")
            (maker / "base-change").write_text("two\\n")
            git(maker, "add", ".")
            git(maker, "commit", "-qm", "base")
            base = git(maker, "rev-parse", "HEAD")
            git(maker, "push", "-q", "origin", "feat-cmux-next")
            for i in range(8):
                git(maker, "branch", f"irrelevant-{i}")
                git(maker, "push", "-q", "origin", f"irrelevant-{i}")

            checkout = root / "pr"
            git(root, "init", "-q", str(checkout))
            git(checkout, "remote", "add", "origin", f"file://{remote}")
            git(checkout, "fetch", "-q", "--depth=1", "--filter=blob:none", "origin", head)
            git(checkout, "checkout", "-q", "--detach", head)
            git(checkout, "config", "user.name", "CI")
            git(checkout, "config", "user.email", "ci@example.org")
            git(checkout, "fetch", "-q", "--no-tags", "--filter=blob:none", "--unshallow", "origin", base)
            self.assertEqual(len(git(checkout, "merge-base", "HEAD", base)), 40)
            self.assertEqual(git(checkout, "rev-parse", "HEAD"), head)
            self.assertEqual(git(checkout, "for-each-ref", "--format=%(refname)",
                                 "refs/remotes/origin"), "")
            git(checkout, "merge", "--no-commit", "--no-ff", base)
            self.assertTrue((checkout / "base-change").is_file())
            self.assertTrue((checkout / "pr-change").is_file())


class KeyWiseDrivers(unittest.TestCase):
    """GitHub ignores merge drivers, so a string catalog or a ratchet baseline that two PRs both add
    entries to conflicts for every other open PR (2026-10-20/21: acpmux/Localizable.xcstrings 101
    conflicting merges, 1 with the driver). The catch-up merges with the base's trusted key-wise
    drivers, so a conflict they resolve is no conflict, and only a real one is left to the author."""

    def setUp(self):
        self.doc = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        self.steps = self.doc["jobs"]["catch-up"]["steps"]

    def step(self, name: str) -> dict:
        return next(step for step in self.steps if step.get("name") == name)

    def test_every_keywise_driver_in_gitattributes_is_registered_from_the_base(self):
        named = set(re.findall(r"merge=([\w.-]+)", (ROOT / ".gitattributes").read_text(encoding="utf-8")))
        self.assertEqual(named - {"cmux-generated-v1"}, set(KEYWISE_DRIVERS))
        trusted = self.step("Check out the base's catch-up script")["with"]["sparse-checkout"].split()
        script = self.step("Merge feat-cmux-next")["run"]
        for driver, path in KEYWISE_DRIVERS.items():
            with self.subTest(driver=driver):
                self.assertIn(path, trusted)
                self.assertIn(f"merge.{driver}.driver", script)
                # Never the pull request's own copy: it runs with the merge's files.
                self.assertIn(f"$trusted/{path}", script)
        self.assertIn('trusted="$(cd ../trusted && pwd)"', script)

    def test_every_helper_the_drivers_load_from_beside_them_is_checked_out_too(self):
        # merge-pbxproj.py loads scripts/ci/merge_main_resolver.py and scripts/normalize-pbxproj.py from its own
        # tree; without them it exits 1 and turns a clean pbxproj text merge into a conflict (review of #23868).
        # scripts/install-git-hooks.sh installs the same set beside the drivers in every clone.
        hooks = (ROOT / "scripts/install-git-hooks.sh").read_text(encoding="utf-8")
        installed = set(re.findall(r'^install -m \d+ (scripts/\S+) "\$MERGE_DRIVER_DIR/', hooks, re.M))
        self.assertTrue(set(KEYWISE_DRIVERS.values()) <= installed, installed)
        trusted = set(self.step("Check out the base's catch-up script")["with"]["sparse-checkout"].split())
        self.assertEqual(installed - trusted, set())

    def test_driver_commands_quote_the_trusted_path(self):
        script = self.step("Merge feat-cmux-next")["run"]
        for driver in KEYWISE_DRIVERS:
            with self.subTest(driver=driver):
                self.assertRegex(script, rf'git config merge\.{re.escape(driver)}\.driver "\$\w+"')

    def git(self, cwd: Path, *args: str) -> str:
        return subprocess.run(["git", "-C", str(cwd), "-c", "user.name=t", "-c", "user.email=t@t",
                               "-c", "commit.gpgsign=false", *args],
                              check=True, capture_output=True, text=True).stdout.strip()

    def catalog(self, *keys: str) -> str:
        strings = {key: {"localizations": {"en": {"stringUnit": {"state": "translated", "value": key}}}}
                   for key in keys}
        return json.dumps({"sourceLanguage": "en", "strings": strings, "version": "1.0"}, indent=2) + "\n"

    def test_a_catalog_both_sides_added_keys_to_merges_without_a_conflict(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        trusted = tmp / "trusted"
        for path in [*KEYWISE_DRIVERS.values(), "scripts/cmux-next/generated_catch_up.py", ".gitattributes"]:
            (trusted / path).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT / path, trusted / path)
        repo = tmp / "pr"
        repo.mkdir()
        self.git(repo, "init", "-q", "-b", "feat-cmux-next")
        (repo / ".gitattributes").write_text("*.xcstrings merge=xcstrings-v2\n")
        (repo / "Localizable.xcstrings").write_text(self.catalog("a", "m", "z"))
        self.git(repo, "add", "-A")
        self.git(repo, "commit", "-qm", "base")
        self.git(repo, "checkout", "-qb", "lane")
        (repo / "Localizable.xcstrings").write_text(self.catalog("a", "lane", "m", "z"))
        self.git(repo, "commit", "-qam", "lane adds a key")
        self.git(repo, "checkout", "-q", "feat-cmux-next")
        (repo / "Localizable.xcstrings").write_text(self.catalog("a", "base", "m", "z"))
        self.git(repo, "commit", "-qam", "base adds a key")
        base = self.git(repo, "rev-parse", "HEAD")
        self.git(repo, "checkout", "-q", "lane")
        self.git(repo, "remote", "add", "origin", str(repo))
        output = tmp / "output"
        output.touch()
        env = {"PATH": os.environ["PATH"], "HOME": str(tmp), "BASE_SHA": base, "BRANCH": "lane", "PR_NUMBER": "7",
               "GITHUB_OUTPUT": str(output), "GITHUB_STEP_SUMMARY": str(tmp / "summary"), "RUNNER_TEMP": str(tmp),
               "GIT_CONFIG_GLOBAL": str(tmp / "gitconfig"), "GIT_CONFIG_NOSYSTEM": "1"}
        (tmp / "gitconfig").write_text("[user]\n\tname = t\n\temail = t@t\n[commit]\n\tgpgsign = false\n")
        result = subprocess.run(["bash", "-e", "-c", self.step("Merge feat-cmux-next")["run"]], cwd=repo, env=env,
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("skip=false", output.read_text())
        self.assertEqual(self.git(repo, "diff", "--name-only", "--diff-filter=U"), "")
        merged = json.loads((repo / "Localizable.xcstrings").read_text())
        self.assertEqual(sorted(merged["strings"]), ["a", "base", "lane", "m", "z"])


if __name__ == "__main__":
    unittest.main()
