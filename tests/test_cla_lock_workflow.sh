#!/usr/bin/env bash
# Verify the merged-PR lock job as a workflow artifact. The maintained action
# owns the API behavior and has its own tests; this check proves that the
# privileged cmux workflow invokes it only for a merged pull request with the
# narrow lock contract.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/cla.yml"
test -f "$WORKFLOW"
command -v ruby >/dev/null

WORKFLOW="$WORKFLOW" ruby <<'RUBY'
require "yaml"

workflow = YAML.safe_load(File.read(ENV.fetch("WORKFLOW")), aliases: false)
jobs = workflow.fetch("jobs")
lock = jobs.fetch("LockMergedPullRequest")

abort "lock job has unexpected permissions" unless lock.fetch("permissions") == {
  "issues" => "write",
  "pull-requests" => "read"
}
abort "lock job must run only for merged pull requests" unless lock.fetch("if").include?("github.event.action == 'closed'") && lock.fetch("if").include?("github.event.pull_request.merged == true")
abort "lock queue is not per pull request" unless lock.fetch("concurrency").fetch("group") == "cla-lock-${{ github.repository }}-${{ github.event.pull_request.number }}"
abort "lock queue must not cancel an earlier lock" unless lock.fetch("concurrency").fetch("cancel-in-progress") == false

steps = lock.fetch("steps")
abort "lock job must contain exactly one action step" unless steps.length == 1
step = steps.fetch(0)
abort "lock job may not execute workflow shell text" if step.key?("run")
uses = step.fetch("uses")
abort "lock action is not pinned" unless uses.match?(%r{\Amanaflow-ai/cla-github-action@[0-9a-f]{40}\z})
abort "lock action token is not the workflow token" unless step.fetch("env") == { "GITHUB_TOKEN" => "${{ secrets.GITHUB_TOKEN }}" }
expected = {
  "mode" => "sign",
  "path-to-signatures" => "signatures/version2/cla.json",
  "path-to-document" => "https://github.com/${{ github.repository }}/blob/${{ github.workflow_sha }}/CLA.md",
  "branch" => "cla-signatures",
  "required-base-ref" => "main",
  "custom-pr-sign-comment" => "I have read the CLA Document v2.2 and I hereby sign the CLA",
  "allowlist-ids" => "38676809,67667005",
  "require-opener-as-author" => "true",
  "lock-pullrequest-aftermerge" => "true"
}
abort "lock action inputs changed" unless step.fetch("with") == expected
puts "PASS: merged-PR lock workflow contract"
RUBY
