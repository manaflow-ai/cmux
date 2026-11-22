#!/usr/bin/env python3
"""Lint-class checks report on the NEXT nightly and are fixed forward; they never hold the publish.

Leo, 2026-11-20, after check:design-tokens failed nightly-next-one's "Finish the webview checks before any signing
secret" and left the NEXT nightly 15 h stale: "aren't these a bit bad to halt the nightly on? what about the
fixit/ignoring and fixing forward for things?"

- Every webview check has a class in fast_gate_webviews_checks.CHECK_CLASSES; a blocking one names why.
- With --advisory-out a lint-class red is a warning in a JSON report (exit 0); a blocking red still exits 1; without
  the flag (ci-web, the fast gates) every red counts, as before.
- Any nightly.yml step that looks lint-class is report-only, or carries `# blocks-nightly: <reason>` right above it.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/nightly.yml"
LINT_LIKE = re.compile(r"\blint\b|\bfmt\b|\bformat\b|\bstyle\b|design-token|ratchet|ui-review|bun run check:", re.I)
ADVISORY = "--advisory-out"


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


checks = load("fast_gate_webviews_checks", ROOT / "scripts/ci/fast_gate_webviews_checks.py")
issue = load("nightly_fix_forward_issue", ROOT / "scripts/ci/nightly_fix_forward_issue.py")


class CheckClassTests(unittest.TestCase):
    def test_every_check_has_a_class(self):
        self.assertEqual(set(checks.CHECK_CLASSES), set(checks.CHECKS))
        for check, (kind, reason) in checks.CHECK_CLASSES.items():
            with self.subTest(check=check):
                self.assertIn(kind, ("lint", "blocks"))
                if kind == "blocks":
                    self.assertTrue(reason.strip(), f"{check} blocks the nightly without a reason")

    def test_the_type_check_and_the_protocol_check_still_block(self):
        self.assertEqual(checks.CHECK_CLASSES["typecheck"][0], "blocks")
        self.assertEqual(checks.CHECK_CLASSES["acpmux-protocol:check"][0], "blocks")
        self.assertEqual(checks.CHECK_CLASSES["check:design-tokens"][0], "lint")


class AdvisoryOutTests(unittest.TestCase):
    def run_main(self, red: dict[str, str], *flags: str) -> int:
        def run_check(_webviews, check, fixit=False):
            return (1, red[check] + "\n") if check in red else (0, "")

        with mock.patch.object(checks, "run_check", run_check), contextlib.redirect_stdout(io.StringIO()) as out:
            code = checks.main(["--no-install", "--repo", str(ROOT), *flags])
        self.out = out.getvalue()
        return code

    def test_a_lint_red_exits_0_and_writes_the_report(self):
        with tempfile.TemporaryDirectory() as temp:
            report = Path(temp) / "lint.json"
            code = self.run_main({"check:design-tokens": "src/a.tsx: raw color #fff"}, ADVISORY, str(report))
            self.assertEqual(code, 0, self.out)
            data = json.loads(report.read_text())
            self.assertEqual([f["check"] for f in data["failed"]], ["check:design-tokens"])
            self.assertIn("src/a.tsx: raw color #fff", data["failed"][0]["findings"])
            self.assertIn("::warning title=webviews check:design-tokens", self.out)
            self.assertNotIn("::error", self.out)

    def test_a_blocking_red_exits_1(self):
        with tempfile.TemporaryDirectory() as temp:
            report = Path(temp) / "lint.json"
            code = self.run_main({"typecheck": "x typescript(TS2448): used before declaration",
                                  "check:fixed-waits": "a.test.ts: 1 fixed wait"}, ADVISORY, str(report))
            self.assertEqual(code, 1, self.out)
            self.assertEqual([f["check"] for f in json.loads(report.read_text())["failed"]], ["check:fixed-waits"])
            self.assertIn("::error title=webviews typecheck", self.out)

    def test_a_clean_run_writes_an_empty_report(self):
        with tempfile.TemporaryDirectory() as temp:
            report = Path(temp) / "lint.json"
            self.assertEqual(self.run_main({}, ADVISORY, str(report)), 0)
            self.assertEqual(json.loads(report.read_text()), {"failed": []})

    # run 44661110467's own red (job 136040412192), the ANSI colours dropped
    BENCH_TS2367 = ("  × typescript(TS2367): This comparison appears to be unintentional because the types "
                    "'\"chromium\"' and '\"webkit\"' have no overlap.\n"
                    "     ╭─[bench/composer-typing.bench.ts:234:17]\n"
                    " 234 │     const cdp = engine === \"webkit\" ? undefined : await x;\n"
                    "     ╰────\n")

    def test_a_typecheck_red_only_in_a_bench_file_is_fixed_forward(self):
        with tempfile.TemporaryDirectory() as temp:
            report = Path(temp) / "lint.json"
            code = self.run_main({"typecheck": self.BENCH_TS2367}, ADVISORY, str(report))
            self.assertEqual(code, 0, self.out)
            data = json.loads(report.read_text())
            self.assertEqual([f["check"] for f in data["failed"]], ["typecheck"])
            self.assertIn("bench/composer-typing.bench.ts", data["failed"][0]["findings"][0])
            self.assertIn("only in files the app never ships", self.out)
            self.assertNotIn("::error", self.out)

    def test_the_real_log_shape_with_buns_lines_is_fixed_forward(self):
        """job 136040412192's typecheck block in its order: the diagnostic, the summary, bun's command and exit lines."""
        real = (self.BENCH_TS2367 + "Found 1 error and 0 warnings in 6953 files (6.5s, 14 threads)\n"
                "$ vp check --no-fmt --no-lint\nerror: Type errors found\n"
                'error: script "typecheck" exited with code 1\n')
        with tempfile.TemporaryDirectory() as temp:
            report = Path(temp) / "lint.json"
            self.assertEqual(self.run_main({"typecheck": real}, ADVISORY, str(report)), 0, self.out)
            self.assertEqual([f["check"] for f in json.loads(report.read_text())["failed"]], ["typecheck"])
        self.assertFalse(checks.outside_the_app(["$ vp check", 'error: script "typecheck" exited with code 1']))

    def test_a_typecheck_red_in_app_source_still_blocks(self):
        app = self.BENCH_TS2367.replace("bench/composer-typing.bench.ts", "src/agent-session/AgentPane.tsx")
        with tempfile.TemporaryDirectory() as temp:
            report = Path(temp) / "lint.json"
            code = self.run_main({"typecheck": app}, ADVISORY, str(report))
            self.assertEqual(code, 1, self.out)
            self.assertEqual(json.loads(report.read_text()), {"failed": []})
            self.assertIn("::error title=webviews typecheck", self.out)

    def test_one_app_file_among_test_files_blocks(self):
        both = self.BENCH_TS2367 + "\n" + self.BENCH_TS2367.replace(
            "bench/composer-typing.bench.ts", "src/ui/Button.tsx")
        with tempfile.TemporaryDirectory() as temp:
            self.assertEqual(self.run_main({"typecheck": both}, ADVISORY, str(Path(temp) / "lint.json")), 1)

    def test_not_shipped_paths(self):
        for path in ("bench/a.bench.ts:", "test/a.test.ts:", "src/x/a.test.tsx:", "src/x/a.gallery.ts:",
                     "dev-server/x.ts:", "scripts/check.ts:", "webviews/test/a.ts:"):
            self.assertTrue(checks.outside_the_app([f"{path} typescript(TS1): m"]), path)
        for path in ("src/agent-session/AgentPane.tsx:", "src/bench.ts:", "src/testing/a.ts:"):
            self.assertFalse(checks.outside_the_app([f"{path} typescript(TS1): m"]), path)
        self.assertFalse(checks.outside_the_app([]))
        self.assertFalse(checks.outside_the_app(["typescript(TS1): no path"]))

    def test_without_the_flag_every_red_counts(self):
        self.assertEqual(self.run_main({"check:design-tokens": "src/a.tsx: raw color #fff"}), 1)
        self.assertIn("::error title=webviews check:design-tokens", self.out)
        self.assertNotIn("::warning", self.out)


class FixForwardIssueTests(unittest.TestCase):
    def test_outputs_sets_lint_report_and_warns(self):
        with tempfile.TemporaryDirectory() as temp:
            report, output = Path(temp) / "lint.json", Path(temp) / "out"
            report.write_text(json.dumps({"failed": [{"check": "check:ui-review", "findings": ["f" * 50] * 500}]}))
            with contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(issue.outputs(report, str(output)), 0)
            line = output.read_text()
            self.assertTrue(line.startswith("lint_report="))
            value = line[len("lint_report="):].strip()
            self.assertLessEqual(len(value), issue.OUTPUT_MAX)
            self.assertEqual(json.loads(value)["failed"][0]["check"], "check:ui-review")
            self.assertIn("::warning", out.getvalue())

    def test_no_report_writes_no_output(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "out"
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(issue.outputs(Path(temp) / "missing.json", str(output)), 0)
            self.assertFalse(output.exists())

    def test_a_github_failure_only_warns(self):
        failing = mock.Mock(return_value=mock.Mock(returncode=1, stdout="", stderr="HTTP 403"))
        with mock.patch.object(issue, "gh", failing), contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(issue.file("o/r", {"failed": [{"check": "check:ui-review"}]}, "url", "abc"), 0)
        self.assertIn("::warning", out.getvalue())

    def test_a_clean_report_closes_the_open_issue(self):
        calls = []

        def gh(*args, stdin=None):
            calls.append(args)
            listed = json.dumps([{"number": 6, "title": issue.TITLE, "pull_request": {"url": "x"}},
                                 {"number": 7, "title": issue.TITLE}, {"number": 8, "title": "something else"}])
            return mock.Mock(returncode=0, stdout=listed if args[0] == "api" else "", stderr="")

        with mock.patch.object(issue, "gh", gh), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(issue.file("o/r", {"failed": []}, "url", "abc"), 0)
        self.assertIn(("issue", "close", "7", "-R", "o/r"), calls)
        # One bounded page per call: the gh quota wrapper refuses gh api's paginate flag.
        reads = [args for args in calls if args[0] == "api"]
        self.assertTrue(reads and all(len(args) == 2 and "page=" in args[1] for args in reads), reads)


class WorkflowTests(unittest.TestCase):
    def test_lint_like_steps_are_report_only_or_say_why_they_block(self):
        lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
        steps: list[tuple[int, int, str]] = []  # (first line, indent, text)
        for i, line in enumerate(lines):
            match = re.match(r"^(\s*)- (?:&\S+\s*$|name:|uses:|run:|id:|if:)", line)
            if match:
                steps.append((i, len(match.group(1)), ""))
        for n, (start, indent, _) in enumerate(steps):
            end = len(lines)
            for j in range(start + 1, len(lines)):
                text = lines[j]
                if text.strip() and len(text) - len(text.lstrip()) <= indent:
                    end = j
                    break
            # Comments are not the step: a job's header comment may name lint or style.
            body = "\n".join(line for line in lines[start:end] if not line.strip().startswith("#"))
            name = re.search(r"^\s*-?\s*name:\s*(.*)$", body, re.M)
            run = re.search(r"^\s*run:\s*(.*(?:\n(?!\s*[\w-]+:).*)*)", body, re.M)
            probe = f"{name.group(1) if name else ''}\n{run.group(1) if run else ''}"
            if not LINT_LIKE.search(probe):
                continue
            above = lines[start - 1].strip() if start else ""
            with self.subTest(line=start + 1, step=name.group(1) if name else body[:60]):
                self.assertTrue(re.search(r"^\s*continue-on-error:\s*true\b", body, re.M) or ADVISORY in body
                                or re.match(r"#\s*blocks-nightly:\s*\S", above),
                                "a lint-class nightly step must be report-only (continue-on-error or "
                                f"{ADVISORY}) or carry `# blocks-nightly: <reason>` on the line above it")

    def test_every_webview_checks_run_passes_the_advisory_flag(self):
        import yaml

        doc = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        runs = [(job_id, step.get("name", "")) for job_id, job in doc["jobs"].items()
                for step in job.get("steps", []) or []
                if "fast_gate_webviews_checks.py" in str(step.get("run", ""))
                and ADVISORY not in str(step.get("run", ""))]
        self.assertEqual(runs, [], "a nightly run of the webview checks without --advisory-out lets a lint red "
                                   "hold the publish")
        sites = {job_id for job_id, job in doc["jobs"].items() for step in job.get("steps", []) or []
                 if "fast_gate_webviews_checks.py" in str(step.get("run", ""))}
        self.assertEqual(sites, {"check-nightly-webviews", "nightly-next-one"})

    def test_the_report_job_only_writes_issues(self):
        import yaml

        doc = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        jobs = doc["jobs"]
        job = jobs["report-nightly-fix-forward"]
        self.assertEqual(job["permissions"], {"contents": "read", "issues": "write"})
        self.assertIn("!cancelled()", job["if"])  # past a red job, not after a cancel
        for source in ("check-nightly-webviews", "nightly-next-one"):
            self.assertIn(source, job["needs"])
            self.assertIn("lint_report", jobs[source]["outputs"])
            self.assertIn(f"needs.{source}.outputs.lint_report", job["if"])
        self.assertIn("nightly_fix_forward_issue.py file", job["steps"][-1]["run"])


if __name__ == "__main__":
    unittest.main()
