#!/usr/bin/env python3
"""Windows notices are pending review (mingw-w64): dogfood packages build, publishing stays closed.

The cmux-tui full gate's "release-path dogfood artifacts" job packages Windows
too. It needs a Windows notice file to build the npm tree, but no reviewed one
exists. The dogfood job writes a pending notice (windows_notice_pending.py);
publish paths never do, so their packaging still stops on the missing notice.
"""

from __future__ import annotations

import importlib.util
import re
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE))


def _load(name: str):
    spec = importlib.util.spec_from_file_location(name, HERE / f"{name}.py")
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


package_npm = _load("package_npm")
package_notices = _load("package_notices")
package_contract = _load("package_contract")
pending = _load("windows_notice_pending")
WINDOWS = "x86_64-pc-windows-gnu"


def _workflow(name: str) -> str:
    return (ROOT / ".github/workflows" / name).read_text()


class DogfoodPathTests(unittest.TestCase):
    def test_pending_notices_let_the_windows_packages_build(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            notices, package = Path(tmp) / "notices", Path(tmp) / "pkg"
            notices.mkdir()
            package.mkdir()
            pending.write_pending(notices)
            for kind in ("cmux-tui", "relay"):
                package_npm.copy_notice(notices, kind, WINDOWS, package)
                text = (package / package_npm.NOTICE_FILE).read_text()
                self.assertIn("pending review", text)
                self.assertIn("must not be published", text)

    def test_pending_never_replaces_a_generated_notice(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            notices = Path(tmp)
            (notices / f"cmux-tui-{WINDOWS}.md").write_text("reviewed notice\n")
            with self.assertRaises(SystemExit):
                pending.write_pending(notices)

    def test_only_the_dogfood_call_sets_windows_notices_pending(self) -> None:
        dogfood = re.split(r"\n  (?=[A-Za-z0-9_-]+:\n)", _workflow("cmux-tui.yml").split("\n  build-artifacts:\n", 1)[1], 1)[0]
        self.assertIn("      windows_notices_pending: ${{ inputs.mode == 'full' }}\n", dogfood + "\n")
        self.assertEqual(_workflow("cmux-tui.yml").count("windows_notices_pending"), 1)
        for name in (
            "cmux-tui-nightly.yml",
            "cmux-tui-release.yml",
            "cmux-tui-artifacts.yml",
            "relay-publish-npm.yml",
            "tui-publish-npm.yml",
            "tui-publish-pypi.yml",
        ):
            self.assertNotIn("windows_notices_pending", _workflow(name), name)
        # The reusable workflow writes the pending notice only for that input.
        build = _workflow("cmux-tui-build-package.yml")
        self.assertIn("if: inputs.windows_notices_pending && inputs.include_windows", build)


class PublishPathTests(unittest.TestCase):
    def test_publish_packaging_still_stops_without_a_windows_notice(self) -> None:
        self.assertIn(WINDOWS, package_notices.REFUSED)
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(SystemExit) as raised:
                package_npm.copy_notice(Path(tmp), "cmux-tui", WINDOWS, Path(tmp))
            self.assertIn("missing third-party notice", str(raised.exception))

    def test_publish_contract_refuses_a_pending_windows_notice(self) -> None:
        # Publishing takes packages only from cmux-tui-release.yml runs, whose notices
        # come from package_notices.py generate (no Windows file). A Windows package that
        # carries the dogfood pending text fails that contract.
        with tempfile.TemporaryDirectory() as tmp:
            release_notices = Path(tmp)
            problem = package_contract._notice_problem(
                pending.TEXT.encode(), release_notices, "cmux-tui", WINDOWS, "cmux-tui-win32-x64"
            )
            self.assertIsNotNone(problem)
            self.assertIn("no generated notice", problem)

    def test_publish_workflows_take_packages_only_from_release_runs(self) -> None:
        for name in ("tui-publish-npm.yml", "tui-publish-pypi.yml"):
            self.assertIn('artifact_path=".github/workflows/cmux-tui-release.yml"', _workflow(name), name)


if __name__ == "__main__":
    unittest.main()
