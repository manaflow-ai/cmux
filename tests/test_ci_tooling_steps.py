#!/usr/bin/env python3
"""tooling-tests runs a step only when the pull request's diff reaches a test it runs, and fails open otherwise.

Leo, 2026-11-19: "only meaningful tests ... not just there for ticky tack". scripts/ci/tooling_steps.py, run by
cmux-next guards / tooling-tests' own setup-tooling-route step on the merge commit's diff, picks the tooling-tests steps whose tests read a changed
file (workflow_paths_cover_inputs.Walker's closure). These check, on a fixture repository, that a change to one
step's test input selects that step only, that a step with an input nobody can resolve always runs, and that a
change to the workflow or the router, or a non-pull-request event, runs every step. Against the real
cmux-next-guards.yml they check that every run step of tooling-tests is a setup step or carries the selection
condition with its own id, so a new step can be neither left out of the selection nor skipped by it.

    python3 -m unittest tests/test_ci_tooling_steps.py
"""
from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import tooling_steps  # noqa: E402

# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
_spec = importlib.util.spec_from_file_location("git_fixture_env", os.path.join(os.path.dirname(
    os.path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(git_fixture_env)

WORKFLOW = ".github/workflows/guards.yml"
FIXTURE_WORKFLOW = """\
on: [pull_request, push]
env:
  BASH_ENV: ${GITHUB_WORKSPACE:-/nonexistent}/scripts/env.sh
jobs:
  tooling-tests:
    runs-on: ubuntu-24.04
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      - name: Prepare Python
        id: setup-python
        run: python3 -m venv "$RUNNER_TEMP/venv"
      - name: A
        id: tt-a
        run: python3 tests/test_a.py
      - name: B
        id: tt-b
        if: ${{ !cancelled() }}
        run: python3 -I tests/test_b.py
      - name: C imports a module nobody can find
        id: tt-c
        run: python3 tests/test_c.py
      - name: D runs no test
        id: tt-d
        run: python3 scripts/check_d.py
      - name: E hides its script behind an expression
        id: tt-e
        run: python3 ${{ github.event_name == 'push' && 'tests/test_a.py' || 'tests/test_b.py' }}
      - name: F runs every shell test in a folder through a variable
        id: tt-f
        run: bash tests/run-all.test.sh
      - name: G checks the paths a data file lists
        id: tt-g
        run: python3 tests/test_g.py
      - name: H checks every tracked file
        id: tt-h
        run: python3 tests/test_h.py
"""
FILES = {
    WORKFLOW: FIXTURE_WORKFLOW,
    "liba/lib_a.py": "VALUE = 1\n",
    "libb/lib_b.py": "VALUE = 2\n",
    "tests/test_a.py": textwrap.dedent("""\
        import sys
        from pathlib import Path
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "liba"))
        import lib_a
        """),
    "tests/test_b.py": textwrap.dedent("""\
        import sys
        from pathlib import Path
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "libb"))
        import lib_b
        """),
    "tests/test_c.py": "import mystery_module_nowhere\n",
    "scripts/check_d.py": "print('d')\n",
    "scripts/env.sh": "true\n",
    "tests/run-all.test.sh": 'for t in tests/shell/*.test.sh; do timeout 60 bash "$t"; done\n',
    "webviews/src/pane.tsx": "export {}\n",
    "tests/test_g.py": textwrap.dedent("""\
        from pathlib import Path
        LISTED = Path(__file__).resolve().parents[1] / "data/listed.txt"
        """),
    "data/listed.txt": "tools/listed_tool.py\n",
    "tools/listed_tool.py": "print('listed')\n",
    "tests/test_h.py": textwrap.dedent("""\
        import subprocess
        tracked = subprocess.run(["git", "ls-files", "-z"], capture_output=True).stdout
        """),
}


class FixtureRepo(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = Path(self.scratch.name)
        git_fixture_env.init_repo(self.root)
        for rel, text in FILES.items():
            path = self.root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        subprocess.run(["git", "-C", str(self.root), "add", "-A"], check=True,
                       env=git_fixture_env.fixture_env())

    def tearDown(self):
        self.scratch.cleanup()

    def route(self, changed, event="pull_request"):
        return tooling_steps.route(self.root, WORKFLOW, "tooling-tests", changed, event)

    def verdicts(self, decision):
        return {s.key: s for s in decision.steps}

    def test_a_change_to_one_tests_input_selects_that_step_only(self):
        decision = self.route(["liba/lib_a.py"])
        self.assertFalse(decision.all)
        steps = self.verdicts(decision)
        self.assertTrue(steps["tt-a"].run, steps["tt-a"].reason)
        self.assertFalse(steps["tt-b"].run, steps["tt-b"].reason)
        decision = self.route(["libb/lib_b.py"])
        steps = self.verdicts(decision)
        self.assertFalse(steps["tt-a"].run, steps["tt-a"].reason)
        self.assertTrue(steps["tt-b"].run, steps["tt-b"].reason)

    def test_a_change_to_the_test_itself_selects_its_step(self):
        steps = self.verdicts(self.route(["tests/test_b.py"]))
        self.assertTrue(steps["tt-b"].run)
        self.assertFalse(steps["tt-a"].run)

    def test_an_unrelated_change_skips_every_resolved_step(self):
        decision = self.route(["webviews/src/pane.tsx"])
        self.assertFalse(decision.all)
        steps = self.verdicts(decision)
        self.assertEqual({k for k, s in steps.items() if not s.run}, {"tt-a", "tt-b", "tt-f", "tt-g"})
        # Setup steps are never selectable: they always run.
        self.assertNotIn("setup-python", steps)

    def test_a_path_a_data_input_names_selects_its_step(self):
        # A deleted script still listed in a data file the test reads (scripts/ci/check-paths.txt): the walker does
        # not follow the data file's lines, so the router reads its text.
        steps = self.verdicts(self.route(["tools/listed_tool.py"]))
        self.assertTrue(steps["tt-g"].run, steps["tt-g"].reason)
        self.assertIn("data/listed.txt", steps["tt-g"].reason)
        self.assertFalse(steps["tt-a"].run, steps["tt-a"].reason)

    def test_a_test_listing_every_tracked_file_always_runs(self):
        steps = self.verdicts(self.route(["webviews/src/pane.tsx"]))
        self.assertTrue(steps["tt-h"].run, steps["tt-h"].reason)
        self.assertIn("lists every tracked file", steps["tt-h"].reason)

    def test_an_unknown_input_runs_the_step(self):
        steps = self.verdicts(self.route(["webviews/src/pane.tsx"]))
        self.assertTrue(steps["tt-c"].run)
        self.assertIn("mystery_module_nowhere", steps["tt-c"].reason)

    def test_a_step_naming_no_test_or_hiding_its_script_runs(self):
        steps = self.verdicts(self.route(["webviews/src/pane.tsx"]))
        self.assertTrue(steps["tt-d"].run)
        self.assertIn("no test", steps["tt-d"].reason)
        self.assertTrue(steps["tt-e"].run)
        self.assertIn("${{ }}", steps["tt-e"].reason)

    def stage(self):
        subprocess.run(["git", "-C", str(self.root), "add", "-A"], check=True, env=git_fixture_env.fixture_env())

    def test_a_shell_script_running_a_variable_reaches_its_own_directory(self):
        # tests/run-all.test.sh runs "$t": a file of its own directory, as run-all scripts do, so a change there runs it.
        self.assertFalse(self.verdicts(self.route(["webviews/src/pane.tsx"]))["tt-f"].run)
        steps = self.verdicts(self.route(["tests/shell/new.test.sh"]))
        self.assertTrue(steps["tt-f"].run, steps["tt-f"].reason)
        # One that declares what it runs reaches that and nothing else of its directory.
        (self.root / "tests/run-all.test.sh").write_text(
            "#!/bin/bash\n# tooling-steps runs: tests/shell/*.test.sh\nfor t in $(ls tests/shell); do bash \"$t\"; done\n")
        (self.root / "tests/shell").mkdir()
        (self.root / "tests/shell/one.test.sh").write_text("true\n")
        self.stage()
        self.assertFalse(self.verdicts(self.route(["tests/other.txt"]))["tt-f"].run)
        steps = self.verdicts(self.route(["tests/shell/one.test.sh"]))
        self.assertTrue(steps["tt-f"].run, steps["tt-f"].reason)

    def test_a_variable_run_outside_a_shell_script_stays_unresolved(self):
        path = self.root / WORKFLOW
        path.write_text(path.read_text().replace("run: bash tests/run-all.test.sh", 'run: bash "$RUNNER"'))
        steps = self.verdicts(self.route(["webviews/src/pane.tsx"]))
        self.assertTrue(steps["tt-f"].run)

    def test_heredoc_bodies_and_test_brackets_are_not_commands(self):
        (self.root / "tests/run-all.test.sh").write_text(textwrap.dedent("""\
            #!/bin/bash
            if [[ -n "${A:-}" && -z "${B:-}" ]]; then args+=("$A"); fi
            cat > out.txt <<'EOF'
            $mystery --not-a-command
            EOF
            python3 - <<'PY'
            print("inline")
            PY
            """))
        self.stage()
        steps = self.verdicts(self.route(["webviews/src/pane.tsx"]))
        self.assertFalse(steps["tt-f"].run, steps["tt-f"].reason)

    def test_the_whole_tree_rule_needs_an_added_or_deleted_file(self):
        steps = self.verdicts(tooling_steps.route(self.root, WORKFLOW, "tooling-tests", ["webviews/src/pane.tsx"],
                                                  "pull_request", []))
        self.assertFalse(steps["tt-h"].run, steps["tt-h"].reason)
        steps = self.verdicts(tooling_steps.route(self.root, WORKFLOW, "tooling-tests", ["webviews/src/new.tsx"],
                                                  "pull_request", ["webviews/src/new.tsx"]))
        self.assertTrue(steps["tt-h"].run, steps["tt-h"].reason)

    def test_a_workflow_or_router_change_runs_every_step(self):
        for changed in (WORKFLOW, "scripts/ci/tooling_steps.py", "scripts/ci/workflow_paths_cover_inputs.py",
                        "scripts/ci/gh_expressions.py", "scripts/env.sh"):
            decision = self.route(["webviews/src/pane.tsx", changed])
            self.assertTrue(decision.all, changed)
            self.assertTrue(all(s.run for s in decision.steps), changed)

    def test_a_bash_env_command_substitution_still_names_its_file(self):
        # The API call log's BASH_ENV is one $( ) that echoes the checkout's file or a fetched copy (2026-11-21).
        path = self.root / WORKFLOW
        path.write_text(path.read_text().replace(
            "BASH_ENV: ${GITHUB_WORKSPACE:-/nonexistent}/scripts/env.sh",
            "BASH_ENV: '$({ w=\"${GITHUB_WORKSPACE:-/nonexistent}/scripts/env.sh\"; [ -f \"$w\" ] && echo \"$w\"; } 2>/dev/null)'"))
        decision = self.route(["webviews/src/pane.tsx", "scripts/env.sh"])
        self.assertTrue(decision.all)
        self.assertFalse(self.route(["webviews/src/pane.tsx"]).all)

    def test_a_non_pull_request_event_or_no_list_runs_every_step(self):
        self.assertTrue(self.route(["webviews/src/pane.tsx"], event="push").all)
        self.assertTrue(self.route(None).all)
        self.assertTrue(self.route([]).all)

    def test_outputs_are_space_padded_and_name_the_verdict(self):
        decision = self.route(["liba/lib_a.py"])
        with tempfile.TemporaryDirectory() as out:
            output, summary = Path(out) / "output", Path(out) / "summary"
            tooling_steps.write_outputs(decision, output, summary, "tooling-tests")
            values = dict(line.split("=", 1) for line in output.read_text(encoding="utf-8").splitlines())
            self.assertEqual(values["tooling_all"], "false")
            self.assertEqual(values["tooling_steps"], " tt-a tt-c tt-d tt-e tt-h ")
            self.assertIn("`tt-b` B:", summary.read_text(encoding="utf-8"))


class RealWorkflow(unittest.TestCase):
    """cmux-next-guards.yml as it is: every tooling-tests run step carries its selection, and the job's own setup-tooling-route step feeds it."""

    @classmethod
    def setUpClass(cls):
        import yaml
        cls.document = yaml.safe_load((ROOT / ".github/workflows/cmux-next-guards.yml").read_text(encoding="utf-8"))
        cls.job = cls.document["jobs"]["tooling-tests"]

    def test_every_run_step_is_setup_or_selected_by_its_own_id(self):
        ids = []
        for step in self.job["steps"]:
            if "run" not in step:
                continue  # a setup action (checkout, Bun, Rust): always runs
            key = str(step.get("id") or "")
            name = step.get("name")
            ids.append(key)
            if key.startswith(tooling_steps.SETUP_ID):
                self.assertNotIn("outputs.tooling_", str(step.get("if", "")), name)
                continue
            self.assertTrue(key.startswith("tt-"), f"{name}: give it `id: tt-<slug>` and the selection `if:`")
            selection = (f"(steps.setup-tooling-route.outputs.tooling_all != 'false' || "
                         f"contains(steps.setup-tooling-route.outputs.tooling_steps, ' {key} '))")
            self.assertIn(step.get("if"), (f"${{{{ success() && {selection} }}}}",
                                           f"${{{{ !cancelled() && {selection} }}}}"), name)
        self.assertEqual(len(ids), len(set(ids)), "step ids repeat")
        self.assertGreater(len([i for i in ids if i.startswith("tt-")]), 40)

    def test_the_router_judges_every_selectable_step(self):
        decision = tooling_steps.route(ROOT, ".github/workflows/cmux-next-guards.yml", "tooling-tests",
                                       ["webviews/src/agent-session/pane.tsx"], "push")
        self.assertTrue(decision.all)
        expected = [s["id"] for s in self.job["steps"] if "run" in s and not s["id"].startswith("setup-")]
        self.assertEqual([s.key for s in decision.steps], expected)

    def test_the_route_step_runs_the_router_before_every_selected_step(self):
        steps = self.job["steps"]
        index = next(i for i, s in enumerate(steps) if s.get("id") == "setup-tooling-route")
        step = steps[index]
        self.assertIn("scripts/ci/tooling_steps.py route --workflow .github/workflows/cmux-next-guards.yml",
                      step["run"])
        self.assertIn("--job tooling-tests", step["run"])
        self.assertIn("tooling_all=true", step["run"])  # a router failure runs every step
        self.assertIs(step.get("continue-on-error"), True)  # a failed route never fails the job
        self.assertEqual(step["if"], "${{ github.event_name == 'pull_request' }}")  # any other event runs every step
        # The router reads workflows with PyYAML, which the venv step puts on PATH first.
        setup_python = next(i for i, s in enumerate(steps) if s.get("id") == "setup-python")
        self.assertLess(setup_python, index)
        self.assertTrue(all(not str(s.get("id") or "").startswith("tt-") for s in steps[:index]))
        # No routing job of its own: tooling-tests waits on coalesce and on the base-red check (#52891).
        self.assertEqual(self.job["needs"], ["coalesce", "tooling-tests-base-red"])
        self.assertNotIn("portable-placement", self.document["jobs"])
        self.assertTrue(self.job["if"].startswith("${{ (!cancelled()"))


if __name__ == "__main__":
    unittest.main()
