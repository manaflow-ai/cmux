#!/usr/bin/env python3
"""The router's compile preflight web answer is the callee's own (pr_router.py preflight_web, compile_preflight.py
router_web).

About 60% of `compile preflight / web bundle build` jobs found no web bundle input (99 of 164 web-routed
feat-cmux-next commits, 2026-11-27): pr_router.json's `affects` dirs started the callee, then its web-touched step
(web-bundle-key.py --routed) said none. Leo, 2026-11-27: "de facto, im asking for 99% fewer minutes of ci time,
period." The route job now asks the same question of the same code:
  - on a fixture of paths the `affects` superset routes but no bundle reads, the router's sparse checkout answers
    what the full checkout's web-touched answers, including a file reached only through an extensionless import
    outside webviews/ and the file that one imports in turn;
  - a full-ci label, an unknown diff, a blob-filtered clone, an error or the kill switch still run the job.
"""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import compile_preflight as cp  # noqa: E402
import pr_router  # noqa: E402

KEY = ROOT / "scripts/cmux-next/web-bundle-key.py"
ROUTER = ROOT / ".github/workflows/pr-router.yml"
CONFIG = json.loads((ROOT / "scripts/ci/pr_router.json").read_text())["callees"][cp.PREFLIGHT_CALLEE]

FILES = {
    "webviews/src/app.ts": 'import { gen } from "../../clients/ts/cloud/src/gen";\nexport const a = gen;\n',
    "webviews/src/style.css": "body { color: red; }\n",
    "clients/ts/cloud/src/gen.ts": 'import { check } from "../../../../config/vite-plus/check.ts";\nexport const gen = check;\n',
    "clients/ts/cloud/src/other.ts": "export const other = 1;\n",
    "config/vite-plus/check.ts": "export const check = 1;\n",
    "config/vite-plus/unused.ts": "export const unused = 1;\n",
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/AppDelegate.swift": "// swift\n",
    "scripts/cmux-next/check-something.py": "# a tool\n",
    "schemas/agent-bridge/bridge.json": "{}\n",
    "release-notes/next/highlights/one.md": "# one\n",
    "release-notes/next/other.md": "# other\n",
    "README.md": "# fixture\n",
}
# (changed paths, the full checkout's web-touched answer). Unrelated paths may be rejected before the exact check.
ROWS = [
    (["Packages/macOS/CmuxNext/Sources/CmuxNextApp/AppDelegate.swift"], False),
    (["scripts/cmux-next/check-something.py"], False),
    (["schemas/agent-bridge/bridge.json"], False),
    (["release-notes/next/other.md"], False),
    (["clients/ts/cloud/src/other.ts", "config/vite-plus/unused.ts"], False),
    (["clients/ts/cloud/src/gen.ts"], True),
    (["config/vite-plus/check.ts"], True),
    (["release-notes/next/highlights/one.md"], True),
    (["webviews/src/style.css"], True),
    (["Packages/macOS/CmuxNext/Sources/CmuxNextApp/AppDelegate.swift", "config/vite-plus/check.ts"], True),
]


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True, text=True).stdout


