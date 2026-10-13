#!/usr/bin/env python3
"""The release body is an exact, idempotent publication record."""

import importlib.util
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import yaml


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "nightly_publication_marker", ROOT / "scripts/ci/nightly-publication-marker.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)
WORKFLOW = ROOT / ".github/workflows/auto-resume-nightly-notarization.yml"


class NightlyPublicationMarkerTests(unittest.TestCase):
    SHA = "A" * 40

    def test_reads_exact_sha_marker_case_insensitively(self):
        body = f"before\n<!-- cmux-published-sha: {self.SHA} -->\nafter"
        self.assertEqual(MODULE.published_sha(body), self.SHA.lower())

    def test_missing_or_malformed_marker_does_not_claim_publication(self):
        self.assertIsNone(MODULE.published_sha("Published commit: `" + "a" * 40 + "`"))
        self.assertIsNone(MODULE.published_sha("<!-- cmux-published-sha: " + "a" * 39 + " -->"))

    def test_continuation_retries_closure_only_for_the_published_source(self):
        steps = {step["name"]: step for step in yaml.safe_load(WORKFLOW.read_text())["jobs"]["publish"]["steps"]}
        guard = steps["Reject stale continuation before publication"]["run"]
        # Execute the workflow's release lookup with a fixture response.
        lookup = guard.split("\n", 2)[2].split("\nPY\n", 1)[0]
        closure = steps["Close deferred nightly failure incident"]["if"].replace("||", "or").replace("&&", "and")
        for published_sha, build, should_publish, should_close in (
            (self.SHA.lower(), 99, False, True),
            (self.SHA.lower(), 100, False, True),
            (self.SHA.lower(), 101, False, True),
            ("b" * 40, 100, False, False),
            ("b" * 40, 101, False, False),
            ("b" * 40, 99, True, True),
            (None, 101, False, False),
        ):
            with self.subTest(published_sha=published_sha, build=build):
                body = f"<!-- cmux-published-build: {build} -->"
                if published_sha:
                    body += f"<!-- cmux-published-sha: {published_sha} -->"
                output = io.StringIO()
                with patch("urllib.request.urlopen", return_value=io.StringIO(json.dumps({"body": body}))), \
                        patch.object(sys, "argv", ["-", "test/repo", "nightly", self.SHA, "100"]), \
                        patch.dict(os.environ, {"GH_TOKEN": "fixture"}), contextlib.redirect_stdout(output):
                    exec(compile(lookup, str(WORKFLOW), "exec"), {})
                result = dict(line.split("=", 1) for line in output.getvalue().splitlines())
                env = SimpleNamespace(
                    ALREADY_PUBLISHED=result.get("already_published", "false"),
                    ALREADY_PUBLISHED_SAME_SOURCE=result.get("published_same_source", "false"),
                )
                self.assertEqual(env.ALREADY_PUBLISHED != "true", should_publish)
                self.assertEqual(eval(closure, {"env": env}), should_close)

    def run_guard(self, body, channel, source_branch, ancestor):
        steps = {step["name"]: step for step in yaml.safe_load(WORKFLOW.read_text())["jobs"]["publish"]["steps"]}
        guard = steps["Reject stale continuation before publication"]["run"]
        lookup = guard.split("\n", 2)[2].split("\nPY\n", 1)[0]
        output = io.StringIO()
        with patch("urllib.request.urlopen", return_value=io.StringIO(json.dumps({"body": body}))), \
                patch.object(sys, "argv", ["-", "test/repo", channel, self.SHA, "100"]), \
                patch.dict(os.environ, {"GH_TOKEN": "fixture"}), contextlib.redirect_stdout(output):
            exec(compile(lookup, str(WORKFLOW), "exec"), {})
        # Run the step's shell on the lookup's output with a stub git whose
        # ancestry answer is fixed.
        shell = guard.split("\nPY\n", 1)[1]
        with tempfile.TemporaryDirectory() as temp:
            bin_dir = Path(temp, "bin")
            bin_dir.mkdir()
            git = bin_dir / "git"
            git.write_text(f"#!/bin/sh\n[ \"$1\" = merge-base ] && exit {0 if ancestor else 1}\nexit 0\n")
            git.chmod(0o755)
            Path(temp, "publication-guard").write_text(output.getvalue())
            env_file = Path(temp, "env")
            env_file.touch()
            completed = subprocess.run(
                ["bash", "-c", "set -euo pipefail\n" + shell],
                env={
                    "PATH": f"{bin_dir}:{os.environ['PATH']}",
                    "RUNNER_TEMP": temp,
                    "GITHUB_ENV": str(env_file),
                    "CHANNEL": channel,
                    "SOURCE_BRANCH": source_branch,
                    "SOURCE_HEAD_SHA": self.SHA.lower(),
                },
                text=True,
                capture_output=True,
                check=False,
            )
        return output.getvalue(), completed

    def test_newer_rc_line_replaces_an_older_line_without_shared_ancestry(self):
        published = "b" * 40
        prose = f"<!-- cmux-published-sha: {published} -->\nAutomated rc build for `{published[:7]}` from `rc/v0.65.0`.\n"
        marker = f"<!-- cmux-published-sha: {published} -->\n<!-- cmux-published-branch: rc/v0.65.0 -->\n"
        no_branch = f"<!-- cmux-published-sha: {published} -->\n"
        same_line = f"<!-- cmux-published-sha: {published} -->\n<!-- cmux-published-branch: rc/v0.65.2 -->\n"
        lookup, _ = self.run_guard(prose, "rc", "rc/v0.65.2", ancestor=False)
        self.assertIn(f"published_sha={published}", lookup)
        self.assertIn("published_branch=rc/v0.65.0", lookup)
        for body, channel, source_branch, ancestor, should_pass in (
            (prose, "rc", "rc/v0.65.2", False, True),
            (marker, "rc", "rc/v0.65.2", False, True),
            (prose, "rc", "rc/v0.65.10", False, True),
            (prose, "rc", "rc/v0.64.9", False, False),
            (prose, "rc", "rc/v0.65.0", False, False),
            (prose, "rc", "rc/vfoo", False, False),
            (no_branch, "rc", "rc/v0.65.2", False, False),
            (same_line, "rc", "rc/v0.65.2", False, False),
            (same_line, "rc", "rc/v0.65.2", True, True),
            (prose, "nightly", "main", False, False),
        ):
            with self.subTest(body=body, channel=channel, source_branch=source_branch, ancestor=ancestor):
                _, completed = self.run_guard(body, channel, source_branch, ancestor)
                self.assertEqual(completed.returncode == 0, should_pass, completed.stderr)

    def test_continuation_closes_issue_when_later_failure_comment_has_newer_sha(self):
        steps = {step["name"]: step for step in yaml.safe_load(WORKFLOW.read_text())["jobs"]["publish"]["steps"]}
        script = steps["Close deferred nightly failure incident"]["with"]["script"]
        original_sha = "A" * 40
        published_sha = "B" * 40
        issue_body = (
            f"cmux NIGHTLY run https://github.com/manaflow-ai/cmux/actions/runs/1 "
            f"failed on {original_sha} (main) in: build-nightly-app."
        )
        node = f"""
const calls = [];
const github = {{
  rest: {{
    issues: {{
      listForRepo: async () => ({{ data: [{{ number: 18582, body: {json.dumps(issue_body)} }}] }}),
      createComment: async (args) => calls.push(["comment", args]),
      update: async (args) => calls.push(["update", args]),
    }},
  }},
}};
const context = {{
  repo: {{ owner: "manaflow-ai", repo: "cmux" }},
  serverUrl: "https://github.com",
  runId: 2,
}};
process.env.CHANNEL = "nightly";
process.env.SOURCE_HEAD_SHA = {json.dumps(published_sha)};
(async () => {{
{script}
  process.stdout.write(JSON.stringify(calls));
}})().catch((error) => {{
  console.error(error);
  process.exit(1);
}});
"""
        completed = subprocess.run(
            ["node", "--input-type=module", "-"],
            input=node,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        calls = json.loads(completed.stdout)
        self.assertEqual([call[0] for call in calls], ["comment", "update"])
        self.assertIn(published_sha, calls[0][1]["body"])


if __name__ == "__main__":
    unittest.main()
