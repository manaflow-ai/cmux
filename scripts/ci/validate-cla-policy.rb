#!/usr/bin/env ruby
# frozen_string_literal: true

# This file is executed only from the immutable base revision by
# cla-policy-guard.yml. It treats pull-request files as data: no file fetched
# from the PR is sourced, loaded as Ruby, or executed.

require "base64"
require "digest"
require "fileutils"
require "json"
require "open3"
require "tempfile"
require "yaml"

class PolicyError < StandardError; end

SHA = /\A[0-9a-f]{40}\z/
REPOSITORY = /\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/
MAX_FILE_BYTES = 300_000
CLA_ACTION = "manaflow-ai/cla-github-action@fc608ba7106e7029d981d487d7bad28a64325956"
# The privileged workflow is an explicit reviewed policy, not an extensible
# script. A digest of its parsed document prevents a PR from adding a command,
# secret reference, action input, or permission while retaining the fragments
# checked below. Policy changes require a separate, reviewed update to this
# base-controlled guard, followed by the workflow change.
EXPECTED_WORKFLOW_DIGEST = "d4db98df5a1b1e6f3b006a82639761a0513eeeaf153a9eb2b98d42d1af782145"
EXPECTED_RERUN_DIGEST = "f4f1fa51bb05b062ebf3f60cc949d8d5b4b501e7849cb065e9a07d7a34030840"
EXPECTED_GUARD_WORKFLOW_DIGEST = "796d55eb22d05bfe06e821c3e704e7d4404081dd35d6af7c49b2fb3618bcd194"
EXPECTED_GUARD_SCRIPT_DIGEST = "dd5465765c5e3b20db76ca7b939a40b50a2dcc02800015310f384429031cfab3"
# Current organization administrators who may approve a trusted control-plane
# update. IDs are used instead of names, and the review must target the exact
# PR head. This is the human path for intentional policy maintenance.
TRUSTED_REVIEWER_IDS = %w[54008264 38676809].freeze

def fail!(message)
  raise PolicyError, message
end

def required_env(name, pattern = nil)
  value = ENV[name].to_s
  fail!("#{name} is missing") if value.empty?
  fail!("#{name} is malformed") if pattern && value !~ pattern
  value
end

def api_json(repository, endpoint, allow_missing: false)
  stdout, stderr, status = Open3.capture3(
    "gh", "api", "--header", "Accept: application/vnd.github+json", endpoint
  )
  return nil if allow_missing && !status.success? && stderr.match?(/404|Not Found/i)
  fail!("GitHub API request failed for #{endpoint}: #{stderr.strip}") unless status.success?
  JSON.parse(stdout)
rescue JSON::ParserError
  fail!("GitHub API returned malformed JSON for #{endpoint}")
end

def require_trusted_review!(repository, pr_number, head_sha)
  latest = {}
  1.upto(3) do |page|
    reviews = api_json(repository, "repos/#{repository}/pulls/#{pr_number}/reviews?per_page=100&page=#{page}")
    fail!("pull-request review response is malformed") unless reviews.is_a?(Array)
    reviews.each do |review|
      user = review["user"]
      next unless user.is_a?(Hash) && TRUSTED_REVIEWER_IDS.include?(user["id"].to_s)
      next unless review["commit_id"] == head_sha
      reviewer_id = user["id"].to_s
      previous = latest[reviewer_id]
      if previous.nil? || review["submitted_at"].to_s > previous["submitted_at"].to_s
        latest[reviewer_id] = review
      end
    end
    break if reviews.length < 100
    fail!("pull-request review history is too large") if page == 3
  end
  approved = latest.values.any? { |review| review["state"] == "APPROVED" }
  fail!("trusted approval for this control-plane update is required") unless approved
end

