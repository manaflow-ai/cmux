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
CLA_ACTION = "manaflow-ai/cla-github-action@0502e16018c7c71dc7647e0d41d056a11903941a"
# The privileged workflow is an explicit reviewed policy, not an extensible
# script. Its exact bytes are compared with the trusted base revision, so a
# policy change requires trusted review without a fragile follow-up hash bump.
EXPECTED_RERUN_DIGEST = "f4f1fa51bb05b062ebf3f60cc949d8d5b4b501e7849cb065e9a07d7a34030840"
EXPECTED_GUARD_WORKFLOW_DIGEST = "0f347a749f53d2e06f5b39b7a832476d39ab40a71c8634b48c029bc728f5c1d1"
# EXPECTED_WORKFLOW_DIGEST is retained as a compatibility marker for the
# immutable validator in the current base revision. Policy validation now
# hashes the candidate workflow bytes after lexical YAML validation.
EXPECTED_GUARD_SCRIPT_DIGEST = "954eb2ab3a6814c4c722cfa3efc1b36d4dd93a4ca6bcc93e4eff9839d7e0e941"
# Current organization administrators who may approve a trusted control-plane
# update. IDs are used instead of names, and the review must target the exact
# PR head. This is the human path for intentional policy maintenance.
TRUSTED_REVIEWER_IDS = %w[54008264 38676809].freeze

# Keep the admission contract in one small, executable specification. The
# pull-request workflow is still checked as data below, but its shell cannot be
# run by this privileged workflow because it comes from an untrusted revision.
CLA_SIGN_PHRASE = "I have read the CLA Document v2.2 and I hereby sign the CLA"
CLA_RECHECK_PHRASE = "recheck"
CLA_DOCUMENT_INPUT = "https://github.com/${{ github.repository }}/blob/${{ github.workflow_sha }}/CLA.md"
CLA_LIFECYCLE_ACTIONS = %w[opened edited reopened synchronize].freeze
CLA_TRUSTED_ASSOCIATIONS = %w[OWNER MEMBER COLLABORATOR].freeze
POSITIVE_ID = /\A[1-9][0-9]*\z/
CLA_WRITER_CONDITION = <<~'EXPRESSION'.gsub(/\s+/, " ").strip.freeze
  needs.CLACommentGate.result == 'success' &&
  needs.CLACommentGate.outputs.admitted == 'true' &&
  (
    (
      github.event_name == 'pull_request_target' &&
      (
        github.event.action == 'opened' ||
        github.event.action == 'edited' ||
        github.event.action == 'reopened' ||
        github.event.action == 'synchronize'
      )
    ) ||
    (
      github.event_name == 'issue_comment' &&
      github.event.issue.state == 'open' &&
      github.event.issue.pull_request &&
      github.event.comment.user.type == 'User' &&
      (
        (
          github.event.comment.body == 'recheck' &&
          (
            github.event.comment.user.id == github.event.issue.user.id ||
            github.event.comment.author_association == 'OWNER' ||
            github.event.comment.author_association == 'MEMBER' ||
            github.event.comment.author_association == 'COLLABORATOR'
          )
        ) ||
        (
          github.event.comment.body == 'I have read the CLA Document v2.2 and I hereby sign the CLA' &&
          needs.CLACommentGate.outputs.signer_authorized == 'true' &&
          needs.CLACommentGate.outputs.head_sha != ''
        )
      )
    )
  )
EXPRESSION

# The guard validates a deliberately closed workflow vocabulary. A policy
# change may alter messages and implementation details inside the listed
# steps, but it may not add a job, permission, action, runner feature, or
# workflow-level control that this validator does not understand.
WORKFLOW_KEYS = %w[name on permissions env jobs].freeze
WORKFLOW_JOB_NAMES = %w[
  CLACommentGate
  CLAAssistant
  CLALedgerWriter
  CLACompatibility
  RerunFailedCLA
  LockMergedPullRequest
].freeze
ALLOWED_ACTIONS = [
  CLA_ACTION,
  "actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd"
].freeze

def fail!(message)
  raise PolicyError, message
end

def required_env(name, pattern = nil)
  value = ENV[name].to_s
  fail!("#{name} is missing") if value.empty?
  fail!("#{name} is malformed") if pattern && value !~ pattern
  value
end

def api_failure_status(stdout, stderr)
  [stderr, stdout].each do |text|
    if (match = text.to_s.match(/\bHTTP(?:\/\d(?:\.\d+)?)?\s+([1-5]\d{2})\b/i))
      return match[1].to_i
    end
  end
  begin
    payload = JSON.parse(stdout)
    value = payload.is_a?(Hash) ? payload["status"] : nil
    return value.to_i if value.to_s.match?(/\A[1-5]\d{2}\z/)
  rescue JSON::ParserError
    # The caller reports the original API failure below.
  end
  nil
