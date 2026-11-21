#!/usr/bin/env python3
"""Main's scheduled readers spend the cmux-bot App's budget, and a refusal names GitHub's reason.

On 2026-11-17 00:40Z the repository's GITHUB_TOKEN pool (1,000 requests an hour, shared by every
workflow) ran dry, and four scheduled jobs on main went red at once: required-checks drift (run
43989794349, "API rate limit exceeded for installation"), triage radar (43989604298, only "GitHub API
request failed (403)"), cmux-tui registry delivery (43989417033, only "HTTP Error 403: Forbidden") and
the full-suite issue sync (44010289849, only "returned non-zero exit status 1"). The classic API
guard on pull requests into main failed its files listing the same way (44033322032), and merge_hold
cannot excuse it: the workflow never runs on main. These tests pin that:

- each of those jobs mints the cmux-bot token and reads with it, github.token as GH_FALLBACK_TOKEN;
- each script asks a refused read once more with the fallback token, and keeps writes on it;
- a failure that remains prints GitHub's message, not only the status.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
LIMIT = "API rate limit exceeded for installation. If you reach out to GitHub Support ..."


def load(name: str, path: pathlib.Path):
    sys.path.insert(0, str(path.parent))
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


radar = load("triage_radar_under_test", ROOT / "scripts/ci/triage-radar.py")
drift = load("required_status_checks_under_test", ROOT / "scripts/ci/required_status_checks.py")
delivery = load("check_release_delivery_under_test", ROOT / "cmux-tui/scripts/check_release_delivery.py")
suite = load("main_full_suite", ROOT / "scripts/ci/main_full_suite.py")
guard = load("classic_api_guard_under_test", ROOT / "scripts/ci/classic_api_guard.py")


class Response(io.BytesIO):
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def fake_urlopen(refuse: dict[str, int], seen: list[tuple[str, str]]):
    def urlopen(request, timeout=30):  # noqa: ANN001, ANN202
        header = request.get_header("Authorization") or ""
        token = header.split()[-1] if header else ""
        seen.append((request.get_method(), token))
        code = refuse.get(token)
        if code:
            body = json.dumps({"message": LIMIT}).encode()
            raise urllib.error.HTTPError(request.full_url, code, "Forbidden", {}, io.BytesIO(body))  # type: ignore[arg-type]
        return Response(b"{}")
    return urlopen


class Workflows(unittest.TestCase):
    JOBS = {
        "required-checks-drift.yml": "Reconcile the required status checks on main",
        "triage-radar.yml": "Refresh current attention candidates",
        "cmux-tui-release-delivery.yml": "Check newest stable TUI release on PyPI and npm",
    }

    def test_each_reader_mints_cmux_bot_and_keeps_github_token_as_the_fallback(self) -> None:
        for name, step_name in self.JOBS.items():
            with self.subTest(workflow=name):
                text = (WORKFLOWS / name).read_text(encoding="utf-8")
                self.assertIn("app-id: ${{ vars.CMUX_BOT_APP_ID }}", text)
                self.assertIn("continue-on-error: true", text)
                step = text.split(f"- name: {step_name}\n", 1)[1]
                self.assertIn("GH_TOKEN: ${{ steps.read-token.outputs.token || github.token }}", step)
                self.assertIn("GH_FALLBACK_TOKEN: ${{ github.token }}", step)
                self.assertLess(text.index("id: read-token"), text.index(f"- name: {step_name}"))

    def test_the_full_suite_report_sends_its_gh_reads_as_cmux_bot(self) -> None:
        text = (WORKFLOWS / "ci-main-full-suite.yml").read_text(encoding="utf-8")
        report = text.split("\n  report:\n", 1)[1]
        self.assertIn("app-id: ${{ vars.CMUX_BOT_APP_ID }}", report)
        install = report.index("bash scripts/ci/gh_app_token.sh --install --reads-only")
        self.assertLess(report.index("id: read-token"), install)
        self.assertLess(install, report.index("- name: Attribute new failures to merged pull requests"))
        self.assertLess(install, report.index("- name: Open, update or close the tracking issue"))


class TriageRadar(unittest.TestCase):
    def calls(self, refuse: dict[str, int], method: str = "GET"):
        seen: list[tuple[str, str]] = []
        gh = radar.GitHub("app", "manaflow-ai/cmux", "workflow")
        with mock.patch.object(radar.urllib.request, "urlopen", fake_urlopen(refuse, seen)), \
                contextlib.redirect_stderr(io.StringIO()):
            try:
                gh.request(method, "/repos/manaflow-ai/cmux/issues/1", {} if method != "GET" else None)
                error = None
            except RuntimeError as raised:
                error = str(raised)
        return seen, error

    def test_reads_use_the_app_and_writes_the_workflow_token(self) -> None:
        self.assertEqual(self.calls({})[0], [("GET", "app")])
        self.assertEqual(self.calls({}, "PATCH")[0], [("PATCH", "workflow")])

    def test_a_refused_read_is_asked_again_with_the_workflow_token(self) -> None:
        seen, error = self.calls({"app": 403})
        self.assertEqual(seen, [("GET", "app"), ("GET", "workflow")])
        self.assertIsNone(error)

    def test_a_failure_names_githubs_message(self) -> None:
        _, error = self.calls({"app": 403, "workflow": 403})
        self.assertIn("HTTP 403", error)
        self.assertIn("API rate limit exceeded for installation", error)


class RequiredChecksDrift(unittest.TestCase):
    def calls(self, refuse: dict[str, int]):
        seen: list[tuple[str, str]] = []
        gh = drift.GitHub("manaflow-ai/cmux", "app", "workflow")
        with mock.patch.object(drift.urllib.request, "urlopen", fake_urlopen(refuse, seen)), \
                contextlib.redirect_stdout(io.StringIO()):
            try:
                gh.get("/repos/manaflow-ai/cmux/rules/branches/main")
                error = None
            except drift.DriftCheckError as raised:
                error = str(raised)
        return seen, error

    def test_a_refused_read_is_asked_again_with_the_workflow_token(self) -> None:
        seen, error = self.calls({"app": 403})
        self.assertEqual(seen, [("GET", "app"), ("GET", "workflow")])
        self.assertIsNone(error)

    def test_a_failure_still_names_githubs_message(self) -> None:
        seen, error = self.calls({"app": 403, "workflow": 403})
        self.assertEqual(len(seen), 2)
        self.assertIn("API rate limit exceeded for installation", error)

    def test_a_not_found_is_not_retried(self) -> None:
        seen, error = self.calls({"app": 404})
        self.assertEqual(seen, [("GET", "app")])
        self.assertIn("HTTP 404", error)


class RegistryDelivery(unittest.TestCase):
    def calls(self, refuse: dict[str, int]):
        seen: list[tuple[str, str]] = []
        with mock.patch.object(delivery.urllib.request, "urlopen", fake_urlopen(refuse, seen)), \
                contextlib.redirect_stderr(io.StringIO()):
            try:
                delivery.fetch_json("https://api.github.com/repos/x/y/git/matching-refs/tags/v", "app", "workflow")
                error = None
            except Exception as raised:  # noqa: BLE001 - the type is part of what is asserted
                error = raised
        return seen, error

    def test_a_refused_read_is_asked_again_with_the_workflow_token(self) -> None:
        seen, error = self.calls({"app": 403})
        self.assertEqual(seen, [("GET", "app"), ("GET", "workflow")])
        self.assertIsNone(error)

    def test_a_failure_names_githubs_message(self) -> None:
        _, error = self.calls({"app": 403, "workflow": 403})
        self.assertIsInstance(error, delivery.FetchError)
        self.assertIn("API rate limit exceeded for installation", str(error))

    def test_main_prints_the_message_and_exits_1_without_a_traceback(self) -> None:
        stderr = io.StringIO()
        with mock.patch.object(delivery.urllib.request, "urlopen", fake_urlopen({"app": 403}, [])), \
                mock.patch.dict(delivery.os.environ, {"GH_TOKEN": "app"}, clear=True), \
                mock.patch.object(sys, "argv", ["check_release_delivery.py"]), \
                contextlib.redirect_stderr(stderr):
            self.assertEqual(delivery.main(), 1)
        self.assertIn("API rate limit exceeded for installation", stderr.getvalue())


class FullSuiteSync(unittest.TestCase):
    def test_a_failed_gh_call_prints_its_stderr(self) -> None:
        error = subprocess.CalledProcessError(
            1, ["gh", "api", "-X", "GET", "repos/manaflow-ai/cmux/actions/workflows/ci.yml/runs"],
            output="", stderr=f"gh: {LIMIT} (HTTP 403)\n",
        )
        stderr = io.StringIO()
        with mock.patch.object(suite, "command_report", side_effect=error), contextlib.redirect_stderr(stderr):
            self.assertEqual(suite.main(["--repo", "manaflow-ai/cmux", "report"]), 1)
        self.assertRegex(stderr.getvalue(), re.escape("::error::gh api -X GET repos/manaflow-ai/cmux/"))
        self.assertIn("API rate limit exceeded for installation", stderr.getvalue())


class ClassicApiGuard(unittest.TestCase):
    WORKFLOW = WORKFLOWS / "classic-api-guard.yml"

    def files_urlopen(self, refuse: dict[str, int], seen: list[tuple[str, str]], files: list[dict]):
        def urlopen(request, timeout=30):  # noqa: ANN001, ANN202
            token = (request.get_header("Authorization") or "").split()[-1]
            seen.append((request.get_method(), token))
            code = refuse.get(token)
            if code:
                body = json.dumps({"message": LIMIT}).encode()
                raise urllib.error.HTTPError(request.full_url, code, "Forbidden", {}, io.BytesIO(body))  # type: ignore[arg-type]
            page = int(re.search(r"[?&]page=(\d+)", request.full_url).group(1))
            return Response(json.dumps(files[(page - 1) * 100:page * 100]).encode())
        return urlopen

    def run_guard(self, env: dict[str, str], refuse: dict[str, int], files: list[dict], body: str = ""):
        seen: list[tuple[str, str]] = []
        out = io.StringIO()
        with tempfile.TemporaryDirectory() as tmp:
            body_file = pathlib.Path(tmp) / "body.md"
            body_file.write_text(body)
            with mock.patch.object(guard.urllib.request, "urlopen", self.files_urlopen(refuse, seen, files)), \
                    mock.patch.dict(guard.os.environ, env, clear=True), contextlib.redirect_stdout(out):
                code = guard.main(["--base", "main", "--body-file", str(body_file), "--pr", "7",
                                   "--repository", "manaflow-ai/cmux", "--expected-files", str(len(files))])
        return code, out.getvalue(), seen

    def test_the_job_mints_cmux_bot_read_only_and_keeps_github_token_as_the_fallback(self) -> None:
        text = self.WORKFLOW.read_text(encoding="utf-8")
        mint = text.split("id: read-token", 1)[1].split("\n\n", 1)[0]
        self.assertIn("app-id: ${{ vars.CMUX_BOT_APP_ID }}", mint)
        self.assertIn("continue-on-error: true", mint)
        self.assertEqual(sorted(re.findall(r"permission-([a-z-]+): (\w+)", mint)),
                         [("contents", "read"), ("pull-requests", "read")])
        step = text.split("- name: Check the changed paths against classic's auto-deploys\n", 1)[1]
        self.assertIn("GH_TOKEN: ${{ steps.read-token.outputs.token || github.token }}", step)
        self.assertIn("GH_FALLBACK_TOKEN: ${{ github.token }}", step)
        self.assertIn("--pr \"$PR\"", step)
        self.assertLess(text.index("id: read-token"), text.index("- name: Check the changed paths"))

    def test_a_refused_listing_is_asked_again_with_the_workflow_token(self) -> None:
        files = [{"filename": "docs/a.md"}]
        code, out, seen = self.run_guard({"GH_TOKEN": "app", "GH_FALLBACK_TOKEN": "workflow"}, {"app": 403}, files)
        self.assertEqual(code, 0, out)
        self.assertEqual(seen, [("GET", "app"), ("GET", "workflow")])
        self.assertIn("No classic auto-deployed API path changed", out)

    def test_a_failed_listing_names_githubs_message(self) -> None:
        code, out, _ = self.run_guard({"GH_TOKEN": "app", "GH_FALLBACK_TOKEN": "workflow"},
                                      {"app": 403, "workflow": 403}, [{"filename": "docs/a.md"}])
        self.assertEqual(code, 1)
        self.assertIn("HTTP 403", out)
        self.assertIn("API rate limit exceeded for installation", out)

    def test_without_an_app_token_it_reads_on_github_token_alone(self) -> None:
        # A failed or skipped mint leaves GH_TOKEN as github.token, the fallback the same token.
        code, out, seen = self.run_guard({"GH_TOKEN": "workflow", "GH_FALLBACK_TOKEN": "workflow"}, {},
                                         [{"filename": "docs/a.md"}])
        self.assertEqual(code, 0, out)
        self.assertEqual(seen, [("GET", "workflow")])

    def test_the_listing_pages_and_counts_a_rename_once(self) -> None:
        files = [{"filename": f"docs/{i}.md"} for i in range(150)]
        files[3] = {"filename": "docs/new.md", "previous_filename": "docs/old.md"}
        seen: list[tuple[str, str]] = []
        with mock.patch.object(guard.urllib.request, "urlopen", self.files_urlopen({}, seen, files)):
            paths, records = guard.list_files(guard.Reader("workflow"), "manaflow-ai/cmux", 7)
        self.assertEqual(records, 150)
        self.assertEqual(len(paths), 151)
        self.assertIn("docs/old.md", paths)
        self.assertEqual(len(seen), 2)


if __name__ == "__main__":
    unittest.main()
