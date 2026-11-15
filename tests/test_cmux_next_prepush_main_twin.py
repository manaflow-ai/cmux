#!/usr/bin/env python3
"""The pre-push hook refuses a feat-cmux-next push that changes the production journey workflow's jobs without main.

The production journey's schedule registers from main, so main's copy of .github/workflows/cloud-journey-prod.yml is
what runs; only the scripts come from feat-cmux-next. cmux#43781 (2026-11-15) added --preclaim-login to
feat-cmux-next's copy only, and production never ran it until cmux#43866 brought main's copy along.

Each test uses the fixture of tests/test_cmux_next_prepush_gate.py (the real hook installer and the real
scripts/cmux-next checks in a throwaway repository, pushed through `git push` to a bare origin). Manual lane: no new
CI tests (CLAUDE.md; Lawrence, 2026-10-23); hq's NOW names a standing difference between the two copies.
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

WORKFLOW = ".github/workflows/cloud-journey-prod.yml"
JOURNEY = """name: Cloud journey (production)
on:
  workflow_dispatch:
jobs:
  journey:
    runs-on: ubuntu-latest
{environment}
    steps:
      # Run the journey.
      - run: bun scripts/cmux-next/cloud-journey.ts --backend prod{flags}
"""
# feat-cmux-next's environment form and main's: one setting, never a difference on their own.
FEAT_ENV = "    environment:\n      name: cmux-next-cloud-journey\n      deployment: false"
MAIN_ENV = "    environment: cmux-next-cloud-journey"
FEAT = JOURNEY.format(environment=FEAT_ENV, flags="")
MAIN = JOURNEY.format(environment=MAIN_ENV, flags="")
FEAT_NEW_FLAG = JOURNEY.format(environment=FEAT_ENV, flags=" --preclaim-login cmux-tui")
FEAT_COMMENT = FEAT.replace("# Run the journey.", "# Run the production journey.")


class MainTwinPushTests(unittest.TestCase):
    setUp = _fixture["setUp"]
    copy_sources = _fixture["copy_sources"]
    git = _fixture["git"]
    write = _fixture["write"]
    commit = _fixture["commit"]
    push = _fixture["push"]
    push_ref = _fixture["push_ref"]
    remote_head = _fixture["remote_head"]

    def base_with_twins(self, feat=FEAT, main=MAIN):
        """origin/feat-cmux-next and origin/main each carry their copy of the journey workflow."""
        self.write(WORKFLOW, feat)
        self.commit("feat-cmux-next's journey workflow")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("checkout", "--quiet", "-b", "main")
        self.write(WORKFLOW, main)
        self.commit("main's journey workflow")
        self.assertEqual(self.push_ref("main", "--no-verify").returncode, 0)
        self.git("checkout", "--quiet", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")

    def test_a_job_change_main_lacks_is_refused_and_names_the_twin_pr_to_open(self):
        self.base_with_twins()
        before = self.remote_head()
        self.write(WORKFLOW, FEAT_NEW_FLAG)
        self.commit("journey: copy the login on spare.ready")

        result = self.push()

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(self.remote_head(), before, "a change production never runs must not reach origin")
        self.assertIn("Production journey workflow matches main's", output)
        self.assertIn("gh pr create --base main", output)
        self.assertIn("Main-Twin:", output)

    def test_a_main_twin_trailer_lets_the_change_through(self):
        self.base_with_twins()
        self.write(WORKFLOW, FEAT_NEW_FLAG)
        self.commit("journey: copy the login on spare.ready\n\nMain-Twin: https://github.com/manaflow-ai/cmux/pull/1")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.remote_head(), self.git("rev-parse", "HEAD").stdout.strip())

    def test_a_comment_only_change_passes(self):
        self.base_with_twins()
        self.write(WORKFLOW, FEAT_COMMENT)
        self.commit("journey: a clearer comment")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_runner_only_change_passes(self):
        # main pins the secret-holding job to a literal label; feat-cmux-next runs it from the pool (cmux#43866).
        self.base_with_twins()
        self.write(WORKFLOW, FEAT.replace("runs-on: ubuntu-latest", "runs-on: ${{ fromJSON(vars.RUNNER_POOLS).linux_8 }}"))
        self.commit("journey: run from the pool")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_change_that_brings_feat_back_to_main_passes(self):
        # feat-cmux-next had drifted (the flag main lacked); a push that undoes it matches main and needs no twin.
        self.base_with_twins(feat=FEAT_NEW_FLAG)
        self.write(WORKFLOW, FEAT)
        self.commit("journey: match main again")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_change_main_already_has_passes(self):
        # The twin landed on main first: feat-cmux-next's push makes the two copies' jobs match.
        self.base_with_twins(main=JOURNEY.format(environment=MAIN_ENV, flags=" --preclaim-login cmux-tui"))
        self.write(WORKFLOW, FEAT_NEW_FLAG)
        self.commit("journey: copy the login on spare.ready (main has it)")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
