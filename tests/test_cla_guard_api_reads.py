#!/usr/bin/env python3
"""Contract tests for bounded, classified CLA policy API reads."""

import json
import os
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "scripts/ci/validate-cla-policy.rb"

RUBY_DRIVER = r'''
require "json"
source = File.read(ARGV.fetch(0))
cut = source.rindex("\nbegin\n  run_yaml_regression_matrix!")
abort "validator main block not found" unless cut
eval(source[0...cut], TOPLEVEL_BINDING, ARGV.fetch(0))
$responses = JSON.parse(ENV.fetch("RESPONSES"))
$calls = []
$sleeps = []
$now = ENV.fetch("NOW", "100").to_f

class FakeStatus
  def initialize(code)
    @code = code
  end
  def success?
    @code.between?(200, 299)
  end
end

def api_capture(args)
  $calls << args
  response = $responses.shift
  raise "no fake response for #{args.inspect}" unless response
  [response[0], response[1], FakeStatus.new(response[2])]
end

def api_wall_time
  $now
end

def api_monotonic_time
  $now
end

def api_sleep(seconds)
  $sleeps << seconds
  $now += seconds.to_f
end

begin
  endpoints = ENV["ENDPOINTS"] ? JSON.parse(ENV["ENDPOINTS"]) : [ENV.fetch("ENDPOINT")]
  results = endpoints.map { |endpoint| api_json("example/cmux", endpoint, allow_missing: ENV["ALLOW_MISSING"] == "1") }
  result = results.length == 1 ? results.fetch(0) : results
  puts JSON.generate({"ok" => true, "result" => result, "calls" => $calls, "sleeps" => $sleeps})
rescue StandardError => error
  puts JSON.generate({"ok" => false, "class" => error.class.name, "error" => error.message, "calls" => $calls, "sleeps" => $sleeps})
end
'''


def http(status, body, *, remaining=None, reset=None, retry_after=None, stderr=""):
    headers = [f"HTTP/2 {status}"]
    if remaining is not None:
        headers.append(f"X-RateLimit-Remaining: {remaining}")
    if reset is not None:
        headers.append(f"X-RateLimit-Reset: {reset}")
    if retry_after is not None:
        headers.append(f"Retry-After: {retry_after}")
    return ["\r\n".join(headers) + "\r\n\r\n" + json.dumps(body), stderr, status]


