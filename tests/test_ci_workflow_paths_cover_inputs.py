#!/usr/bin/env python3
"""Every file a path-filtered workflow's tests read starts that workflow, or the guard router runs the test for it.

scripts/ci/workflow_paths_cover_inputs.py reads each workflow with `paths:` or `paths-ignore:` on push or
pull_request, finds the tests its steps run, follows their imports, sourced scripts and the files they open by a
path built from `__file__`, and lists every such input the event's filter does not admit. A PR that changes only
that input starts no run of the workflow, merges green, and leaves the red for the next PR that touches a listed
path (cmuxterm-hq#8984: a suite imported a sibling tool's module its workflow did not list).

A gap is excused when cmux-next-guards.yml, which runs on every feat-cmux-next pull request and push with no path
filter, runs the same test for that input: `guards-local.sh --feat-routes` runs ci-guards.yml's `ci` group plus the
groups detect_linux_guard_changes.classify_feat routes the changed path to (scripts/ci/run_ci_guards.py plans
them).
"""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import workflow_paths_cover_inputs as detector  # noqa: E402
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

# (workflow, event) -> why its filter deliberately leaves out inputs of the tests it runs. Each needs a reason; an
# entry with no gap left behind it fails.
EXEMPT: dict[tuple[str, str], str] = {
    (".github/workflows/cmux-next.yml", "push"): (
        "a feat-cmux-next push starts every tier, the Mac compiles included, so its push list stays the product "
        "list (#21504); pull requests admit every CI input and the router picks the tier "
        "(tests/test_ci_workflow_path_filter_parity.py PULL_REQUEST_ONLY_PATTERNS)"
    ),
}


def guard_router():
    """covered(test, path, workflow, event, document): whether cmux-next-guards' routed guard run executes `test` for
    a change to `path` every time `event` starts the workflow.

    cmux-next-guards runs for feat-cmux-next pull requests and pushes only, so it covers an event only when that
    event is limited to feat-cmux-next; a push run leaves out release-notary (it runs in nightly-guards)."""
    import detect_linux_guard_changes  # noqa: PLC0415 - scripts/ci, the router
    import run_ci_guards  # noqa: PLC0415

    units = run_ci_guards.plan(run_ci_guards.load_yaml(ROOT / ".github/workflows/ci-guards.yml"), "BASE", "HEAD")
    walker = detector.Walker(detector.Repo.load(ROOT))
    tests: dict[str, set[str]] = {}
    for unit in units:
        for step in unit.steps:
            cwd = str(ROOT / step.working_directory) if step.working_directory else str(ROOT)
            for name in {unit.group, unit.job} - {None}:
                tests.setdefault(name, set()).update(walker.entries(step.run, cwd, {}))
    cache: dict[tuple[str, str], set[str]] = {}

    def feat_only(document, event: str) -> bool:
        config = detector.triggers(document).get(event)
        branches = config.get("branches") if isinstance(config, dict) else None
        return isinstance(branches, list) and set(map(str, branches)) == {"feat-cmux-next"}

    def covered(test: str, path: str, workflow: str, event: str, document) -> bool:
        if not feat_only(document, event):
            return False
        key = (path, event)
        if key not in cache:
            groups = set(run_ci_guards.FAST_GROUPS) | set(detect_linux_guard_changes.classify_feat([path]))
            if event == "push":
                groups.discard("release-notary")
            cache[key] = set().union(*(tests.get(group, set()) for group in groups))
        return test in cache[key]

    return covered


