#!/usr/bin/env python3
"""The pre-push hook refuses a push whose changed workflow does not parse as YAML.

dd8b867f (2026-11-06, a direct commit to feat-cmux-next) left an unquoted colon-space in a
workflow_dispatch input description of .github/workflows/nightly.yml. GitHub could not load the
workflow, so every push made a 0-job failed run of it and no nightly built for 3.5 hours.

Each test uses the fixture of tests/test_cmux_next_prepush_gate.py (the real hook installer and the
real scripts/cmux-next checks in a throwaway repository, pushed through `git push` to a bare origin),
so the installed trusted hook copy is what runs. Manual lane: no new CI tests (CLAUDE.md); CI's
"Lint every workflow" step (actionlint) is the pull request and push backstop.
"""
# tests/git_fixture_env.py, loaded by path (`python3 -I` puts no script folder on sys.path): it drops inherited
# GIT_DIR / GIT_INDEX_FILE / GIT_CONFIG redirects and turns off git's background maintenance in temp repos.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)
import importlib.util
import os
import unittest
from pathlib import Path


def _load_gate_tests():
    """tests/test_cmux_next_prepush_gate.py by path, so `python3 -I` runs this file too."""
    path = Path(__file__).resolve().parent / "test_cmux_next_prepush_gate.py"
    spec = importlib.util.spec_from_file_location("cmux_next_prepush_gate_tests", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


gate_tests = _load_gate_tests()
# Not bound to a module name: unittest would collect PrePushGateTests here too and run its whole suite.
_fixture = gate_tests.PrePushGateTests.__dict__

WORKFLOW = ".github/workflows/nightly.yml"
DESCRIPTION = ("nightly-next only. One diagnostic notary submission of a build with exactly this one "
               "browser-import part compiled out. Leave empty to ship the import exactly as it would ship: "
               "is Apple's status 7000 hold still there?")
NIGHTLY = """name: nightly
on:
  workflow_dispatch:
    inputs:
      notary_test_import_part:
        description: {description}
        required: false
        default: ""
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
"""
# dd8b867f's shape: a plain scalar with ": " inside it is a second mapping value on one line.
BROKEN = NIGHTLY.format(description=DESCRIPTION)
QUOTED = NIGHTLY.format(description=f'"{DESCRIPTION}"')
CHANGED = QUOTED.replace("echo ok", "echo still ok")


class WorkflowYamlPushTests(unittest.TestCase):
    setUp = _fixture["setUp"]
    copy_sources = _fixture["copy_sources"]
    git = _fixture["git"]
    write = _fixture["write"]
    commit = _fixture["commit"]
    push = _fixture["push"]
    push_ref = _fixture["push_ref"]
    remote_head = _fixture["remote_head"]
    remote_head_of = _fixture["remote_head_of"]

    def base_with_workflow(self):
        """origin/feat-cmux-next carries a nightly.yml that parses."""
        self.write(WORKFLOW, QUOTED)
        self.commit("a nightly workflow that parses")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")

    def assert_refused(self, result, before, ref):
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(self.remote_head_of(ref), before, "the workflow that does not parse must not reach origin")
        self.assertIn("Workflow YAML parses", output)
        # File and line of the description (line 6 of the fixture), so the fix needs no search.
        self.assertIn(f"{WORKFLOW}:6:", output)

    def test_a_direct_push_to_feat_cmux_next_with_a_workflow_that_does_not_parse_is_refused_even_with_a_skip_reason(self):
        self.base_with_workflow()
        before = self.remote_head()
        self.write(WORKFLOW, BROKEN)
        self.commit("notary bisect input")

        result = self.push(CMUX_NEXT_CHECKS_SKIP_REASON="unrelated")

        self.assert_refused(result, before, "feat-cmux-next")
        self.assertIn("does not skip", result.stdout + result.stderr)

    def test_a_push_to_main_with_a_workflow_that_does_not_parse_is_refused(self):
        self.base_with_workflow()
        self.git("checkout", "--quiet", "-b", "main")
        first = self.push_ref("main", "--no-verify")
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.git("fetch", "--quiet", "origin")
        before = self.remote_head_of("main")
        self.write(WORKFLOW, BROKEN)
        self.commit("notary bisect input on main")

        result = self.push_ref("main")

        self.assert_refused(result, before, "main")

    def test_a_push_that_changes_a_workflow_that_still_parses_passes(self):
        self.base_with_workflow()
        self.write(WORKFLOW, CHANGED)
        self.commit("a workflow change that parses")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.remote_head(), self.git("rev-parse", "HEAD").stdout.strip())

    def test_a_later_commit_that_fixes_the_workflow_lets_the_push_through(self):
        # GitHub loads the pushed head's workflow: a broken middle commit fixed before the push is not refused.
        self.base_with_workflow()
        self.write(WORKFLOW, BROKEN)
        self.commit("broken")
        self.write(WORKFLOW, CHANGED)
        self.commit("fixed")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
