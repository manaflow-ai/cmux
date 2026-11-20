#!/usr/bin/env python3
"""The CLA policy guard reads each revision's files by git at that revision's own sha.

The base's guard and policy files come from the base sha, never from the pull
request's head, so a head that changes a policy file is still judged against
the base's file. The reads cost git round trips, not one contents API call per
file per revision; when git cannot read them, the guard falls back to the
contents API, and that fallback reads the base at the base sha too.
"""
import base64
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "scripts/ci/validate-cla-policy.rb"
CLA_WORKFLOW = ".github/workflows/cla.yml"
FIXTURE_PATHS = [
    ".github/workflows/cla-policy-guard.yml",
    "scripts/ci/validate-cla-policy.rb",
    CLA_WORKFLOW,
    "CLA.md",
]
REPOSITORY = "manaflow-ai/cmux"
REPOSITORY_ID = 1001
HEAD_REPOSITORY = "contributor/cmux"

# Loads the validator's definitions, then replaces its two outside readers:
# the API (recorded, answered from FIXTURE_API, a 404 for anything else) and
# the git remote (the local fixture repository). MODE "read" prints what
# read_revisions returns; MODE "main" runs the validator's main block.
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
if ENV.fetch("MODE") == "read"
  revisions = read_revisions(ENV.fetch("GH_REPO"), JSON.parse(ENV.fetch("REVISIONS")))
  puts JSON.generate(revisions.transform_values { |files| files.transform_values { |bytes| bytes&.force_encoding("UTF-8") } })
else
  eval(src[cut..], TOPLEVEL_BINDING, path)
