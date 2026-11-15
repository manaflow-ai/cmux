#!/usr/bin/env python3
"""The NEXT nightly publishes no tree with red webview checks, and none holding a known-bad commit without its fix.

2026-11-02: #32056 (fca2e5f4) landed a temporal-dead-zone read in SessionInfo.tsx (TS2448 in webviews'
`bun run check`), every agent pane showed "could not be drawn", and the nightly published 50298238a with it
before the fix #32160 (c8b7f59e) landed. Two runs already building that tree could not be stopped: the
legacy-identity requirement is a dispatch-time variable.

- check-nightly-webviews runs the gating webview checks on the exact build commit beside the app build, and
  publish-nightly's Final publication gate refuses a build without them green (scripts/ci/nightly_publish_guard.py
  webview-verdict).
- .github/nightly-known-bad.json, read live from feat-cmux-next, holds a build whose commit contains a listed bad
  commit without its fix, in publish-nightly, before anything is uploaded.
  Held is not failed; an unreadable list publishes with a warning.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import nightly_publish_guard as guard  # noqa: E402
from nightly_workflow_text import nightly_text  # noqa: E402
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

GUARD = ROOT / "scripts/ci/nightly_publish_guard.py"
LIST = ROOT / ".github/nightly-known-bad.json"
BAD, FIX, BUILD = "b" * 40, "f" * 40, "c" * 40


def jobs() -> dict:
    return yaml.safe_load(nightly_text())["jobs"]


def step_index(job: dict, name: str) -> int:
    return next(i for i, s in enumerate(job["steps"]) if s.get("name") == name)


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()


class DecideTests(unittest.TestCase):
    pairs = [{"bad": BAD, "fix": FIX, "note": "#32056"}]

    def decide(self, history: dict):
        return guard.decide(self.pairs, lambda commit: history.get(commit), BUILD)

    def test_bad_without_its_fix_is_held(self):
        skip, reason, warnings = self.decide({BAD: True, FIX: False})
        self.assertTrue(skip)
        self.assertIn("known-bad bbbbbbbbbbbb without its fix ffffffffffff (#32056)", reason)
        self.assertEqual(warnings, [])

    def test_bad_with_its_fix_publishes(self):
        self.assertFalse(self.decide({BAD: True, FIX: True})[0])

    def test_neither_publishes(self):
        self.assertFalse(self.decide({BAD: False, FIX: False})[0])

    def test_unknown_ancestry_publishes_with_a_warning(self):
        for history in ({BAD: None}, {BAD: True, FIX: None}):
            with self.subTest(history=history):
                skip, _, warnings = self.decide(history)
                self.assertFalse(skip)
                self.assertEqual(len(warnings), 1)

    def test_the_list_needs_full_shas(self):
        with self.assertRaises(ValueError):
            guard.parse_pairs('{"pairs": [{"bad": "fca2e5f4", "fix": "c8b7f59e"}]}')
        with self.assertRaises(ValueError):
            guard.parse_pairs('{"bad": []}')

    def test_the_seeded_list_holds_the_incident(self):
        pairs = guard.parse_pairs(LIST.read_text())
        self.assertIn({"bad": "fca2e5f462f66949c1fb41a37da80c47daff7971",
                       "fix": "c8b7f59ea4d4271274acbe8d795846de3e2805a0"},
                      [{"bad": p["bad"], "fix": p["fix"]} for p in pairs])


class KnownBadCommandTests(unittest.TestCase):
    """The command end to end: a real (local) repository's history through the treeless fetch."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.work = Path(self.temp.name)
        repo = self.repo = self.work / "repo"
        repo.mkdir()
        git(repo, "init", "-q", "-b", "main")
        git(repo, "config", "user.email", "t@example.invalid")
        git(repo, "config", "user.name", "t")
        git(repo, "config", "uploadpack.allowAnySHA1InWant", "true")
        git(repo, "config", "uploadpack.allowFilter", "true")
        self.commits = {}
        for name in ("base", "bad", "between", "fix", "after"):
            (repo / "f").write_text(name)
            git(repo, "add", "f")
            git(repo, "commit", "-q", "-m", name)
            self.commits[name] = git(repo, "rev-parse", "HEAD")
        (self.work / "list.json").write_text(json.dumps(
            {"pairs": [{"bad": self.commits["bad"], "fix": self.commits["fix"], "note": "test"}]}))

    def tearDown(self):
        self.temp.cleanup()

    def run_guard(self, sha: str, list_file: str | None = None) -> tuple[subprocess.CompletedProcess, dict]:
        output = self.work / "output"
        output.write_text("")
        env = dict(os.environ, NIGHTLY_KNOWN_BAD_GIT_URL=f"file://{self.repo}", GITHUB_STEP_SUMMARY=str(self.work / "summary"),
                   PATH=f"{self.work / 'nogh'}:{os.environ['PATH']}")
        (self.work / "nogh").mkdir(exist_ok=True)
        fake = self.work / "nogh" / "gh"
        fake.write_text("#!/bin/sh\necho 'HTTP 503' >&2\nexit 1\n")
        fake.chmod(0o755)
        result = subprocess.run([sys.executable, str(GUARD), "known-bad", "--repo", "o/r", "--sha", sha,
                                 "--list-file", list_file or str(self.work / "list.json"), "--github-output", str(output)],
                                env=env, capture_output=True, text=True)
        return result, dict(line.split("=", 1) for line in output.read_text().splitlines() if "=" in line)

    def test_a_tree_between_bad_and_fix_is_held(self):
        result, out = self.run_guard(self.commits["between"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(out["skip"], "true", result.stdout)
        self.assertIn("held, not published", (self.work / "summary").read_text())

    def test_a_tree_with_the_fix_or_before_the_bad_publishes(self):
        for name in ("fix", "after", "base"):
            with self.subTest(name=name):
                result, out = self.run_guard(self.commits[name])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(out["skip"], "false", result.stdout)

    def test_an_unreadable_list_publishes_with_a_warning(self):
        result, out = self.run_guard(self.commits["between"], list_file=str(self.work / "missing.json"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(out["skip"], "false")
        self.assertIn("::warning", result.stdout)

    def test_an_unreadable_live_list_publishes_with_a_warning(self):
        # No --list-file: the list is read from GitHub, and the fake gh fails.
        output = self.work / "output"
        env = dict(os.environ, PATH=f"{self.work / 'nogh'}:{os.environ['PATH']}", NIGHTLY_KNOWN_BAD_LIST_FILE="")
        self.run_guard(self.commits["between"])  # makes the fake gh
        result = subprocess.run([sys.executable, str(GUARD), "known-bad", "--repo", "o/r", "--sha", self.commits["between"],
                                 "--github-output", str(output)], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("skip=false", output.read_text())
        self.assertIn("known-bad list unreadable", result.stdout)


class WebviewVerdictTests(unittest.TestCase):
    def test_own_build_needs_this_runs_job_green_on_the_build_commit(self):
        self.assertTrue(guard.webview_verdict("own", "success", BUILD, BUILD)[0])
        for result, checked in (("failure", ""), ("skipped", ""), ("", ""), ("success", "d" * 40), ("success", "")):
            with self.subTest(result=result, checked=checked):
                self.assertFalse(guard.webview_verdict("own", result, checked, BUILD)[0])

    def test_recovered_build_needs_its_runs_job_green(self):
        green = [{"name": guard.WEBVIEW_JOB, "conclusion": "success"}]
        self.assertTrue(guard.webview_verdict("recovered", "", "", BUILD, lambda: green)[0])
        for listed in ([], [{"name": guard.WEBVIEW_JOB, "conclusion": "failure"}], [{"name": "other", "conclusion": "success"}]):
            with self.subTest(listed=listed):
                self.assertFalse(guard.webview_verdict("recovered", "", "", BUILD, lambda: listed)[0])

    def test_an_unreadable_recovered_run_refuses(self):
        def broken():
            raise RuntimeError("HTTP 502")
        ok, line = guard.webview_verdict("recovered", "", "", BUILD, broken)
        self.assertFalse(ok)
        self.assertIn("HTTP 502", line)


class GateTests(unittest.TestCase):
    """publish-nightly's real Final publication gate, with NIGHTLY_NEXT_WRITER=mac read from a fake gh."""

    def run_gate(self, *, check: str = "success", checked: str = BUILD, pairs: list | None = None):
        gate = next(s for s in jobs()["publish-nightly"]["steps"] if s.get("name") == "Final publication gate")
        with tempfile.TemporaryDirectory() as temp:
            work = Path(temp)
            (work / "bin").mkdir()
            gh = work / "bin" / "gh"
            # NIGHTLY_NEXT_WRITER reads mac; the compare API says the fix is not in the build.
            gh.write_text('#!/bin/sh\ncase "$*" in *compare*) echo diverged ;; *variables*) echo mac ;; *) exit 1 ;; esac\n')
            gh.chmod(0o755)
            (work / "list.json").write_text(json.dumps({"pairs": pairs or []}))
            output = work / "output"
            output.touch()
            env = dict(os.environ, PATH=f"{work / 'bin'}:{os.environ['PATH']}", TRACK="nightly-next", SOURCE="own",
                       NIGHTLY_BUILD="4900101", BUILD_SHA=BUILD, WRITER_TOKEN="t", GITHUB_REPOSITORY="o/r",
                       CHANNEL_RELEASE_TAG="nightly-next", GITHUB_OUTPUT=str(output),
                       GITHUB_STEP_SUMMARY=str(work / "summary"), RUNNER_TEMP=str(work),
                       PUBLISH_TOOLING=str(ROOT / "scripts"), WEBVIEW_CHECK=check, WEBVIEW_CHECK_SHA=checked,
                       NIGHTLY_KNOWN_BAD_LIST_FILE=str(work / "list.json"), NIGHTLY_KNOWN_BAD_GIT_URL="")
            result = subprocess.run(["bash", "-c", gate["run"]], cwd=ROOT, env=env, capture_output=True, text=True)
            result.output = dict(l.split("=", 1) for l in output.read_text().splitlines() if "=" in l)  # type: ignore[attr-defined]
            return result

    def test_green_checks_and_no_listed_commit_publish(self):
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("refused", result.output, result.stdout)

    def test_red_webview_checks_refuse_with_a_reason(self):
        for check, checked in (("failure", ""), ("skipped", ""), ("success", "d" * 40)):
            with self.subTest(check=check):
                result = self.run_gate(check=check, checked=checked)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.output.get("refused"), "true")
                self.assertIn("webview checks", result.output.get("refusal_reason", ""))

    def test_a_listed_commit_is_held_without_a_failure(self):
        # The build commit itself is listed as bad; the fix's ancestry comes from the (fake) compare API.
        result = self.run_gate(pairs=[{"bad": BUILD, "fix": FIX}])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.output.get("refused"), "true", result.stdout)
        self.assertNotIn("refusal_reason", result.output)
        self.assertIn("Publication stood down", result.stdout)


class WorkflowTests(unittest.TestCase):
    def test_the_check_job_checks_the_build_commit_beside_the_build(self):
        job = jobs()["check-nightly-webviews"]
        self.assertEqual(job["name"], guard.WEBVIEW_JOB)
        self.assertEqual(job["needs"], ["decide", "resolve-nightly-cmux-tui-client"],
                         "beside build-nightly-app, never after it")
        checkout = job["steps"][0]
        self.assertEqual(checkout["with"]["ref"], "${{ needs.resolve-nightly-cmux-tui-client.outputs.build_sha }}")
        self.assertIn("fast_gate_webviews_checks.py", job["steps"][-1]["run"])
        self.assertNotIn("--base", job["steps"][-1]["run"], "every red counts on the build commit")
        self.assertIn("needs.resolve-nightly-cmux-tui-client.outputs.build_sha", job["outputs"]["sha"])

    def test_publish_nightly_gates_on_it_before_any_upload(self):
        job = jobs()["publish-nightly"]
        self.assertIn("check-nightly-webviews", job["needs"])
        gate_at = step_index(job, "Final publication gate")
        env = job["steps"][gate_at]["env"]
        self.assertEqual(env["WEBVIEW_CHECK"], "${{ needs.check-nightly-webviews.result }}")
        self.assertEqual(env["WEBVIEW_CHECK_SHA"], "${{ needs.check-nightly-webviews.outputs.sha }}")
        self.assertIn("nightly_publish_guard.py\" webview-verdict", job["steps"][gate_at]["run"])
        self.assertIn("nightly_publish_guard.py\" known-bad", job["steps"][gate_at]["run"])
        for i, step in enumerate(job["steps"]):
            name = step.get("name", "")
            if name.startswith(("Publish", "Upload nightly", "Prune old", "Move channel")) and "Upload branch" not in name:
                with self.subTest(step=name):
                    self.assertGreater(i, gate_at)
                    self.assertIn("steps.gate.outputs.refused != 'true'", step["if"])
        # A failed check never skips the job (its gate refuses with a reason instead).
        self.assertNotIn("check-nightly-webviews.result", job["if"])

    def test_the_legacy_order_step_skips_a_held_build(self):
        script = ROOT / "scripts/ci/nightly-steps/legacy-identity-publish-skip-published.sh"
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "output"
            env = dict(os.environ, KNOWN_BAD="true", NIGHTLY_BUILD="4900101", GITHUB_OUTPUT=str(output),
                       GITHUB_STEP_SUMMARY=str(Path(temp) / "summary"), NIGHTLY_NEXT_LEGACY_FEED_BASE="http://127.0.0.1:9")
            result = subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(output.read_text(), "skip=true\n")


if __name__ == "__main__":
    unittest.main()