class WorkflowPathsCoverInputs(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gaps, cls.unknown, cls.checked = detector.find_gaps(ROOT, covered=guard_router())

    def test_every_input_of_a_filtered_workflows_tests_starts_it(self):
        open_gaps = [g for g in self.gaps if (g.workflow, g.event) not in EXEMPT]
        lines = [f"{g.workflow} ({g.event}): {g.input}  [{' -> '.join(g.chain)}]" for g in open_gaps]
        self.assertEqual(lines, [], "add each input to the workflow's paths (both lists), or the test misses its "
                                    "changes (docs: scripts/ci/workflow_paths_cover_inputs.py)")

    def test_every_exemption_still_has_a_gap_and_a_reason(self):
        exempted = {(g.workflow, g.event) for g in self.gaps}
        for key, reason in EXEMPT.items():
            self.assertTrue(reason.strip(), key)
            self.assertIn(key, exempted, f"{key} has no gap left: remove its EXEMPT entry")

    def test_the_detector_reads_the_workflows(self):
        self.assertIn(".github/workflows/cmux-next.yml", self.checked)
        self.assertTrue(self.checked[".github/workflows/cmux-next.yml"], "cmux-next.yml runs tests the detector found")


class DetectorUnits(unittest.TestCase):
    def test_filters_follow_github(self):
        admits = detector.admits
        self.assertTrue(admits("paths", ["scripts/ci/**"], "scripts/ci/a/b.py"))
        self.assertFalse(admits("paths", [".github/workflows/*.yml"], ".github/workflows/x/y.yml"))
        self.assertFalse(admits("paths", ["build/**", "!build/**/*.md"], "build/a/README.md"))
        self.assertTrue(admits("paths", ["build/**", "!build/a/**", "build/a/keep.py"], "build/a/keep.py"))
        self.assertFalse(admits("paths-ignore", ["docs/**"], "docs/x.md"))
        self.assertTrue(admits("paths-ignore", ["docs/**"], "src/x.py"))
        self.assertTrue(admits("paths", ["**/*.py"], "a.py"))

    def test_event_conditions_drop_only_other_events(self):
        self.assertFalse(detector.may_run_for("github.event_name == 'schedule'", "pull_request"))
        self.assertTrue(detector.may_run_for("github.event_name == 'schedule' || inputs.x", "pull_request"))
        self.assertFalse(detector.may_run_for("${{ github.event_name != 'pull_request' }}", "pull_request"))
        self.assertTrue(detector.may_run_for("${{ github.event_name != 'pull_request' }}", "push"))

    def test_run_targets(self):
        self.assertEqual(detector.run_targets(["python3", "-I", "tests/test_a.py", "-v"]), ["tests/test_a.py"])
        self.assertEqual(detector.run_targets(["X=1", "bash", "-o", "pipefail", "t.sh"]), ["t.sh"])
        self.assertEqual(detector.run_targets(["python3", "-m", "unittest", "a"]), [])
        self.assertEqual(detector.run_targets(["for", "t", "in", "a.py", "b.py"]), ["a.py", "b.py"])
        self.assertEqual(detector.run_targets(["chmod", "+x", "scripts/*.sh"]), ["chmod"])

    def test_python_paths_from_file(self):
        import ast
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "pkg" / "test_x.py"
            source.parent.mkdir()
            source.write_text(
                "import sys, subprocess\nfrom pathlib import Path\n"
                "ROOT = Path(__file__).resolve().parents[1]\n"
                "sys.path.insert(0, str(ROOT / 'tools' / 'lib'))\n"
                "DATA = ROOT / 'fixtures' / 'a.json'\n"
                "subprocess.run([sys.executable, str(ROOT / 'tools' / 'run.py')])\n"
                "import helper\n"
            )
            facts = detector.python_facts(str(source))
            self.assertIn(str(Path(tmp) / "tools" / "lib"), facts.sys_path)
            self.assertIn(str(Path(tmp) / "fixtures" / "a.json"), facts.paths)
            self.assertIn(str(Path(tmp) / "tools" / "run.py"), facts.runs)
            self.assertNotIn(str(Path(tmp) / "fixtures" / "a.json"), facts.runs)
            self.assertIn(("helper", 0, ()), facts.imports)
            ast.parse(source.read_text())

    def test_review_findings_on_a_fixture_repo(self):
        """Each case a review of the first version reproduced: a cached sys.path addition, an undotted unittest module,
        `go test $(go list)` and a Go file read, a `<` operand, a test covered while another is not, and a broken
        nested action file."""
        import subprocess

        files = {
            ".github/workflows/w.yml": (
                "on:\n  pull_request:\n    paths: ['a/**', '.github/workflows/w.yml']\n"
                "jobs:\n  t:\n    runs-on: x\n    steps:\n"
                "      - run: python3 a/test_one.py && python3 a/test_two.py\n"
                "      - run: cd a && python3 -m unittest -v solo_test\n"
                "      - run: bash a/test_redirect.sh\n"
                "      - run: |\n          pkgs=$(go list ./... | grep -v x)\n          go test $pkgs\n"
                "        working-directory: g\n"
                "      - uses: ./.github/actions/broken\n"
            ),
            ".github/actions/broken/action.yml": "runs: [unclosed\n",
            "a/test_one.py": "import sys\nfrom pathlib import Path\nsys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'lib'))\nimport boot\n",
            "a/test_two.py": "import sys\nfrom pathlib import Path\nsys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'lib'))\nimport boot\n",
            "lib/boot.py": "import sys\nfrom pathlib import Path\nsys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'deep'))\nimport deepmod\n",
            "deep/deepmod.py": "",
            "a/solo_test.py": "import solo_dep\n",
            "a/solo_dep.py": "",
            "a/test_redirect.sh": "cat < data/input.py\n",  # relative to the step's directory
            "data/input.py": "import shouldnotfollow\n",
            "data/shouldnotfollow.py": "",
            "g/go.mod": "module ex\n",
            "g/p/p.go": "package p\n",
            "g/p/p_test.go": 'package p\nconst wf = "x.yml"\nfunc f() { os.ReadFile(filepath.Join("..", "..", "spec", wf)) }\n',
            "spec/x.yml": "",
        }
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for rel, text in files.items():
                (root / rel).parent.mkdir(parents=True, exist_ok=True)
                (root / rel).write_text(text)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            gaps, unknown, checked = detector.find_gaps(root)
            found = {g.input for g in gaps}
            # Both tests reach deep/deepmod.py through lib/boot.py, whichever was walked first.
            self.assertIn("deep/deepmod.py", found)
            self.assertLessEqual({"a/test_one.py", "a/test_two.py", "a/solo_test.py", "g/p/p_test.go"},
                                 set(checked[".github/workflows/w.yml"]))
            self.assertIn("spec/x.yml", found)  # the Go test's ReadFile
            self.assertIn("data/input.py", found)  # read through `<`: data
            self.assertNotIn("data/shouldnotfollow.py", found)  # ...so its imports are not followed
            self.assertIn("lib/boot.py", found)
            self.assertTrue(any("unreadable" in " ".join(v) for v in unknown.values()), unknown)

            # An input read by two tests is a gap unless the router covers both.
            only_one = detector.find_gaps(root, covered=lambda test, path, *_: test == "a/test_one.py")[0]
            self.assertIn("lib/boot.py", {g.input for g in only_one})
            both = detector.find_gaps(root, covered=lambda test, path, *_: test in ("a/test_one.py",
                                                                                     "a/test_two.py"))[0]
            self.assertNotIn("lib/boot.py", {g.input for g in both})

    def test_shell_forms(self):
        words = list(detector.shell_words('DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
                                          'source "$DIR/lib.sh"\n. "$UNSET/x.sh"\n', "/r/s", {}, []))
        self.assertEqual(words[0], ["source", "/r/s/lib.sh"])
        self.assertEqual(words[1], [".", "$UNSET/x.sh"])


if __name__ == "__main__":
    unittest.main()