end

def api_json(repository, endpoint, allow_missing: false)
  stdout, stderr, status = Open3.capture3(
    "gh", "api", "--header", "Accept: application/vnd.github+json", endpoint
  )
  unless status.success?
    response_status = api_failure_status(stdout, stderr)
    return nil if allow_missing && response_status == 404

    fail!("GitHub API request failed for #{endpoint}: #{stderr.strip}")
  end
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

def parse_workflow(raw)
  stream = Psych.parse_stream(raw)
  fail!("CLA workflow must contain exactly one YAML document") unless stream.children.length == 1
  root = stream.children.first.root
  fail!("CLA workflow is not a YAML mapping") unless root.is_a?(Psych::Nodes::Mapping)
  keys = root.children.each_slice(2).map do |key_node, _value_node|
    fail!("CLA workflow has a non-scalar top-level key") unless key_node.is_a?(Psych::Nodes::Scalar)

    key_node.value
  end
  fail!("CLA workflow has duplicate top-level keys") unless keys.uniq.length == keys.length
  # Psych applies YAML 1.1 boolean coercion to an unquoted `on` key. GitHub
  # uses the literal key, so accepting `true` here would validate a workflow
  # that GitHub does not trigger. Keep the lexical key check before loading.
  fail!("CLA workflow must contain the literal on trigger key") unless keys.include?("on")
  fail!("CLA workflow must not use a boolean trigger key") if keys.include?("true")

  document = YAML.safe_load(raw, aliases: false)
  fail!("CLA workflow is not a YAML mapping") unless document.is_a?(Hash)
  document
rescue Psych::Exception => error
  fail!("CLA workflow YAML is invalid: #{error.message.lines.first.to_s.strip}")
end

def workflow_digest(raw)
  # Hash the exact bytes after validating the YAML lexical structure. A parsed
  # digest can hide duplicate keys or YAML 1.1/GitHub parser differences.
  parse_workflow(raw)
  Digest::SHA256.hexdigest(raw)
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

def step_using_with(job_value, action, input, expected, name)
  found = steps(job_value, name).find do |step|
    step.is_a?(Hash) &&
      step["uses"] == action &&
      step["with"].is_a?(Hash) &&
      step["with"][input].to_s == expected
  end
  fail!("#{name} does not use #{action} with #{input}=#{expected}") unless found
  found
end

def dependencies(job_value, name)
  value = job_value["needs"]
  result = value.is_a?(Array) ? value : [value]
  fail!("#{name}.needs is malformed") unless result.all? { |item| item.is_a?(String) && !item.empty? }
  result
end

def assert_text(text, fragment)
  fail!("CLA workflow is missing #{fragment.inspect}") unless text.include?(fragment)
end

def assert_permission(job_value, name, permission, expected)
  permissions = job_value["permissions"]
  fail!("#{name}.permissions is not a mapping") unless permissions.is_a?(Hash)
  fail!("#{name}.permissions.#{permission} must be #{expected}") unless permissions[permission] == expected
end

def assert_exact_keys(value, expected, name)
  fail!("#{name} is not a mapping") unless value.is_a?(Hash)
  actual = value.keys.map(&:to_s)
  expected = expected.map(&:to_s)
  unknown = actual - expected
  missing = expected - actual
  fail!("#{name} has unsupported keys: #{unknown.join(', ')}") unless unknown.empty?
  fail!("#{name} is missing keys: #{missing.join(', ')}") unless missing.empty?
end

def assert_no_keys(value, forbidden, name)
  return unless value.is_a?(Hash)

  found = value.keys.map(&:to_s) & forbidden
  fail!("#{name} contains forbidden keys: #{found.join(', ')}") unless found.empty?
end

def assert_positive_integer(value, name)
  fail!("#{name} must be a positive integer") unless value.is_a?(Integer) && value.positive?
end

def assert_string(value, name)
  fail!("#{name} must be a string") unless value.is_a?(String)
  value
end

def assert_action_reference(reference, name)
  fail!("#{name} must be a pinned action reference") unless reference.is_a?(String)
  fail!("#{name} uses an unapproved action") unless ALLOWED_ACTIONS.include?(reference)
end

def assert_action_inputs(step, expected, name)
  inputs = step["with"]
  assert_exact_keys(inputs, expected.keys, "#{name}.with")
  expected.each do |key, value|
    fail!("#{name}.with.#{key} is unsafe") unless inputs[key].to_s == value.to_s
  end
end

