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


class Prelude(unittest.TestCase):
    """The serial prelude: a runner hiccup is no verdict (exit 3, no failure record, so no commit status);
    a lockfile or FILE:LINE error is the tree's red. 2026-11-27 c9bbf76cd5 went red "in prelude" on an empty log."""

    def run_matrix(self, bun_body: str) -> tuple[subprocess.CompletedProcess, Path]:
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", "--", str(tmp)]))
        bin_dir = tmp / "bin"; bin_dir.mkdir()
        bun = bin_dir / "bun"
        bun.write_text("#!/bin/sh\n" + bun_body.replace("STATE", str(tmp / "calls")))
        bun.chmod(bun.stat().st_mode | stat.S_IXUSR)
        out = tmp / "out"
        names = subprocess.run(["bash", str(MATRIX), "--list"], capture_output=True, text=True, check=True).stdout
        skips = [a for n in names.splitlines() for a in ("--skip", n.split("\t")[0])]
        env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}"}
        done = subprocess.run(["bash", str(MATRIX), "--no-install", "--out", str(out), *skips],
                              capture_output=True, text=True, env=env)
        return done, out / "failure.tsv"

    def test_an_empty_log_is_no_verdict(self) -> None:
        done, failure = self.run_matrix("exit 1\n")
        self.assertEqual(done.returncode, 3, done.stderr)
        self.assertFalse(failure.exists())

    def test_a_hiccup_the_retry_clears_is_green(self) -> None:
        # The first call fails; every later one passes.
        done, failure = self.run_matrix('[ -f STATE ] && exit 0\n: > STATE\nexit 1\n')
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertFalse(failure.exists())

    def test_a_file_line_error_is_the_trees_red(self) -> None:
        done, failure = self.run_matrix('echo "src/strings/en.ts:12:3: error: unterminated string"; exit 1\n')
        self.assertEqual(done.returncode, 1, done.stderr)
        job, file, line, message = failure.read_text(encoding="utf-8").rstrip("\n").split("\t")
        self.assertEqual((job, file, line), ("prelude", "src/strings/en.ts", "12"))
        self.assertIn("unterminated string", message)

    def test_a_frozen_lockfile_refusal_is_red_on_the_lockfile(self) -> None:
        done, failure = self.run_matrix('echo "error: lockfile had changes, but lockfile is frozen"; exit 1\n')
        self.assertEqual(done.returncode, 1, done.stderr)
        self.assertEqual(failure.read_text(encoding="utf-8").split("\t")[:2], ["prelude", "webviews/bun.lock"])


class FailureRecord(unittest.TestCase):
    """The push workflow reads failure.tsv by tab: `IFS='|'` put the whole record in JOB (the culprit then had no
    FILE:LINE and no revert ever opened), and `IFS=$'\\t' read` folds an empty FILE's tabs."""

    def parse(self, record: str) -> dict[str, str]:
        workflow = (ROOT / ".github/workflows/web-bundle-matrix.yml").read_text(encoding="utf-8")
        block = re.search(r'^( *)f="\$MATRIX_OUT/failure\.tsv"\n(?:\1.*\n){2}', workflow, re.M)
        self.assertIsNotNone(block, "the workflow no longer reads failure.tsv with cut")
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "failure.tsv").write_text(record, encoding="utf-8")
            script = block.group(0) + 'printf "%s|%s|%s|%s" "$job" "$file" "$line" "$message"\n'
            out = subprocess.run(["bash", "-c", script], env={**os.environ, "MATRIX_OUT": tmp},
                                 capture_output=True, text=True, check=True).stdout
        return dict(zip(("job", "file", "line", "message"), out.split("|", 3)))

    def test_every_field_lands_in_its_own_output(self) -> None:
        got = self.parse("bundle:pages\tV.tsx\t4\tx Identifier `a` has already been declared\n")
        self.assertEqual(got, {"job": "bundle:pages", "file": "V.tsx", "line": "4",
                               "message": "x Identifier `a` has already been declared"})

    def test_an_empty_file_keeps_the_message_in_place(self) -> None:
        self.assertEqual(self.parse("typecheck\t\t\tboom\n"), {"job": "typecheck", "file": "", "line": "", "message": "boom"})


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
