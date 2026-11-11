#!/usr/bin/env python3
"""fast-checks.yml pins out-of-tree scripts to the checkout's Playwright and proves it launches.

On 2026-10-28 a capture run (40786981913, `--setup playwright`) wrote its script to /tmp and ran
it with bun. Nothing above /tmp has a node_modules, so Bun auto-installed the newest Playwright
(1.64.1, Chromium revision 1248) instead of the pinned 1.62.1 whose browsers (revision 1234)
setup had installed, and the capture died mid-run: "Executable doesn't exist at
.../chromium_headless_shell-1248/...". Setup now exports NODE_PATH (Bun resolves it before
auto-installing) with the workspace whose Playwright installed the browsers first
(scripts/gallery-matrix for `playwright`; main's webviews has no Playwright at all), then
webviews, and launches the Playwright an out-of-tree script resolves plus each workspace's own,
so a missing or mismatched browser fails setup with its version and path.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

WORKFLOW = Path(__file__).resolve().parents[1] / ".github" / "workflows" / "fast-checks.yml"
STEP = "Pin and check the Playwright browsers"
BUN_SETUPS = "if: inputs.setup == 'webviews' || inputs.setup == 'playwright'"

# A stand-in for the playwright package: chromium.launch works only when the browsers path holds
# the revision this "version" needs, as the real one fails when its executable is missing.
FAKE_PLAYWRIGHT = """
const fs = require("fs");
const path = require("path");
const revision = require("./package.json").revision;
exports.chromium = {
  async launch() {
    const exe = path.join(process.env.PLAYWRIGHT_BROWSERS_PATH || "/nonexistent", `chromium_headless_shell-${revision}`);
    if (!fs.existsSync(exe)) throw new Error(`browserType.launch: Executable doesn't exist at ${exe}\\nmore`);
    return { close: async () => {} };
  },
};
"""


def text() -> str:
    return WORKFLOW.read_text(encoding="utf-8")


def step_names() -> list[str]:
    return re.findall(r"^      - name: (.*)$", text(), re.M)


def step(name: str) -> str:
    match = re.search(rf"^      - name: {re.escape(name)}\n(.*?)(?=^      - |\Z)", text(), re.S | re.M)
    if not match:
        raise AssertionError(f"no step named {name!r}")
    return match.group(1)


def block(body: str, key: str, indent: int) -> str:
    """The `KEY: |` block scalar at INDENT spaces in a step body, dedented."""
    pad = " " * indent
    match = re.search(rf"^{pad}{key}: \|\n((?:{pad}  .*\n|\s*\n)+)", body, re.M)
    if not match:
        raise AssertionError(f"step has no {key} block")
    return textwrap.dedent(match.group(1))


def make_playwright(tree: Path, directory: str, version: str, revision: str) -> None:
    """A workspace as `bun install --frozen-lockfile` leaves it: its manifest and lockfile pin
    Playwright to VERSION, and node_modules holds that copy and its launcher."""
    workspace = tree / directory
    workspace.mkdir(parents=True, exist_ok=True)
    (workspace / "package.json").write_text(f'{{"name": "{workspace.name}", "devDependencies": {{"playwright": "{version}"}}}}\n')
    (workspace / "bun.lock").write_text(f'{{"lockfileVersion": 1, "packages": {{"playwright": ["playwright@{version}", ""]}}}}\n')
    package = workspace / "node_modules" / "playwright"
    package.mkdir(parents=True)
    (package / "package.json").write_text(f'{{"name": "playwright", "version": "{version}", "revision": "{revision}"}}\n')
    (package / "index.js").write_text(FAKE_PLAYWRIGHT)
    bin_dir = tree / directory / "node_modules" / ".bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    (bin_dir / "playwright").write_text("#!/bin/sh\n")
    (bin_dir / "playwright").chmod(0o755)


@unittest.skipUnless(shutil.which("node"), "needs node to stand in for bun -e")
class LaunchCheckTests(unittest.TestCase):
    def run_step(self, tree: Path, setup: str, browsers: Path) -> tuple[subprocess.CompletedProcess, str]:
        body = step(STEP)
        shim = tree / "bin"
        shim.mkdir(exist_ok=True)
        # `bun -e CODE` and `node -e CODE` run the same CommonJS check.
        (shim / "bun").write_text(f'#!/bin/sh\nexec {shutil.which("node")} "$@"\n')
        (shim / "bun").chmod(0o755)
        github_env = tree / "github_env"
        github_env.write_text("")
        env = {
            **os.environ,
            "PATH": f"{shim}:{os.environ['PATH']}",
            "SETUP": setup,
            "PLAYWRIGHT_LAUNCH_CHECK": block(body, "PLAYWRIGHT_LAUNCH_CHECK", 10),
            "PLAYWRIGHT_BROWSERS_PATH": str(browsers),
            "GITHUB_ENV": str(github_env),
        }
        result = subprocess.run(["bash", "-e", "-c", block(body, "run", 8)], cwd=tree, env=env,
                                capture_output=True, text=True)
        return result, github_env.read_text()

    def test_installed_browsers_pass_and_node_path_puts_the_installer_first(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            tree = Path(root)
            make_playwright(tree, "webviews", "1.62.1", "1234")
            make_playwright(tree, "scripts/gallery-matrix", "1.62.1", "1234")
            browsers = tree / "browsers"
            (browsers / "chromium_headless_shell-1234").mkdir(parents=True)
            result, github_env = self.run_step(tree, "playwright", browsers)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"NODE_PATH={tree}/scripts/gallery-matrix/node_modules:{tree}/webviews/node_modules\n",
                          github_env)
            result, github_env = self.run_step(tree, "webviews", browsers)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"NODE_PATH={tree}/webviews/node_modules\n", github_env)

    def test_main_tree_playwright_only_in_gallery_matrix_is_what_outside_scripts_get(self) -> None:
        # main's webviews/package.json has no Playwright; `playwright` installs gallery-matrix's.
        with tempfile.TemporaryDirectory() as root:
            tree = Path(root)
            make_playwright(tree, "scripts/gallery-matrix", "1.62.1", "1234")
            browsers = tree / "browsers"
            (browsers / "chromium_headless_shell-1234").mkdir(parents=True)
            result, github_env = self.run_step(tree, "playwright", browsers)
            self.assertEqual(result.returncode, 0, result.stderr)
            node_path = re.search(r"^NODE_PATH=(.*)$", github_env, re.M).group(1)
            self.assertEqual(node_path.split(":")[0], f"{tree}/scripts/gallery-matrix/node_modules")
            # An out-of-tree script through that NODE_PATH resolves the pinned copy.
            probe = subprocess.run([shutil.which("node"), "-e", 'console.log(require("playwright/package.json").version)'],
                                   cwd=browsers, env={**os.environ, "NODE_PATH": node_path},
                                   capture_output=True, text=True)
            self.assertEqual(probe.stdout.strip(), "1.62.1", probe.stderr)
            (browsers / "chromium_headless_shell-1234").rmdir()
            result, _ = self.run_step(tree, "playwright", browsers)
            self.assertEqual(result.returncode, 2)
            self.assertIn("scripts/gallery-matrix: Playwright 1.62.1 cannot launch", result.stderr)
            # With no workspace launcher to check (.bin absent), the out-of-tree check still runs.
            (tree / "scripts" / "gallery-matrix" / "node_modules" / ".bin" / "playwright").unlink()
            result, _ = self.run_step(tree, "playwright", browsers)
            self.assertEqual(result.returncode, 2)
            self.assertIn("a script outside the checkout: Playwright 1.62.1 cannot launch", result.stderr)

    def test_a_missing_browser_fails_setup_with_its_version_and_path(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            tree = Path(root)
            make_playwright(tree, "webviews", "1.62.1", "1234")
            browsers = tree / "browsers"
            (browsers / "chromium_headless_shell-1248").mkdir(parents=True)  # another revision's
            result, _ = self.run_step(tree, "webviews", browsers)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("webviews: Playwright 1.62.1 cannot launch its headless Chromium", result.stderr)
            self.assertIn(str(browsers), result.stderr)
            self.assertIn("chromium_headless_shell-1234", result.stderr)
            self.assertNotIn("more", result.stderr)  # one line, not the whole banner

    def test_the_gallery_playwright_is_checked_only_for_the_playwright_setup(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            tree = Path(root)
            make_playwright(tree, "webviews", "1.62.1", "1234")
            make_playwright(tree, "scripts/gallery-matrix", "1.64.1", "1248")
            browsers = tree / "browsers"
            (browsers / "chromium_headless_shell-1234").mkdir(parents=True)
            result, _ = self.run_step(tree, "webviews", browsers)
            self.assertEqual(result.returncode, 0, result.stderr)
            result, _ = self.run_step(tree, "playwright", browsers)
            self.assertEqual(result.returncode, 2)
            self.assertIn("scripts/gallery-matrix: Playwright 1.64.1", result.stderr)

    def test_a_tree_without_playwright_checks_nothing(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            tree = Path(root)
            result, github_env = self.run_step(tree, "playwright", tree / "browsers")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("NODE_PATH=", github_env)


class WorkflowShapeTests(unittest.TestCase):
    def test_the_check_runs_for_both_bun_setups_after_the_browser_installs(self) -> None:
        self.assertIn(BUN_SETUPS, step(STEP))
        names = step_names()
        at = names.index(STEP)
        self.assertGreater(at, names.index("Prepare full webview tests"))
        self.assertGreater(at, names.index("Install gallery dependencies and browsers"))
        self.assertLess(at, names.index("Run fast checks"))

    def test_each_workspace_installs_playwright_frozen_to_its_lockfile_before_the_check(self) -> None:
        # The version NODE_PATH serves is the one each workspace's bun.lock pins: every install
        # that runs before the check is frozen to its lockfile.
        names = step_names()
        at = names.index(STEP)
        for name in names[:at]:
            for line in step(name).splitlines():
                if re.search(r"\bbun install\b", line):
                    self.assertIn("--frozen-lockfile", line, f"{name}: {line.strip()}")

    @unittest.skipUnless(shutil.which("bun"), "needs bun")
    def test_bun_resolves_an_out_of_tree_script_through_node_path(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            tree = Path(root)
            make_playwright(tree, "webviews", "1.62.1", "1234")
            script = tree / "outside" / "capture.mjs"
            script.parent.mkdir()
            script.write_text('import pw from "playwright/package.json";\nconsole.log(pw.version);\n')
            env = {**os.environ, "NODE_PATH": str(tree / "webviews" / "node_modules")}
            result = subprocess.run(["bun", "--no-install", str(script)], cwd=script.parent, env=env,
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "1.62.1")


if __name__ == "__main__":
    unittest.main()
