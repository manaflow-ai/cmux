"""web-bundle-matrix.sh and its helpers (scripts/ci/web_bundle_culprit.py, web_bundle_typecheck.py), and where the
matrix is wired: the pull request fast tier, the push workflow, and the nightly-next train's refusal."""
from __future__ import annotations

import os
import re
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MATRIX = ROOT / "scripts/ci/web-bundle-matrix.sh"
CULPRIT = ROOT / "scripts/ci/web_bundle_culprit.py"
TYPECHECK = ROOT / "scripts/ci/web_bundle_typecheck.py"


def git(repo: Path, *args: str) -> str:
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=True, env=env).stdout.strip()


class MatrixScript(unittest.TestCase):
    def test_list_names_every_bundle_builder_the_nightly_runs(self) -> None:
        out = subprocess.run(["bash", str(MATRIX), "--list"], capture_output=True, text=True, check=True).stdout
        names = [line.split("\t")[0] for line in out.splitlines()]
        build_script = (ROOT / "scripts/cmux-next/build-web-bundles.sh").read_text(encoding="utf-8")
        for builder in ("build-agent-pane-web.sh", "build-pages-web.sh", "build-agent-activity-web.sh", "build-webviews-app.sh"):
            self.assertIn(builder, build_script, f"{builder} left build-web-bundles.sh: update the matrix")
            self.assertTrue(any(builder in line for line in out.splitlines()), f"the matrix does not run {builder}")
        for job in ("lint-redeclare", "typecheck", "inspector", "bundle:webviews-app", "bundle:pages",
                    "bundle:agent-pane", "bundle:agent-activity"):
            self.assertIn(job, names)

    def test_cheap_checks_run_before_the_builds(self) -> None:
        out = subprocess.run(["bash", str(MATRIX), "--list"], capture_output=True, text=True, check=True).stdout
        names = [line.split("\t")[0] for line in out.splitlines()]
        self.assertLess(names.index("lint-redeclare"), names.index("bundle:pages"))

    def test_skip_drops_a_job(self) -> None:
        out = subprocess.run(["bash", str(MATRIX), "--skip", "typecheck", "--skip", "inspector", "--list"],
                             capture_output=True, text=True, check=True).stdout
        names = [line.split("\t")[0] for line in out.splitlines()]
        self.assertNotIn("typecheck", names)
        self.assertNotIn("inspector", names)
        self.assertIn("lint-redeclare", names)

    def test_a_bad_flag_is_usage(self) -> None:
        done = subprocess.run(["bash", str(MATRIX), "--nope"], capture_output=True, text=True)
        self.assertEqual(done.returncode, 2)
        done = subprocess.run(["bash", str(MATRIX), "--jobs", "0", "--list"], capture_output=True, text=True)
        self.assertEqual(done.returncode, 2)

    def test_the_lint_config_forbids_a_redeclared_name(self) -> None:
        text = (ROOT / "webviews/scripts/lint/bundle-breakers.json").read_text(encoding="utf-8")
        self.assertIn('"no-redeclare": "error"', text)