def assert_safe_job_common(job_value, name)
  # These keys are the complete job-level surface used by the reviewed policy.
  # In particular, environment, containers, services, defaults, and
  # continue-on-error are intentionally absent. They can change where a
  # token-bearing step runs or whether a failed guard is ignored.
  assert_no_keys(
    job_value,
    %w[environment container services defaults strategy continue-on-error concurrency-group],
    name
  )
  assert_string(job_value["runs-on"], "#{name}.runs-on")
  assert_positive_integer(job_value["timeout-minutes"], "#{name}.timeout-minutes")
  fail!("#{name}.runs-on may not be PR-controlled") if job_value["runs-on"].include?("github.event")
end

def assert_step_keys(step, name, allowed)
  assert_exact_keys(step, allowed, name)
  fail!("#{name} must be a mapping") unless step.is_a?(Hash)
end

# Return the observable result of the exact admission contract. `:ordinary`
# means a valid human discussion comment that must not reach the signer. The
# `:malformed` result represents a fail-closed event or metadata shape error.
# This is deliberately independent of the candidate workflow text. The
# structural checks in `validate_workflow` bind the candidate to the same
# contract, while this matrix catches accidental drift in the trusted policy
# specification itself.
def cla_admission_outcome(event)
  return :malformed unless event.is_a?(Hash)

  event_name = event[:event_name]
  event_action = event[:action]
  if event_name == "pull_request_target"
    return :admitted if CLA_LIFECYCLE_ACTIONS.include?(event_action)

    return :malformed
  end
  return :malformed unless event_name == "issue_comment" && event_action == "created"

  required = %i[
    issue_state
    issue_pull_request
    comment_body
    comment_author_type
    comment_author_id
    comment_author_login
    pr_author_id
    comment_author_association
  ]
  return :malformed unless required.all? { |key| event.key?(key) }
  return :malformed unless event[:issue_state] == "open" && event[:issue_pull_request] == true

  author_type = event[:comment_author_type]
  author_id = event[:comment_author_id]
  author_login = event[:comment_author_login]
  pr_author_id = event[:pr_author_id]
  association = event[:comment_author_association]
  return :malformed unless author_type == "User" && author_login.is_a?(String) && !author_login.empty?
  return :malformed if author_login.downcase.end_with?("[bot]")
  return :malformed unless author_id.is_a?(String) && author_id.match?(POSITIVE_ID)
  return :malformed unless pr_author_id.is_a?(String) && pr_author_id.match?(POSITIVE_ID)
  return :malformed unless association.is_a?(String) && !association.empty? && !association.match?(/[\r\n]/)

  if event[:comment_body] == CLA_SIGN_PHRASE
    # The maintained action's signer-preflight is the single source of truth
    # for commit authorship and co-authorship. The base-controlled matrix only
    # admits an authenticated exact declaration to that read-only check; an
    # arbitrary commenter cannot reach the writer unless preflight authorizes
    # the same live identity.
    return :admitted
  end
  if event[:comment_body] == CLA_RECHECK_PHRASE
    return :admitted if author_id == pr_author_id || CLA_TRUSTED_ASSOCIATIONS.include?(association)

    return :ordinary
  end

  :ordinary
end

def run_trusted_cla_regression_matrix!
  base = {
    event_name: "issue_comment",
    action: "created",
    issue_state: "open",
    issue_pull_request: true,
    comment_body: CLA_RECHECK_PHRASE,
    comment_author_type: "User",
    comment_author_id: "300",
    comment_author_login: "contributor",
    pr_author_id: "300",
    comment_author_association: "NONE"
  }
  cases = []
  add = lambda do |name, changes, expected|
    cases << [name, base.merge(changes), expected]
  end

  add.call("author-recheck", {}, :admitted)
  add.call("exact-sign", { comment_body: CLA_SIGN_PHRASE }, :admitted)
  add.call("other-contributor-sign", {
    comment_body: CLA_SIGN_PHRASE,
    comment_author_id: "301",
    comment_author_login: "reviewer",
    comment_author_association: "MEMBER"
  }, :admitted)
  add.call("legacy-sign", { comment_body: "I have read the CLA Document and I hereby sign the CLA" }, :ordinary)
  add.call("uppercase-recheck", { comment_body: "RECHECK" }, :ordinary)
  add.call("padded-sign", { comment_body: " #{CLA_SIGN_PHRASE} " }, :ordinary)
  add.call("wrapped-sign", { comment_body: "Please sign: #{CLA_SIGN_PHRASE}" }, :ordinary)
  add.call("ordinary-comment", { comment_body: "Thanks for the review!" }, :ordinary)
  CLA_TRUSTED_ASSOCIATIONS.each do |association|
    add.call("#{association.downcase}-recheck", {
      comment_author_id: "301",
      comment_author_login: "maintainer",
      comment_author_association: association
    }, :admitted)
  end
  add.call("untrusted-recheck", { comment_author_id: "301" }, :ordinary)
  add.call("bot-type", { comment_author_type: "Bot" }, :malformed)
  add.call("bot-login", { comment_author_login: "github-actions[bot]" }, :malformed)
  add.call("missing-author-id", { comment_author_id: nil }, :malformed)
  add.call("malformed-association", { comment_author_association: "MEMBER\nOWNER" }, :malformed)
  add.call("closed-issue", { issue_state: "closed" }, :malformed)
  add.call("non-pull-request", { issue_pull_request: false }, :malformed)
  add.call("wrong-comment-action", { action: "edited" }, :malformed)
  CLA_LIFECYCLE_ACTIONS.each do |action|
    add.call("pull-request-#{action}", {
      event_name: "pull_request_target",
      action: action
    }, :admitted)
  end
  add.call("pull-request-closed", { event_name: "pull_request_target", action: "closed" }, :malformed)
  add.call("unsupported-event", { event_name: "push", action: "" }, :malformed)
  cases << ["nil-event", nil, :malformed]

  failures = []
  cases.each do |name, event, expected|
    actual = cla_admission_outcome(event)
    failures << "#{name}: expected #{expected}, got #{actual}" unless actual == expected
  end
  fail!("trusted CLA regression matrix failed: #{failures.join('; ')}") unless failures.empty?
  puts "PASS: trusted CLA regression matrix (#{cases.length} cases)"
