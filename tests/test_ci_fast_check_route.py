"""scripts/ci/fast_check_route.py: the fast per-PR checks skip a pull request that touches none of their inputs, run
everything on a push, the full-ci label, an unreadable diff or a router change, and the detector holds each check's
declared inputs to what its job actually reads."""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
spec = importlib.util.spec_from_file_location("fast_check_route", ROOT / "scripts/ci/fast_check_route.py")
route = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = route
spec.loader.exec_module(route)

FAST_GATES = ".github/workflows/cmux-next-fast-gates.yml"
GUARDS = ".github/workflows/cmux-next-guards.yml"
DOCTOR = ".github/workflows/cmux-next-react-doctor.yml"


def changed(*paths, status="M"):
    return [(status, path) for path in paths]


class TheRepositoryTest(unittest.TestCase):
    def test_the_map_holds_every_job_it_lists(self):
        """The detector on this tree: every input exists, every job is wired to the route, every push covers it, and
        each job reads nothing outside its inputs."""
        self.assertEqual(route.check(ROOT), [])


class RouteTest(unittest.TestCase):
    def run_route(self, workflow, pairs, event="pull_request", labels=()):
        return {job: run for job, (run, _why) in
                route.route(workflow, pairs, event=event, labels=list(labels), root=ROOT).items()}

    def test_a_product_change_outside_every_input_skips(self):
        self.assertEqual(self.run_route(DOCTOR, changed("cmux-next-ios/CmuxMobileKit/Sources/A.swift")),
                         {"react-doctor": False})
        self.assertEqual(self.run_route(FAST_GATES, changed("tests/test_base_red_excuse.py", "workers/x/index.ts")),
                         {"fast-gates": False})
        self.assertEqual(self.run_route(GUARDS, changed("cmux-tui/crates/acpmux/src/lib.rs"))["ci-guard-group"],
                         False)

    def test_an_input_runs_it(self):
        self.assertEqual(self.run_route(DOCTOR, changed("webviews/src/App.tsx")), {"react-doctor": True})
        self.assertEqual(self.run_route(FAST_GATES, changed("Packages/macOS/CmuxNext/Sources/A.swift")),
                         {"fast-gates": True})
        self.assertEqual(self.run_route(FAST_GATES, changed("Resources/Localizable.xcstrings")), {"fast-gates": True})
        self.assertEqual(self.run_route(GUARDS, changed("tests/test_base_red_excuse.py")), {"ci-guard-group": True, "own-change-checks": False})

    def test_the_workflow_itself_is_an_input(self):
        self.assertEqual(self.run_route(DOCTOR, changed(DOCTOR)), {"react-doctor": True})

    def test_a_guard_group_route_runs_the_guard_job(self):
        """A product path a routed group owns (a Swift test the determinism scan reads) runs the guard group."""
        self.assertTrue(self.run_route(GUARDS, changed("Packages/macOS/CmuxNext/Tests/ATests/ATests.swift"))[
                        "ci-guard-group"])

    def test_push_label_unreadable_and_router_run_everything(self):
        product = changed("cmux-next-ios/CmuxMobileKit/Sources/A.swift")
        self.assertEqual(self.run_route(DOCTOR, product, event="push"), {"react-doctor": True})
        self.assertEqual(self.run_route(DOCTOR, product, labels=["full-ci"]), {"react-doctor": True})
        self.assertEqual(self.run_route(DOCTOR, None), {"react-doctor": True})
        self.assertEqual(self.run_route(DOCTOR, changed("scripts/ci/fast_check_route.py")), {"react-doctor": True})

    def test_added_files_and_generated_outputs(self):
        data = {"workflows": {"w.yml": {"j": {"inputs": ["a/"], "added_files": True, "generated": True}}}}
        decide = lambda pairs: route.route("w.yml", pairs, event="pull_request", labels=[], root=ROOT, data=data)["j"][0]
        self.assertFalse(decide(changed("b/x.txt")))
        self.assertTrue(decide(changed("b/x.txt", status="A")))
        self.assertTrue(decide(changed("b/generated/x.json")))
        self.assertTrue(decide(changed("a/x.txt")))

    def test_globs(self):
        self.assertTrue(route.covered("Resources/Localizable.xcstrings", "**/*.xcstrings"))
        self.assertTrue(route.covered("Localizable.xcstrings", "**/*.xcstrings"))
        self.assertFalse(route.covered("Resources/a.json", "**/*.xcstrings"))
        self.assertTrue(route.covered("web/x", "web/"))
        self.assertFalse(route.covered("webviews/x", "web/"))

    def test_the_cli_writes_github_outputs(self):
        with tempfile.TemporaryDirectory() as temp:
            names = Path(temp) / "changed.txt"
            names.write_text("M\tcmux-next-ios/CmuxMobileKit/Sources/A.swift\n", encoding="utf-8")
            out = Path(temp) / "out"
            route.main(["route", "--workflow", DOCTOR, "--changed", str(names), "--event", "pull_request",
                        "--github-output", str(out)])
            self.assertEqual(out.read_text(encoding="utf-8"), "react_doctor=false\n")