class CulpritBlame(unittest.TestCase):
    def test_two_pull_requests_importing_the_same_name_blame_the_later_one(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            git(repo, "init", "-q", "-b", "main")
            src = repo / "V.tsx"
            src.write_text('import { a } from "./m";\nimport {\n  b,\n} from "./m";\n')
            git(repo, "add", "."); git(repo, "commit", "-q", "-m", "base (#1)")
            src.write_text('import { a, layoutGeometry } from "./m";\nimport {\n  b,\n} from "./m";\n')
            git(repo, "commit", "-qam", "first imports it (#10)")
            src.write_text('import { a, layoutGeometry } from "./m";\nimport {\n  b,\n  layoutGeometry,\n} from "./m";\n')
            git(repo, "commit", "-qam", "second imports it again (#11)")
            sha = git(repo, "rev-parse", "HEAD")
            second = git(repo, "rev-parse", "HEAD")
            failure = repo.parent / "failure.tsv"
            failure.write_text("bundle:pages|V.tsx|4|x Identifier `layoutGeometry` has already been declared\n")
            out = Path(tmp) / "out.txt"
            subprocess.run(["python3", "-I", str(CULPRIT), "--failure", str(failure), "--sha", sha, "--repo-dir", str(repo),
                            "--github-output", str(out)], check=True, capture_output=True, text=True)
            values = dict(line.split("=", 1) for line in out.read_text().splitlines())
            self.assertEqual(values["pr"], "11")
            self.assertEqual(values["merge_sha"], second)
            self.assertEqual(values["pair"], "#10 #11")
            self.assertEqual(values["file"], "V.tsx")

    def test_a_line_no_pull_request_wrote_names_nobody(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            git(repo, "init", "-q", "-b", "main")
            (repo / "V.tsx").write_text("x\n")
            git(repo, "add", "."); git(repo, "commit", "-q", "-m", "direct push")
            failure = repo.parent / "failure2.tsv"
            failure.write_text("bundle:pages|V.tsx|1|boom\n")
            out = Path(tmp) / "out.txt"
            subprocess.run(["python3", "-I", str(CULPRIT), "--failure", str(failure), "--sha", git(repo, "rev-parse", "HEAD"),
                            "--repo-dir", str(repo), "--github-output", str(out)], check=True, capture_output=True, text=True)
            values = dict(line.split("=", 1) for line in out.read_text().splitlines())
            self.assertEqual(values["pr"], "")


class Typecheck(unittest.TestCase):
    LOG = (
        "error: Type errors found\n"
        "x typescript(TS2300): Duplicate identifier 'a'.\n"
        "  ,-[src/App.tsx:3:10]\n 3 | a\n  `----\n\n"
        "  x typescript(TS2300): Duplicate identifier 'b'.\n"
        "  ,-[test/App.test.tsx:3:10]\n 3 | b\n  `----\n\n"
        "  x typescript(TS7005): implicit any.\n"
        "  ,-[src/Other.tsx:9:1]\n 9 | c\n  `----\n"
    )

    def run_log(self, text: str) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "log"
            log.write_text(text)
            return subprocess.run(["python3", "-I", str(TYPECHECK), "--log", str(log)], capture_output=True, text=True)

    def test_a_redeclared_name_in_shipped_code_fails_and_tests_and_other_codes_do_not(self) -> None:
        done = self.run_log(self.LOG)
        self.assertEqual(done.returncode, 1)
        self.assertIn("src/App.tsx:3", done.stdout)
        self.assertNotIn("test/App.test.tsx", done.stdout)
        self.assertIn("1 bundle-breaking, 2 other", done.stdout)

    def test_only_other_errors_pass(self) -> None:
        done = self.run_log("  x typescript(TS7005): implicit any.\n  ,-[src/Other.tsx:9:1]\n 9 | c\n  `----\n")
        self.assertEqual(done.returncode, 0)


class Wiring(unittest.TestCase):
    def test_pull_request_fast_tier_runs_the_matrix(self) -> None:
        text = (ROOT / "scripts/ci/fast_gate_webviews_checks.py").read_text(encoding="utf-8")
        self.assertIn('"check:bundle-matrix"', text)
        self.assertRegex((ROOT / "webviews/package.json").read_text(encoding="utf-8"),
                         r'"check:bundle-matrix":\s*"bash \.\./scripts/ci/web-bundle-matrix\.sh')

    def test_push_workflow_posts_the_status_the_train_reads(self) -> None:
        workflow = (ROOT / ".github/workflows/web-bundle-matrix.yml").read_text(encoding="utf-8")
        status = (ROOT / "scripts/ci/web-bundle-matrix-status.sh").read_text(encoding="utf-8")
        train = (ROOT / "scripts/cmux-next/request-nightly-next.sh").read_text(encoding="utf-8")
        self.assertIn("branches: [feat-cmux-next]", workflow)
        for text in (status, train):
            self.assertIn("cmux-next/web-bundle-matrix", text)
        self.assertIn("revert/pr-", (ROOT / "scripts/ci/web-bundle-matrix-fix-pr.sh").read_text(encoding="utf-8"))

    def test_train_refuses_only_a_posted_failure(self) -> None:
        train = (ROOT / "scripts/cmux-next/request-nightly-next.sh").read_text(encoding="utf-8")
        body = re.search(r"^web_matrix_reason=\"\"\nweb_matrix_green\(\) \{.*?^\}\n", train, re.S | re.M)
        self.assertIsNotNone(body)
        with tempfile.TemporaryDirectory() as tmp:
            gh = Path(tmp) / "gh"
            gh.write_text('#!/bin/sh\nif [ -n "$FAKE_GH_FAIL" ]; then exit 1; fi\nprintf "%s\\n" "$FAKE_STATE"\n')
            gh.chmod(gh.stat().st_mode | stat.S_IXUSR)

            def run(state: str, fail: bool = False, off: bool = False) -> int:
                env = {**os.environ, "PATH": f"{tmp}:{os.environ['PATH']}", "FAKE_STATE": state}
                if fail: env["FAKE_GH_FAIL"] = "1"
                if off: env["NIGHTLY_NEXT_WEB_MATRIX"] = "0"
                script = f'repo=o/r\n{body.group(0)}\nweb_matrix_green abc\n'
                return subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True).returncode

            self.assertEqual(run("failure red in x https://u"), 1)
            self.assertEqual(run("success ok https://u"), 0)
            self.assertEqual(run(" "), 0)            # no status posted yet
            self.assertEqual(run("", fail=True), 0)   # unreadable is unknown, never red
            self.assertEqual(run("failure red", off=True), 0)


if __name__ == "__main__":
    unittest.main()