def fetch_file(repository, sha, path, allow_missing: false)
  payload = api_json(repository, "repos/#{repository}/contents/#{path}?ref=#{sha}", allow_missing: allow_missing)
  return nil if payload.nil?
  fail!("#{path} is not a regular file") unless payload["type"] == "file"
  fail!("#{path} is not base64 encoded") unless payload["encoding"] == "base64"

  encoded = payload["content"].to_s.delete("\r\n")
  fail!("#{path} has malformed base64") unless encoded.match?(/\A(?:[A-Za-z0-9+\/]{4})*(?:[A-Za-z0-9+\/]{2}==|[A-Za-z0-9+\/]{3}=)?\z/)
  bytes = Base64.strict_decode64(encoded)
  fail!("#{path} is too large") if bytes.bytesize > MAX_FILE_BYTES
  bytes
rescue ArgumentError
  fail!("#{path} has malformed base64")
end

def walk(value, &block)
  case value
  when Hash
    value.each do |key, child|
      block.call(key, child)
      walk(child, &block)
    end
  when Array
    value.each { |child| walk(child, &block) }
  end
end

def canonical(value)
  case value
  when Hash
    value.keys.sort_by(&:to_s).each_with_object({}) do |key, result|
      result[key.to_s] = canonical(value[key])
    end
  when Array
    value.map { |child| canonical(child) }
  else
    value
  end
end

def guard_script_digest(raw)
  normalized = raw.sub(
    /EXPECTED_GUARD_SCRIPT_DIGEST = "[0-9a-f]{64}"/,
    'EXPECTED_GUARD_SCRIPT_DIGEST = "<self-digest>"'
  )
  Digest::SHA256.hexdigest(normalized)
end

def job(document, name)
  jobs = document["jobs"]
  fail!("jobs is not a mapping") unless jobs.is_a?(Hash)
  value = jobs[name]
  fail!("required job #{name} is missing") unless value.is_a?(Hash)
  value
end

def steps(job_value, name)
  value = job_value["steps"]
  fail!("#{name}.steps is not a list") unless value.is_a?(Array)
  value
end

def step_using(job_value, action, name)
  found = steps(job_value, name).find { |step| step.is_a?(Hash) && step["uses"] == action }
  fail!("#{name} does not use #{action}") unless found
  found
end

def assert_text(text, fragment)
  fail!("CLA workflow is missing #{fragment.inspect}") unless text.include?(fragment)
end

def assert_permission(job_value, name, permission, expected)
  permissions = job_value["permissions"]
  fail!("#{name}.permissions is not a mapping") unless permissions.is_a?(Hash)
  fail!("#{name}.permissions.#{permission} must be #{expected}") unless permissions[permission] == expected
end

