"""cmux-next generated catch-up: a PR whose only conflicts with feat-cmux-next
are generated web bundles and strings tables gets the base merged in and those
files rebuilt by CI, so a landed UI PR no longer stops every other open PR."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/generated_catch_up.py"
WORKFLOW = ROOT / ".github/workflows/cmux-next-generated-catch-up.yml"


def load():
    spec = importlib.util.spec_from_file_location("generated_catch_up", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def pr(number, **overrides):
    value = {"number": number, "headRefName": f"lane-{number}", "headRefOid": f"{number:040d}",
             "isDraft": False, "isCrossRepository": False, "mergeable": "CONFLICTING"}
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


class Workflow(unittest.TestCase):
    def setUp(self):
        self.doc = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        self.text = WORKFLOW.read_text(encoding="utf-8")

    def test_runs_when_feat_cmux_next_moves(self):
        on = self.doc[True]
        self.assertEqual(on["push"]["branches"], ["feat-cmux-next"])
        self.assertIn("workflow_dispatch", on)

    def test_pushes_only_when_enabled(self):
        # Dry run until the repo variable turns it on: it logs what it would push.
        self.assertIn("vars.CMUX_NEXT_GENERATED_CATCH_UP == '1'", self.text)

    def test_the_write_token_is_contents_only_on_a_hosted_runner(self):
        job = self.doc["jobs"]["catch-up"]
        self.assertEqual(job["runs-on"], "ubuntu-24.04")
        mint = next(step for step in job["steps"] if step.get("uses", "").startswith("actions/create-github-app-token"))
        self.assertEqual(mint["with"].get("permission-contents"), "write")
        self.assertNotIn("permission-pull-requests", mint["with"])
        # The PR's code builds before the token exists.
        names = [step.get("name", "") for step in job["steps"]]
        self.assertLess(names.index("Rebuild the generated files"), names.index(mint["name"]))

    def test_classifies_with_the_base_branch_copy(self):
        self.assertIn("trusted/scripts/cmux-next/generated_catch_up.py", self.text)
        self.assertIn("trusted/.gitattributes", self.text)


if __name__ == "__main__":
    unittest.main()
