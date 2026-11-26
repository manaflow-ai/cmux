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
import shutil
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
      - name: I lists source folders under a root it is handed
        id: tt-i
        run: python3 tests/test_i.py
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
    # ios_placeholder_bounds.py's shape: the root is a parameter (`--root`), the folders a tuple it loops over;
    # the listing of a scratch folder names no repository directory and adds nothing.
    "tests/test_i.py": textwrap.dedent("""\
        import sys
        from pathlib import Path
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
        import check_i
        """),
    "scripts/check_i.py": textwrap.dedent("""\
        import tempfile
        from pathlib import Path
        SOURCE_DIRS = ("app/Sources", "kit/Sources")
        def sources(root: Path):
            for rel in SOURCE_DIRS:
                base = root / rel
                yield from base.rglob("*.swift")
        def scratch():
            tmp = Path(tempfile.mkdtemp())
            return list((tmp / "out").glob("*.json"))
        """),
    "app/Sources/Feature/View.swift": "struct V {}\n",
    "kit/Sources/Kit.swift": "struct K {}\n",
    "app/Other/Readme.swift": "struct R {}\n",
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

    def route(self, changed, event="pull_request", added_deleted=None):
        return tooling_steps.route(self.root, WORKFLOW, "tooling-tests", changed, event, added_deleted)

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
        self.assertEqual({k for k, s in steps.items() if not s.run}, {"tt-a", "tt-b", "tt-f", "tt-g", "tt-i"})
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
        steps = self.verdicts(self.route(["docs/notes.md"]))
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

    def test_a_command_run_from_a_variable_is_judged_only_for_a_non_product_diff(self):
        # tt-f's script runs `bash "$t"`: any file of tests/shell may run, so a tooling change runs it, but a diff of
        # product source alone (which no tooling test reads) skips it.
        steps = self.verdicts(self.route(["webviews/src/pane.tsx"]))
        self.assertFalse(steps["tt-f"].run, steps["tt-f"].reason)
        # With a file of its own directory in the diff, it runs.
        steps = self.verdicts(self.route(["webviews/src/pane.tsx", "tests/shell/new.test.sh"]))
        self.assertTrue(steps["tt-f"].run, steps["tt-f"].reason)

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

    # A listing under a root the script is handed (`root / rel`, `--root`) is read as one under the repository: the
    # walker used to drop it, so a change under those folders skipped the step and turned the base red after merge
    # (tests/test_ios_placeholder_bounds.py, RecoveryGalleryRoot.swift, fixed on base by #55212).
    def test_a_change_under_a_computed_root_listing_runs_the_step(self):
        for changed in ("app/Sources/Feature/View.swift", "kit/Sources/Kit.swift"):
            steps = self.verdicts(self.route([changed]))
            self.assertTrue(steps["tt-i"].run, f"{changed}: {steps['tt-i'].reason}")
            self.assertIn("lists", steps["tt-i"].reason)

    def test_a_change_beside_a_computed_root_listing_skips_it(self):
        steps = self.verdicts(self.route(["app/Other/Readme.swift"]))
        self.assertFalse(steps["tt-i"].run, steps["tt-i"].reason)
        self.assertFalse(steps["tt-a"].run, steps["tt-a"].reason)


DECLARED_FIXTURE = """\
{"%s": {"tooling-tests": {
  "tt-f": {"inputs": ["tests/shell/**", "tests/run-all.test.sh"], "why": "runs every tests/shell/*.test.sh by a loop variable"},
  "tt-d": {"inputs": ["scripts/check_d.py"], "why": "a script, not a test"}
}}}
""" % WORKFLOW