class RouterWebExact(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.tmp = Path(tempfile.mkdtemp())
        cls.full = cls.tmp / "full"
        for rel, text in {**FILES, "scripts/cmux-next/web-bundle-key.py": KEY.read_text()}.items():
            (cls.full / rel).parent.mkdir(parents=True, exist_ok=True)
            (cls.full / rel).write_text(text)
        git(cls.tmp, "init", "-q", "full")
        git(cls.full, "add", "-A")
        git(cls.full, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "fixture")
        cls.sparse = cls.tmp / "sparse"
        git(cls.tmp, "clone", "-q", "--no-checkout", str(cls.full), "sparse")
        git(cls.sparse, "sparse-checkout", "set", "--no-cone", "/scripts/cmux-next/web-bundle-key.py")
        git(cls.sparse, "checkout", "-q")

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.tmp)

    def full_answer(self, files: list[str]) -> bool:
        module = cp.key_module(self.full)
        module.unresolved = lambda message: None
        return bool(cp.web_touched(files, module.routed_inputs(str(self.full)), module.pathspec_matcher))

    def test_web_inputs_are_routed_by_the_coarse_superset(self) -> None:
        for files, web in ROWS:
            if web:
                self.assertTrue(pr_router.affects(CONFIG, files), files)

    def test_the_sparse_router_agrees_with_the_full_checkout(self) -> None:
        self.assertFalse((self.sparse / "webviews").exists(), "the route checkout starts with no webviews/")
        for files, want in ROWS:
            with self.subTest(files=files):
                self.assertEqual(self.full_answer(files), want, "the fixture's own expectation")
                web, why = cp.router_web(self.sparse, files)
                self.assertEqual(web, want, why)
        # The extensionless import outside webviews/ was checked out, then the file it imports.
        self.assertTrue((self.sparse / "config/vite-plus/check.ts").is_file())
        self.assertFalse((self.sparse / "config/vite-plus/unused.ts").exists(), "only what an import names")

    def test_a_static_input_answers_without_a_checkout(self) -> None:
        add = mock.Mock()
        web, _ = cp.router_web(self.sparse, ["webviews/package.json"], add=add)
        self.assertTrue(web)
        add.assert_not_called()

    def test_a_blob_filtered_clone_cannot_answer(self) -> None:
        with mock.patch.object(cp, "partial_clone", return_value=True):
            self.assertIsNone(cp.router_web(self.sparse, ["scripts/cmux-next/check-something.py"])[0])

    def test_sparse_patterns_name_one_path(self) -> None:
        self.assertEqual(cp.sparse_pattern("webviews/"), "/webviews/")
        self.assertEqual(cp.sparse_pattern("a/[x]*.ts"), r"/a/\[x\]\*.ts")


class PreflightWeb(unittest.TestCase):
    callees = {cp.PREFLIGHT_CALLEE: CONFIG}
    event = {"pull_request": {"labels": []}}
    swift = ["Packages/macOS/CmuxNext/Sources/CmuxNextApp/AppDelegate.swift"]
    possible_web = ["clients/ts/cloud/src/other.ts"]

    def answer(self, exact, files=None, event=None, start=None, env=None):
        with mock.patch.dict(os.environ, env or {"CI_ROUTER_WEB_EXACT": "1"}):
            return pr_router.preflight_web(event or self.event, self.callees,
                                           self.possible_web if files is None else files, start, exact=exact)

    def test_ignored_paths_skip_before_the_exact_check(self) -> None:
        exact = mock.Mock(side_effect=AssertionError("ignored paths need no exact check"))
        self.assertFalse(self.answer(exact, files=self.swift)[0])
        exact.assert_not_called()

    def test_the_exact_answer_skips_and_runs(self) -> None:
        self.assertFalse(self.answer(lambda root, files: (False, "none"))[0])
        self.assertTrue(self.answer(lambda root, files: (True, "one"))[0])

    def test_anything_unread_runs(self) -> None:
        def boom(root, files):
            raise subprocess.TimeoutExpired("git", 90)
        self.assertTrue(self.answer(boom)[0])
        self.assertTrue(self.answer(lambda root, files: (None, "filtered"))[0])
        never = mock.Mock(side_effect=AssertionError("not asked"))
        self.assertTrue(self.answer(never, files=[])[0])
        self.assertTrue(pr_router.preflight_web(self.event, self.callees, None, exact=never)[0])
        full = {"pull_request": {"labels": [{"name": pr_router.FULL_CI}]}}
        self.assertTrue(self.answer(never, event=full)[0])
        self.assertTrue(self.answer(never, env={"CI_ROUTER_WEB_EXACT": "0"})[0])
        self.assertTrue(self.answer(never, start=["pr-pipeline.yml"])[0], "no checkout when the callee does not start")


class Workflow(unittest.TestCase):
    def test_the_route_checkout_has_the_check_and_the_job_reads_the_answer(self) -> None:
        text = ROUTER.read_text()
        route = text[text.index("Checkout the router"):text.index("sparse-checkout-cone-mode: false")]
        self.assertIn("scripts/ci/compile_preflight.py", route)
        self.assertIn("scripts/cmux-next/web-bundle-key.py", route)
        self.assertIn("web: ${{ needs.route.outputs.preflight_web || 'true' }}", text)
        self.assertIn("CI_ROUTER_WEB_EXACT: ${{ vars.CI_ROUTER_WEB_EXACT || '1' }}", text)
        callee = (ROOT / ".github/workflows/cmux-next-compile-preflight.yml").read_text()
        self.assertIn("if: ${{ inputs.web != 'false' || inputs.force_web }}", callee)


if __name__ == "__main__":
    unittest.main()
