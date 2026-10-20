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
                   "nightly-next-car-guard.sh"):
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


class CarGuards(unittest.TestCase):
    def test_a_kind_is_reused_only_when_every_covering_pr_check_passed(self):
        checks = "cmux-next checks (god files, concurrency, crash safety, l10n)"
        self.assertEqual(car_guards.reused_kinds({}), set())
        self.assertEqual(car_guards.reused_kinds({"web / Web tests (1)": "success", "web / Web tests (2)": "success"}), {"web"})
        self.assertEqual(car_guards.reused_kinds({"web / Web tests (1)": "success", "web / Web tests (2)": "failure"}), set())
        self.assertEqual(car_guards.reused_kinds({checks: "SUCCESS"}), {"guard", "python"})
        self.assertEqual(car_guards.reused_kinds({"cmux-next fast tier (cargo)": "success"}), {"cargo"},
                         "the cargo job never stands in for the Swift fast tier")
        self.assertEqual(car_guards.reused_kinds({"cmux-next fast tier": "success", "cmux-next swift test": "skipped"}), set(),
                         "a skipped tier proved nothing")

    def run_car(self, quarantine: list[str]) -> tuple[int, dict]:
        with tempfile.TemporaryDirectory() as tmp:
            root = repo(tmp, {
                "scripts/cmux-next/prepush-gate.py": "import sys\nsys.exit(0)\n",
                "scripts/cmux-next/check-no-godfiles.sh": "exit 0\n",
                "scripts/cmux-next/quarantine.json": json.dumps({"entries": [{"name": n} for n in quarantine]}),
                "tests/test-execution.toml": '[[test]]\npath = "tests/test_tool.py"\nlane = "linux-guard"\n',
                "tests/test_tool.py": 'import sys\n"scripts/ci/the-tool.py"\nsys.exit(0)\n',
                "scripts/ci/the-tool.py": "",
            })
            base = git(root, "rev-parse", "HEAD")
            write(root, {"scripts/ci/the-tool.py": "x = 1\n", "tests/test_tool.py": 'import sys\n"scripts/ci/the-tool.py"\nsys.exit(1)\n'})
            git(root, "add", "-A")
            git(root, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "car")
            receipt = Path(tmp) / "verdict.json"
            proc = subprocess.run([sys.executable, "-I", str(root / "scripts/ci/car_guards.py"), "run", "--root", str(root),
                                   "--where", "linux", "--base", base, "--head", "HEAD", "--car", "pr-1",
                                   "--receipt", str(receipt)], capture_output=True, text=True, timeout=120)
            return proc.returncode, json.loads(receipt.read_text())

    def test_a_failing_focused_test_fails_the_car_with_its_output(self):
        code, verdict = self.run_car([])
        self.assertEqual(code, 1)
        self.assertEqual(verdict["status"], "fail")
        by_name = {r["name"]: r for r in verdict["results"]}
        self.assertEqual(by_name["python:tests/test_tool.py"]["status"], "fail")
        self.assertEqual(by_name["guard:prepush"]["status"], "pass")
        self.assertEqual(by_name["guard:godfiles"]["status"], "pass")
        self.assertEqual(verdict["car"], "pr-1")

    def test_a_quarantined_flake_still_runs_but_does_not_fail_the_car(self):
        code, verdict = self.run_car(["python:tests/test_tool.py"])
        self.assertEqual(code, 0)
        self.assertEqual({r["name"]: r["status"] for r in verdict["results"]}["python:tests/test_tool.py"], "quarantined-fail")

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

    def test_mac_runs_one_build_per_package_then_each_filter(self):
        the_plan = {"python": [], "web": [], "native": [], "cargo": {"changed": False}, "unmapped": [],
                    "swift": [{"package": "Packages/macOS/A", "filter": "ATests"}, {"package": "Packages/macOS/A", "filter": "BTests"}]}
        (entry,) = car_guards.entries(ROOT, "b", "h", "mac", the_plan, set())
        script = entry["cmd"][-1]
        self.assertEqual(script.count("swift build --build-tests"), 1)
        self.assertIn("--filter '^ATests\\.'", script)
        self.assertIn("--filter '^BTests\\.'", script)
        self.assertEqual(car_guards.entries(ROOT, "b", "h", "mac", the_plan, {"swift"}), [], "a reused kind does not run")


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
                              env={**os.environ, "CAR_GUARD_RECEIPTS": str(receipts)})

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
        self.assertEqual(sorted(on["workflow_call"]["outputs"]), ["linux", "mac"])
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