class DetectorTest(unittest.TestCase):
    """The detector on a small tree: what it refuses."""

    WORKFLOW = """name: t
on:
  pull_request:
  push:
    branches: [feat-cmux-next]
jobs:
  fast-check-route:
    runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository && (vars.CI_FORK_LINUX_RUNNER || 'ubuntu-24.04') || vars.CI_OVERFLOW_LINUX || 'cmux-linux' }}
    outputs:
      gate: ${{ steps.route.outputs.gate }}
    steps:
      - run: python3 scripts/ci/fast_check_route.py route --workflow .github/workflows/t.yml
  gate:
    needs: fast-check-route
    if: ${{ !cancelled() && needs.fast-check-route.outputs.gate != 'false' }}
    steps:
      - run: python3 scripts/ci/gate.py
"""
    GATE = 'import helper\nDATA = "data/rules.json"\nprint("see docs/readme.md")\n'

    def tree(self, inputs, workflow=WORKFLOW, gate=GATE, not_inputs=None):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        files = {
            ".github/workflows/t.yml": workflow,
            "scripts/ci/gate.py": gate,
            "scripts/ci/helper.py": 'OTHER = "other/thing.txt"\n',
            "scripts/ci/fast_check_route.py": "",
            "data/rules.json": "{}",
            "docs/readme.md": "",
            "other/thing.txt": "",
            route.MAP: json.dumps({"workflows": {".github/workflows/t.yml": {"gate": {
                "inputs": inputs, "not_inputs": not_inputs or {}}}}}),
        }
        for path, text in files.items():
            (root / path).parent.mkdir(parents=True, exist_ok=True)
            (root / path).write_text(text, encoding="utf-8")
        return route.check(root, files=list(files))

    def test_whole(self):
        self.assertEqual(self.tree(["scripts/ci/gate.py", "scripts/ci/helper.py", "data/", "other/"],
                                   not_inputs={"docs/readme.md": "named in a message"}), [])

    def test_a_read_outside_the_inputs(self):
        problems = self.tree(["scripts/ci/gate.py", "scripts/ci/helper.py", "other/"])
        self.assertTrue(any("reads data/rules.json" in p for p in problems), problems)
        self.assertTrue(any("reads docs/readme.md" in p for p in problems), problems)

    def test_an_import_is_followed(self):
        problems = self.tree(["scripts/ci/gate.py", "data/", "docs/"])
        self.assertTrue(any("reads scripts/ci/helper.py" in p for p in problems), problems)
        self.assertTrue(any("reads other/thing.txt" in p for p in problems), problems)

    def test_an_input_that_names_nothing(self):
        problems = self.tree(["scripts/ci/gate.py", "scripts/ci/helper.py", "data/", "other/", "docs/", "gone/"])
        self.assertTrue(any("input gone/ names no tracked path" in p for p in problems), problems)

    def test_an_unwired_job(self):
        unwired = self.WORKFLOW.replace("    if: ${{ !cancelled() && needs.fast-check-route.outputs.gate != 'false' }}\n",
                                        "")
        problems = self.tree(["scripts/ci/gate.py", "scripts/ci/helper.py", "data/", "other/", "docs/"],
                             workflow=unwired)
        self.assertTrue(any("does not read" in p for p in problems), problems)

    def test_a_heavy_route_runner(self):
        heavy = self.WORKFLOW.replace(f"    runs-on: {route.ROUTE_RUNS_ON}\n    outputs:", "    runs-on: big\n    outputs:")
        problems = self.tree(["scripts/ci/gate.py", "scripts/ci/helper.py", "data/", "other/", "docs/"],
                             workflow=heavy)
        self.assertTrue(any("not the one Linux label" in p for p in problems), problems)

    def test_no_push_and_no_cover(self):
        no_push = self.WORKFLOW.replace("  push:\n    branches: [feat-cmux-next]\n", "")
        problems = self.tree(["scripts/ci/gate.py", "scripts/ci/helper.py", "data/", "other/", "docs/"],
                             workflow=no_push)
        self.assertTrue(any("no feat-cmux-next push starts" in p for p in problems), problems)