end
"""


def git(cwd: Path, *args: str) -> str:
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}
    return subprocess.run(["git", *args], cwd=cwd, env=env, capture_output=True, text=True, check=True).stdout.strip()


@unittest.skipUnless(shutil.which("ruby") and shutil.which("git"), "ruby and git are required")
class CLAGuardGitReadsTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.repo = Path(self.directory.name) / "remote"
        self.repo.mkdir()
        git(self.repo, "init", "-q", "-b", "main")
        git(self.repo, "config", "uploadpack.allowFilter", "true")
        git(self.repo, "config", "uploadpack.allowAnySHA1InWant", "true")
        for relative in FIXTURE_PATHS:
            target = self.repo / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((ROOT / relative).read_bytes())
        (self.repo / "README.md").write_text("base\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "base")
        self.base = git(self.repo, "rev-parse", "HEAD")
        self.base_workflow = (self.repo / CLA_WORKFLOW).read_text()

    def commit_head(self, *, policy_change: bool) -> str:
        git(self.repo, "checkout", "-q", "-b", f"head-{policy_change}", self.base)
        if policy_change:
            with (self.repo / CLA_WORKFLOW).open("a") as workflow:
                workflow.write("# proposed by the pull request\n")
        else:
            (self.repo / "README.md").write_text("head\n")
        git(self.repo, "commit", "-q", "-am", "head")
        return git(self.repo, "rev-parse", "HEAD")

    def pull_request(self, head: str) -> dict:
        return {
            "number": 7, "state": "open", "mergeable": False, "user": {"id": 42},
            "base": {"ref": "main", "sha": self.base, "repo": {"full_name": REPOSITORY, "id": REPOSITORY_ID}},
            "head": {"ref": "feature", "sha": head, "repo": {"full_name": HEAD_REPOSITORY, "id": 2002}},
        }

    def run_driver(self, mode: str, head: str, api: dict, remote: str | None = None,
                   revisions: dict | None = None) -> tuple[subprocess.CompletedProcess, list[str]]:
        api_file = Path(self.directory.name) / "api.json"
        api_file.write_text(json.dumps(api))
        env = {
            **os.environ, "MODE": mode, "GH_REPO": REPOSITORY, "PR_NUMBER": "7", "BASE_SHA": self.base,
            "HEAD_SHA": head, "GITHUB_REPOSITORY_ID": str(REPOSITORY_ID), "FIXTURE_API_FILE": str(api_file),
            "FIXTURE_REMOTE": remote or self.repo.as_uri(), "REVISIONS": json.dumps(revisions or {}),
        }
        env.pop("CANDIDATE_DIR", None)
        result = subprocess.run(["ruby", "-e", RUBY_DRIVER, str(VALIDATOR)], env=env,
                                capture_output=True, text=True, check=False, timeout=600)
        marker = [line for line in result.stderr.splitlines() if line.startswith("API_CALLS=")]
        self.assertTrue(marker, result.stdout + result.stderr)
        return result, json.loads(marker[-1].removeprefix("API_CALLS="))

    def test_each_revision_is_read_at_its_own_sha_with_no_api_call(self):
        head = self.commit_head(policy_change=True)
        result, calls = self.run_driver(
            "read", head, {}, revisions={self.base: REPOSITORY, head: HEAD_REPOSITORY})
        self.assertEqual(result.returncode, 0, result.stderr)
        revisions = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertEqual(revisions[self.base][CLA_WORKFLOW], self.base_workflow)
        self.assertEqual(revisions[head][CLA_WORKFLOW], self.base_workflow + "# proposed by the pull request\n")
        self.assertEqual(revisions[self.base]["CLA.md"], (ROOT / "CLA.md").read_text())
        # A policy path the revision does not have reads as missing.
        self.assertIsNone(revisions[self.base][".github/scripts/rerun-failed-cla.sh"])
        self.assertEqual(calls, [])

    def test_a_head_that_changes_policy_is_judged_against_the_base(self):
        # The base carries an unreviewed edit of cla.yml; the head puts back
        # the reviewed file. Judged against the base's file, that is a policy
        # change: it needs a trusted approval, and none exists, so the guard
        # rejects it. Were the base's files read from the head, base and head
        # would both be the reviewed file and the guard would pass it as
        # "unchanged".
        git(self.repo, "checkout", "-q", "-b", "edited-base", self.base)
        with (self.repo / CLA_WORKFLOW).open("a") as workflow:
            workflow.write("# an edit on the base\n")
        git(self.repo, "commit", "-q", "-am", "edited base")
        self.base = git(self.repo, "rev-parse", "HEAD")
        (self.repo / CLA_WORKFLOW).write_text(self.base_workflow)
        git(self.repo, "commit", "-q", "-am", "head restores the reviewed policy")
        head = git(self.repo, "rev-parse", "HEAD")
        api = {f"repos/{REPOSITORY}/pulls/7": self.pull_request(head),
               f"repos/{REPOSITORY}/pulls/7/reviews?per_page=100&page=1": []}
        result, calls = self.run_driver("main", head, api)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertNotIn("PASS: CLA policy files are unchanged", result.stdout)
        self.assertIn("rejected the proposed policy", result.stderr)
        # Only the pull request's metadata (and the merge check, the review
        # list) came from the API; no file did.
        self.assertFalse([call for call in calls if "/contents/" in call], calls)

    def test_a_head_that_leaves_policy_alone_passes_on_one_api_call(self):
        head = self.commit_head(policy_change=False)
        api = {f"repos/{REPOSITORY}/pulls/7": self.pull_request(head)}
        result, calls = self.run_driver("main", head, api)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS: CLA policy files are unchanged", result.stdout)
        # Before: the repository, the pull request and 12 file reads (six
        # paths at the base and at the head). Now: the pull request alone.
        self.assertEqual(calls, [f"repos/{REPOSITORY}/pulls/7"])

    def test_when_git_cannot_read_the_api_fallback_reads_the_base_at_the_base_sha(self):
        head = self.commit_head(policy_change=True)
        api = {}
        for sha, repository in ((self.base, REPOSITORY), (head, HEAD_REPOSITORY)):
            for relative in FIXTURE_PATHS:
                content = subprocess.run(["git", "show", f"{sha}:{relative}"], cwd=self.repo,
                                         capture_output=True, check=True).stdout
                api[f"repos/{repository}/contents/{relative}?ref={sha}"] = {
                    "type": "file", "encoding": "base64", "content": base64.b64encode(content).decode()}
        result, calls = self.run_driver(
            "read", head, api, remote=(Path(self.directory.name) / "missing").as_uri(),
            revisions={self.base: REPOSITORY, head: HEAD_REPOSITORY})
        self.assertEqual(result.returncode, 0, result.stderr)
        revisions = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertEqual(revisions[self.base][CLA_WORKFLOW], self.base_workflow)
        self.assertNotEqual(revisions[head][CLA_WORKFLOW], self.base_workflow)
        self.assertTrue(calls)
        for call in calls:
            if call.startswith(f"repos/{REPOSITORY}/"):
                self.assertTrue(call.endswith(f"?ref={self.base}"), call)
            else:
                self.assertTrue(call.startswith(f"repos/{HEAD_REPOSITORY}/") and call.endswith(f"?ref={head}"), call)

    def commit_large_document(self, size: int) -> str:
        git(self.repo, "checkout", "-q", "-b", f"large-{size}", self.base)
        (self.repo / "CLA.md").write_bytes(os.urandom(size))
        git(self.repo, "commit", "-q", "-am", "large document")
        return git(self.repo, "rev-parse", "HEAD")

    def test_a_policy_blob_over_the_limit_fails_before_its_bytes_are_read(self):
        # Fetched within the per-object cap, then refused on its size alone.
        head = self.commit_large_document(310_000)
        result, calls = self.run_driver(
            "read", head, {}, revisions={self.base: REPOSITORY, head: HEAD_REPOSITORY})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAIL: a policy file is too large", result.stderr)
        self.assertEqual(calls, [])

    def test_a_blob_past_the_fetch_cap_is_never_downloaded_by_git(self):
        # The blob fetch stops at its pack cap (a policy file's limit per
        # wanted blob), so git reads
        # nothing and the guard falls back to the contents API, which reads
        # each revision at its own sha (and rejects a file that large).
        head = self.commit_large_document(3_000_000)
        result, calls = self.run_driver(
            "read", head, {}, revisions={self.base: REPOSITORY, head: HEAD_REPOSITORY})
        self.assertIn(f"repos/{HEAD_REPOSITORY}/contents/CLA.md?ref={head}", calls)
        self.assertIn(f"repos/{REPOSITORY}/contents/CLA.md?ref={self.base}", calls)

    def test_a_symlink_policy_file_fails_the_guard(self):
        git(self.repo, "checkout", "-q", "-b", "symlink", self.base)
        (self.repo / "CLA.md").unlink()
        (self.repo / "CLA.md").symlink_to("README.md")
        git(self.repo, "commit", "-q", "-am", "symlink")
        head = git(self.repo, "rev-parse", "HEAD")
        result, _calls = self.run_driver(
            "read", head, {}, revisions={self.base: REPOSITORY, head: HEAD_REPOSITORY})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAIL: CLA.md is not a regular file", result.stderr)


if __name__ == "__main__":
    unittest.main()
