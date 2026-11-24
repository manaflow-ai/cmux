#!/usr/bin/env python3
"""scripts/ci/web_abi_gate.py fails when host ops change without a web ABI bump.

The failing example: a change that adds a host op on both sides (the app serves `cmux.demo.newOp`, a page
calls it) and leaves webviews/src/web-abi.json at the same abi. The same change with the bump passes.
"""
from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/web_abi_gate.py"
WEB = "webviews/src/demo/ops.ts"
APP = "Packages/macOS/CmuxNext/Sources/CmuxNextDemo/DemoPageProvider.swift"
ABI = "webviews/src/web-abi.json"


def git(repo: Path, *args: str) -> str:
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True,
                          env=env).stdout.strip()


def web(*ops: str) -> str:
    return "".join(f'export const OP{i} = "{op}";\n' for i, op in enumerate(ops))


def app(*ops: str) -> str:
    return "".join(f'    static let op{i} = "{op}"\n' for i, op in enumerate(ops))


def abi(n: int) -> str:
    return f'{{\n  "abi": {n}\n}}\n'


class WebAbiGate(unittest.TestCase):
    def setUp(self):
        self.repo = Path(tempfile.mkdtemp(prefix="web-abi-gate-"))
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.repo)])
        git(self.repo, "init", "-q", "-b", "feat-cmux-next")
        self.base = self.commit({WEB: web("cmux.demo.recents"), APP: app("cmux.demo.recents"), ABI: abi(8)})

    def commit(self, files: dict[str, str]) -> str:
        for rel, text in files.items():
            path = self.repo / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
            git(self.repo, "add", rel)
        git(self.repo, "commit", "-q", "--allow-empty", "-m", "change")
        return git(self.repo, "rev-parse", "HEAD")

    def gate(self, head: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(SCRIPT), "--repo", str(self.repo), "--base", self.base,
                               "--head", head], capture_output=True, text=True)

    def test_a_new_host_op_without_a_bump_fails(self):
        head = self.commit({WEB: web("cmux.demo.recents", "cmux.demo.newOp"),
                            APP: app("cmux.demo.recents", "cmux.demo.newOp")})
        result = self.gate(head)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("added: cmux.demo.newOp", result.stdout)
        self.assertIn("Bump abi in webviews/src/web-abi.json", result.stdout)

    def test_the_same_change_with_a_bump_passes(self):
        head = self.commit({WEB: web("cmux.demo.recents", "cmux.demo.newOp"),
                            APP: app("cmux.demo.recents", "cmux.demo.newOp"), ABI: abi(9)})
        result = self.gate(head)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("abi 8 -> 9", result.stdout)

    def test_a_removed_host_op_without_a_bump_fails(self):
        head = self.commit({WEB: web(), APP: app()})
        result = self.gate(head)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("removed: cmux.demo.recents", result.stdout)

    def test_the_web_calling_an_op_the_app_already_served_passes(self):
        self.base = self.commit({APP: app("cmux.demo.recents", "cmux.demo.open")})
        head = self.commit({WEB: web("cmux.demo.recents", "cmux.demo.open")})
        self.assertEqual(self.gate(head).returncode, 0)

    def test_native_only_and_web_only_names_pass(self):
        head = self.commit({WEB: web("cmux.demo.recents", "cmux.demo.storageKey"),
                            APP: app("cmux.demo.recents", "cmux.demo.defaultsKey")})
        self.assertEqual(self.gate(head).returncode, 0)

    def test_test_and_gallery_files_are_not_the_web(self):
        head = self.commit({"webviews/src/demo/ops.test.ts": web("cmux.demo.newOp"),
                            "webviews/src/gallery/frame/pages.ts": web("cmux.demo.newOp"),
                            APP: app("cmux.demo.recents", "cmux.demo.newOp")})
        self.assertEqual(self.gate(head).returncode, 0)

    def test_wired_into_the_fast_gates(self):
        spec = importlib.util.spec_from_file_location("fast_gates", ROOT / "scripts/ci/cmux_next_fast_gates.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        gates = dict(module.gates(ROOT, "B", "M", ROOT, web=False))
        self.assertEqual(gates["web abi"][1:], ["scripts/ci/web_abi_gate.py", "--base", "B", "--head", "M"])


if __name__ == "__main__":
    unittest.main()