class ReactDoctorRouteRunsOnlyWhereItsGateCanTest(unittest.TestCase):
    """The React Doctor route job skips where its gate job cannot run (into feat-cmux-next without full-ci): 2,563
    route runs and 2,944 runner-min in 10 h of 2026-11-25 fed a gate that ran 246 times, base pushes included."""

    @staticmethod
    def runs(expr: str, base: str, labels: tuple[str, ...], event: str = "pull_request", draft: bool = False) -> bool:
        import re  # noqa: PLC0415
        py = expr.strip().removeprefix("${{").removesuffix("}}")
        py = re.sub(r"contains\(github\.event\.pull_request\.labels\.\*\.name, '([^']*)'\)",
                    lambda m: repr(m.group(1) in labels), py)
        py = re.sub(r"startsWith\(github\.event\.pull_request\.base\.ref, '([^']*)'\)",
                    lambda m: repr(base.startswith(m.group(1))), py)
        py = py.replace("(vars.CI_DRAFT_CHEAP_TIER || '1')", "'1'").replace("vars.CI_FORK_LINUX_RUNNER", "''")
        py = re.sub(r"needs\.[a-z-]+\.outputs\.[a-z_]+", "''", py)
        py = py.replace("!cancelled()", "True")
        py = py.replace("github.event.pull_request.draft", repr(draft)).replace("github.event_name", repr(event))
        py = py.replace("&&", " and ").replace("||", " or ").replace("!=", " __NE__ ").replace("==", " __EQ__ ")
        py = py.replace("!", " not ").replace(" __NE__ ", " != ").replace(" __EQ__ ", " == ")
        py = py.replace("true", "True").replace("false", "False")
        return bool(eval(py, {"__builtins__": {}}, {}))  # noqa: S307 - the input is this repository's workflow

    def test_the_route_runs_exactly_where_the_gate_can(self):
        import yaml  # noqa: PLC0415
        jobs = yaml.safe_load((ROOT / DOCTOR).read_text(encoding="utf-8"))["jobs"]
        route_if, gate_if = jobs["fast-check-route"]["if"], jobs["react-doctor"]["if"]
        for base, labels in (("feat-cmux-next", ()), ("feat-cmux-next", ("full-ci",)), ("main", ()),
                             ("main", ("full-ci",))):
            self.assertEqual(self.runs(route_if, base, labels), self.runs(gate_if, base, labels), (base, labels))
        self.assertFalse(self.runs(route_if, "feat-cmux-next", ()))
        self.assertTrue(self.runs(route_if, "feat-cmux-next", ("full-ci",)))
        self.assertFalse(self.runs(route_if, "", (), event="push"))  # a push runs the gate on every project

if __name__ == "__main__":
    unittest.main()
