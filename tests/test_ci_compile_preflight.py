#!/usr/bin/env python3
"""The compile preflight (.github/workflows/cmux-next-compile-preflight.yml, scripts/ci/compile_preflight.py).

Leo, 2026-11-27: "surely we can just have legit build fail preflight checks" / "like the classes of failures before
we can analyze them".

cmux#57269 (a second `layoutGeometry` import in VirtualTranscript.tsx) and cmux#46930 (SetupCard importing
SignInButton from a path that does not exist) landed with every web build skipped by the land tier, and turned
feat-cmux-next's web bundle build and NIGHTLY red. This test keeps the gate that catches them:
  - both changes reach a web bundle, so the preflight builds them; a change that reaches none builds nothing;
  - the build's bundler errors (the exact lines NIGHTLY run 45907763450 printed) become annotations;
  - the gate has no tier rule: pr-router.yml calls it on every head its route job runs for, with no `start` gate
    and no label or tier condition, and the callee's job has no job-level `if:`, so its check is never "skipped";
  - the build step runs build-web-bundles.sh, the build NIGHTLY runs.
The build itself (a merged tree with each break, red) is proven on a runner: the PR that added this test.
"""

from __future__ import annotations

import importlib.util
import re
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/compile_preflight.py"
CALLEE = ROOT / ".github/workflows/cmux-next-compile-preflight.yml"
ROUTER = ROOT / ".github/workflows/pr-router.yml"

spec = importlib.util.spec_from_file_location("compile_preflight", SCRIPT)
cp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cp)

# NIGHTLY run 45907763450 (feat-cmux-next 0b7f5de6, after cmux#57269), the web bundle build's own lines.
NIGHTLY_57269 = """\
✘ [ERROR] /Users/cmux/actions-runner-glaeda/_work/cmux/cmux/webviews/src/agent-session/acpmux/VirtualTranscript.tsx: Identifier 'layoutGeometry' has already been declared. (51:2)
  This error came from the "onLoad" callback registered here:
error: Build failed with 1 error:
src/agent-session/acpmux/App.tsx:408:53: ERROR: [plugin: react-compiler] /Users/cmux/actions-runner-glaeda/_work/cmux/cmux/webviews/src/agent-session/acpmux/VirtualTranscript.tsx: Identifier 'layoutGeometry' has already been declared. (51:2)
      at failureErrorWithLog (/Users/cmux/actions-runner-glaeda/_work/cmux/cmux/webviews/node_modules/esbuild/lib/main.js:1748:19)
"""
# esbuild's unresolved import, as cmux#46930's SetupCard path gave it.
UNRESOLVED_46930 = """\
✘ [ERROR] Could not resolve "../../components/SignInButton"

    src/pages/setup-card/SetupCard.tsx:12:29:
      12 │ import { SignInButton } from "../../components/SignInButton";
"""


def job_block(text: str, job: str) -> str:
    """The YAML of JOB under `jobs:` in TEXT (its lines up to the next two-space key)."""
    match = re.search(rf"^  {re.escape(job)}:\n(.*?)(?=^  \S|\Z)", text, re.M | re.S)
    if not match:
        raise AssertionError(f"no job {job}")
    return match.group(1)