class DeclaredInputs(unittest.TestCase):
    """scripts/ci/tooling-step-inputs.json: a step the walker cannot read whole runs only when a changed path matches
    its declared globs or its resolved inputs; a bad or missing file declares nothing (every such step runs)."""

    setUp_fixture, tearDown, route, verdicts = FixtureRepo.setUp, FixtureRepo.tearDown, FixtureRepo.route, \
        FixtureRepo.verdicts

    def setUp(self):
        self.setUp_fixture()
        self.declare(DECLARED_FIXTURE)
        (self.root / "tests/shell").mkdir(parents=True, exist_ok=True)
        (self.root / "tests/shell/one.test.sh").write_text("cat data/listed.txt >/dev/null\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(self.root), "add", "-A"], check=True, env=git_fixture_env.fixture_env())

    def declare(self, text):
        path = self.root / tooling_steps.DECLARED
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def test_a_declared_step_is_skipped_with_its_reason(self):
        steps = self.verdicts(self.route(["webviews/src/pane.tsx"]))
        # tt-f's loop the walker resolves since #53873, so only tt-d leans on its declaration here.
        self.assertFalse(steps["tt-f"].run, steps["tt-f"].reason)
        for key in ("tt-d",):
            self.assertFalse(steps[key].run, steps[key].reason)
            self.assertIn("none of its declared inputs", steps[key].reason)
            self.assertIn(tooling_steps.DECLARED, steps[key].reason)
        # Undeclared steps the walker cannot read still run.
        self.assertTrue(steps["tt-c"].run)
        self.assertTrue(steps["tt-e"].run)

    def test_a_change_a_declared_glob_matches_runs_the_step(self):
        steps = self.verdicts(self.route(["tests/shell/two.test.sh"]))
        self.assertTrue(steps["tt-f"].run, steps["tt-f"].reason)
        self.assertIn("matches its declared input tests/shell/**", steps["tt-f"].reason)
        self.assertFalse(steps["tt-d"].run, steps["tt-d"].reason)
        steps = self.verdicts(self.route(["scripts/check_d.py"]))
        self.assertTrue(steps["tt-d"].run, steps["tt-d"].reason)

    def test_a_change_to_the_declarations_runs_every_step(self):
        decision = self.route(["webviews/src/pane.tsx", tooling_steps.DECLARED])
        self.assertTrue(decision.all)

    def test_a_missing_or_malformed_file_declares_nothing(self):
        for text in (None, "{", "[]", '{"%s": {"tooling-tests": {"tt-f": {"inputs": []}}}}' % WORKFLOW,
                     '{"%s": {"tooling-tests": {"tt-f": {"inputs": ["tests/shell/**"]}}}}' % WORKFLOW):
            if text is None:
                (self.root / tooling_steps.DECLARED).unlink()
            else:
                self.declare(text)
            steps = self.verdicts(self.route(["webviews/src/pane.tsx"]))
            self.assertTrue(steps["tt-d"].run, text)

    def test_a_traced_declaration_alone_decides_its_step(self):
        # 2026-11-23T18..11-24T18: tt-measure-tests ran on 3,637 of 4,398 tooling-tests jobs (6.9k runner-min/day): the
        # walker's folder and whole-tree guesses (a script naming Packages/macOS/CmuxNext, a `git ls-files`) matched
        # nearly every diff its declared globs did not. With "traced": true, its globs and resolved files decide it.
        added = ["webviews/src/new.tsx"]
        steps = self.verdicts(self.route(added, added_deleted=added))
        self.assertTrue(steps["tt-h"].run, steps["tt-h"].reason)  # undeclared: the whole-tree guess holds
        self.declare('{"%s": {"tooling-tests": {"tt-h": {"inputs": ["tests/test_h.py", "data/**"], '
                     '"why": "traced: reads only its test and data/", "traced": true}}}}' % WORKFLOW)
        steps = self.verdicts(self.route(added, added_deleted=added))
        self.assertFalse(steps["tt-h"].run, steps["tt-h"].reason)
        self.assertIn("traced", steps["tt-h"].reason)
        for path in ("data/new.txt", "tests/test_h.py"):
            steps = self.verdicts(self.route([path], added_deleted=[path]))
            self.assertTrue(steps["tt-h"].run, (path, steps["tt-h"].reason))
        # "traced" counts only as the literal true, on an entry load_declared accepts.
        self.declare('{"%s": {"tooling-tests": {"tt-h": {"inputs": ["tests/test_h.py"], "why": "x", '
                     '"traced": "yes"}}}}' % WORKFLOW)
        steps = self.verdicts(self.route(added, added_deleted=added))
        self.assertTrue(steps["tt-h"].run, steps["tt-h"].reason)

    def test_the_real_traced_steps_are_declared_steps(self):
        workflow = ".github/workflows/cmux-next-guards.yml"
        traced = tooling_steps.load_traced(ROOT, workflow, "tooling-tests")
        self.assertIn("tt-measure-tests", traced)
        self.assertLessEqual(traced, set(tooling_steps.load_declared(ROOT, workflow, "tooling-tests")))

    def test_parse_trace_reads_the_checkout_only(self):
        repo = tooling_steps.Repo.load(self.root)
        root = str(self.root)
        log = [
            f'100 execve("/bin/bash", ["bash", "-c", "x"], 0x0 /* 1 var */) = 0',
            f'100 openat(AT_FDCWD</x>, "tests/run-all.test.sh", O_RDONLY) = 3',
            f'100 clone(child_stack=NULL, flags=SIGCHLD) = 101',
            f'101 chdir("tests") = 0',
            f'101 openat(AT_FDCWD, "shell", O_RDONLY|O_NONBLOCK|O_CLOEXEC|O_DIRECTORY) = 3',
            f'101 newfstatat(AT_FDCWD, "missing/thing.py", 0x0, 0) = -1 ENOENT (No such file or directory)',
            f'100 openat(7</tmp/elsewhere>, "liba", O_RDONLY|O_DIRECTORY) = 4',
            f'100 openat(7, "libb", O_RDONLY|O_DIRECTORY) = 4',
            f'100 openat(8<{root}/data>, "listed.txt", O_RDONLY) = 5',
            f'100 newfstatat(5<{root}/data/listed.txt>, "", {{st_mode=S_IFREG}}, AT_EMPTY_PATH) = 0',
            f'100 openat(AT_FDCWD, "{root}/.git/HEAD", O_RDONLY) = 6',
            f'100 newfstatat(AT_FDCWD, "nosuchtool", 0x0, 0) = -1 ENOENT (No such file or directory)',
            f'102 execve("/usr/bin/git", ["git", "ls-files", "--", "tests/"], 0x0 /* 1 var */) = 0',
        ]
        trace = tooling_steps.parse_trace(repo, log)
        self.assertEqual(trace.files, {"tests/run-all.test.sh", "data/listed.txt"})
        self.assertEqual(trace.dirs, {"tests/shell"})
        self.assertEqual(trace.probes, {"tests/missing/thing.py"})
        self.assertEqual(trace.git, ["ls-files tests/"])

    @unittest.skipUnless(shutil.which("strace"), "strace is not installed")
    def test_verify_names_a_read_the_declared_inputs_miss(self):
        problems = tooling_steps.verify(self.root, WORKFLOW, "tooling-tests", ["tt-f"])
        self.assertEqual(problems, ["tt-f: read data/listed.txt, outside its declared inputs and its resolved inputs"])
        self.declare(DECLARED_FIXTURE.replace('"tests/run-all.test.sh"', '"tests/run-all.test.sh", "data/**"'))
        self.assertEqual(tooling_steps.verify(self.root, WORKFLOW, "tooling-tests", ["tt-f"]), [])


class GreenReuse(FixtureRepo):
    """scripts/ci/tooling_reuse.py: a later head reuses an earlier run's pass for a step only when route, asked about the
    diff between the two merge trees, would not select that step."""

    def setUp(self):
        super().setUp()
        sys.path.insert(0, str(ROOT / "scripts" / "ci"))
        import tooling_reuse
        self.reuse = tooling_reuse
        self.commit("fixture")
        self.before = tooling_reuse.tree_of(self.root)

    def commit(self, message):
        env = git_fixture_env.fixture_env()
        subprocess.run(["git", "-C", str(self.root), "add", "-A"], check=True, env=env)
        subprocess.run(["git", "-C", str(self.root), "-c", "user.name=t", "-c", "user.email=t@example.com",
                        "commit", "-q", "--allow-empty", "-m", message], check=True, env=env)

    def edit(self, rel, text):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        self.commit(f"edit {rel}")

    def found(self, selected, passed=("tt-a", "tt-b", "tt-g")):
        record = self.reuse.Record("run 1", self.before, set(passed))
        return self.reuse.reusable(self.root, WORKFLOW, "tooling-tests", list(selected),
                                   self.reuse.tree_of(self.root), [record])

    def test_the_same_tree_reuses_every_step_that_passed(self):
        found = self.found(["tt-a", "tt-b", "tt-c"])
        self.assertEqual(set(found), {"tt-a", "tt-b"})  # tt-c never passed in run 1

    def test_a_change_one_step_reads_reruns_that_step_only(self):
        self.edit("liba/lib_a.py", "VALUE = 2\n")
        found = self.found(["tt-a", "tt-b"])
        self.assertEqual(set(found), {"tt-b"})
        self.assertIn("run 1", found["tt-b"][0])

    def test_a_change_to_the_workflow_or_reuse_logic_reuses_nothing(self):
        for rel in (WORKFLOW, "scripts/ci/tooling_reuse.py"):
            with self.subTest(rel=rel):
                path = self.root / rel
                old = path.read_text(encoding="utf-8") if path.exists() else ""
                self.edit(rel, old + "\n# changed\n")
                self.assertEqual(self.found(["tt-a", "tt-b"]), {})

    def test_a_deleted_file_a_listed_data_file_names_reruns_its_step(self):
        (self.root / "tools/listed_tool.py").unlink()
        self.commit("delete")
        self.assertNotIn("tt-g", self.found(["tt-a", "tt-g"]))

    def test_apply_rewrites_the_route_output_and_fails_open(self):
        self.edit("webviews/src/pane.tsx", "export const x = 1\n")
        out = self.root / "tooling.out"
        out.write_text("tooling_steps= tt-a tt-b tt-c \ntooling_all=false\n", encoding="utf-8")
        record = self.reuse.Record("run 1", self.before, {"tt-a", "tt-c"})
        found = self.reuse.apply(out, self.root, WORKFLOW, "tooling-tests", lambda: [record])
        self.assertEqual(set(found), {"tt-a"})  # tt-c reads an unknown module, so route still selects it
        self.assertEqual(out.read_text(encoding="utf-8"), "tooling_steps= tt-b tt-c \ntooling_all=false\n")

        def broken():
            raise TimeoutError("api down")
        out.write_text("tooling_steps= tt-a \ntooling_all=false\n", encoding="utf-8")
        self.assertEqual(self.reuse.apply(out, self.root, WORKFLOW, "tooling-tests", broken), {})
        self.assertEqual(out.read_text(encoding="utf-8"), "tooling_steps= tt-a \ntooling_all=false\n")

    def test_record_keeps_only_steps_that_ran_and_passed(self):
        import json
        steps = {"setup-python": {"outcome": "success"}, "tt-a": {"outcome": "success"},
                 "tt-b": {"outcome": "skipped"}, "tt-c": {"outcome": "failure"}}
        out = self.root / "out" / "tooling-passed.json"
        passed = self.reuse.record(WORKFLOW, "tooling-tests", self.root, json.dumps(steps), out, "1")
        self.assertEqual(passed, ["tt-a"])
        data = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(data["tree"], self.before)

    def test_record_keeps_the_steps_the_side_by_side_runner_passed(self):
        import json
        steps = {"setup-tooling-run": {"outcome": "failure", "outputs": {"ran": "true", "passed": " tt-b "}},
                 "tt-a": {"outcome": "skipped"}, "tt-b": {"outcome": "skipped"}, "tt-c": {"outcome": "skipped"}}
        out = self.root / "out" / "tooling-passed.json"
        self.assertEqual(self.reuse.record(WORKFLOW, "tooling-tests", self.root, json.dumps(steps), out, "1"), ["tt-b"])

    def test_audit_is_stable_per_run_and_near_its_percent(self):
        self.assertEqual(self.reuse.audited("123", 10), self.reuse.audited("123", 10))
        hits = sum(self.reuse.audited(str(n), 10) for n in range(2000))
        self.assertTrue(120 < hits < 280, hits)
        self.assertFalse(any(self.reuse.audited(str(n), 0) for n in range(200)))


class RealDeclarations(unittest.TestCase):
    """Every step scripts/ci/tooling-step-inputs.json names is a tooling-tests run step, and the file loads (a
    malformed file would silently declare nothing)."""

    def test_the_declarations_load_and_name_real_steps(self):
        workflow = ".github/workflows/cmux-next-guards.yml"
        declared = tooling_steps.load_declared(ROOT, workflow, "tooling-tests")
        self.assertTrue(declared, f"{tooling_steps.DECLARED} declares nothing: malformed?")
        import yaml
        job = yaml.safe_load((ROOT / workflow).read_text(encoding="utf-8"))["jobs"]["tooling-tests"]
        ids = {s.get("id") for s in job["steps"] if "run" in s}
        self.assertLessEqual(set(declared), ids)


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
            selection = (f"steps.setup-tooling-run.outputs.ran != 'true' && "
                         f"(steps.setup-tooling-route.outputs.tooling_all != 'false' || "
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

    def test_an_iphone_swift_change_runs_the_placeholder_bounds_step(self):
        decision = tooling_steps.route(ROOT, ".github/workflows/cmux-next-guards.yml", "tooling-tests",
            ["cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileShell/RecoveryGalleryRoot.swift"], "pull_request")
        step = next(s for s in decision.steps if s.key == "tt-ios-placeholder-bounds")
        self.assertTrue(step.run, step.reason)

    def test_the_runner_step_runs_after_every_setup_and_before_every_step_it_runs(self):
        steps = self.job["steps"]
        index = next(i for i, s in enumerate(steps) if s.get("id") == "setup-tooling-run")
        step = steps[index]
        self.assertIn("scripts/ci/tooling_steps.py run --workflow .github/workflows/cmux-next-guards.yml", step["run"])
        self.assertIn('--selection "$RUNNER_TEMP/tooling.out"', step["run"])
        self.assertIn('--github-output "$GITHUB_OUTPUT"', step["run"])
        tt = [i for i, s in enumerate(steps) if str(s.get("id") or "").startswith("tt-")]
        self.assertLess(index, min(tt))
        last_tt = max(tt)  # after the steps, only post-run actions (tooling_reuse's upload) may be actions
        self.assertTrue(all("run" in s for s in steps[index:last_tt + 1]), "every setup action comes before the runner")
        for other in (steps[i] for i in tt):  # an expression env reaches the runner as the same expression
            for key, value in (other.get("env") or {}).items():
                if "${{" in str(value):
                    self.assertEqual((step.get("env") or {}).get(key), value, f"{other['id']}: mirror {key} on the runner step")
        # It plans the real job: every tt- step's env, shell and timeout this runner can give it.
        environ = {k: str(v) for k, v in (step.get("env") or {}).items()}
        planned = tooling_steps.plan_run(ROOT, ".github/workflows/cmux-next-guards.yml", "tooling-tests", None, environ)
        self.assertEqual([s.key for s in planned], [steps[i]["id"] for i in tt])

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
        self.assertIn("(!cancelled() && needs.coalesce.outputs.run != 'false')", self.job["if"])  # after the draft tier


class SideBySide(unittest.TestCase):
    """tooling_steps.py run: the selected tt- steps at once, each with its own env, shell and timeout."""

    WORKFLOW = textwrap.dedent("""\
        on: push
        jobs:
          t:
            timeout-minutes: 5
            steps:
              - uses: actions/checkout@v4
              - id: setup-x
                run: exit 3
              - id: tt-slow-a
                if: ${{ success() }}
                env:
                  WHO: a
                  EVENT_NAME: ${{ github.event_name }}
                run: |
                  sleep 1
                  echo "$WHO $EVENT_NAME"
              - id: tt-slow-b
                run: sleep 1; echo b
              - id: tt-fails
                name: The failing one
                run: echo broken; exit 7
              - id: tt-slow-py
                shell: python
                timeout-minutes: 0.02
                run: |
                  import time
                  time.sleep(30)
        """)

    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root, True)
        (self.root / "w.yml").write_text(self.WORKFLOW, encoding="utf-8")

    def plan(self, selection=None, environ=None):
        return tooling_steps.plan_run(self.root, "w.yml", "t", selection, environ or {"EVENT_NAME": "pull_request"})

    def test_plan_keeps_the_tt_steps_the_selection_keeps(self):
        self.assertEqual([s.key for s in self.plan()], ["tt-slow-a", "tt-slow-b", "tt-fails", "tt-slow-py"])
        self.assertEqual([s.key for s in self.plan({"tt-slow-b"})], ["tt-slow-b"])
        steps = self.plan()
        self.assertEqual(steps[0].env, {"WHO": "a", "EVENT_NAME": "pull_request"})
        self.assertEqual(steps[3].shell[0], "python3")
        self.assertAlmostEqual(steps[3].timeout, 1.2)
        self.assertEqual(steps[1].timeout, 300)

    def test_an_expression_env_the_runner_step_lacks_falls_back(self):
        with self.assertRaisesRegex(ValueError, "EVENT_NAME"):
            tooling_steps.plan_run(self.root, "w.yml", "t", None, {})

    def test_the_selection_file(self):
        out = self.root / "tooling.out"
        self.assertIsNone(tooling_steps.read_selection(out))
        out.write_text("tooling_steps= tt-a tt-b \ntooling_all=false\n", encoding="utf-8")
        self.assertEqual(tooling_steps.read_selection(out), {"tt-a", "tt-b"})
        out.write_text("tooling_all=true\ntooling_steps=\n", encoding="utf-8")
        self.assertIsNone(tooling_steps.read_selection(out))

    def test_steps_run_at_once_and_every_failure_is_named(self):
        import io
        import time
        buf = io.StringIO()
        started = time.monotonic()
        results = tooling_steps.run_steps(self.plan(), 4, dict(os.environ, EVENT_NAME="push"), buf)
        wall = time.monotonic() - started
        self.assertLess(wall, 1.9, "the two 1 s steps ran side by side")
        self.assertEqual([r.step.key for r in results], ["tt-slow-a", "tt-slow-b", "tt-fails", "tt-slow-py"])
        codes = {r.step.key: r.code for r in results}
        self.assertEqual(codes, {"tt-slow-a": 0, "tt-slow-b": 0, "tt-fails": 7, "tt-slow-py": 124})
        text = buf.getvalue()
        self.assertIn("a pull_request", text)  # the step's own env, not the runner's EVENT_NAME
        self.assertIn("::group::The failing one (", text)
        self.assertIn("::error title=tooling-tests tt-fails::The failing one failed (exit 7)", text)
        self.assertIn("tt-slow-py: timed out after 1 s", text)
        summary = io.StringIO()
        tooling_steps.write_run_summary(results, wall, None, summary)
        self.assertIn("2 failed", summary.getvalue())
        self.assertIn("FAILED tt-fails", summary.getvalue())

    def test_main_marks_ran_and_fails_on_a_red_step(self):
        out = self.root / "out"
        sel = self.root / "sel"
        args = ["run", "--root", str(self.root), "--workflow", "w.yml", "--job", "t", "--selection", str(sel)]
        sel.write_text("tooling_steps= tt-slow-b \ntooling_all=false\n", encoding="utf-8")
        self.assertEqual(tooling_steps.main([*args, "--github-output", str(out)]), 0)
        self.assertEqual(out.read_text(encoding="utf-8"), "ran=true\npassed= tt-slow-b \n")
        sel.write_text("tooling_steps= tt-fails \ntooling_all=false\n", encoding="utf-8")
        self.assertEqual(tooling_steps.main(args), 1)

    def test_main_leaves_the_steps_one_by_one_when_it_cannot_plan(self):
        out = self.root / "out"
        code = tooling_steps.main(["run", "--root", str(self.root), "--workflow", "w.yml", "--job", "missing",
                                   "--github-output", str(out)])
        self.assertEqual(code, 0)
        self.assertFalse(out.exists(), "no ran=true: each step's own if: runs it")


if __name__ == "__main__":
    unittest.main()