class ApiReadTests(unittest.TestCase):
    def invoke(self, endpoint, responses, *, now=100, allow_missing=False, endpoints=None):
        env = {
            **os.environ,
            "RESPONSES": json.dumps(responses),
            "ENDPOINT": endpoint,
            **({"ENDPOINTS": json.dumps(endpoints)} if endpoints is not None else {}),
            "NOW": str(now),
            "ALLOW_MISSING": "1" if allow_missing else "0",
        }
        result = subprocess.run(
            ["ruby", "-e", RUBY_DRIVER, str(VALIDATOR)],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        outcome = json.loads(result.stdout.strip().splitlines()[-1])
        outcome["diagnostics"] = result.stderr
        return outcome

    def test_installation_rate_limit_is_classified_waited_once_and_retried(self):
        value = {"id": 7, "state": "open"}
        outcome = self.invoke(
            "repos/example/cmux/issues/7",
            [
                http(403, {"message": "API rate limit exceeded for installation"}, remaining=0, reset=105),
                http(200, value),
            ],
        )
        self.assertTrue(outcome["ok"], outcome)
        self.assertEqual(outcome["result"], value)
        self.assertEqual(len(outcome["calls"]), 2)
        self.assertEqual(outcome["sleeps"], [6.0])
        self.assertIn("rate limit (HTTP 403; rate-limit reset 105)", outcome["diagnostics"])

    def test_plain_forbidden_is_fail_closed_without_retry(self):
        outcome = self.invoke(
            "repos/example/cmux/issues/7",
            [http(403, {"message": "Resource not accessible by integration"}, remaining=4999)],
        )
        self.assertFalse(outcome["ok"])
        self.assertEqual(outcome["class"], "APIReadError", outcome)
        self.assertEqual(len(outcome["calls"]), 1)
        self.assertEqual(outcome["sleeps"], [])
        self.assertIn("forbidden (HTTP 403", outcome["error"])

    def test_server_error_uses_bounded_backoff(self):
        outcome = self.invoke(
            "repos/example/cmux/issues/7",
            [http(500, {"message": "temporary"}, remaining=4999, reset=1000),
             http(502, {}, remaining=4999, reset=1000), http(200, {"ok": True})],
        )
        self.assertTrue(outcome["ok"], outcome)
        self.assertEqual(outcome["sleeps"], [1.0, 2.0])

    def test_far_reset_fails_without_sleep_and_redacts_response(self):
        outcome = self.invoke(
            "repos/example/cmux/issues/7",
            [http(403, {"message": "API rate limit exceeded; secret=DO_NOT_LEAK"}, remaining=0, reset=1000,
                       stderr="Authorization: bearer DO_NOT_LEAK")],
        )
        self.assertFalse(outcome["ok"])
        self.assertEqual(outcome["class"], "APIReadError", outcome)
        self.assertEqual(outcome["sleeps"], [])
        self.assertNotIn("DO_NOT_LEAK", outcome["error"] + outcome["diagnostics"])
        self.assertRegex(outcome["error"], r"(?i)(rate|reset|403)")

    def test_graphql_pull_request_mapping_does_not_fall_back_to_rest(self):
        graphql = {"data": {"repository": {"databaseId": 1001, "nameWithOwner": "example/cmux", "pullRequest": {
            "number": 7, "state": "OPEN", "mergeable": "MERGEABLE", "potentialMergeCommit": {"oid": "a" * 40},
            "author": {"databaseId": 42}, "baseRefName": "main", "baseRefOid": "b" * 40,
            "headRefName": "feature", "headRefOid": "c" * 40,
            "headRepository": {"nameWithOwner": "contributor/cmux", "databaseId": 99},
        }}}}
        outcome = self.invoke("repos/example/cmux/pulls/7", [http(200, graphql)])
        self.assertTrue(outcome["ok"], outcome)
        result = outcome["result"]
        self.assertEqual(result["number"], 7)
        self.assertEqual(result["state"], "open")
        self.assertEqual(result["user"]["id"], 42)
        self.assertEqual(result["base"]["ref"], "main")
        self.assertEqual(result["base"]["sha"], "b" * 40)
        self.assertEqual(result["base"]["repo"]["id"], 1001)
        self.assertEqual(result["base"]["repo"]["full_name"], "example/cmux")
        self.assertEqual(result["head"]["ref"], "feature")
        self.assertEqual(result["head"]["sha"], "c" * 40)
        self.assertEqual(result["head"]["repo"]["full_name"], "contributor/cmux")
        self.assertTrue(result["mergeable"])
        self.assertEqual(result["merge_commit_sha"], "a" * 40)
        self.assertIn("graphql", " ".join(outcome["calls"][0]).lower())
        self.assertNotIn("/pulls/7", " ".join(outcome["calls"][0]))

    def test_graphql_partial_error_fails_closed_and_missing_fork_stays_nil(self):
        partial = {"data": {"repository": {"pullRequest": {"number": 7}}},
                   "errors": [{"type": "FORBIDDEN", "message": "secret details"}]}
        outcome = self.invoke("repos/example/cmux/pulls/7", [http(200, partial)])
        self.assertFalse(outcome["ok"])
        self.assertEqual(outcome["class"], "APIReadError", outcome)
        self.assertNotIn("secret details", outcome["error"])

        missing_repo = {"data": {"repository": {"databaseId": 1001, "nameWithOwner": "example/cmux", "pullRequest": {
            "number": 7, "state": "OPEN", "mergeable": "UNKNOWN", "potentialMergeCommit": None,
            "author": {"databaseId": 42}, "baseRefName": "main", "baseRefOid": "b" * 40,
            "headRefName": "feature", "headRefOid": "c" * 40, "headRepository": None,
        }}}}
        outcome = self.invoke("repos/example/cmux/pulls/7", [http(200, missing_repo)])
        self.assertTrue(outcome["ok"], outcome)
        self.assertIsNone(outcome["result"]["head"]["repo"])
        self.assertEqual(len(outcome["calls"]), 1)

    def test_persistent_rate_limit_exhausts_four_attempts(self):
        outcome = self.invoke(
            "repos/example/cmux/issues/7",
            [http(429, {"message": "rate limited"}) for _ in range(4)],
        )
        self.assertFalse(outcome["ok"])
        self.assertEqual(outcome["class"], "APIReadError", outcome)
        self.assertEqual(len(outcome["calls"]), 4)
        self.assertEqual(outcome["sleeps"], [60.0, 60.0, 60.0])

    def test_retry_deadline_is_shared_across_api_json_calls(self):
        outcome = self.invoke(
            "repos/example/cmux/issues/7",
            [
                http(403, {"message": "rate limit"}, remaining=0, reset=400),
                http(200, {"first": True}),
                http(403, {"message": "rate limit"}, remaining=0, reset=601),
            ],
            endpoints=["repos/example/cmux/issues/7", "repos/example/cmux/issues/8"],
        )
        self.assertFalse(outcome["ok"])
        self.assertEqual(outcome["class"], "APIReadError", outcome)
        self.assertEqual(len(outcome["calls"]), 3)
        self.assertEqual(outcome["sleeps"], [301.0])

    def test_graphql_rate_limit_error_retries_then_maps_result(self):
        graphql_error = {"errors": [{"type": "RATE_LIMITED", "message": "quota"}]}
        graphql = {"data": {"repository": {"databaseId": 1001, "nameWithOwner": "example/cmux", "pullRequest": {
            "number": 7, "state": "OPEN", "mergeable": "MERGEABLE", "potentialMergeCommit": {"oid": "a" * 40},
            "author": {"databaseId": 42}, "baseRefName": "main", "baseRefOid": "b" * 40,
            "headRefName": "feature", "headRefOid": "c" * 40,
            "headRepository": {"nameWithOwner": "contributor/cmux", "databaseId": 99},
        }}}}
        outcome = self.invoke("repos/example/cmux/pulls/7", [http(200, graphql_error), http(200, graphql)])
        self.assertTrue(outcome["ok"], outcome)
        self.assertEqual(outcome["sleeps"], [60.0])

    def test_allow_missing_only_converts_404_to_nil(self):
        outcome = self.invoke("repos/example/cmux/issues/7", [http(404, {"message": "missing"})], allow_missing=True)
        self.assertTrue(outcome["ok"], outcome)
        self.assertIsNone(outcome["result"])


if __name__ == "__main__":
    unittest.main()
