#!/usr/bin/env python3
"""fast-checks.yml installs every Bun workspace a webview or Playwright run may import from.

Bun resolves a package from the importing file's directory upward, so a workspace
that commits its own package.json and bun.lock (scripts/gallery-matrix) needs its
own install: webviews/node_modules is never on its path. On 2026-10-28 three
`cmux-ci test --setup webviews` runs of scripts/gallery-matrix/geometry-audit.test.ts
failed before any assertion with "Cannot find package 'pngjs'": the webviews setup
installed webviews alone. Both Bun setups now install webviews, each
scripts/<tool>/ workspace with a committed lockfile and the backend/ workspace,
each frozen to its lockfile, so a lockfile change is always installed and a stale
cache can never stand in for it.
"""

from __future__ import annotations

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

WORKFLOW = Path(__file__).resolve().parents[1] / ".github" / "workflows" / "fast-checks.yml"
BUN_SETUPS = "if: inputs.setup == 'webviews' || inputs.setup == 'playwright'"


def text() -> str:
    return WORKFLOW.read_text(encoding="utf-8")


def step(name: str) -> str:
    """The body of the step called NAME, up to the next step."""
    match = re.search(rf"^      - name: {re.escape(name)}\n(.*?)(?=^      - |\Z)", text(), re.S | re.M)
    if not match:
        raise AssertionError(f"no step named {name!r}")
    return match.group(1)


def run_script(body: str) -> str:
    """The `run: |` block of a step body, dedented."""
    match = re.search(r"^        run: \|\n((?:          .*\n|\s*\n)+)", body, re.M)
    if not match:
        raise AssertionError("step has no run block")
    return "\n".join(line[10:] for line in match.group(1).splitlines()) + "\n"


class FastChecksBunWorkspaceTests(unittest.TestCase):
    def test_both_bun_setups_install_script_workspaces(self) -> None:
        body = step("Install script workspace dependencies")
        self.assertIn(BUN_SETUPS, body)
        self.assertIn("bun install --frozen-lockfile", body)

    def test_webviews_install_is_frozen_to_its_lockfile(self) -> None:
        body = step("Install webview dependencies")
        self.assertIn(BUN_SETUPS, body)
        self.assertIn("run: bun install --frozen-lockfile", body)

    def test_installs_only_run_against_the_lockfile(self) -> None:
        # A bare `bun install` would rewrite or ignore the lockfile; every install is frozen.
        for line in text().splitlines():
            if re.search(r"\bbun install\b", line):
                self.assertIn("--frozen-lockfile", line, line.strip())

    def test_the_script_installs_each_locked_script_workspace(self) -> None:
        script = run_script(step("Install script workspace dependencies"))
        with tempfile.TemporaryDirectory() as root:
            tree = Path(root)
            for name, files in (("gallery-matrix", ("package.json", "bun.lock")),
                                ("future-tool", ("package.json", "bun.lock")),
                                ("no-lock", ("package.json",)),
                                ("no-manifest", ("bun.lock",))):
                (tree / "scripts" / name).mkdir(parents=True)
                for file in files:
                    (tree / "scripts" / name / file).write_text("{}\n")
            (tree / "scripts" / "loose.ts").write_text("\n")
            shim = tree / "bin"
            shim.mkdir()
            log = tree / "installs.log"
            (shim / "bun").write_text(f'#!/bin/bash\necho "$PWD $*" >> {log}\n')
            (shim / "bun").chmod(0o755)
            env = {**os.environ, "PATH": f"{shim}:{os.environ['PATH']}"}
            subprocess.run(["bash", "-e", "-c", script], cwd=tree, env=env, check=True,
                           stdout=subprocess.DEVNULL)
            installed = sorted(Path(line.split()[0]).name for line in log.read_text().splitlines())
            self.assertEqual(installed, ["future-tool", "gallery-matrix"])
            for line in log.read_text().splitlines():
                self.assertTrue(line.endswith(" install --frozen-lockfile"), line)

    def test_both_bun_setups_install_the_backend_workspace(self) -> None:
        # 2026-10-28: backend/apps/api tests run through cmux-ci had no backend/node_modules
        # (no vitest, no @cloudflare/vitest-pool-workers): no step installed backend/.
        body = step("Install backend workspace dependencies")
        self.assertIn(BUN_SETUPS, body)
        script = run_script(body)
        with tempfile.TemporaryDirectory() as root:
            tree = Path(root)
            shim = tree / "bin"
            shim.mkdir()
            log = tree / "installs.log"
            (shim / "bun").write_text(f'#!/bin/bash\necho "$(basename "$PWD") $*" >> {log}\n')
            (shim / "bun").chmod(0o755)
            env = {**os.environ, "PATH": f"{shim}:{os.environ['PATH']}"}
            # No backend (main's own tree): nothing to install.
            subprocess.run(["bash", "-e", "-c", script], cwd=tree, env=env, check=True, stdout=subprocess.DEVNULL)
            self.assertFalse(log.exists())
            (tree / "backend").mkdir()
            (tree / "backend" / "package.json").write_text("{}\n")
            subprocess.run(["bash", "-e", "-c", script], cwd=tree, env=env, check=True, stdout=subprocess.DEVNULL)
            self.assertFalse(log.exists())  # no lockfile: never an unfrozen install
            (tree / "backend" / "bun.lock").write_text("{}\n")
            subprocess.run(["bash", "-e", "-c", script], cwd=tree, env=env, check=True, stdout=subprocess.DEVNULL)
            self.assertEqual(log.read_text().splitlines(), ["backend install --frozen-lockfile"])

    def test_the_script_is_a_no_op_without_script_workspaces(self) -> None:
        script = run_script(step("Install script workspace dependencies"))
        with tempfile.TemporaryDirectory() as root:
            subprocess.run(["bash", "-e", "-c", script], cwd=root, check=True, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    unittest.main()