def validate_workflow(raw)
  document = YAML.safe_load(raw, aliases: false)
  fail!("CLA workflow is not a YAML mapping") unless document.is_a?(Hash)
  digest = Digest::SHA256.hexdigest(JSON.generate(canonical(document)))
  require_trusted_review!(ENV.fetch("GH_REPO"), ENV.fetch("PR_NUMBER"), ENV.fetch("HEAD_SHA")) unless digest == EXPECTED_WORKFLOW_DIGEST

  triggers = document["on"] || document[true]
  fail!("CLA workflow has no mapping of triggers") unless triggers.is_a?(Hash)
  fail!("CLA workflow must not use pull_request") if triggers.key?("pull_request")
  fail!("issue_comment must trigger only on created") unless triggers["issue_comment"] == { "types" => ["created"] }
  target = triggers["pull_request_target"]
  fail!("pull_request_target is malformed") unless target.is_a?(Hash)
  fail!("pull_request_target must target main only") unless target["branches"] == ["main"]
  expected_types = %w[opened closed edited reopened synchronize]
  fail!("pull_request_target event set is unsafe") unless target["types"] == expected_types
  fail!("top-level permissions must be empty") unless document["permissions"] == {}

  generation = document.dig("env", "CLA_GENERATION")
  fail!("CLA_GENERATION is missing or malformed") unless generation.is_a?(String) && generation.match?(/\Av[0-9]+\.[0-9]+-action-[0-9a-f]{40}\z/)

  gate = job(document, "CLACommentGate")
  assistant = job(document, "CLAAssistant")
  compatibility = job(document, "CLACompatibility")
  rerun = job(document, "RerunFailedCLA")
  lock = job(document, "LockMergedPullRequest")
  [gate, assistant, compatibility, rerun, lock].each_with_index do |value, index|
    names = %w[CLACommentGate CLAAssistant CLACompatibility RerunFailedCLA LockMergedPullRequest]
    fail!("#{names[index]} has no runner") unless value.key?("runs-on")
  end

  fail!("CLACommentGate must have no permissions") unless gate["permissions"] == {}
  fail!("CLACompatibility must have no permissions") unless compatibility["permissions"] == {}
  assert_permission(assistant, "CLAAssistant", "contents", "write")
  assert_permission(assistant, "CLAAssistant", "issues", "write")
  assert_permission(assistant, "CLAAssistant", "pull-requests", "write")
  fail!("CLAAssistant must not have actions: write") if assistant.dig("permissions", "actions") == "write"
  assert_permission(rerun, "RerunFailedCLA", "actions", "write")
  assert_permission(rerun, "RerunFailedCLA", "contents", "read")
  assert_permission(rerun, "RerunFailedCLA", "issues", "read")
  assert_permission(rerun, "RerunFailedCLA", "pull-requests", "read")
  assert_permission(lock, "LockMergedPullRequest", "issues", "write")
  assert_permission(lock, "LockMergedPullRequest", "pull-requests", "read")

  action_step = step_using(assistant, CLA_ACTION, "CLAAssistant")
  with_values = action_step["with"]
  fail!("CLA action inputs are missing") unless with_values.is_a?(Hash)
  {
    "path-to-signatures" => "signatures/version2/cla.json",
    "branch" => "cla-signatures",
    "required-base-ref" => "main",
    "custom-pr-sign-comment" => "I have read the CLA Document v2.2 and I hereby sign the CLA",
    "allowlist-ids" => "38676809,67667005",
    "require-opener-as-author" => "true"
  }.each do |key, expected|
    fail!("CLA action input #{key} is unsafe") unless with_values[key].to_s == expected
  end

  checkout = step_using(rerun, "actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd", "RerunFailedCLA")
  checkout_with = checkout["with"]
  fail!("trusted rerun checkout inputs are missing") unless checkout_with.is_a?(Hash)
  {
    "repository" => "${{ github.repository }}",
    "ref" => "${{ github.workflow_sha }}",
    "persist-credentials" => false,
    "sparse-checkout" => ".github/scripts/rerun-failed-cla.sh",
    "sparse-checkout-cone-mode" => false
  }.each do |key, expected|
    fail!("trusted rerun checkout #{key} is unsafe") unless checkout_with[key].to_s == expected.to_s
  end
  rerun_runs = steps(rerun, "RerunFailedCLA").each_with_object([]) do |step, runs|
    runs << step["run"] if step.is_a?(Hash) && step["run"].is_a?(String)
  end
  fail!("rerun job does not invoke the trusted guard") unless rerun_runs.any? { |run| run.include?("bash .github/scripts/rerun-failed-cla.sh") }

  # These are the high-value admission and identity invariants. The local
  # fixture harnesses exercise their full event matrix; this base-controlled
  # check ensures a PR cannot remove the invariants from that harness's input.
  [
    "github.event.comment.body == 'recheck'",
    "github.event.comment.body == 'I have read the CLA Document v2.2 and I hereby sign the CLA'",
    "github.event.comment.user.type == 'User'",
    "github.event.comment.user.id == github.event.issue.user.id",
    "github.event.action == 'created'",
    "id: admission",
    "admitted: ${{ steps.admission.outputs.admitted }}",
    "if: success()",
    "issues: write"
  ].each { |fragment| assert_text(raw, fragment) }
  fail!("CLA workflow may not checkout a pull-request ref") if raw.match?(/ref:\s*\$\{\{\s*github\.event\.pull_request/)

  uses = []
  walk(document) { |key, value| uses << value if key == "uses" && value.is_a?(String) }
  uses.each do |reference|
    next if reference.start_with?("./")
    fail!("action reference is not pinned: #{reference}") unless reference.match?(/\A[^@]+@[0-9a-f]{40}\z/)
  end

  raw
rescue Psych::Exception => error
  fail!("CLA workflow YAML is invalid: #{error.message.lines.first.to_s.strip}")
end

def validate_script(raw)
  fail!("CLA rerun script is missing a shell shebang") unless raw.start_with?("#!/usr/bin/env bash")
  if Digest::SHA256.hexdigest(raw) != EXPECTED_RERUN_DIGEST
    require_trusted_review!(ENV.fetch("GH_REPO"), ENV.fetch("PR_NUMBER"), ENV.fetch("HEAD_SHA"))
  end
  Tempfile.create(["cla-rerun", ".sh"]) do |file|
    file.write(raw)
    file.close
    _stdout, stderr, status = Open3.capture3("bash", "-n", file.path)
    fail!("CLA rerun script has invalid shell syntax: #{stderr.strip}") unless status.success?
  end
end

def validate_guard_workflow(raw)
  document = YAML.safe_load(raw, aliases: false)
  fail!("guard workflow is not a YAML mapping") unless document.is_a?(Hash)
  digest = Digest::SHA256.hexdigest(JSON.generate(canonical(document)))
  if digest != EXPECTED_GUARD_WORKFLOW_DIGEST
    require_trusted_review!(ENV.fetch("GH_REPO"), ENV.fetch("PR_NUMBER"), ENV.fetch("HEAD_SHA"))
  end
  triggers = document["on"] || document[true]
  fail!("guard workflow has unsafe triggers") unless
    triggers.is_a?(Hash) &&
    !triggers.key?("pull_request") &&
    triggers["pull_request_target"].is_a?(Hash) &&
    triggers["pull_request_target"]["branches"] == ["main"]
  fail!("guard workflow must have empty top-level permissions") unless document["permissions"] == {}
  guard_job = document.dig("jobs", "validate")
  fail!("guard workflow validate job is missing") unless guard_job.is_a?(Hash)
  fail!("guard workflow must use read-only permissions") unless
    guard_job["permissions"] == { "contents" => "read", "pull-requests" => "read" }
  fail!("guard workflow must verify the immutable checkout") unless
    raw.include?("ref: ${{ github.workflow_sha }}") &&
    raw.include?("persist-credentials: false") &&
    raw.include?("scripts/ci/validate-cla-policy.rb")
  uses = []
  walk(document) { |key, value| uses << value if key == "uses" && value.is_a?(String) }
  uses.each do |reference|
    next if reference.start_with?("./")
    fail!("guard action reference is not pinned") unless reference.match?(/\A[^@]+@[0-9a-f]{40}\z/)
  end
rescue Psych::Exception
  fail!("guard workflow YAML is invalid")
end

def validate_guard_script(raw)
  fail!("guard script is missing a Ruby shebang") unless raw.start_with?("#!/usr/bin/env ruby")
  if guard_script_digest(raw) != EXPECTED_GUARD_SCRIPT_DIGEST
    require_trusted_review!(ENV.fetch("GH_REPO"), ENV.fetch("PR_NUMBER"), ENV.fetch("HEAD_SHA"))
  end
  [
    "EXPECTED_WORKFLOW_DIGEST",
    "def validate_workflow",
    "base_workflow != head_workflow",
    "guard_changed && policy_changed",
    "pull-request revision deletes the rerun helper",
    "CLA policy validation rejected the proposed policy"
  ].each do |fragment|
    fail!("guard script is missing a required safety check") unless raw.include?(fragment)
  end
  Tempfile.create(["cla-policy-guard", ".rb"]) do |file|
    file.write(raw)
    file.close
    _stdout, _stderr, status = Open3.capture3("ruby", "-c", file.path)
    fail!("guard script has invalid Ruby syntax") unless status.success?
  end
end

begin
  repository = required_env("GH_REPO", REPOSITORY)
  pr_number = required_env("PR_NUMBER", /\A[1-9][0-9]*\z/)
  base_sha = required_env("BASE_SHA", SHA)
  head_sha = required_env("HEAD_SHA", SHA)
  fail!("base and head revisions are identical") if base_sha == head_sha

  live_pr = api_json(repository, "repos/#{repository}/pulls/#{pr_number}")
  fail!("pull request metadata changed while validating") unless
    live_pr["number"].to_s == pr_number &&
    live_pr["state"] == "open" &&
    live_pr.dig("base", "ref") == "main" &&
    live_pr.dig("base", "repo", "full_name") == repository &&
    live_pr.dig("base", "sha") == base_sha &&
    live_pr.dig("head", "sha") == head_sha

  base_workflow = fetch_file(repository, base_sha, ".github/workflows/cla.yml")
  head_workflow = fetch_file(repository, head_sha, ".github/workflows/cla.yml")
  fail!("CLA workflow is missing from the pull-request revision") if head_workflow.nil?
  base_guard_workflow = fetch_file(repository, base_sha, ".github/workflows/cla-policy-guard.yml", allow_missing: true)
  head_guard_workflow = fetch_file(repository, head_sha, ".github/workflows/cla-policy-guard.yml", allow_missing: true)
  base_guard_script = fetch_file(repository, base_sha, "scripts/ci/validate-cla-policy.rb", allow_missing: true)
  head_guard_script = fetch_file(repository, head_sha, "scripts/ci/validate-cla-policy.rb", allow_missing: true)
  guard_changed = base_guard_workflow != head_guard_workflow || base_guard_script != head_guard_script

  base_script = fetch_file(repository, base_sha, ".github/scripts/rerun-failed-cla.sh", allow_missing: true)
  head_script = fetch_file(repository, head_sha, ".github/scripts/rerun-failed-cla.sh", allow_missing: true)
  policy_changed = base_workflow != head_workflow || base_script != head_script
  # A policy PR cannot also weaken the validator that reviews it. A guard-only
  # PR remains possible for normal maintenance, with CODEOWNERS providing the
  # human review gate for this trusted control plane.
  fail!("guard and CLA policy files must change in separate pull requests") if guard_changed && policy_changed

  if guard_changed
    fail!("guard workflow cannot be deleted") if head_guard_workflow.nil?
    fail!("guard validator cannot be deleted") if head_guard_script.nil?
    validate_guard_workflow(head_guard_workflow)
    validate_guard_script(head_guard_script)
  end

  if base_workflow == head_workflow && base_script == head_script
    puts "PASS: CLA policy files are unchanged"
    exit 0
  end

  if base_script && head_script.nil?
    fail!("the pull-request revision deletes the rerun helper used by the base workflow")
  end
  if base_workflow != head_workflow
    fail!("CLA rerun helper is missing from the changed workflow revision") if head_script.nil?
    validate_workflow(head_workflow)
  end
  validate_script(head_script) unless head_script.nil?

  candidate_dir = ENV["CANDIDATE_DIR"].to_s
  unless candidate_dir.empty?
    FileUtils.mkdir_p(candidate_dir)
    File.binwrite(File.join(candidate_dir, "cla.yml"), head_workflow) if head_workflow
    File.binwrite(File.join(candidate_dir, "rerun-failed-cla.sh"), head_script) if head_script
  end
  puts "PASS: base-controlled CLA policy validation for #{head_sha}"
rescue PolicyError
  # Candidate-controlled API, YAML, and shell diagnostics must not be copied
  # into a public check annotation. Keep the check deterministic and generic;
  # maintainers can reproduce the exact revision locally from the PR URL.
  warn "::error::CLA policy validation rejected the proposed policy"
  exit 1
rescue StandardError
  warn "::error::CLA policy validation could not complete"
  exit 1
end
