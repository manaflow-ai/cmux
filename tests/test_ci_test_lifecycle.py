# test-category: guard why=a proof test must never be skipped where it was asked to run, and a guard never skipped at all
"""scripts/ci/test_lifecycle.py: test categories decide which webview test files a tier runs, and the lint."""
from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/test_lifecycle.py"
RUNNER = ROOT / "scripts/ci/run-webviews-tests.sh"
CI_WEB = ROOT / ".github/workflows/ci-web.yml"


def load():
    spec = importlib.util.spec_from_file_location("test_lifecycle", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


lifecycle = load()


class FilterTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.root = self.tmp / "webviews"
        (self.root / "src").mkdir(parents=True)
        (self.root / "test").mkdir()
        (self.root / "src/subject.ts").write_text("export const x = 1;\n")
        self.write("test/guard.test.ts", "// test-category: guard why=pins a past bug\n")
        self.write("test/contract.test.ts", "// test-category: contract why=wire format\n")
        self.write("test/legacy.test.ts", "import { x } from '../src/subject';\n")
        self.write("test/proof.test.ts",
                   "// test-category: proof owner=lane-1 review-by=2026-12-20\nimport { x } from \"../src/subject\";\n")
        self.write("test/old-proof.test.ts", "// test-category: proof owner=lane-1 review-by=2026-10-01\n")
        self.write("test/sampled.test.ts", "// test-category: proof owner=lane-1 review-by=2026-12-20 tier=sampled\n")
        self.write("test/manifest-proof.test.ts", "import { x } from './nothing';\n")
        (self.root / "test-categories.json").write_text(
            '{"version": 1, "files": {"test/manifest-proof.test.ts": '
            '{"category": "proof", "owner": "sweep", "review_by": "2026-12-20"}}}')
        self.env = dict(os.environ, TEST_LIFECYCLE_TODAY="2026-11-22")

    def write(self, name, text):
        (self.root / name).write_text(text)

    def run_filter(self, tier, changed=None):
        names = sorted(str(p.relative_to(self.root)) for p in self.root.rglob("*.test.ts"))
        listing = self.tmp / "files"
        listing.write_bytes(b"".join(n.encode() + b"\0" for n in names))
        env = dict(self.env)
        if changed is not None:
            (self.tmp / "changed").write_text("\n".join(changed) + "\n")
            env["CMUX_PR_CHANGED_FILES"] = str(self.tmp / "changed")
        result = subprocess.run([sys.executable, str(SCRIPT), "filter", str(listing), "--tier", tier,
                                 "--root", str(self.root)], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return {item.decode() for item in listing.read_bytes().split(b"\0") if item}

    def test_push_runs_guards_contracts_and_unclassified_only(self):
        self.assertEqual(self.run_filter("push"),
                         {"test/guard.test.ts", "test/contract.test.ts", "test/legacy.test.ts"})

    def test_pull_request_runs_a_proof_whose_subject_changed(self):
        got = self.run_filter("pull_request", ["webviews/src/subject.ts"])
        self.assertIn("test/proof.test.ts", got)
        self.assertNotIn("test/manifest-proof.test.ts", got)
        self.assertNotIn("test/old-proof.test.ts", got)  # expired: nightly only
        self.assertNotIn("test/sampled.test.ts", got)
        self.assertIn("test/guard.test.ts", got)

    def test_pull_request_runs_a_changed_proof_file(self):
        got = self.run_filter("pull_request", ["webviews/test/manifest-proof.test.ts"])
        self.assertIn("test/manifest-proof.test.ts", got)
        self.assertNotIn("test/proof.test.ts", got)

    def test_pull_request_with_no_diff_runs_every_live_proof(self):
        got = self.run_filter("pull_request")
        self.assertIn("test/proof.test.ts", got)
        self.assertNotIn("test/sampled.test.ts", got)

    def test_nightly_runs_the_sampled_tier(self):
        self.assertEqual(self.run_filter("nightly"), {"test/old-proof.test.ts", "test/sampled.test.ts"})

    def test_all_runs_everything(self):
        self.assertEqual(len(self.run_filter("all")), 7)


class LintTest(unittest.TestCase):
    now = lifecycle.dt.date(2026, 11, 22)

    def problems(self, text):
        return lifecycle.lint_problems("webviews/test/x.test.ts", text, self.now)

    def test_missing_line_fails(self):
        self.assertEqual(len(self.problems("import x from 'y';\n")), 1)

    def test_good_lines_pass(self):
        self.assertEqual(self.problems("// test-category: guard why=issue 123 never again\n"), [])
        self.assertEqual(self.problems("// test-category: contract why=socket v2 frame\n"), [])
        self.assertEqual(self.problems("// test-category: proof owner=lane-1 review-by=2026-12-22\n"), [])
        self.assertEqual(lifecycle.lint_problems("tests/test_x.py", "# test-category: guard why=x\n", self.now), [])

    def test_proof_needs_owner_and_near_review(self):
        self.assertTrue(self.problems("// test-category: proof review-by=2026-12-22\n"))
        self.assertTrue(self.problems("// test-category: proof owner=a review-by=2027-06-01\n"))
        self.assertTrue(self.problems("// test-category: proof owner=a review-by=2026-11-01\n"))
        self.assertTrue(self.problems("// test-category: proof owner=a\n"))

    def test_guard_needs_a_why_and_unknown_fails(self):
        self.assertTrue(self.problems("// test-category: guard\n"))
        self.assertTrue(self.problems("// test-category: smoke why=x\n"))

    def test_lint_reads_only_added_test_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            git = lambda *a: subprocess.run(["git", "-C", tmp, *a], check=True, capture_output=True)
            git("init", "-q")
            git("config", "user.email", "t@example.com")
            git("config", "user.name", "t")
            (repo / "webviews/test").mkdir(parents=True)
            (repo / "webviews/test/old.test.ts").write_text("x\n")
            git("add", ".")
            git("commit", "-qm", "base")
            (repo / "webviews/test/old.test.ts").write_text("y\n")  # a change to a legacy file needs no line
            (repo / "webviews/test/new.test.ts").write_text("// no category\n")
            (repo / "webviews/test/fine.test.ts").write_text("// test-category: guard why=x\n")
            git("add", ".")
            git("commit", "-qm", "head")
            result = subprocess.run([sys.executable, str(SCRIPT), "lint", "--base", "HEAD~1", "--repo", tmp],
                                    capture_output=True, text=True, env=dict(os.environ, TEST_LIFECYCLE_TODAY="2026-11-22"))
            self.assertEqual(result.returncode, 1)
            self.assertIn("new.test.ts", result.stdout)
            self.assertNotIn("old.test.ts", result.stdout)
            self.assertNotIn("fine.test.ts", result.stdout)


class WiringTest(unittest.TestCase):
    def test_runner_filters_after_the_split_and_ci_sets_the_tier(self):
        text = RUNNER.read_text()
        self.assertLess(text.index('python3 "$shards_py" assign'), text.index('"$lifecycle_py" filter'))
        self.assertIn("CMUX_WEB_TEST_TIER:", CI_WEB.read_text())


if __name__ == "__main__":
    unittest.main()
