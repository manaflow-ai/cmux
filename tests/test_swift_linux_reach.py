#!/usr/bin/env python3
"""scripts/ci/swift_linux_reach.py: a pull request runs only the Swift-on-Linux groups and listed suites its
change can fail, and every group when it cannot tell (fails open)."""

import json
import fnmatch
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import swift_linux_reach as reach  # noqa: E402

WORKFLOW = ROOT / ".github" / "workflows" / "swift-linux-packages.yml"


class Reach(unittest.TestCase):
    def setUp(self):
        self.all = list(reach.matrix_groups(ROOT))

    def test_reads_every_matrix_group(self):
        self.assertEqual(self.all[0], "listed")
        self.assertIn("ios-kit", self.all)
        self.assertGreaterEqual(len(self.all), 10)

    def test_one_package_runs_its_groups_and_dependents_only(self):
        out = reach.reach(["Packages/Shared/CmuxEgress/Sources/CmuxEgress/x.swift"])
        self.assertIn("CmuxEgress", out["groups"])
        self.assertNotIn("CmuxVisibleRows", out["groups"])
        self.assertNotIn("stack-auth", out["groups"])
        self.assertLess(len(out["groups"]), len(self.all))

    def test_a_dependency_reaches_its_dependents(self):
        # Every package naming CmuxEgress by path, directly or through another, runs.
        pkgs = reach.packages(ROOT)
        direct = sorted(p for p, deps in pkgs.items() if "Packages/Shared/CmuxEgress" in deps)
        self.assertTrue(direct, "some package depends on CmuxEgress")
        out = reach.reach(["Packages/Shared/CmuxEgress/Package.swift"])
        rows = reach.listed_rows(ROOT)
        for p in direct:
            if p in rows:
                self.assertIn(p, out["listed"].split())

    def test_whole_run_files_run_everything(self):
        for f in reach.WHOLE_RUN:
            out = reach.reach([f])
            self.assertEqual(out["groups"], self.all, f)
            self.assertEqual(out["listed"], "*", f)

    def test_suite_helpers_route_the_workflow_and_every_group(self):
        routing = json.loads((ROOT / 'scripts/ci/pr_router.json').read_text())['callees']['swift-linux-packages.yml']
        for helper in ('scripts/ci/package-test-lane/swift_suite_outcomes.py', 'scripts/ci/require_swift_test_execution.py'):
            self.assertEqual(reach.reach([helper])['groups'], self.all)
            for selection in ('paths', 'affects'):
                self.assertTrue(any(fnmatch.fnmatchcase(helper, pattern) for pattern in routing[selection]))

    def test_the_list_runs_every_row(self):
        out = reach.reach([reach.LIST])
        self.assertEqual(out["listed"], "*")
        self.assertEqual(out["groups"][0], "listed")

    def test_a_file_in_no_package_runs_everything(self):
        out = reach.reach(["Packages/Shared/README-not-a-package.md"])
        self.assertEqual(out["groups"], self.all)

    def test_cmuxnext_outside_its_linux_targets_reaches_nothing(self):
        out = reach.reach(["Packages/macOS/CmuxNext/Sources/CmuxNextSomethingMacOnly/x.swift"])
        self.assertNotIn("Packages/macOS/CmuxNext", out["listed"].split())
        out = reach.reach(["Packages/macOS/CmuxNext/Sources/CmuxNextHostPressure/x.swift"])
        self.assertIn("Packages/macOS/CmuxNext", out["listed"].split())

    def test_every_cmuxnext_linux_target_reaches_its_row(self):
        # Before 2026-11-26 the reach list was a copy that named 3 of the 16 targets, so a change to Focus,
        # CLIInstall, Compat, CopyMode, TerminalFind or TerminalGeometry skipped the Linux CmuxNext row.
        names = reach.linux_target_names(ROOT, "Packages/macOS/CmuxNext")
        self.assertIn("CmuxNextFocus", names)
        for name in names:
            top = "Tests" if name.endswith("Tests") else "Sources"
            out = reach.reach([f"Packages/macOS/CmuxNext/{top}/{name}/x.swift"])
            self.assertIn("Packages/macOS/CmuxNext", out["listed"].split(), name)

    def test_app_ffi_inputs_reach_the_cmuxnext_row(self):
        for f in ("cmux-tui/crates/cmux-app-ffi/src/lib.rs", "cmux-tui/Cargo.lock", "scripts/ci/app_ffi_linux.py",
                  "scripts/cmux-next/build-app-ffi.sh", "Packages/macOS/CmuxNext/LinuxAppFFI/x"):
            self.assertEqual(reach.reach([f])["listed"], "Packages/macOS/CmuxNext", f)
        self.assertEqual(reach.reach(["cmux-tui/README.md"])["listed"], "")

    def test_extra_inputs_reach_the_kit_row_and_group(self):
        for pkg, prefixes in reach.EXTRA_INPUTS.items():
            for prefix in prefixes:
                f = prefix + "x.json" if prefix.endswith("/") else prefix
                out = reach.reach([f])
                self.assertIn(pkg, out["listed"].split(), f)
                self.assertIn("ios-kit", out["groups"], f)
        self.assertEqual(reach.reach(["cmux-next-ios/rust/crates/cmux-mobile-link-ffi/src/lib.rs"])["groups"], [])

    def test_every_file_a_listed_kit_test_reads_outside_the_kit_is_an_extra_input(self):
        """The detector: a listed CmuxMobileKit test target that reads a file outside the kit through `#filePath`
        (a string literal naming a path that exists from one of the test file's ancestors) must name it in
        EXTRA_INPUTS, or a change to that file alone runs none of the Swift tests that read it."""
        kit = "cmux-next-ios/CmuxMobileKit"
        row = next(line.split() for line in (ROOT / reach.LIST).read_text().splitlines()
                   if line.split() and line.split()[0].rstrip("/") == kit)
        targets = row[1].split(",")
        literal = re.compile(r'"((?:[^"\\]|\\.)*)"')
        found = {}
        for target in targets:
            for f in sorted((ROOT / kit / "Tests" / target).rglob("*.swift")):
                text = f.read_text(errors="replace")
                if "#filePath" not in text:
                    continue
                for m in literal.finditer(text):
                    s = m.group(1)
                    if "\\(" in s:  # an interpolated name: its directory is the input
                        s = s.split("\\(")[0].rsplit("/", 1)[0] + "/"
                    if "/" not in s or s.startswith(("/", "http")) or " " in s:
                        continue
                    for up in f.parents:
                        if up == ROOT.parent:
                            break
                        if (up / s).exists():
                            rel = (up / s).resolve().relative_to(ROOT).as_posix()
                            if not rel.startswith(kit + "/"):
                                found.setdefault(rel, f.relative_to(ROOT).as_posix())
                            break
        self.assertIn("cmux-next-ios/rust/crates/cmux-mobile-link-ffi/tests/fixtures/connection_contract.json", found)
        prefixes = reach.EXTRA_INPUTS[kit]
        for rel, by in found.items():
            self.assertTrue(rel.startswith(prefixes) or rel + "/" in prefixes,
                            f"{by} reads {rel}; name it in swift_linux_reach.py EXTRA_INPUTS")

    def test_push_paths_and_router_name_every_extra_input(self):
        router = json.loads((ROOT / "scripts/ci/pr_router.json").read_text())

        def find(o):
            if isinstance(o, dict):
                entry = o.get("swift-linux-packages.yml")
                if isinstance(entry, dict) and "affects" in entry:
                    return entry
                for v in o.values():
                    hit = find(v)
                    if hit is not None:
                        return hit
            return None

        entry = find(router)
        push = WORKFLOW.read_text().split("  workflow_dispatch:")[0]
        for prefixes in reach.EXTRA_INPUTS.values():
            for prefix in prefixes:
                want = prefix + "**" if prefix.endswith("/") else prefix
                self.assertIn(want, entry["affects"], f"pr_router.json affects misses {want}")
                self.assertIn(want, entry["paths"], f"pr_router.json paths misses {want}")
                self.assertIn(f"      - {want}\n", push, f"{WORKFLOW.name} push paths miss {want}")

    def test_a_lost_target_list_fails_open(self):
        with tempfile.TemporaryDirectory() as d:
            pkg = Path(d) / "Packages/macOS/CmuxNext"
            pkg.mkdir(parents=True)
            (pkg / "Package.swift").write_text("let other = 1\n")
            with self.assertRaises(ValueError):
                reach.narrow(Path(d))
            (pkg / "Package.swift").write_text('let linuxTargetNames: Set<String> = [\n    "CmuxNextGone",\n]\n')
            with self.assertRaises(ValueError):
                reach.narrow(Path(d))

    def test_router_affects_names_every_reaching_path(self):
        router = json.loads((ROOT / "scripts/ci/pr_router.json").read_text())

        def find(o):
            if isinstance(o, dict):
                if "swift-linux-packages.yml" in o and isinstance(o["swift-linux-packages.yml"], dict) \
                        and "affects" in o["swift-linux-packages.yml"]:
                    return o["swift-linux-packages.yml"]["affects"]
                for v in o.values():
                    hit = find(v)
                    if hit is not None:
                        return hit
            return None

        globs = find(router)
        self.assertIsNotNone(globs)
        for prefix in reach.narrow(ROOT)["Packages/macOS/CmuxNext"]:
            want = prefix + "**" if prefix.endswith("/") else prefix
            self.assertIn(want, globs, f"pr_router.json swift-linux-packages.yml affects misses {want}")

    def test_cli_fails_open_and_writes_outputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            changed, gh_out = Path(tmp) / "changed", Path(tmp) / "out"
            changed.write_text("Packages/Shared/CmuxEgress/x.swift\0")
            subprocess.run([sys.executable, str(ROOT / "scripts/ci/swift_linux_reach.py"), "--changed", str(changed),
                            "--github-output", str(gh_out)], check=True, capture_output=True)
            lines = dict(line.split("=", 1) for line in gh_out.read_text().splitlines())
            self.assertIn('"CmuxEgress"', lines["groups"])
            gh_out.unlink()
            subprocess.run([sys.executable, str(ROOT / "scripts/ci/swift_linux_reach.py"), "--changed", str(Path(tmp) / "missing"),
                            "--github-output", str(gh_out)], check=True, capture_output=True)
            lines = dict(line.split("=", 1) for line in gh_out.read_text().splitlines())
            self.assertEqual(json.loads(lines["groups"]), self.all)
            self.assertEqual(lines["listed"], "*")


class Workflow(unittest.TestCase):
    def test_every_build_step_is_gated_and_the_plan_fails_open(self):
        wf = WORKFLOW.read_text()
        self.assertIn("python3 scripts/ci/swift_linux_reach.py", wf)
        self.assertIn("needs.plan.result != 'success' || needs.plan.outputs.groups == '*'", wf)
        self.assertIn("groups: ${{ steps.reach.outputs.groups || '*' }}", wf)
        for name in ("Checkout", "Install python3, SQLite and zlib headers, xz", "Cache key", "Restore .build",
                     "Fetch the fleet client from the controller", "package-test-lane.sh suite, every listed package",
                     "Build and test"):
            block = wf.split(f"- name: {name}\n", 1)[1].split("\n      - name:", 1)[0]
            self.assertIn("env.REACHED == '1'", block, name)
        self.assertEqual(wf.count('[ "$LISTED_ROWS" = \'*\' ] ||'), 2)


if __name__ == "__main__":
    unittest.main()
