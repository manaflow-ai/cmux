#!/usr/bin/env python3
"""The nightly train's per-car fast guards (workstreams/cmux-next-nightly-train.md 1.2, PR 3).

scripts/ci/focused_tests.py maps a car's changed source paths to the tests that cover them,
derived from the tree (Swift imports and path dependencies, the CmuxNext target graph, the
webviews import graph, tests that name a path), so no hand list rots. scripts/ci/car_guards.py
runs a car's repo guards and focused tests and writes one verdict; the train calls
.github/workflows/cmux-next-car-guards.yml once per car. Each case here builds a small
repository, so no real test, build or network runs.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
FOCUSED = ROOT / "scripts/ci/focused_tests.py"
GUARDS = ROOT / "scripts/ci/car_guards.py"
WORKFLOW = ROOT / ".github/workflows/cmux-next-car-guards.yml"
sys.path.insert(0, str(ROOT / "scripts/ci"))
import car_guards  # noqa: E402


def write(root: Path, files: dict[str, str]) -> None:
    for name, text in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")


def git(root: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True, text=True).stdout.strip()


def repo(tmp: str, files: dict[str, str]) -> Path:
    root = Path(tmp) / "repo"
    root.mkdir()
    # The helpers the map imports, from this checkout.
    for helper in ("select_package_tests.py", "focused_tests.py", "car_guards.py", "cmux_next_route.py",
                   "nightly-next-car-guard.sh", "car-guard-python.sh"):
        write(root, {f"scripts/ci/{helper}": (ROOT / "scripts/ci" / helper).read_text(encoding="utf-8")})
    write(root, files)
    git(root, "init", "-q")
    git(root, "add", "-A")
    git(root, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base")
    return root


def plan(root: Path, *files: str, env: dict | None = None) -> dict:
    out = subprocess.run([sys.executable, "-I", str(root / "scripts/ci/focused_tests.py"), "--root", str(root),
                          "--files", *files], check=True, capture_output=True, text=True,
                         env={**os.environ, **(env or {})}).stdout
    return json.loads(out)


SWIFT_TREE = {
    "Packages/macOS/App/Package.swift": '// swift-tools-version:6.0\n.package(path: "../../Shared/Core")\n',
    "Packages/macOS/App/Sources/AppKitty/View.swift": "struct V {}\n",
    "Packages/macOS/App/Tests/AppKittyTests/ViewTests.swift": "import Testing\n@testable import AppKitty\n",
    "Packages/macOS/App/Tests/UsesCoreTests/CoreTests.swift": "import Testing\nimport CoreModel\n",
    "Packages/macOS/App/Tests/UnrelatedTests/OtherTests.swift": "import Testing\nimport Foundation\n",
    "Packages/Shared/Core/Package.swift": "// swift-tools-version:6.0\n",
    "Packages/Shared/Core/Sources/CoreModel/Model.swift": "struct M {}\n",
    "Packages/Shared/Core/Tests/CoreModelTests/ModelTests.swift": "@testable import CoreModel\n",
}


class FocusedTestMap(unittest.TestCase):
    def test_a_swift_source_selects_the_test_targets_that_import_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = repo(tmp, SWIFT_TREE)
            got = plan(root, "Packages/macOS/App/Sources/AppKitty/View.swift")
            self.assertEqual([(s["package"], s["filter"]) for s in got["swift"]],
                             [("Packages/macOS/App", "AppKittyTests")])
            self.assertEqual(got["unmapped"], [])

    def test_a_shared_package_change_reaches_the_packages_that_depend_on_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = repo(tmp, SWIFT_TREE)
            got = plan(root, "Packages/Shared/Core/Sources/CoreModel/Model.swift")
            self.assertEqual(sorted((s["package"], s["filter"]) for s in got["swift"]),
                             [("Packages/Shared/Core", "CoreModelTests"), ("Packages/macOS/App", "UsesCoreTests")])

    def test_a_test_file_selects_its_target_and_a_manifest_selects_every_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = repo(tmp, SWIFT_TREE)
            got = plan(root, "Packages/macOS/App/Tests/UnrelatedTests/OtherTests.swift")
            self.assertEqual([s["filter"] for s in got["swift"]], ["UnrelatedTests"])
            got = plan(root, "Packages/macOS/App/Package.swift")
            self.assertEqual(sorted(s["filter"] for s in got["swift"]), ["AppKittyTests", "UnrelatedTests", "UsesCoreTests"])

    def test_python_tests_that_name_a_path_or_a_distinctive_script_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = repo(tmp, {
                "scripts/ci/bump-thing.py": "",
                "docs/README.md": "",
                "tests/test_by_path.py": 'SCRIPT = ROOT / "scripts/ci/bump-thing.py"\n',
                "tests/test_by_name.py": 'run("bump-thing.py")\n',
                "tests/test_readme.py": 'open("README.md")\n',
                "scripts/tests/test_scripts_dir.py": '"scripts/ci/bump-thing.py"\n',
            })
            got = plan(root, "scripts/ci/bump-thing.py")
            self.assertEqual([p["path"] for p in got["python"]],
                             ["scripts/tests/test_scripts_dir.py", "tests/test_by_name.py", "tests/test_by_path.py"])
            got = plan(root, "tests/test_readme.py", "docs/README.md")
            self.assertEqual([p["path"] for p in got["python"]], ["tests/test_readme.py"], "a changed test runs itself")
            self.assertEqual(got["docs"], ["docs/README.md"], "docs need no test and are not unmapped")
            self.assertEqual(got["unmapped"], [])

    def test_webviews_tests_cover_what_they_import_transitively_nearest_first(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = repo(tmp, {
                "webviews/src/pages/x/ops.ts": "export const a = 1\n",
                "webviews/src/pages/x/View.tsx": 'import { a } from "./ops"\n',
                "webviews/src/pages/x/index.ts": 'export * from "./View"\n',
                "webviews/src/pages/x/ops.test.ts": 'import { a } from "./ops"\n',
                "webviews/test/view.test.tsx": 'import { V } from "../src/pages/x"\n',
                "webviews/test/other.test.ts": 'import { b } from "../src/other"\n',
                "webviews/src/other.ts": "export const b = 2\n",
            })
            got = plan(root, "webviews/src/pages/x/ops.ts")
            self.assertEqual([w["path"] for w in got["web"]], ["src/pages/x/ops.test.ts", "test/view.test.tsx"])
            self.assertIn("3 hops", got["web"][1]["why"], "ops <- View <- index <- view.test")
            got = plan(root, "webviews/src/pages/x/ops.ts", env={"FOCUSED_WEB_CAP": "1"})
            self.assertEqual([w["path"] for w in got["web"]], ["src/pages/x/ops.test.ts"], "the nearest test is kept")
            self.assertEqual(got["web_dropped"], 1)

    def test_rust_changes_go_to_cargo_affected_and_native_workspaces(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = repo(tmp, {
                "cmux-tui/crates/a/src/lib.rs": "",
                "Native/OptChat/chief/Cargo.toml": "[package]\nname = \"chief\"\n[workspace]\n",
                "Native/OptChat/chief/Cargo.lock": "",
                "Native/OptChat/chief/src/lib.rs": "",
                "elsewhere/mystery.bin": "",
            })
            got = plan(root, "cmux-tui/crates/a/src/lib.rs", "Native/OptChat/chief/src/lib.rs", "elsewhere/mystery.bin")
            self.assertEqual(got["cargo"], {"changed": True, "files": ["cmux-tui/crates/a/src/lib.rs"]})
            self.assertEqual([n["manifest"] for n in got["native"]], ["Native/OptChat/chief/Cargo.toml"])
            self.assertEqual(got["unmapped"], ["elsewhere/mystery.bin"], "a file no rule maps is reported")

    def test_cmux_next_follows_the_committed_target_graph(self):
        """The car guards and the PR's swift test tier select the same CmuxNext targets."""
        sys.path.insert(0, str(ROOT / "scripts/ci"))
        import cmux_next_route
        import focused_tests

        sources = sorted((ROOT / "Packages/macOS/CmuxNext/Sources/CmuxNextFiles").glob("*.swift"))
        self.assertTrue(sources, "a CmuxNextFiles source to route")
        path = str(sources[0].relative_to(ROOT))
        routed = cmux_next_route.route(ROOT, "pull_request", [path], set())
        got = focused_tests.plan(ROOT, [path])
        self.assertEqual(sorted(s["filter"] for s in got["swift"] if s["package"] == "Packages/macOS/CmuxNext"),
                         sorted(routed.tests))


