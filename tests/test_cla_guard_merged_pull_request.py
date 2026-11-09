#!/usr/bin/env python3
"""The CLA policy guard has nothing to gate on a pull request that is already merged.

A bot (for example a review bot that rewrites its summary) can edit a pull
request a few seconds after it merges. The guard workflow triggers on
`edited`, so GitHub starts a run on the merged pull request. A merged pull
request cannot merge again or reopen. Before this rule, the validator required
`state == "open"` and the run failed with "rejected the proposed policy"
(cmux #39226, run 42566226142), a red check that nobody could act on.

These tests run the validator's real main block. Only its API reader is
replaced: it answers the pull-request read from a fixture and fails any other
read. The git remote points to a path that does not exist, so a revision read
also fails.
"""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "scripts/ci/validate-cla-policy.rb"
REPOSITORY = "manaflow-ai/cmux"
REPOSITORY_ID = 1001
BASE = "b" * 40
HEAD = "c" * 40

RUBY_DRIVER = r"""
require "json"
path = ARGV.shift
src = File.read(path)
cut = src.rindex("\nbegin\n  run_yaml_regression_matrix!")
abort "validator main block not found" unless cut
eval(src[0...cut], TOPLEVEL_BINDING, path)
$api_calls = []
$fixture_api = JSON.parse(File.read(ENV.fetch("FIXTURE_API_FILE")))
def api_json(repository, endpoint, allow_missing: false)
  $api_calls << endpoint
  return $fixture_api.fetch(endpoint) if $fixture_api.key?(endpoint)
  return nil if allow_missing

  fail!("GitHub API request failed for #{endpoint}")
end
def git_remote_url(repository)
  ENV.fetch("FIXTURE_REMOTE")
end
def fail!(message)
  STDERR.puts "FAIL: #{message}"
  raise PolicyError, message
end
at_exit { STDERR.puts "API_CALLS=#{JSON.generate($api_calls)}" }
eval(src[cut..], TOPLEVEL_BINDING, path)
"""


class CLAGuardMergedPullRequestTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)

    def pull_request(self, state: str, head: str = HEAD) -> dict:
        # The shape api_json returns for a pull request (mapped from GraphQL,
        # where the state is OPEN, CLOSED or MERGED).
        return {
            "number": 7, "state": state, "mergeable": None, "user": {"id": 42},
            "base": {"ref": "main", "sha": BASE, "repo": {"full_name": REPOSITORY, "id": REPOSITORY_ID}},
            "head": {"ref": "feature", "sha": head, "repo": {"full_name": "contributor/cmux", "id": 2002}},
        }

    def run_validator(self, pull_request: dict) -> tuple[subprocess.CompletedProcess, list[str]]:
        api_file = Path(self.directory.name) / "api.json"
        api_file.write_text(json.dumps({f"repos/{REPOSITORY}/pulls/7": pull_request}))
        env = {
            **os.environ, "GH_REPO": REPOSITORY, "PR_NUMBER": "7", "BASE_SHA": BASE, "HEAD_SHA": HEAD,
            "GITHUB_REPOSITORY_ID": str(REPOSITORY_ID), "FIXTURE_API_FILE": str(api_file),
            "FIXTURE_REMOTE": (Path(self.directory.name) / "no-such-remote").as_uri(),
        }
        env.pop("CANDIDATE_DIR", None)
        result = subprocess.run(["ruby", "-e", RUBY_DRIVER, str(VALIDATOR)], env=env,
                                capture_output=True, text=True, check=False, timeout=600)
        marker = [line for line in result.stderr.splitlines() if line.startswith("API_CALLS=")]
        self.assertTrue(marker, result.stdout + result.stderr)
        return result, json.loads(marker[-1].removeprefix("API_CALLS="))

    def test_a_merged_pull_request_at_its_head_passes_with_no_file_read(self):
        result, calls = self.run_validator(self.pull_request("merged"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("already merged", result.stdout)
        self.assertEqual(calls, [f"repos/{REPOSITORY}/pulls/7"])

    def test_a_closed_pull_request_that_did_not_merge_still_fails(self):
        # A closed pull request can reopen; it stays fail-closed.
        result, _ = self.run_validator(self.pull_request("closed"))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("pull request metadata changed while validating", result.stderr)

    def test_a_merged_pull_request_with_another_head_still_fails(self):
        result, _ = self.run_validator(self.pull_request("merged", head="d" * 40))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertNotIn("already merged", result.stdout)


if __name__ == "__main__":
    unittest.main()
