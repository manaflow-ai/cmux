#!/usr/bin/env python3
"""Pins scripts/ci/guard_step_inputs.py: a guard step runs when the change reaches its inputs, and only then.

Each case builds a small git tree and asks which steps a change selects. Run it yourself after changing
guard_step_inputs.py or run_ci_guards.py --affected: python3 tests/test_guard_step_inputs.py (seconds, no build).
"""
from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import guard_step_inputs as g  # noqa: E402


def _load_git_fixture_env():
    """tests/git_fixture_env.py by path, so `python3 -I` (no script folder on sys.path) runs this file too."""
    spec = importlib.util.spec_from_file_location("git_fixture_env", Path(__file__).resolve().parent / "git_fixture_env.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # importing it disables git auto maintenance
    return module


git_fixture_env = _load_git_fixture_env()

FILES = {
    # A test that imports a tool through sys.path, reads a config file and walks a named folder.
    "tests/test_a.py": """
        import sys
        from pathlib import Path
        ROOT = Path(__file__).resolve().parents[1]
        sys.path.insert(0, str(ROOT / "scripts" / "ci"))
        import tool_a
        CONFIG = ROOT / "config" / "a.json"
        DOCS = ROOT / "docs"
        def test():
            return CONFIG.read_text(), sorted(DOCS.glob("*.md")), tool_a.VALUE
    """,
    "scripts/ci/tool_a.py": "from helper import VALUE\n",
    "scripts/ci/helper.py": "VALUE = 1\n",
    "config/a.json": "{}\n",
    "docs/one.md": "one\n",
    # A walk of the whole tree: its inputs are every file.
    "tests/test_b.py": """
        from pathlib import Path
        ROOT = Path(__file__).resolve().parents[1]
        print(sorted(ROOT.rglob("*.py")))
    """,
    # A test that runs a script: the script's own imports are the test's inputs too.
    "tests/test_c.py": """
        import subprocess, sys
        from pathlib import Path
        SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "run_me.py"
        subprocess.run([sys.executable, str(SCRIPT)], check=True)
    """,
    "scripts/run_me.py": "import deep\n",
    "scripts/deep.py": "X = 1\n",
    # A test that only names a script as data, and a path in its docstring: neither is followed.
    "tests/test_d.py": '''
        """Unlike tests/test_b.py, this reads a file."""
        from pathlib import Path
        TEXT = (Path(__file__).resolve().parents[1] / "scripts/ci/data_only.py").read_text()
    ''',
    "scripts/ci/data_only.py": "import data_dep\n",
    "scripts/ci/data_dep.py": "Y = 1\n",
    # A temporary folder's walk reads nothing of the tree.
    "tests/test_e.py": """
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as tmp:
            print(list(Path(tmp).rglob("*")))
    """,
    # A test that reads git history.
    "tests/test_f.py": """
        import subprocess
        subprocess.run(["git", "log", "-1"], check=True)
    """,
    # A test that runs a script it reads out of a workflow: that script's reads are not in any text.
    "tests/test_g.py": """
        import subprocess
        from pathlib import Path
        SCRIPT = (Path(__file__).resolve().parents[1] / "config" / "a.json").read_text()
        subprocess.run(["bash", "-c", SCRIPT], check=True)
    """,
    # A read of a root folder named at runtime: any root path may be read.
    "tests/test_h.py": """
        from pathlib import Path
        ROOT = Path(__file__).resolve().parents[1]
        for d in ("docs", "plans"):
            print((ROOT / d / "index.md").read_text())
    """,
    # A JavaScript test that reads a file it joins from segments.
    "tests/test_i.test.mjs": """
        import { readFileSync } from "node:fs";
        import path from "node:path";
        readFileSync(path.join(import.meta.dirname, "..", "web", "fix", "data.json"));
    """,
    "web/fix/data.json": "{}\n",
    # A test whose json import a tree file next to it would shadow.
    "tests/test_j.py": "import json\nprint(json.dumps({}))\n",
    # A test that starts make, whose Makefile runs scripts no text here names.
    "tests/test_k.py": """
        import subprocess
        subprocess.run(["make", "check"], check=True)
    """,
    # A test that names a file inside a submodule: a pointer bump changes only the submodule's entry.
    "tests/test_l.py": """
        from pathlib import Path
        print((Path(__file__).resolve().parents[1] / "vendor/sub/build.zig.zon").exists())
    """,
    # The same holes in the shapes the code here writes them: each reads a tree file or starts a tool at runtime.
    "tests/runtime_joinpath.py": "from pathlib import Path\nROOT = Path(__file__).resolve().parents[1]\n"
                                 "for d in ('docs',):\n    (ROOT.joinpath(d) / 'index.md').read_text()\n",
    "tests/runtime_fstring.py": "from pathlib import Path\nROOT = Path(__file__).resolve().parents[1]\n"
                                "for d in ('docs',):\n    open(f'{ROOT}/{d}/index.md').read()\n",
    "tests/runtime_concat.py": "import os\nROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))\n"
                               "for d in ('docs',):\n    open(ROOT + '/' + d + '/index.md').read()\n",
    "tests/tool_variable.py": "import subprocess\nCMD = ['make', 'check']\nsubprocess.run(CMD)\n",
    "tests/tool_shell.py": "import subprocess\nsubprocess.run(['bash', '-c', 'make check'])\n",
    "tests/tool_prefix.py": "import subprocess\nsubprocess.run(['env', 'A=1', '/usr/bin/cargo', 'test'])\n",
    "tests/tool_module.py": "import subprocess, sys\nsubprocess.run([sys.executable, '-m', 'pytest', '-q'])\n",
    # JavaScript: a join whose folder argument is itself a call, and a workspace package that imports another.
    "tests/test_nested.test.mjs": """
        import path from "node:path";
        import { fileURLToPath } from "node:url";
        import "@fx/a";
        readFileSync(path.join(path.dirname(fileURLToPath(import.meta.url)), "fixtures", "n.json"));
    """,
    "tests/fixtures/n.json": "{}\n",
    "packages/a/package.json": '{"name": "@fx/a"}\n',
    "packages/a/index.js": 'import "@fx/b";\n',
    "packages/b/package.json": '{"name": "@fx/b"}\n',
    "packages/b/index.js": "export const b = 1;\n",
    "unrelated.txt": "x\n",
}

STEPS = [
    ("A", "python3 tests/test_a.py", None),
    ("B", "python3 tests/test_b.py", None),
    ("C", "python3 tests/test_c.py", None),
    ("D", "python3 tests/test_d.py", None),
    ("E", "set -euo pipefail\npython3 tests/test_e.py", None),
    ("F", "python3 tests/test_f.py", None),
    ("piped", "python3 tests/test_a.py | tee out.log", None),
    ("two", "python3 tests/test_d.py && python3 tests/test_e.py", None),
    ("G", "python3 tests/test_g.py", None),
    ("H", "python3 tests/test_h.py", None),
    ("I", "node --test tests/test_i.test.mjs", None),
    ("J", "python3 tests/test_j.py", None),
    ("K", "python3 tests/test_k.py", None),
    ("L", "python3 tests/test_l.py", None),
    ("N", "node --test tests/test_nested.test.mjs", None),
]
RUNTIME = ["runtime_joinpath", "runtime_fstring", "runtime_concat"]
TOOLS = ["tool_variable", "tool_shell", "tool_prefix", "tool_module"]


class GuardStepInputs(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        root = Path(cls.tmp.name)
        for path, body in FILES.items():
            (root / path).parent.mkdir(parents=True, exist_ok=True)
            (root / path).write_text(textwrap.dedent(body).lstrip())
        git_fixture_env.init_repo(root)
        env = git_fixture_env.fixture_env()
        subprocess.run(["git", "add", "-A"], cwd=root, check=True, env=env)
        subprocess.run(["git", "update-index", "--add", "--cacheinfo", f"160000,{'1' * 40},vendor/sub"], cwd=root, check=True,
                       env=env)
        cls.tree = g.Tree(root)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def picked(self, *changed):
        return set(g.select(self.tree, STEPS, sorted(changed)))

    def test_an_unrelated_change_runs_only_the_steps_whose_inputs_cannot_be_read(self):
        self.assertEqual(self.picked("unrelated.txt"), {"B", "F", "G", "H", "K", "piped"})

    def test_a_path_built_on_the_root_at_runtime_or_a_tool_run_reads_the_whole_tree(self):
        self.assertIn("names at runtime", g.step_inputs(self.tree, STEPS[9][1], None, frozenset()).whole)
        self.assertIn("starts 'make'", g.step_inputs(self.tree, STEPS[12][1], None, frozenset()).whole)

    def test_a_javascript_path_joined_from_segments_reaches_its_test(self):
        self.assertIn("I", self.picked("web/fix/data.json"))
        self.assertIn("N", self.picked("tests/fixtures/n.json"))  # the folder argument is a nested call

    def test_a_workspace_package_reaches_the_packages_it_imports(self):
        self.assertIn("N", self.picked("packages/b/index.js"))

    def test_every_shape_of_a_runtime_root_path_or_a_tool_run_reads_the_whole_tree(self):
        for name in RUNTIME + TOOLS:
            with self.subTest(name):
                self.assertTrue(g.step_inputs(self.tree, f"python3 tests/{name}.py", None, frozenset()).whole)

    def test_a_new_file_that_shadows_a_standard_module_reaches_its_test(self):
        self.assertIn("J", self.picked("tests/json.py"))
        self.assertNotIn("J", self.picked("scripts/json.py"))

    def test_a_submodule_bump_reaches_a_test_naming_a_path_inside_it(self):
        self.assertIn("L", self.picked("vendor/sub"))

    def test_a_module_imported_through_sys_path_reaches_its_test(self):
        self.assertIn("A", self.picked("scripts/ci/helper.py"))
        self.assertNotIn("C", self.picked("scripts/ci/helper.py"))

    def test_a_named_file_and_a_new_file_in_a_walked_folder_reach_their_test(self):
        self.assertIn("A", self.picked("config/a.json"))
        self.assertIn("A", self.picked("docs/two.md"))

    def test_a_deleted_module_reaches_every_test_that_imports_its_name(self):
        self.assertIn("A", self.picked("scripts/old/helper.py"))

    def test_a_script_a_test_runs_brings_its_own_imports(self):
        self.assertIn("C", self.picked("scripts/deep.py"))

    def test_a_file_named_as_data_is_an_input_but_its_imports_are_not(self):
        self.assertIn("D", self.picked("scripts/ci/data_only.py"))
        self.assertNotIn("D", self.picked("scripts/ci/data_dep.py"))
        self.assertNotIn("D", self.picked("tests/test_b.py"))  # named in a docstring only

    def test_a_temporary_folder_walk_is_not_a_tree_walk(self):
        inputs = g.step_inputs(self.tree, STEPS[4][1], None, frozenset())
        self.assertEqual(inputs.whole, "")
        self.assertIn("E", self.picked("tests/test_e.py"))

    def test_whole_tree_reasons(self):
        self.assertIn("walks 'ROOT'", g.step_inputs(self.tree, STEPS[1][1], None, frozenset()).whole)
        self.assertIn("git", g.step_inputs(self.tree, STEPS[5][1], None, frozenset()).whole)
        self.assertIn("cannot read", g.step_inputs(self.tree, STEPS[6][1], None, frozenset()).whole)
        self.assertIn("runs code it builds", g.step_inputs(self.tree, STEPS[8][1], None, frozenset()).whole)

    def test_a_step_of_two_commands_runs_when_either_is_reached(self):
        self.assertIn("two", self.picked("scripts/ci/data_only.py"))
        self.assertIn("two", self.picked("tests/test_e.py"))

    def test_an_unreadable_tracked_source_runs_its_step(self):
        tree = g.Tree(self.tree.root)
        tree.read = lambda path: None if path == "scripts/ci/helper.py" else g.Tree.read(tree, path)
        self.assertIn("cannot read scripts/ci/helper.py", g.inputs_of(tree, STEPS[0]).whole)

    def test_the_selection_itself_and_a_huge_change_run_everything(self):
        self.assertIn("selection itself", g.everything_reason([".github/workflows/ci-guards.yml"]))
        self.assertIn("selection itself", g.everything_reason(["scripts/ci/guard_step_inputs.py"]))
        self.assertIn("over", g.everything_reason([f"f{i}" for i in range(g.MAX_CHANGED + 1)]))
        self.assertEqual(g.everything_reason(["unrelated.txt"]), "")

    def test_verify_reports_a_read_outside_the_inputs(self):
        inputs = g.step_inputs(self.tree, STEPS[0][1], None, frozenset())
        root = self.tree.root
        trace = "\n".join([
            f"open\t{root}/config/a.json",
            f"list\t{root}/docs",
            f"open\t{root}/scripts/ci/helper.py",
            f"open\t{root}/unrelated.txt",
            f"list\t{root}/scripts",
            f'exec\t["git", "ls-files"]\t{root}',
            'exec\t["git", "log", "-1"]\t/tmp/a-fixture-repo',  # git in a temporary repository reads none of the tree
            "open\t/usr/lib/python3/os.py",
        ])
        self.assertEqual(g.escapes(inputs, trace, root),
                         ["lists scripts/", "reads unrelated.txt", "runs git ls-files"])

    def test_every_real_guard_step_gets_a_verdict(self):
        tree = g.Tree()
        steps = g.guard_steps()
        self.assertGreater(len(steps), 100)
        selectable = [s for s in steps if not g.inputs_of(tree, s).whole]
        self.assertGreater(len(selectable), 50)
        # A change to a test file runs that test's step.
        name, run, working_directory, *_ = selectable[0]
        files, _ = g.command_files(run, working_directory)
        self.assertIn(name, g.select(tree, [selectable[0]], [files[0]]))


if __name__ == "__main__":
    unittest.main()
