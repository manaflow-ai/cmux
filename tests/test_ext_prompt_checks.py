"""Exercise each command prompt through the cold-model checker's normal entry point."""
from __future__ import annotations

import json
import os
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts/cmux-next"
sys.path.insert(0, str(SCRIPTS))
checker = runpy.run_path(str(SCRIPTS / "ext-recipe-cold-model.py"))
PROMPTS = ROOT / "skills/cmux-extension-author/prompts"
CLOCK = ROOT / "examples/extensions/widget-clock"


def expectation(page):
    return checker["page_check"]((PROMPTS / f"{page}.md").read_text(), True)


class PromptChecks(unittest.TestCase):
    def test_successful_clock_cannot_pass_either_command_prompt(self):
        clock = subprocess.CompletedProcess([], 0, json.dumps({"scene": ["Just a clock"]}), "")
        with patch.object(subprocess, "run", return_value=clock):
            for page in ("palette-command", "composer-slash-command"):
                with self.subTest(page=page):
                    result = checker["check"](CLOCK, expectation(page), False, True, prompts=True)
                    self.assertFalse(result["passed"], result)
                    self.assertEqual(result["exitCode"], 0)

    def test_no_daemon_retries_headless_and_checks_the_command(self):
        results = [subprocess.CompletedProcess([], code, "{}", "") for code in (3, 0)]
        with patch.object(subprocess, "run", side_effect=results) as run:
            result = checker["check"](CLOCK, expectation("composer-slash-command"), True, False, prompts=True)
        self.assertIn("--headless", run.call_args.args[0])
        self.assertFalse(result["passed"])

    def test_a_prompt_must_declare_observable_behavior(self):
        for page in PROMPTS.glob("*.md"):
            if page.name != "README.md":
                expectation(page.stem)
        for directive in ("loads", "something-new", ""):
            with self.subTest(directive=directive), self.assertRaises(ValueError):
                checker["page_check"](f"<!-- prompt-check: {directive} -->", True)
        self.assertEqual(checker["page_check"]("<!-- recipe-check: loads -->", False), "loads")

    @unittest.skipUnless(os.environ.get("CMUX_TEST_PROMPT_CLI"), "requires the PR's cmux CLI")
    def test_built_cli_manifest_only_composer_and_unrelated_clock(self):
        with tempfile.TemporaryDirectory() as root:
            folder = Path(root)
            commands = [{"name": "review", "description": "Review my changes",
                         "insert": "Review the changes on this branch: what could break, "
                                   "what is missing a test, and what you would rename."}]
            manifest = {
                "manifestVersion": 2, "id": "local/prompt-review", "name": "Review",
                "description": "Review a branch", "version": "1.0.0", "engines": {"cmux": "^2.0"},
                "implements": {"cmux.composer.command/1": {"title": "Review", "options": {"commands": commands}}},
            }
            (folder / "cmux-app.json").write_text(json.dumps(manifest))
            report = checker["check"](folder, expectation("composer-slash-command"), False, True, prompts=True)
            self.assertTrue(report["passed"], report)
            clock = folder / "clock"
            shutil.copytree(CLOCK, clock, ignore=shutil.ignore_patterns("node_modules", "dist"))
            for page in ("palette-command", "composer-slash-command"):
                with self.subTest(page=page):
                    report = checker["check"](clock, expectation(page), False, True, prompts=True)
                    self.assertEqual(report["exitCode"], 0, report)
                    self.assertFalse(report["passed"], report)


if __name__ == "__main__":
    unittest.main()