class WebTouched(unittest.TestCase):
    def setUp(self) -> None:
        if not (ROOT / "webviews").is_dir():
            self.skipTest("webviews/ is not checked out (sparse checkout)")
        self.key = cp.key_module(ROOT)
        self.routed = self.key.routed_inputs(str(ROOT))

    def touched(self, files: list[str]) -> list[str]:
        return cp.web_touched(files, self.routed, self.key.pathspec_matcher)

    def test_57269_and_46930_reach_a_web_bundle(self) -> None:
        self.assertEqual(self.touched(["webviews/src/agent-session/acpmux/VirtualTranscript.tsx"]),
                         ["webviews/src/agent-session/acpmux/VirtualTranscript.tsx"])
        self.assertEqual(self.touched(["webviews/src/pages/setup-card/SetupCard.tsx"]),
                         ["webviews/src/pages/setup-card/SetupCard.tsx"])

    def test_a_build_script_and_the_protocol_ir_reach_it(self) -> None:
        self.assertTrue(self.touched(["scripts/cmux-next/build-web-bundles.sh"]))
        self.assertTrue(self.touched(["cmux-tui/crates/acpmux/spec/acpmux-protocol.json"]))

    def test_a_change_that_reaches_no_bundle_builds_nothing(self) -> None:
        self.assertEqual(self.touched(["docs/ci/notes.md", "cmux-tui/crates/acpmux/src/lib.rs",
                                       "Packages/macOS/CmuxNext/Sources/CmuxNextApp/App.swift"]), [])


class WebTouchedCommand(unittest.TestCase):
    def test_prints_one_output_line(self) -> None:
        if not (ROOT / "webviews").is_dir():
            self.skipTest("webviews/ is not checked out (sparse checkout)")
        out = subprocess.run([sys.executable, "-I", str(SCRIPT), "web-touched", str(ROOT), "HEAD", "HEAD"],
                             capture_output=True, text=True, check=True)
        self.assertEqual(out.stdout, "web=false\n")


class BuildErrors(unittest.TestCase):
    def test_the_57269_duplicate_import_is_named(self) -> None:
        lines = cp.error_lines(NIGHTLY_57269)
        self.assertTrue(lines)
        self.assertTrue(all("layoutGeometry" in line or line.startswith("error:") for line in lines), lines)
        self.assertIn("Identifier 'layoutGeometry' has already been declared", lines[0])

    def test_the_46930_unresolved_path_is_named(self) -> None:
        lines = cp.error_lines(UNRESOLVED_46930)
        self.assertEqual(lines, ['✘ [ERROR] Could not resolve "../../components/SignInButton"'])

    def test_a_failed_build_exits_red_with_annotations(self) -> None:
        fake = ROOT / "scripts/cmux-next/build-web-bundles.sh"
        self.assertTrue(fake.is_file(), "the preflight builds with build-web-bundles.sh")
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "scripts/cmux-next").mkdir(parents=True)
            (root / "scripts/cmux-next/build-web-bundles.sh").write_text(
                "#!/bin/bash\ncat <<'EOF'\n" + NIGHTLY_57269 + "EOF\nexit 1\n")
            out = subprocess.run([sys.executable, "-I", str(SCRIPT), "web-build", str(root), str(root / "out")],
                                 capture_output=True, text=True)
        self.assertEqual(out.returncode, 1, out.stdout)
        self.assertIn("::error title=web bundle build::✘ [ERROR]", out.stdout)
        self.assertIn("NIGHTLY red", out.stdout)


class NeverSkipped(unittest.TestCase):
    def test_router_calls_it_on_every_tier(self) -> None:
        block = job_block(ROUTER.read_text(), "compile-preflight")
        self.assertIn("uses: ./.github/workflows/cmux-next-compile-preflight.yml", block)
        condition = re.search(r"^    if: (.*)$", block, re.M).group(1)
        self.assertEqual(condition, "${{ !cancelled() && needs.route.result == 'success' }}")
        for tier_word in ("start", "ready-to-land", "full-ci", "CI_LAND", "draft", "fast-gates"):
            self.assertNotIn(tier_word, condition)

    def test_the_callee_job_has_no_job_level_if_and_builds_as_nightly(self) -> None:
        text = CALLEE.read_text()
        block = job_block(text, "web")
        self.assertNotRegex(block, r"^    if:", "a job-level if: would report the check skipped")
        self.assertIn("name: web bundle build", block)
        self.assertIn("compile_preflight.py web-build", block)
        self.assertIn("compile_preflight.py web-touched . HEAD^1 HEAD", block)
        self.assertIn("fetch-depth: 2", block)


if __name__ == "__main__":
    unittest.main()
