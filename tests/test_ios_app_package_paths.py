"""scripts/ci/ios_app_package_paths.py: the iOS workflows' path filters name exactly the local
packages the NEXT iOS app links, read from its manifests, so a Mac runs for every change the app
builds and for none it does not."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ios_app_package_paths", ROOT / "scripts/ci/ios_app_package_paths.py")
paths = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
sys.modules[SPEC.name] = paths
SPEC.loader.exec_module(paths)


def write(root: Path, rel: str, text: str) -> None:
    p = root / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)


WORKFLOW = """name: x
on:
  pull_request:
    paths:
      - "cmux-next-ios/**"
{lines}
      - "!**/*.md"
  push:
    branches: [feat-cmux-next]
    paths:
      - "cmux-next-ios/**"
{lines}
  workflow_dispatch:
jobs: {{}}
"""


class FixtureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        write(self.root, "cmux-next-ios/project.yml",
              "name: app\npackages:\n  CmuxMobileKit:\n    path: CmuxMobileKit\n  Conv:\n    path: ../Packages/iOS/Conv\n"
              "targets:\n  App:\n    info:\n      path: App/Info.plist\n")
        write(self.root, "cmux-next-ios/CmuxMobileKit/Package.swift",
              'let p = Package(dependencies: [.package(path: "../../Packages/Shared/A")])\n')
        write(self.root, "Packages/iOS/Conv/Package.swift", "let p = Package()\n")
        # A links B transitively; C is a shared package the app never links.
        write(self.root, "Packages/Shared/A/Package.swift", 'let p = Package(dependencies: [.package(path: "../B")])\n')
        write(self.root, "Packages/Shared/B/Package.swift", "let p = Package()\n")
        write(self.root, "Packages/Shared/C/Package.swift", "let p = Package()\n")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def workflows(self, lines: list[str]) -> None:
        body = "\n".join(f'      - "{line}"' for line in lines)
        for wf in paths.WORKFLOWS:
            write(self.root, wf, WORKFLOW.format(lines=body))

    def test_closure_is_transitive_and_skips_info_plist_paths(self) -> None:
        self.assertEqual(paths.app_packages(self.root), ["Packages/Shared/A", "Packages/Shared/B", "Packages/iOS/Conv"])

    def test_exact_filters_pass(self) -> None:
        self.workflows(["Packages/Shared/A/**", "Packages/Shared/B/**", "Packages/iOS/Conv/**"])
        self.assertEqual(paths.check(self.root), [])

    def test_a_blanket_shared_filter_fails(self) -> None:
        self.workflows(["Packages/Shared/**", "Packages/iOS/Conv/**"])
        problems = paths.check(self.root)
        self.assertTrue(any("names Packages/Shared/**" in p for p in problems), problems)

    def test_resource_wildcard_cannot_admit_unlinked_packages(self) -> None:
        self.workflows(["Packages/Shared/A/**", "Packages/Shared/B/**", "Packages/iOS/Conv/**",
                        "Packages/Shared/**/Resources/**"])
        self.assertTrue(any("names Packages/Shared/**/Resources/**" in p for p in paths.check(self.root)))

    def test_a_missing_transitive_package_fails(self) -> None:
        self.workflows(["Packages/Shared/A/**", "Packages/iOS/Conv/**"])
        problems = paths.check(self.root)
        self.assertTrue(any("misses Packages/Shared/B/**" in p for p in problems), problems)

    def test_an_unlinked_package_fails(self) -> None:
        self.workflows(["Packages/Shared/A/**", "Packages/Shared/B/**", "Packages/Shared/C/**", "Packages/iOS/Conv/**"])
        problems = paths.check(self.root)
        self.assertTrue(any("names Packages/Shared/C/**" in p for p in problems), problems)


class RepoTests(unittest.TestCase):
    def test_the_repo_filters_match_the_app(self) -> None:
        self.assertEqual(paths.check(ROOT), [])

    def test_the_rust_inputs_come_from_the_ffi_cargo_graph(self) -> None:
        packages, roots = paths.ffi_closure(ROOT)
        want = paths.rust_inputs(packages, roots)
        self.assertIn("cmux-tui/crates/cmux-wg/**", want)  # cmux#55399's crate
        self.assertIn("cmux-tui/Cargo.lock", want)
        self.assertFalse([w for w in want if w.startswith("cmux-next-ios/")], "cmux-next-ios/** covers those")

    def test_a_new_shared_crate_is_a_drift(self) -> None:
        packages, roots = paths.ffi_closure(ROOT)
        problems = paths.check(ROOT, rust=(packages + ["cmux-tui/crates/cmux-new-shared"], roots))
        self.assertEqual(problems, ["ci/steps.toml: step ios-kit misses cmux-tui/crates/cmux-new-shared/** "
                                    "(CmuxMobileLinkFFI compiles it)"])

    def test_a_crate_the_ffi_dropped_is_a_drift(self) -> None:
        packages, roots = paths.ffi_closure(ROOT)
        problems = paths.check(ROOT, rust=([p for p in packages if p != "cmux-tui/crates/cmux-wg"], roots))
        self.assertEqual(problems, ["ci/steps.toml: step ios-kit names cmux-tui/crates/cmux-wg/**, which "
                                    "CmuxMobileLinkFFI does not compile"])


if __name__ == "__main__":
    unittest.main()