PASS = 'import sys\n"scripts/ci/the-tool.py"\nsys.exit(0)\n'
FAIL = 'import sys\n"scripts/ci/the-tool.py"\nsys.exit(1)\n'


class CarGuards(unittest.TestCase):
    def test_a_kind_is_reused_only_when_every_covering_pr_check_passed(self):
        checks = "cmux-next checks (god files, concurrency, crash safety, l10n)"
        self.assertEqual(car_guards.reused_kinds({}), set())
        self.assertEqual(car_guards.reused_kinds({checks: "SUCCESS"}), {"guard"},
                         "the checks job runs a fixed test list, not the car's focused python tests")
        self.assertEqual(car_guards.reused_kinds({"web / Web tests (1)": "success"}), set(),
                         "ci-web's Web tests are web/, not webviews/: never reused")
        self.assertEqual(car_guards.reused_kinds({"cmux-next fast tier (cargo)": "success"}), {"cargo"},
                         "the cargo job never stands in for the Swift fast tier")
        self.assertEqual(car_guards.reused_kinds({"cmux-next fast tier": "success", "cmux-next swift test": "skipped"}), set(),
                         "a skipped tier proved nothing")

    def run_car(self, base_test: str = PASS, head_test: str = FAIL, quarantine=(), godfiles: str = "exit 0\n",
                extra: dict | None = None) -> tuple[int, dict]:
        with tempfile.TemporaryDirectory() as tmp:
            root = repo(tmp, {
                "scripts/cmux-next/prepush-gate.py": "import sys\nsys.exit(0)\n",
                "scripts/cmux-next/check-no-godfiles.sh": godfiles,
                "scripts/cmux-next/quarantine.json": json.dumps({"entries": [{"name": n} for n in quarantine]}),
                "tests/test-execution.toml": '[[test]]\npath = "tests/test_tool.py"\nlane = "linux-guard"\n',
                "tests/test_tool.py": base_test,
                "scripts/ci/the-tool.py": "",
            })
            base = git(root, "rev-parse", "HEAD")
            write(root, {"scripts/ci/the-tool.py": "x = 1\n", "tests/test_tool.py": head_test, **(extra or {})})
            git(root, "add", "-A")
            git(root, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "car")
            receipt = Path(tmp) / "verdict.json"
            proc = subprocess.run([sys.executable, "-I", str(root / "scripts/ci/car_guards.py"), "run", "--root", str(root),
                                   "--where", "linux", "--base", base, "--head", "HEAD", "--car", "pr-1",
                                   "--receipt", str(receipt)], capture_output=True, text=True, timeout=120)
            self.assertEqual(git(root, "worktree", "list").count("\n"), 0, "the base worktree is removed")
            return proc.returncode, json.loads(receipt.read_text())

    @staticmethod
    def statuses(verdict: dict) -> dict[str, str]:
        return {r["name"]: r["status"] for r in verdict["results"]}

    def test_a_test_the_car_breaks_fails_the_car(self):
        code, verdict = self.run_car(base_test=PASS, head_test=FAIL)
        self.assertEqual((code, verdict["status"]), (1, "fail"))
        self.assertEqual(self.statuses(verdict), {"guard:prepush": "pass", "guard:godfiles": "pass",
                                                  "python:tests/test_tool.py": "fail"})
        self.assertEqual(verdict["car"], "pr-1")

    def test_a_test_red_at_the_base_too_is_the_bases_and_the_car_rides(self):
        """The PR's own first run: four selected tests were red on feat-cmux-next already."""
        code, verdict = self.run_car(base_test=FAIL, head_test=FAIL)
        self.assertEqual((code, verdict["status"]), (0, "pass"))
        self.assertEqual(self.statuses(verdict)["python:tests/test_tool.py"], "base-red")

    def test_a_quarantined_flake_still_runs_but_does_not_fail_the_car(self):
        code, verdict = self.run_car(quarantine=["python:tests/test_tool.py"])
        self.assertEqual(code, 0)
        self.assertEqual(self.statuses(verdict)["python:tests/test_tool.py"], "quarantined-fail")

    def test_a_missing_module_is_the_runners_error_not_the_cars_red(self):
        code, verdict = self.run_car(head_test='import a_module_no_runner_has\n"scripts/ci/the-tool.py"\n')
        self.assertEqual((code, verdict["status"]), (2, "error"))
        self.assertEqual(self.statuses(verdict)["python:tests/test_tool.py"], "error")

    def test_god_files_over_its_allowance_warns_as_on_the_checks_job(self):
        code, verdict = self.run_car(head_test=PASS, godfiles='[ "$GODFILES_WARN_SLACK" = 20 ] || exit 3\nexit 1\n')
        self.assertEqual((code, verdict["status"]), (0, "pass"))
        self.assertEqual(self.statuses(verdict)["guard:godfiles"], "warn")

    def test_a_serial_test_runs_alone_after_the_parallel_batch(self):
        the_plan = {"python": [{"path": "tests/a.py", "lane": "linux-guard", "serial": True},
                               {"path": "tests/b.py", "lane": "linux-guard", "serial": False}],
                    "web": [], "native": [], "cargo": {"changed": False}, "swift": [], "unmapped": []}
        todo = car_guards.entries(ROOT, "b", "h", "linux", the_plan, {"guard"})
        self.assertEqual([(e["name"], e.get("serial")) for e in todo], [("python:tests/a.py", True), ("python:tests/b.py", False)])
        order = []
        real = car_guards.run_one
        car_guards.run_one = lambda root, e: (order.append(e["name"]), {"name": e["name"], "kind": e["kind"], "status": "pass", "seconds": 0, "tail": ""})[1]
        try:
            car_guards.run_all(ROOT, todo)
        finally:
            car_guards.run_one = real
        self.assertEqual(order, ["python:tests/b.py", "python:tests/a.py"])

    def test_a_checkout_at_another_commit_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = repo(tmp, {"a.txt": ""})
            base = git(root, "rev-parse", "HEAD")
            write(root, {"a.txt": "x"})
            git(root, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qam", "car")
            proc = subprocess.run([sys.executable, "-I", str(root / "scripts/ci/car_guards.py"), "run", "--root", str(root),
                                   "--where", "linux", "--base", base, "--head", base], capture_output=True, text=True)
            self.assertEqual(proc.returncode, 2)
            self.assertIn("not the car's head", proc.stderr)

    def test_mac_builds_once_per_package_and_judges_each_filter_alone(self):
        the_plan = {"python": [], "web": [], "native": [], "cargo": {"changed": False}, "unmapped": [],
                    "swift": [{"package": "Packages/macOS/A", "filter": "ATests"}, {"package": "Packages/macOS/A", "filter": "BTests"}]}
        todo = car_guards.entries(ROOT, "b", "h", "mac", the_plan, set())
        self.assertEqual([e["name"] for e in todo], ["swift-build:Packages/macOS/A", "swift:ATests", "swift:BTests"])
        self.assertEqual(todo[1]["cmd"][-2:], ["--filter", "^ATests\\."])
        self.assertTrue(all(e.get("needs") == "swift-build:Packages/macOS/A" for e in todo[1:]))
        self.assertEqual(car_guards.entries(ROOT, "b", "h", "mac", the_plan, {"swift"}), [], "a reused kind does not run")
        real = car_guards.run_one
        car_guards.run_one = lambda root, e: {"name": e["name"], "kind": e["kind"], "status": "fail", "seconds": 0, "tail": ""}
        try:
            results = car_guards.run_all(ROOT, todo)
        finally:
            car_guards.run_one = real
        self.assertEqual([r["status"] for r in results], ["fail", "skipped", "skipped"], "no filter runs on a failed build")


class Deferred(unittest.TestCase):
    def test_a_browser_lane_webviews_file_is_deferred_not_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = repo(tmp, {
                "webviews/src/x.ts": "export const a = 1\n",
                "webviews/test/x.test.ts": 'import { a } from "../src/x"\n',
                "webviews/test/x-browser.test.ts": 'import { a } from "../src/x"\nimport { requireBrowserLane } from "./support/requireBrowserLane"\n',
            })
            got = plan(root, "webviews/src/x.ts")
            self.assertEqual([(w["path"], w["browser"]) for w in got["web"]], [("test/x-browser.test.ts", True), ("test/x.test.ts", False)])
            (web,) = [e for e in car_guards.entries(root, "b", "h", "linux", got, {"guard"}) if e["kind"] == "web"]
            self.assertEqual(web["env"]["CMUX_WEB_TEST_FILES"], "test/x.test.ts")

    def test_a_whole_package_swift_selection_is_deferred_to_the_candidate(self):
        tree = dict(SWIFT_TREE)
        for i in range(10):
            tree[f"Packages/macOS/App/Tests/Many{i}Tests/T.swift"] = "import Foundation\n"
        with tempfile.TemporaryDirectory() as tmp:
            root = repo(tmp, tree)
            got = plan(root, "Packages/macOS/App/Package.swift")
            self.assertEqual(got["swift"], [])
            self.assertIn("every test target", got["swift_deferred"])
        sys.path.insert(0, str(ROOT / "scripts/ci"))
        import focused_tests
        got = focused_tests.plan(ROOT, ["Packages/macOS/CmuxNext/Package.swift"])
        self.assertEqual([s for s in got["swift"] if s["package"] == "Packages/macOS/CmuxNext"], [])
        self.assertTrue(got["swift_deferred"], "a CmuxNext manifest change is the candidate's swift test tier")

    def test_a_plans_data_file_that_tests_name_selects_them(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = repo(tmp, {"plans/x/action-surfaces.json": "{}", "plans/x/notes.txt": "",
                              "tests/test_surfaces.py": '"plans/x/action-surfaces.json"\n'})
            got = plan(root, "plans/x/action-surfaces.json", "plans/x/notes.txt")
            self.assertEqual([p["path"] for p in got["python"]], ["tests/test_surfaces.py"])
            self.assertEqual(got["docs"], ["plans/x/notes.txt"])


class TrainAdapter(unittest.TestCase):
    """nightly_next_train_drive.py runs `nightly-next-car-guard.sh --car-json FILE` per car, up to
    eight at once from one checkout: exit 0 keeps the car, 1 quarantines it, else a warning."""

    def setUp(self):
        self.tmp = self.enterContext(tempfile.TemporaryDirectory())
        self.root = repo(self.tmp, {
            "scripts/cmux-next/prepush-gate.py": "import sys\nsys.exit(0)\n",
            "scripts/cmux-next/check-no-godfiles.sh": "exit 0\n",
            "tests/test-execution.toml": '[[test]]\npath = "tests/test_tool.py"\nlane = "linux-guard"\n',
            "tests/test_tool.py": 'import sys\n"scripts/ci/the-tool.py"\nsys.exit(0)\n',
            "scripts/ci/the-tool.py": "",
        })
        self.base = git(self.root, "rev-parse", "HEAD")

    def commit(self, files: dict[str, str]) -> str:
        write(self.root, files)
        git(self.root, "add", "-A")
        git(self.root, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "car")
        return git(self.root, "rev-parse", "HEAD")

    def guard(self, car: dict) -> subprocess.CompletedProcess:
        path = Path(self.tmp) / "car.json"
        path.write_text(json.dumps(car))
        receipts = Path(self.tmp) / "receipts"
        return subprocess.run(["bash", str(self.root / "scripts/ci/nightly-next-car-guard.sh"), "--car-json", str(path)],
                              capture_output=True, text=True, timeout=120,
                              env={**os.environ, "CAR_GUARD_RECEIPTS": str(receipts), "CAR_GUARD_PYTHON": sys.executable})

    def test_a_good_car_rides_and_a_bad_one_is_quarantined_in_its_own_worktree(self):
        good = self.commit({"scripts/ci/the-tool.py": "x = 1\n"})
        bad = self.commit({"tests/test_tool.py": 'import sys\n"scripts/ci/the-tool.py"\nsys.exit(1)\n'})
        git(self.root, "checkout", "-q", self.base)  # the train's checkout is elsewhere
        proc = self.guard({"id": "pr-1", "commits": [good]})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        proc = self.guard({"id": "pr-2", "commits": [bad]})
        self.assertEqual(proc.returncode, 1, proc.stderr)
        verdict = json.loads((Path(self.tmp) / "receipts/pr-2.json").read_text())
        self.assertEqual(verdict["head"], bad)
        self.assertEqual(git(self.root, "rev-parse", "HEAD"), self.base, "the train's checkout is not moved")
        self.assertEqual(git(self.root, "worktree", "list").count("\n"), 0, "the car's worktree is removed")

    def test_a_car_it_cannot_read_is_a_warning_not_a_quarantine(self):
        self.assertEqual(self.guard({"id": "pr-3", "commits": []}).returncode, 2)
        self.assertEqual(self.guard({"id": "pr-4", "commits": ["0" * 40]}).returncode, 2)


class CarGuardsWorkflow(unittest.TestCase):
    def workflow(self) -> dict:
        return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))

    def test_the_train_calls_it_per_car(self):
        on = self.workflow().get("on", self.workflow().get(True))
        inputs = on["workflow_call"]["inputs"]
        self.assertEqual(sorted(inputs), ["base", "car", "head", "prior"])
        self.assertTrue(all(inputs[n]["required"] for n in ("base", "head", "car")))
        self.assertEqual(sorted(on["workflow_call"]["outputs"]), ["linux", "linux_needed", "mac", "mac_needed"],
                         "a needed leg that never reported is told from one the plan did not need")
        self.assertIn("scripts/ci/focused_tests.py", on["pull_request"]["paths"], "a PR that changes the guards runs them")

    def test_it_runs_on_ci_runners_only_and_holds_no_secret(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertNotIn("secrets.", text)
        for name, job in self.workflow()["jobs"].items():
            with self.subTest(job=name):
                runs_on = str(job["runs-on"])
                self.assertRegex(runs_on, r"blacksmith-|ubuntu-|macos-26")
                self.assertNotRegex(runs_on.lower(), r"self-hosted|glaeda|cosmic|air-blue")
        mac_steps = self.workflow()["jobs"]["mac"]["steps"]
        restore = next(s for s in mac_steps if "cache-restore" in str(s.get("uses", "")))
        self.assertEqual(restore["env"]["CI_CACHE_R2_PUBLIC_URL"], "https://ci-cache-next.cmux.com",
                         "the Mac leg reads the fast-tier seed read-only")
        self.assertNotIn("save-if: true", text)

    def test_each_leg_reports_its_verdict(self):
        jobs = self.workflow()["jobs"]
        for leg in ("linux", "mac"):
            with self.subTest(leg=leg):
                self.assertEqual(jobs[leg]["outputs"]["status"], "${{ steps.guards.outputs.status }}")
                run = next(s for s in jobs[leg]["steps"] if s.get("id") == "guards")["run"]
                self.assertIn(f"--where {leg}", run)
                self.assertIn('echo "status=', run)
                upload = next(s for s in jobs[leg]["steps"] if "upload-artifact" in str(s.get("uses", "")))
                self.assertEqual(upload["if"], "always()")


if __name__ == "__main__":
    unittest.main()
