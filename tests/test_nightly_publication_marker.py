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

    def _run_continuation_close(self, compare_status):
        steps = {step["name"]: step for step in yaml.safe_load(WORKFLOW.read_text())["jobs"]["publish"]["steps"]}
        script = steps["Close deferred nightly failure incident"]["with"]["script"]
        original_sha = "a" * 40
        published_sha = "b" * 40
        issue_body = (
            f"cmux NIGHTLY run https://github.com/manaflow-ai/cmux/actions/runs/1 "
            f"failed on {original_sha} (main) in: build-nightly-app."
        )
        node = f"""
const calls = [];
const github = {{
  paginate: async (fn, args) => (await fn(args)).data,
  rest: {{
    issues: {{
      listForRepo: async () => ({{ data: [{{ number: 18582, body: {json.dumps(issue_body)} }}] }}),
      listComments: async () => ({{ data: [] }}),
      createComment: async (args) => calls.push(["comment", args]),
      update: async (args) => calls.push(["update", args]),
    }},
    repos: {{
      // Against a branch name: the failed commit is still on its branch.
      compareCommitsWithBasehead: async ({{ basehead }}) => ({{ data: {{ status: /[.][.][.][0-9a-f]{{40}}$/.test(basehead) ? {json.dumps(compare_status)} : 'ahead' }} }}),
    }},
  }},
}};
const context = {{
  repo: {{ owner: "manaflow-ai", repo: "cmux" }},
  serverUrl: "https://github.com",
  runId: 2,
}};
const core = {{ info: () => {{}} }};
process.env.GITHUB_WORKSPACE = {json.dumps(str(ROOT))};
process.env.CHANNEL = "nightly";
process.env.SOURCE_HEAD_SHA = {json.dumps(published_sha)};
process.env.SOURCE_BRANCH = "main";
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
        return published_sha, json.loads(completed.stdout)

    def test_continuation_closes_an_incident_its_commit_includes(self):
        published_sha, calls = self._run_continuation_close("ahead")
        self.assertEqual([call[0] for call in calls], ["comment", "update"])
        self.assertIn(published_sha, calls[0][1]["body"])
        self.assertEqual(calls[1][1]["state"], "closed")

    def test_continuation_leaves_open_an_incident_on_a_newer_commit(self):
        # Push runs build in parallel: an older continuation must not close a
        # newer commit's failure.
        published_sha, calls = self._run_continuation_close("behind")
        self.assertEqual([call[0] for call in calls], ["comment"])
        self.assertIn("stays open", calls[0][1]["body"])

if __name__ == "__main__":
    unittest.main()