end

def validate_workflow(raw, trusted_base_digest)
  document = parse_workflow(raw)
  candidate_digest = workflow_digest(raw)
  require_trusted_review!(ENV.fetch("GH_REPO"), ENV.fetch("PR_NUMBER"), ENV.fetch("HEAD_SHA")) unless candidate_digest == trusted_base_digest

  # Keep the policy surface closed. YAML keys that are harmless in an
  # ordinary workflow, such as `defaults`, `services`, or `concurrency` at the
  # top level, can silently change the trust boundary here. A maintainer must
  # update this validator in a separate control-plane PR before introducing a
  # new surface.
  top_level_keys = document.keys.map { |key| key == true ? "on" : key.to_s }
  fail!("CLA workflow has unsupported top-level keys") unless
    top_level_keys.uniq.sort == WORKFLOW_KEYS.sort
  fail!("CLA workflow name is not the reviewed context") unless document["name"] == "CLA Assistant v3"

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

  env = document["env"]
  assert_exact_keys(env, ["CLA_GENERATION"], "CLA workflow env")
  generation = env["CLA_GENERATION"]
  fail!("CLA_GENERATION is missing or malformed") unless
    generation.is_a?(String) && generation.match?(/\Av[0-9]+\.[0-9]+-action-[0-9a-f]{40}\z/)
  action_sha = CLA_ACTION.split("@", 2).last
  fail!("CLA_GENERATION is not bound to the maintained action") unless
    generation.match?(/\A v[0-9]+\.[0-9]+-action-#{Regexp.escape(action_sha)} \z/x)

  gate = job(document, "CLACommentGate")
  assistant = job(document, "CLAAssistant")
  writer = job(document, "CLALedgerWriter")
  compatibility = job(document, "CLACompatibility")
  rerun = job(document, "RerunFailedCLA")
  lock = job(document, "LockMergedPullRequest")
  jobs = document["jobs"]
  fail!("CLA workflow has unsupported jobs") unless jobs.keys.map(&:to_s).sort == WORKFLOW_JOB_NAMES.sort
  job_keys = {
    "CLACommentGate" => %w[name if runs-on timeout-minutes concurrency permissions outputs steps],
    "CLAAssistant" => %w[name needs if runs-on timeout-minutes permissions steps],
    "CLALedgerWriter" => %w[name needs if runs-on timeout-minutes concurrency permissions outputs steps],
    "CLACompatibility" => %w[name needs if runs-on timeout-minutes permissions steps],
    "RerunFailedCLA" => %w[name needs if runs-on timeout-minutes permissions steps],
    "LockMergedPullRequest" => %w[name if runs-on timeout-minutes concurrency permissions steps]
  }
  [gate, assistant, writer, compatibility, rerun, lock].each_with_index do |value, index|
    names = %w[CLACommentGate CLAAssistant CLALedgerWriter CLACompatibility RerunFailedCLA LockMergedPullRequest]
    fail!("#{names[index]} has no runner") unless value.key?("runs-on")
    assert_exact_keys(value, job_keys.fetch(names[index]), names[index])
    assert_safe_job_common(value, names[index])
    fail!("#{names[index]} must use the reviewed ephemeral runner") unless value["runs-on"] == "ubuntu-24.04"
  end

  fail!("CLACommentGate must use read-only permissions") unless
    gate["permissions"] == { "contents" => "read", "issues" => "read", "pull-requests" => "read" }
  fail!("CLACompatibility must have no permissions") unless compatibility["permissions"] == {}
  fail!("CLA Assistant result must have no permissions") unless assistant["permissions"] == {}
  fail!("CLACommentGate outputs are not the reviewed contract") unless
    gate["outputs"] == {
      "admitted" => "${{ steps.admission.outputs.admitted }}",
      "signer_authorized" => "${{ steps.signer_preflight.outputs.signer_authorized }}",
      "head_sha" => "${{ steps.signer_preflight.outputs.head_sha }}"
    }
  fail!("CLALedgerWriter outputs are not the reviewed contract") unless
    writer["outputs"] == {
      "signature_recorded" => "${{ steps.cla_action.outputs.signature_recorded }}"
    }
  fail!("CLA ledger writer must depend on the admission gate") unless dependencies(writer, "CLALedgerWriter").include?("CLACommentGate")
  fail!("CLA ledger writer must not run with always()") if writer["if"].to_s.include?("always()")
  writer_condition = writer["if"].to_s.gsub(/\s+/, " ").strip
  fail!("CLA ledger writer condition is not the reviewed admission contract") unless
    writer_condition == CLA_WRITER_CONDITION
  fail!("CLA Assistant result must depend on the ledger writer") unless dependencies(assistant, "CLAAssistant").include?("CLALedgerWriter")
  fail!("CLA Assistant result must always report the writer outcome") unless assistant["if"].to_s.include?("always()")
  fail!("CLA compatibility must depend on the v2 result") unless dependencies(compatibility, "CLACompatibility").include?("CLAAssistant")

  # A write-capable job is intentionally one pinned action invocation. An
  # extra `run` step would execute contributor-controlled policy text with the
  # ledger token in its environment. The no-permission result and compatibility
  # jobs may run shell diagnostics, but they cannot introduce actions or
  # service/container settings.
  writer_steps = steps(writer, "CLALedgerWriter")
  fail!("CLALedgerWriter must contain exactly one step") unless writer_steps.length == 1
  writer_step = writer_steps.first
  assert_step_keys(writer_step, "CLALedgerWriter step", %w[name id uses env with])
  fail!("CLALedgerWriter step must have id cla_action") unless writer_step["id"] == "cla_action"
  assert_action_reference(writer_step["uses"], "CLALedgerWriter step uses")
  fail!("CLALedgerWriter must invoke only the maintained CLA action") unless writer_step["uses"] == CLA_ACTION
  fail!("CLALedgerWriter action must receive the GitHub token explicitly") unless
    writer_step["env"] == { "GITHUB_TOKEN" => "${{ secrets.GITHUB_TOKEN }}" }

  gate_steps = steps(gate, "CLACommentGate")
  fail!("CLACommentGate must contain exactly two steps") unless gate_steps.length == 2
  admission_step_shape = gate_steps[0]
  assert_step_keys(admission_step_shape, "CLACommentGate admission step", %w[name id env run])
  fail!("CLACommentGate admission step must have id admission") unless admission_step_shape["id"] == "admission"
  fail!("CLACommentGate admission step must not access a token or network") if
    admission_step_shape["run"].to_s.match?(/\b(gh|curl|wget|git|ssh|sudo|eval|source)\b|secrets\.GITHUB_TOKEN|GITHUB_TOKEN/)
  preflight_step_shape = gate_steps[1]
  assert_step_keys(preflight_step_shape, "CLACommentGate preflight step", %w[name id if uses env with])
  assert_action_reference(preflight_step_shape["uses"], "CLACommentGate preflight uses")
  fail!("CLACommentGate preflight must invoke only the maintained CLA action") unless preflight_step_shape["uses"] == CLA_ACTION
  fail!("CLACommentGate preflight step must have id signer_preflight") unless preflight_step_shape["id"] == "signer_preflight"
  fail!("CLACommentGate preflight token binding is unsafe") unless
    preflight_step_shape["env"] == { "GITHUB_TOKEN" => "${{ secrets.GITHUB_TOKEN }}" }

  result_steps = steps(assistant, "CLAAssistant")
  fail!("CLAAssistant must contain exactly one result step") unless result_steps.length == 1
  assert_step_keys(result_steps.first, "CLAAssistant result step", %w[name env run])
  compatibility_steps = steps(compatibility, "CLACompatibility")
  fail!("CLACompatibility must contain exactly one result step") unless compatibility_steps.length == 1
  assert_step_keys(compatibility_steps.first, "CLACompatibility result step", %w[name env run])

  rerun_steps = steps(rerun, "RerunFailedCLA")
  fail!("RerunFailedCLA must contain exactly two steps") unless rerun_steps.length == 2
  assert_step_keys(rerun_steps[0], "RerunFailedCLA checkout step", %w[name uses with])
  assert_step_keys(rerun_steps[1], "RerunFailedCLA guard step", %w[name env run])
  assert_action_reference(rerun_steps[0]["uses"], "RerunFailedCLA checkout uses")
  fail!("RerunFailedCLA may not invoke the CLA action") if rerun_steps.any? { |step| step["uses"] == CLA_ACTION }
  fail!("RerunFailedCLA guard step must invoke the immutable helper exactly") unless
    rerun_steps[1]["run"] == "bash .github/scripts/rerun-failed-cla.sh"
  assert_exact_keys(
    rerun_steps[1]["env"],
    %w[GH_TOKEN GH_REPO EVENT_NAME ISSUE_NUMBER PR_NUMBER COMMENT_ID COMMENT_BODY COMMENT_CREATED_AT COMMENT_AUTHOR_ID COMMENT_AUTHOR_LOGIN COMMENT_AUTHOR_TYPE COMMENT_AUTHOR_ASSOCIATION WORKFLOW_PATH WORKFLOW_SHA CLA_GENERATION TARGET_EVENT TARGET_BASE_REF SIGNATURE_RECORDED],
    "RerunFailedCLA guard environment"
  )

  lock_steps = steps(lock, "LockMergedPullRequest")
  fail!("LockMergedPullRequest must contain exactly one step") unless lock_steps.length == 1
  assert_step_keys(lock_steps.first, "LockMergedPullRequest step", %w[name uses env with])
  assert_action_reference(lock_steps.first["uses"], "LockMergedPullRequest uses")
  fail!("LockMergedPullRequest must invoke only the maintained CLA action") unless lock_steps.first["uses"] == CLA_ACTION
  fail!("LockMergedPullRequest action must receive the GitHub token explicitly") unless
    lock_steps.first["env"] == { "GITHUB_TOKEN" => "${{ secrets.GITHUB_TOKEN }}" }
  assert_action_inputs(
    lock_steps.first,
    {
      "mode" => "sign",
      "path-to-signatures" => "signatures/version2/cla.json",
      "path-to-document" => CLA_DOCUMENT_INPUT,
      "branch" => "cla-signatures",
      "required-base-ref" => "main",
      "custom-pr-sign-comment" => CLA_SIGN_PHRASE,
      "allowlist-ids" => "38676809,67667005",
      "require-opener-as-author" => "true",
      "lock-pullrequest-aftermerge" => "true"
    },
    "LockMergedPullRequest action"
  )

  [assistant, compatibility, rerun, lock].each do |job_value|
    steps(job_value, job_value.equal?(assistant) ? "CLAAssistant" : job_value.equal?(compatibility) ? "CLACompatibility" : job_value.equal?(rerun) ? "RerunFailedCLA" : "LockMergedPullRequest").each do |step|
      fail!("policy jobs may not mix run and uses in one step") if step.is_a?(Hash) && step.key?("run") && step.key?("uses")
    end
  end

  admission_step = steps(gate, "CLACommentGate").find { |step| step.is_a?(Hash) && step["id"] == "admission" }
  admission_run = admission_step && admission_step["run"]
  fail!("CLACommentGate admission implementation is missing") unless admission_run.is_a?(String)
  sign_branch = admission_run[/if \[\[ "\$\{COMMENT_BODY\}" == "#{Regexp.escape(CLA_SIGN_PHRASE)}" \]\]; then(.*?)(?:\n\s*fi)/m]
  fail!("CLA signing admission implementation is missing") unless sign_branch&.include?("printf 'admitted=true\\n'")
  fail!("CLA signing admission must not duplicate commit identity mapping") if sign_branch.match?(/COMMENT_AUTHOR_ID|PR_AUTHOR_ID/)
  preflight = step_using_with(gate, CLA_ACTION, "mode", "signer-preflight", "CLACommentGate")
  preflight_with = preflight["with"]
  fail!("CLA signer preflight inputs are missing") unless preflight_with.is_a?(Hash)
  {
    "mode" => "signer-preflight",
    "path-to-signatures" => "signatures/version2/cla.json",
    "path-to-document" => CLA_DOCUMENT_INPUT,
    "required-base-ref" => "main",
    "custom-pr-sign-comment" => CLA_SIGN_PHRASE,
    "require-opener-as-author" => "true",
    "allowlist-ids" => "38676809,67667005",
    "branch" => "cla-signatures"
  }.then { |expected| assert_action_inputs(preflight, expected, "CLACommentGate preflight") }
  fail!("CLA signer preflight must be conditional on the exact signing phrase") unless preflight["if"].to_s.include?(CLA_SIGN_PHRASE)
  fail!("CLA gate must expose the signer preflight result") unless gate.dig("outputs", "signer_authorized").to_s.include?("signer_preflight")
  fail!("CLALedgerWriter permissions are not least-privilege") unless
    writer["permissions"] == { "contents" => "write", "issues" => "write", "pull-requests" => "write" }
  fail!("RerunFailedCLA permissions are not least-privilege") unless
    rerun["permissions"] == { "actions" => "write", "contents" => "read", "issues" => "read", "pull-requests" => "read" }
  fail!("LockMergedPullRequest permissions are not least-privilege") unless
    lock["permissions"] == { "issues" => "write", "pull-requests" => "read" }

  action_step = step_using(writer, CLA_ACTION, "CLALedgerWriter")
  with_values = action_step["with"]
  fail!("CLA action inputs are missing") unless with_values.is_a?(Hash)
  writer_inputs = {
    "path-to-document" => CLA_DOCUMENT_INPUT,
    "path-to-signatures" => "signatures/version2/cla.json",
    "branch" => "cla-signatures",
    "required-base-ref" => "main",
    "custom-pr-sign-comment" => CLA_SIGN_PHRASE,
    "allowlist-ids" => "38676809,67667005",
    "require-opener-as-author" => "true",
    "lock-pullrequest-aftermerge" => "false",
    "expected-head-sha" => "${{ needs.CLACommentGate.outputs.head_sha }}"
  }
  assert_action_inputs(action_step, writer_inputs, "CLALedgerWriter action")

  checkout = step_using(rerun, "actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd", "RerunFailedCLA")
  assert_action_inputs(
    checkout,
    {
      "repository" => "${{ github.repository }}",
      "ref" => "${{ github.workflow_sha }}",
      "persist-credentials" => false,
      "sparse-checkout" => ".github/scripts/rerun-failed-cla.sh",
      "sparse-checkout-cone-mode" => false
    },
    "RerunFailedCLA checkout"
  )
  rerun_runs = steps(rerun, "RerunFailedCLA").each_with_object([]) do |step, runs|
    runs << step["run"] if step.is_a?(Hash) && step["run"].is_a?(String)
  end
  fail!("rerun job does not invoke the trusted guard") unless rerun_runs.any? { |run| run.include?("bash .github/scripts/rerun-failed-cla.sh") }

  # These are the high-value admission and identity invariants. The local
  # fixture harnesses exercise their full event matrix; this base-controlled
  # check ensures a PR cannot remove the invariants from that harness's input.
  [
    "github.event.comment.body == '#{CLA_RECHECK_PHRASE}'",
    "github.event.comment.body == '#{CLA_SIGN_PHRASE}'",
    "github.event.comment.user.type == 'User'",
    "github.event.comment.user.id == github.event.issue.user.id",
    "github.event.action == 'created'",
    "id: admission",
    "admitted: ${{ steps.admission.outputs.admitted }}",
    "issues: write"
  ].each { |fragment| assert_text(raw, fragment) }
  # YAML block scalars normalize the expression at runtime, but the raw
  # source can contain `if: >-` or `if: |`; accept only those scalar markers
  # while still requiring the literal success() guard.
  fail!("CLA workflow is missing a successful-step guard") unless raw.match?(/if:\s*(?:[>|]-?\s*)?(?:\$\{\{\s*)?success\(\)/)
  [gate["if"], assistant["if"]].each do |expression|
    fail!("CLA signing trigger is missing from a signer job") unless expression.is_a?(String) && expression.include?(CLA_SIGN_PHRASE)
  end
  sign_author_guard = Regexp.new(
    "github\\.event\\.comment\\.body\\s*==\\s*'#{Regexp.escape(CLA_SIGN_PHRASE)}'\\s*&&\\s*" \
    "github\\.event\\.comment\\.user\\.id\\s*==\\s*github\\.event\\.issue\\.user\\.id"
  )
  fail!("CLA signing trigger must admit authenticated contributors") if [gate["if"], assistant["if"], rerun["if"]].any? { |expression| expression.to_s.match?(sign_author_guard) }
  fail!("CLA workflow may not checkout a pull-request ref") if raw.match?(/ref:\s*\$\{\{\s*github\.event\.pull_request/)

  uses = []
  walk(document) { |key, value| uses << value if key == "uses" && value.is_a?(String) }
  uses.each do |reference|
    assert_action_reference(reference, "CLA workflow action")
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
  document = parse_workflow(raw)
  digest = workflow_digest(raw)
  if digest != EXPECTED_GUARD_WORKFLOW_DIGEST
    require_trusted_review!(ENV.fetch("GH_REPO"), ENV.fetch("PR_NUMBER"), ENV.fetch("HEAD_SHA"))
  end
  triggers = document["on"] || document[true]
  fail!("guard workflow has no mapping of triggers") unless triggers.is_a?(Hash)
  target = triggers["pull_request_target"]
  fail!("guard workflow has unsafe triggers") unless
    !triggers.key?("pull_request") &&
    target.is_a?(Hash) &&
    target["branches"] == ["main"] &&
    target["types"] == %w[opened edited reopened synchronize]
  fail!("guard workflow must have empty top-level permissions") unless document["permissions"] == {}
  guard_top_level_keys = document.keys.map { |key| key == true ? "on" : key.to_s }
  fail!("guard workflow has unsupported top-level keys") unless
    guard_top_level_keys.uniq.sort == %w[name on permissions jobs].sort
  jobs = document["jobs"]
  fail!("guard workflow jobs are malformed") unless jobs.is_a?(Hash)
  fail!("guard workflow has an unexpected job") unless jobs.keys == ["validate"]
  guard_job = document.dig("jobs", "validate")
  fail!("guard workflow validate job is missing") unless guard_job.is_a?(Hash)
  assert_exact_keys(guard_job, %w[name runs-on timeout-minutes permissions steps], "guard workflow validate job")
  assert_string(guard_job["name"], "guard workflow validate job name")
  assert_positive_integer(guard_job["timeout-minutes"], "guard workflow validate timeout")
  fail!("guard workflow must use an ephemeral GitHub-hosted runner") unless guard_job["runs-on"] == "ubuntu-24.04"
  fail!("guard workflow must use read-only permissions") unless
    guard_job["permissions"] == { "contents" => "read", "pull-requests" => "read" }
  fail!("guard workflow must verify the immutable checkout") unless
    raw.include?("ref: ${{ github.workflow_sha }}") &&
    raw.include?("persist-credentials: false") &&
    raw.include?("scripts/ci/validate-cla-policy.rb")
  guard_steps = guard_job["steps"]
  fail!("guard workflow steps are malformed") unless guard_steps.is_a?(Array) && guard_steps.length == 3
  assert_step_keys(guard_steps[0], "guard checkout step", %w[name uses with])
  assert_step_keys(guard_steps[1], "guard checkout verification step", %w[name env run])
  assert_step_keys(guard_steps[2], "guard validation step", %w[name env run])
  fail!("guard workflow checkout step is not the immutable checkout") unless
    guard_steps[0]["uses"] == "actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd"
  fail!("guard workflow verification step may not access a token or network") if
    guard_steps[1]["run"].to_s.match?(/\b(gh|curl|wget|ssh|sudo|eval|source)\b|secrets\.GITHUB_TOKEN|GITHUB_TOKEN/)
  uses = []
  walk(document) { |key, value| uses << value if key == "uses" && value.is_a?(String) }
  uses.each do |reference|
    fail!("guard workflow may not use repository-local actions") if reference.start_with?("./")
    fail!("guard workflow uses an unapproved action") unless reference == "actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd"
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
    "def parse_workflow",
    "Psych.parse_stream",
    "def workflow_digest",
    "Digest::SHA256.hexdigest(raw)",
    "literal on trigger key",
    "base_workflow_digest",
    "validate_workflow(head_workflow, base_workflow_digest)",
    "def validate_workflow",
    "signer-preflight",
    "CLALedgerWriter",
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
  run_trusted_cla_regression_matrix!
  repository = required_env("GH_REPO", REPOSITORY)
  pr_number = required_env("PR_NUMBER", /\A[1-9][0-9]*\z/)
  base_sha = required_env("BASE_SHA", SHA)
  head_sha = required_env("HEAD_SHA", SHA)
  fail!("base and head revisions are identical") if base_sha == head_sha

  repository_metadata = api_json(repository, "repos/#{repository}")
  repository_id = repository_metadata.is_a?(Hash) ? repository_metadata["id"] : nil
  assert_positive_integer(repository_id, "base repository ID")
  live_pr = api_json(repository, "repos/#{repository}/pulls/#{pr_number}")
  fail!("pull request metadata is malformed") unless live_pr.is_a?(Hash)
  live_base = live_pr["base"]
  live_head = live_pr["head"]
  live_base_repo = live_base.is_a?(Hash) ? live_base["repo"] : nil
  live_head_repo = live_head.is_a?(Hash) ? live_head["repo"] : nil
  fail!("pull request metadata changed while validating") unless
    live_pr["number"].to_s == pr_number &&
    live_pr["state"] == "open" &&
    live_base.is_a?(Hash) &&
    live_base["ref"] == "main" &&
    live_base["sha"] == base_sha &&
    live_base_repo.is_a?(Hash) &&
    live_base_repo["full_name"].to_s.downcase == repository.downcase &&
    live_base_repo["id"] == repository_id &&
    live_head.is_a?(Hash) &&
    live_head["sha"] == head_sha &&
    live_head["ref"].is_a?(String) &&
    !live_head["ref"].empty? &&
    live_head_repo.is_a?(Hash) &&
    live_head_repo["full_name"].is_a?(String) &&
    !live_head_repo["full_name"].empty? &&
    live_head_repo["id"].is_a?(Integer) &&
    live_head_repo["id"].positive?

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
    base_workflow_digest = workflow_digest(base_workflow)
    validate_workflow(head_workflow, base_workflow_digest)
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
