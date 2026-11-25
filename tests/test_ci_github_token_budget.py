#!/usr/bin/env python3
"""scripts/ci/github_token_budget_lint.py lists every step that spends the repository GITHUB_TOKEN and warns,
never fails, on one with no line in .github/github-token-budget.json."""

from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import github_token_budget_lint as lint  # noqa: E402
from github_token_polling import Scripts  # noqa: E402

OWN = "${{ github.token }}"


def spends(step: dict, job: dict | None = None, workflow: dict | None = None, scripts: Scripts | None = None) -> bool:
    return lint.step_spends(step, job or {}, workflow or {}, scripts)


class StepDetection(unittest.TestCase):
    def test_gh_and_curl_with_the_own_token(self):
        self.assertTrue(spends({"run": "gh pr view 1", "env": {"GH_TOKEN": OWN}}))
        self.assertTrue(spends({"run": 'curl -H "Authorization: Bearer $GITHUB_TOKEN" "$GITHUB_API_URL/repos/o/r"',
                                "env": {"GITHUB_TOKEN": "${{ secrets.GITHUB_TOKEN }}"}}))
        # The token is set on the job, the call on the step.
        self.assertTrue(spends({"run": "gh api rate_limit"}, {"env": {"GH_TOKEN": OWN}}))

    def test_another_token_or_no_call_does_not_count(self):
        self.assertFalse(spends({"run": "gh pr view 1", "env": {"GH_TOKEN": "${{ steps.app.outputs.token }}"}}))
        self.assertFalse(spends({"run": "echo hi", "env": {"GH_TOKEN": OWN}}))
        self.assertFalse(spends({"run": "gh pr view 1"}))  # gh has no token at all
        # An inner scope's App token hides the workflow's github.token.
        self.assertFalse(spends({"run": "gh pr view 1", "env": {"GH_TOKEN": "${{ secrets.APP }}"}},
                                {}, {"env": {"GH_TOKEN": OWN}}))

    def test_an_app_token_with_a_github_token_fallback_counts(self):
        self.assertTrue(spends({"run": "gh pr view 1",
                                "env": {"GH_TOKEN": "${{ steps.app.outputs.token || github.token }}"}}))

    def test_a_script_reading_its_own_env_name_counts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "scripts").mkdir()
            (root / "scripts" / "x.py").write_text(
                "import os, urllib.request\nurllib.request.urlopen('https://api.github.com/rate_limit')\n")
            (root / "scripts" / "quiet.py").write_text("print('no api')\n")
            (root / "scripts" / "alias.py").write_text(
                "import urllib.request\ndef read(path, opener=urllib.request.urlopen):\n    return opener(path)\n")
            scripts = Scripts(root)
            self.assertTrue(spends({"run": "python3 scripts/x.py", "env": {"BUDGET_TOKEN": OWN}}, scripts=scripts))
            self.assertFalse(spends({"run": "python3 scripts/quiet.py", "env": {"BUDGET_TOKEN": OWN}}, scripts=scripts))
            self.assertFalse(spends({"run": "python3 scripts/x.py", "env": {"BUDGET_TOKEN": "${{ secrets.X }}"}},
                                    scripts=scripts))
            # A callable bound to urlopen through a parameter default is an API call too.
            self.assertTrue(spends({"run": "python3 -I scripts/alias.py", "env": {"GH_TOKEN": OWN}}, scripts=scripts))

    def test_python_shell_and_heredocs(self):
        self.assertTrue(spends({"shell": "python", "env": {"GH_TOKEN": OWN},
                                "run": "import subprocess\nsubprocess.run(['gh', 'api', 'x'])\n"}))
        heredoc = "python3 - <<'PY'\nimport subprocess\nsubprocess.run(['gh', 'api', 'x'])\nPY\n"
        self.assertTrue(spends({"run": heredoc, "env": {"GH_TOKEN": OWN}}))
        # A workflow-level `defaults.run.shell: python` makes the step Python too.
        self.assertTrue(spends({"env": {"GH_TOKEN": OWN}, "run": "import subprocess\nsubprocess.run(['gh', 'api', 'x'])\n"},
                               {}, {"defaults": {"run": {"shell": "python"}}}))

    def test_github_script(self):
        script = {"uses": "actions/github-script@v7", "with": {"script": "await github.rest.pulls.get({})"}}
        self.assertTrue(spends(script))
        self.assertTrue(spends({**script, "with": {**script["with"], "github-token": OWN}}))
        self.assertFalse(spends({**script, "with": {**script["with"], "github-token": "${{ steps.app.outputs.token }}"}}))
        self.assertFalse(spends({"uses": "actions/github-script@v7", "with": {"script": "core.info('x')"}}))

    def test_api_calling_actions(self):
        self.assertTrue(spends({"uses": "actions/download-artifact@v4", "with": {"run-id": "1", "github-token": OWN}}))
        self.assertFalse(spends({"uses": "actions/download-artifact@v4", "with": {"name": "x"}}))  # this run's
        self.assertFalse(spends({"uses": "actions/download-artifact@v4",
                                 "with": {"run-id": "1", "github-token": "${{ steps.app.outputs.token }}"}}))
        self.assertTrue(spends({"uses": "dorny/paths-filter@v3", "with": {"filters": "x"}}))
        self.assertFalse(spends({"uses": "dorny/paths-filter@v3", "with": {"token": "${{ secrets.X }}"}}))
        self.assertTrue(spends({"uses": "actions/attest-build-provenance@v2", "with": {"subject-path": "x"}}))
        self.assertTrue(spends({"uses": "manaflow-ai/cla-github-action@v1",
                                "env": {"GITHUB_TOKEN": "${{ secrets.GITHUB_TOKEN }}"}}))
        self.assertFalse(spends({"uses": "actions/checkout@v6"}))
        self.assertFalse(spends({"uses": "actions/upload-artifact@v4"}))


class Lint(unittest.TestCase):
    def tree(self, workflow: str, budget: dict) -> tuple[Path, Path]:
        holder = tempfile.TemporaryDirectory()
        self.addCleanup(holder.cleanup)
        tmp = Path(holder.name)
        (tmp / ".github" / "workflows").mkdir(parents=True)
        (tmp / ".github" / "workflows" / "w.yml").write_text(textwrap.dedent(workflow))
        (tmp / ".github" / "github-token-budget.json").write_text(json.dumps({"steps": budget}))
        return tmp / ".github" / "workflows", tmp / ".github" / "github-token-budget.json"

    WORKFLOW = """
        on: push
        jobs:
          a:
            runs-on: ubuntu-24.04
            env:
              GH_TOKEN: ${{ github.token }}
            steps:
              - name: Read the PR
                run: gh pr view 1
              - name: New reader
                run: gh run list
              - name: Quiet
                run: echo hi
        """

    def run_main(self, workflows: Path, budget: Path) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = lint.main(["--workflows", str(workflows), "--budget", str(budget)])
        return code, out.getvalue()

    def test_an_unbudgeted_step_warns_and_never_fails(self):
        workflows, budget = self.tree(self.WORKFLOW, {"w.yml: Read the PR": "one read", "w.yml: Gone": "old"})
        self.assertEqual(lint.spending_steps(workflows), ["w.yml: New reader", "w.yml: Read the PR"])
        code, out = self.run_main(workflows, budget)
        self.assertEqual(code, 0)
        warnings = [line for line in out.splitlines() if line.startswith("::warning")]
        self.assertEqual(len(warnings), 1, out)
        self.assertTrue(warnings[0].startswith("::warning file=.github/workflows/w.yml,title=GITHUB_TOKEN budget::"
                                               "w.yml: New reader calls the GitHub API"))
        self.assertIn("github-token-budget.json", warnings[0])
        self.assertIn("no longer spends the token (drop its line from", out)
        self.assertIn("w.yml: Gone", out)

    def test_a_fully_budgeted_tree_is_quiet(self):
        workflows, budget = self.tree(self.WORKFLOW, {"w.yml: Read the PR": "x", "w.yml: New reader": "y"})
        code, out = self.run_main(workflows, budget)
        self.assertEqual(code, 0)
        self.assertNotIn("::warning", out)

    def test_a_broken_budget_file_warns_and_exits_zero(self):
        workflows, budget = self.tree(self.WORKFLOW, {})
        budget.write_text("{not json")
        code, out = self.run_main(workflows, budget)
        self.assertEqual(code, 0)
        self.assertIn("::warning title=GITHUB_TOKEN budget::the budget lint could not run", out)
        self.assertEqual(len([l for l in out.splitlines() if "could not run" in l]), 1)


class Repository(unittest.TestCase):
    def test_the_budget_file_parses_and_every_line_has_a_reason(self):
        budget = lint.load_budget(lint.BUDGET)
        self.assertTrue(budget)
        for key, reason in budget.items():
            with self.subTest(key=key):
                self.assertRegex(key, r"^[\w.-]+\.ya?ml: .+")
                self.assertTrue(reason.strip())

    def test_every_polling_step_is_also_a_spending_step(self):
        from github_token_polling import polling_steps
        found = set(lint.spending_steps(lint.WORKFLOWS))
        self.assertEqual([k for k in polling_steps(lint.WORKFLOWS) if k not in found], [])

    def test_the_checks_job_runs_the_lint_warn_only(self):
        import yaml
        workflow = yaml.safe_load((ROOT / ".github" / "workflows" / "cmux-next.yml").read_text(encoding="utf-8"))
        steps = [s for s in workflow["jobs"]["checks"]["steps"] if "github_token_budget_lint.py" in str(s.get("run", ""))]
        self.assertEqual(len(steps), 1)
        self.assertIs(steps[0].get("continue-on-error"), True)
        self.assertIn("python3 tests/test_ci_github_token_budget.py", steps[0]["run"])


if __name__ == "__main__":
    unittest.main()
