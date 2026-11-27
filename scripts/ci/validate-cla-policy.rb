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
require "time"
require "yaml"

class PolicyError < StandardError; end

SHA = /\A[0-9a-f]{40}\z/
REPOSITORY = /\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/
MAX_FILE_BYTES = 300_000
MAX_YAML_NODES = 10_000
MAX_YAML_DEPTH = 64
# A policy transition may start from one of the two reviewed legacy action
# revisions or from a reviewed workflow that main has carried. Those
# references are accepted only with their matching immutable workflow/helper
# bytes. A changed policy must move directly to the maintained final revision.
CLA_ACTION_LEGACY_REFS = %w[
  manaflow-ai/cla-github-action@fc608ba7106e7029d981d487d7bad28a64325956
  manaflow-ai/cla-github-action@b4d3c4fab86d21e7775c63522d4b39b3724ea4bf
].freeze
# Reviewed single-job cla.yml revisions that main has carried, oldest first,
# as [action reference, cla.yml SHA-256] pairs with no helper. A pull request
# records the main revision it was last synchronized against as its base, so
# a cla.yml bump on main appends a pin here and keeps the earlier ones: a
# branch behind main still names a reviewed base. Main carries the last
# pin, or the runner successor of it in CLA_ACTION_RUNNER_SUCCESSOR_PINS once
# that lands; both stay reviewed bases.
CLA_ACTION_REVIEWED_MAIN_PINS = [
  # #14668: f567 action on the GitHub-hosted runner.
  %w[
    manaflow-ai/cla-github-action@f567430d44e22bc0bb6ecd1e00d383ef22886025
    ce0112907844270c70c5e2cc235e20f8a45eb7a0ef42a88f054ceb6dc0198a64
  ].freeze,
  # #14913: 3bdedfb action, trusted merge status for pr-catch-up.yml merges.
  %w[
    manaflow-ai/cla-github-action@3bdedfb05157fd9c1c879dfea58455e32a770f96
    317432cd2145726daadec61cd3a6d84674197374ac92bf66ba09c8f6761853cc
  ].freeze
].freeze
# Reviewed runner-only successors of a main pin, as [action reference, from
# cla.yml SHA-256, to cla.yml SHA-256]. The single-job workflow is checked by
# its exact bytes, so moving it off the GitHub-hosted-only runner is pinned
# here before that policy pull request opens. The successor keeps the action
# and every step, and changes only CLAAssistant.runs-on to
# CLA_TRUSTED_RUNNER_EXPRESSION plus a leading CLA_EPHEMERAL_RUNNER_GUARD_*
# step. A policy pull request may move main from the pin to exactly these
# bytes, still with a trusted exact-head review; once landed they are a
# reviewed base like any main pin.
CLA_ACTION_RUNNER_SUCCESSOR_PINS = [
  %w[
    manaflow-ai/cla-github-action@3bdedfb05157fd9c1c879dfea58455e32a770f96
    317432cd2145726daadec61cd3a6d84674197374ac92bf66ba09c8f6761853cc
    6ef80bb2ccae3cc83aef8dc345ae7a5774ea2b81e4c941397ceaba244508e391
  ].freeze
].freeze
CLA_ACTION_CURRENT_BASE_REF = CLA_ACTION_REVIEWED_MAIN_PINS.last.fetch(0)
CLA_ACTION_FINAL = "manaflow-ai/cla-github-action@212a0f2dd659b24b48a30ba35966e06dc41736af".freeze
CLA_ACTION_BASE_REFS = (
  CLA_ACTION_LEGACY_REFS + CLA_ACTION_REVIEWED_MAIN_PINS.map(&:first) + [CLA_ACTION_FINAL]
).uniq.freeze
CLA_ACTION = CLA_ACTION_FINAL
# CLA policy jobs handle repository trust decisions and must stay on an
# ephemeral VM that runs one job and is destroyed: GitHub-hosted ubuntu-24.04
# or a Blacksmith Ubuntu 24.04 VM. A repository variable must never redirect
# this privileged work to a persistent self-hosted machine, so runs-on is an
# exact-string allowlist, never a pattern. CLA_TRUSTED_RUNNER_EXPRESSION is
# the CI_TRUSTED_RUNNER selector main already uses for trusted tokens
# (backend-migrations.yml): its variable can only choose among the listed
# ephemeral labels, any other value falls back to Blacksmith, and a fork
# running its own copy gets GitHub-hosted. Either provider can then carry the
# CLA checks while the other is down.
CLA_RUNNER = "ubuntu-24.04".freeze
CLA_BLACKSMITH_RUNNERS = %w[blacksmith-2vcpu-ubuntu-2404 blacksmith-4vcpu-ubuntu-2404].freeze
CLA_TRUSTED_RUNNER_EXPRESSION = "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || contains(fromJSON('[\"ubuntu-24.04\",\"blacksmith-2vcpu-ubuntu-2404\",\"blacksmith-4vcpu-ubuntu-2404\"]'), vars.CI_TRUSTED_RUNNER) && vars.CI_TRUSTED_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}".freeze
CLA_RUNNERS = ([CLA_RUNNER] + CLA_BLACKSMITH_RUNNERS + [CLA_TRUSTED_RUNNER_EXPRESSION]).freeze
# The original runner identity guard admits only GitHub-hosted runners. It
# stays valid so workflows main carries keep passing until they move to the
# ephemeral guard below.
CLA_HOSTED_RUNNER_GUARD_NAME = "Require GitHub-hosted runner".freeze
CLA_HOSTED_RUNNER_GUARD_IF = "runner.environment != 'github-hosted'".freeze
CLA_HOSTED_RUNNER_STEP_IF = "runner.environment == 'github-hosted'".freeze
CLA_HOSTED_RUNNER_GUARD_RUN = <<~'SH'.strip.freeze
  set -euo pipefail
  echo "::error::CLA policy requires a GitHub-hosted runner"
  exit 1
SH
# Blacksmith runners register as self-hosted (runner.environment is
# 'self-hosted'), so the ephemeral guard identifies them by runner.name. Each
# Blacksmith scale set names its single-job VMs '<scale set>-<id>', and the
# scale set name is exactly the runs-on label (runner group 'Blacksmith scale
# sets - blacksmith-4vcpu-ubuntu-2404'). Current VMs use a random id
# (blacksmith-4vcpu-ubuntu-2404-56ere4cqq7ryjqvc); until early October 2026
# the id was 'Runner-<10 hex>' (blacksmith-4vcpu-ubuntu-2404-Runner-337101a82d),
# which the same prefix still matches. The guard admits '<label>-' for the two
# allowlisted Blacksmith labels only (it also matches a sibling scale set such as
# blacksmith-4vcpu-ubuntu-2404-arm, which runs-on cannot select and which is
# still a one-job Blacksmith VM), and also refuses any name containing
# 'glaeda': owned machines are registered by glaeda as '<host>-glaeda[-N]'
# (cmuxs-mac-mini-5-glaeda-1), so a misrouted job is refused by two
# independent signals.
#
# runner.name is chosen when a runner registers, which needs organization
# admin rights, and is evaluated by the runner process itself. It therefore
# cannot stop a hostile administrator or a compromised runner; it catches a
# job that lands on an owned machine by mistake. The real control is the
# exact runs-on allowlist above, which routes only to GitHub-hosted runners
# or Blacksmith's read-only scale-set labels. If Blacksmith renames its VMs
# again so that a name no longer starts with its label, this guard fails
# closed, and CI_TRUSTED_RUNNER=ubuntu-24.04 restores the GitHub-hosted route.
CLA_EPHEMERAL_RUNNER_PREFIXES = CLA_BLACKSMITH_RUNNERS.map { |label| "#{label}-" }.freeze
CLA_OWNED_RUNNER_NAME_MARKER = "glaeda".freeze
CLA_EPHEMERAL_RUNNER_GUARD_NAME = "Require GitHub-hosted or Blacksmith runner".freeze
CLA_EPHEMERAL_RUNNER_GUARD_IF = (
  "(#{(
    ["runner.environment != 'github-hosted'"] +
    CLA_EPHEMERAL_RUNNER_PREFIXES.map { |prefix| "!startsWith(runner.name, '#{prefix}')" }
  ).join(' && ')}) || contains(runner.name, '#{CLA_OWNED_RUNNER_NAME_MARKER}')"
).freeze
CLA_EPHEMERAL_RUNNER_STEP_IF = (
  "((#{(
    ["runner.environment == 'github-hosted'"] +
    CLA_EPHEMERAL_RUNNER_PREFIXES.map { |prefix| "startsWith(runner.name, '#{prefix}')" }
  ).join(' || ')}) && !contains(runner.name, '#{CLA_OWNED_RUNNER_NAME_MARKER}'))"
).freeze
CLA_EPHEMERAL_RUNNER_GUARD_RUN = <<~'SH'.strip.freeze
  set -euo pipefail
  echo "::error::CLA policy requires a GitHub-hosted or Blacksmith runner"
  exit 1
SH
# Each accepted runner identity guard is one exact [name, if, run] triple.
CLA_RUNNER_GUARD_STEPS = [
  [CLA_HOSTED_RUNNER_GUARD_NAME, CLA_HOSTED_RUNNER_GUARD_IF, CLA_HOSTED_RUNNER_GUARD_RUN].freeze,
  [CLA_EPHEMERAL_RUNNER_GUARD_NAME, CLA_EPHEMERAL_RUNNER_GUARD_IF, CLA_EPHEMERAL_RUNNER_GUARD_RUN].freeze
].freeze
# A later privileged step must carry one of these as a top-level AND term.
CLA_RUNNER_STEP_IFS = [CLA_HOSTED_RUNNER_STEP_IF, CLA_EPHEMERAL_RUNNER_STEP_IF].freeze
CLA_DOCUMENT_PATH = "CLA.md".freeze
CLA_DOCUMENT_VERSION = "v2.2".freeze
CLA_SIGNATURES_PATH = "signatures/version2/cla.json".freeze
CLA_SIGNATURES_PATH_PATTERN = %r{\Asignatures/version[0-9]+(?:\.[0-9]+)?/cla\.json\z}
# The maintained action does not accept a document digest. The workflow URL
# therefore binds every action read to github.workflow_sha, while a document
# change must rotate the visible version, generation marker, and ledger path.
# The privileged workflow is an explicit reviewed policy, not an extensible
# script. Its candidate structure is checked as data, and every policy change
# requires trusted review without a fragile follow-up hash bump.
EXPECTED_GUARD_WORKFLOW_DIGEST = "9ffdce443e15c05f7771cd548686f913e2f3b78a59491da4d5004805c53f0a41"
# The guard workflow remains pinned to its reviewed immutable bytes. The CLA
# policy itself is validated structurally, then authorized by an exact-head
# trusted review.
EXPECTED_GUARD_SCRIPT_DIGEST = "288d7dd67993fe090d498014b2a52078f33e6b3db31103a437cee6145719ea52"
# Migration marker for the base v2 guard validator. That validator requires
# the literal EXPECTED_WORKFLOW_DIGEST while it checks this candidate. The v3
# validator does not use this inert marker for policy authorization.
# The first v3 migration is allowed only from these exact, base-controlled v2
# bytes. This is a one-step compatibility bridge for the live main branch,
# not a second policy vocabulary. The migration still needs trusted review,
# and the candidate must pass every v3 check below.
LEGACY_CLA_WORKFLOW_DIGEST = "22f4f8c4b7fb879514a5b072505877843fd94dc32b279f2aceb8fc216adde65f"
LEGACY_CLA_RERUN_DIGEST = "f4f1fa51bb05b062ebf3f60cc949d8d5b4b501e7849cb065e9a07d7a34030840"
LEGACY_CLA_HELPER_PATH = ".github/scripts/rerun-failed-cla.sh".freeze
# The b4d3 action used a different, reviewed helper and workflow shape. Keep
# the pair explicit so a digest from one revision cannot be paired with the
# other.
LEGACY_B4D3_CLA_WORKFLOW_DIGEST = "e03fa7a1d41eb5d59843807bf3a3bd153f5f7ab343f78e521d1d43cbecc43891"
LEGACY_B4D3_CLA_REFRESH_DIGEST = "580ea1130f9745be686e428e45aa39c93ad290ca48736330c429e3206d9211ec"
LEGACY_B4D3_CLA_HELPER_PATH = ".github/scripts/refresh-cla-check.sh".freeze
# The newest reviewed main pin above: the single-job workflow, which
# intentionally has no rerun helper. After the runner successor lands, main
# carries that successor's bytes instead; reviewed_cla_base? accepts both, and
# this digest stays the pin the successor is reviewed from.
CURRENT_MAIN_CLA_WORKFLOW_DIGEST = CLA_ACTION_REVIEWED_MAIN_PINS.last.fetch(1)
REVIEWED_CLA_BASES = {
  CLA_ACTION_LEGACY_REFS.fetch(0) => {
    workflow_digest: LEGACY_CLA_WORKFLOW_DIGEST,
    helper_digest: LEGACY_CLA_RERUN_DIGEST,
    helper_path: LEGACY_CLA_HELPER_PATH
  }.freeze,
  CLA_ACTION_LEGACY_REFS.fetch(1) => {
    workflow_digest: LEGACY_B4D3_CLA_WORKFLOW_DIGEST,
    helper_digest: LEGACY_B4D3_CLA_REFRESH_DIGEST,
    helper_path: LEGACY_B4D3_CLA_HELPER_PATH
  }.freeze
}.merge(
  CLA_ACTION_REVIEWED_MAIN_PINS.to_h do |reference, digest|
    [reference, { workflow_digest: digest, helper_digest: nil, helper_path: nil }.freeze]
  end
).freeze
CLA_WORKFLOW_PATH = ".github/workflows/cla.yml".freeze
# Every path that makes up the CLA policy. Both reviewed helper paths are
# listed, so the set does not depend on parsing any revision's workflow.
CLA_POLICY_PATHS = [
  CLA_WORKFLOW_PATH, CLA_DOCUMENT_PATH, LEGACY_CLA_HELPER_PATH, LEGACY_B4D3_CLA_HELPER_PATH
].freeze
GUARD_WORKFLOW_PATH = ".github/workflows/cla-policy-guard.yml".freeze
GUARD_SCRIPT_PATH = "scripts/ci/validate-cla-policy.rb".freeze
GUARD_PATHS = [GUARD_WORKFLOW_PATH, GUARD_SCRIPT_PATH].freeze
TEST_MERGE_ATTEMPTS = 6
TEST_MERGE_RETRY_SECONDS = 5
# Designated maintainers who may approve a trusted control-plane update. The
# PR author is deliberately excluded, even when they are an administrator, so
# the validator cannot turn self-approval into a policy-change bypass. IDs are
# used instead of names, and the review must target the exact PR head.
TRUSTED_REVIEWER_IDS = %w[38676809 67667005].freeze
TRUSTED_REVIEW_STATES = %w[APPROVED COMMENTED CHANGES_REQUESTED DISMISSED PENDING].freeze
TRUSTED_REVIEW_DECISION_STATES = %w[APPROVED CHANGES_REQUESTED DISMISSED].freeze
MAX_REVIEW_PAGES = 3
MAX_REVIEWS_PER_PAGE = 100
MAX_REVIEW_ID = (1 << 63) - 1
GITHUB_TOKEN_EXPRESSION = "${{ secrets.GITHUB_TOKEN }}"
ALLOWED_SECRET_PATHS = [
  %w[jobs CLACommentGate steps] + [2] + %w[env GITHUB_TOKEN],
  %w[jobs CLALedgerWriter steps] + [1] + %w[env GITHUB_TOKEN],
  %w[jobs RerunFailedCLA steps] + [2] + %w[env GH_TOKEN],
  %w[jobs LockMergedPullRequest steps] + [1] + %w[env GITHUB_TOKEN]
].freeze
GUARD_ALLOWED_SECRET_PATHS = [
  %w[jobs validate steps] + [2] + %w[env GH_TOKEN]
].freeze
GUARD_HOSTED_ALLOWED_SECRET_PATHS = [
  %w[jobs validate steps] + [3] + %w[env GH_TOKEN]
].freeze

ADMISSION_ENV = {
  "EVENT_NAME" => "${{ github.event_name }}",
  "EVENT_ACTION" => "${{ github.event.action }}",
  "COMMENT_BODY" => "${{ github.event.comment.body || '' }}",
  "COMMENT_AUTHOR_ID" => "${{ github.event.comment.user.id || '' }}",
  "COMMENT_AUTHOR_LOGIN" => "${{ github.event.comment.user.login || '' }}",
  "COMMENT_AUTHOR_TYPE" => "${{ github.event.comment.user.type || '' }}",
  "PR_AUTHOR_ID" => "${{ github.event.issue.user.id || '' }}",
  "COMMENT_AUTHOR_ASSOCIATION" => "${{ github.event.comment.author_association || '' }}"
}.freeze
RESULT_ENV = {
  "EVENT_NAME" => "${{ github.event_name }}",
  "COMMENT_BODY" => "${{ github.event.comment.body || '' }}",
  "GATE_RESULT" => "${{ needs.CLACommentGate.result }}",
  "ADMITTED" => "${{ needs.CLACommentGate.outputs.admitted || '' }}",
  "SIGNER_AUTHORIZED" => "${{ needs.CLACommentGate.outputs.signer_authorized || '' }}",
  "WRITER_RESULT" => "${{ needs.CLALedgerWriter.result }}",
  "CLA_PASSED" => "${{ needs.CLALedgerWriter.outputs.cla_passed || '' }}"
}.freeze
CLA_COMMENT_BINDING_OUTPUTS = {
  "comment_id" => "${{ steps.signer_preflight.outputs.comment_id }}",
  "comment_created_at" => "${{ steps.signer_preflight.outputs.comment_created_at }}",
  "comment_author_id" => "${{ steps.signer_preflight.outputs.comment_author_id }}"
}.freeze
CLA_COMMENT_BINDING_INPUTS = {
  "expected-comment-id" => "${{ needs.CLACommentGate.outputs.comment_id }}",
  "expected-comment-created-at" => "${{ needs.CLACommentGate.outputs.comment_created_at }}",
  "expected-comment-author-id" => "${{ needs.CLACommentGate.outputs.comment_author_id }}"
}.freeze
COMPATIBILITY_ENV = {
  "RESULT" => "${{ needs.CLAAssistant.result }}"
}.freeze
RERUN_ENV = {
  "GH_TOKEN" => GITHUB_TOKEN_EXPRESSION,
  "GH_REPO" => "${{ github.repository }}",
  "EVENT_NAME" => "${{ github.event_name }}",
  "ISSUE_NUMBER" => "${{ github.event.issue.number }}",
  "PR_NUMBER" => "${{ github.event.issue.number }}",
  "COMMENT_ID" => "${{ github.event.comment.id }}",
  "COMMENT_BODY" => "${{ github.event.comment.body }}",
  "COMMENT_CREATED_AT" => "${{ github.event.comment.created_at }}",
  "COMMENT_AUTHOR_ID" => "${{ github.event.comment.user.id }}",
  "COMMENT_AUTHOR_LOGIN" => "${{ github.event.comment.user.login }}",
  "COMMENT_AUTHOR_TYPE" => "${{ github.event.comment.user.type }}",
  "COMMENT_AUTHOR_ASSOCIATION" => "${{ github.event.comment.author_association }}",
  "WORKFLOW_PATH" => ".github/workflows/cla.yml",
  "WORKFLOW_SHA" => "${{ github.workflow_sha }}",
  "CLA_GENERATION" => "${{ env.CLA_GENERATION }}",
  "TARGET_EVENT" => "pull_request_target",
  "TARGET_BASE_REF" => "main",
  "SIGNATURE_RECORDED" => "${{ needs.CLALedgerWriter.outputs.signature_recorded || '' }}"
}.freeze
# Run blocks are shell text, not an expression surface. Reject every GitHub
# expression here, including bracket notation and nested format/toJSON calls
# that a token-specific regular expression cannot parse safely.
GITHUB_CONTEXT_IN_RUN = /\$\{\{/m
TOKEN_ENV_IN_RUN = /(?:\A|[^A-Za-z0-9_])(?:GITHUB_TOKEN|GH_TOKEN|ACTIONS_RUNTIME_TOKEN|ACTIONS_ID_TOKEN_REQUEST_TOKEN|RUNNER_TOKEN)(?:\z|[^A-Za-z0-9_])/i
EXPRESSION_MARKER = /\$\{\{/m
GITHUB_CONTEXT_EXPRESSION = /\bgithub\b/i
GITHUB_TOKEN_EXPRESSION_PATTERN = /\bgithub\b.*\btoken\b|\btoJSON\s*\(\s*github\b/i
ALLOWED_EXPRESSION_PATHS = [
  /\Aenv\.[^.]+\z/,
  /\Ajobs\.[^.]+\.if\z/,
  /\Ajobs\.[^.]+\.concurrency\.group\z/,
  /\Ajobs\.[^.]+\.outputs\.[^.]+\z/,
  /\Ajobs\.[^.]+\.steps\.\d+\.env\.[^.]+\z/,
  /\Ajobs\.[^.]+\.steps\.\d+\.with\.[^.]+\z/
].freeze

# The guard workflow is itself a privileged control-plane input. Keep its
# checkout, environment, and shell contracts as immutable data. Whitespace is
# normalized only at line boundaries so a YAML block scalar cannot gain an
# extra command, redirection, or interpolation while retaining the reviewed
# command sequence.
GUARD_CHECKOUT_WITH = {
  "repository" => "${{ github.repository }}",
  "ref" => "${{ github.workflow_sha }}",
  "fetch-depth" => 1,
  "persist-credentials" => false,
  "sparse-checkout" => "scripts/ci/validate-cla-policy.rb",
  "sparse-checkout-cone-mode" => false
}.freeze
GUARD_TRIGGER_KEYS = %w[pull_request_target].freeze
GUARD_TRIGGER = {
  "branches" => ["main"],
  "types" => %w[opened edited reopened synchronize]
}.freeze
GUARD_HOSTED_TRIGGER = {
  "branches" => ["main"],
  "types" => %w[opened edited reopened synchronize ready_for_review]
}.freeze
GUARD_WORKFLOW_NAME = "CLA policy guard"
GUARD_TIMEOUT_MINUTES = 10
# Metadata-only skips must never publish a successful skipped required check.
# Admit the condition and alternate name only as one exact reviewed contract.
GUARD_METADATA_ONLY = "github.event_name == 'pull_request_target' && github.event.action == 'edited' && !github.event.changes.base && (github.event.changes.body || github.event.changes.title)".freeze
GUARD_VALIDATE_IF = "${{ !(github.event_name == 'pull_request_target' && github.event.action == 'edited' && !github.event.changes.base && (github.event.changes.body || github.event.changes.title)) }}".freeze
GUARD_VALIDATE_NAME = "${{ github.event_name == 'pull_request_target' && github.event.action == 'edited' && !github.event.changes.base && (github.event.changes.body || github.event.changes.title) && 'CLA policy guard metadata (ignored)' || 'CLA policy guard' }}".freeze
GUARD_VERIFY_ENV = {
  "WORKFLOW_SHA" => "${{ github.workflow_sha }}"
}.freeze
GUARD_VALIDATE_ENV = {
  "GH_TOKEN" => GITHUB_TOKEN_EXPRESSION,
  "GH_REPO" => "${{ github.repository }}",
  "PR_NUMBER" => "${{ github.event.pull_request.number }}",
  "BASE_SHA" => "${{ github.event.pull_request.base.sha }}",
  "HEAD_SHA" => "${{ github.event.pull_request.head.sha }}"
}.freeze
GUARD_VERIFY_RUN = <<~'SH'.strip.freeze
  set -euo pipefail
  [[ "$WORKFLOW_SHA" =~ ^[0-9a-f]{40}$ ]]
  [[ "$(git rev-parse HEAD)" == "$WORKFLOW_SHA" ]]
  [[ -f scripts/ci/validate-cla-policy.rb ]]
SH
GUARD_VALIDATE_RUN = <<~'SH'.strip.freeze
  set -euo pipefail
  candidate_dir="$(mktemp -d "$RUNNER_TEMP/cla-policy.XXXXXX")"
  trap 'rm -rf "$candidate_dir"' EXIT
  CANDIDATE_DIR="$candidate_dir" ruby scripts/ci/validate-cla-policy.rb
  if [[ -f "$candidate_dir/rerun-failed-cla.sh" ]]; then
    shellcheck --shell=bash "$candidate_dir/rerun-failed-cla.sh"
  fi
  if [[ -f "$candidate_dir/cla.yml" ]]; then
    archive="$RUNNER_TEMP/actionlint.tar.gz"
    curl -fsSL -o "$archive" \
      "https://github.com/rhysd/actionlint/releases/download/v1.7.7/actionlint_1.7.7_linux_amd64.tar.gz"
    echo "023070a287cd8cccd71515fedc843f1985bf96c436b7effaecce67290e7e0757  $archive" | sha256sum --check --strict
    tar -xzf "$archive" -C "$RUNNER_TEMP" actionlint
    "$RUNNER_TEMP/actionlint" "$candidate_dir/cla.yml"
  fi
SH
# These hashes make the reviewed command contracts auditable without relying
# on YAML formatting. They are recomputed from normalize_run_text below when
# this policy file changes intentionally.
GUARD_VERIFY_RUN_HASH = "708659eb2df9c50e070dab49190c2c3712a1485a5292eadb86eb4ae3fb01cbb5"
GUARD_VALIDATE_RUN_HASH = "759f3978ae0a2e0620eb2630cd4c1ec2cbff8f9bcc9a37f76b330b845091bda8"

# Keep the admission contract in one small, executable specification. The
# pull-request workflow is still checked as data below, but its shell cannot be
# run by this privileged workflow because it comes from an untrusted revision.
CLA_SIGN_PHRASE = "I have read the CLA Document #{CLA_DOCUMENT_VERSION} and I hereby sign the CLA"
CLA_RECHECK_PHRASE = "recheck"
CLA_DOCUMENT_INPUT = "https://github.com/${{ github.repository }}/blob/${{ github.workflow_sha }}/#{CLA_DOCUMENT_PATH}"
CLA_LIFECYCLE_ACTIONS = %w[opened edited reopened synchronize ready_for_review].freeze
CLA_TRUSTED_ASSOCIATIONS = %w[OWNER MEMBER COLLABORATOR].freeze
POSITIVE_ID = /\A[1-9][0-9]*\z/
CLA_WRITER_CONDITION = <<~EXPRESSION.gsub(/\s+/, " ").strip.freeze
  needs.CLACommentGate.result == 'success' &&
  needs.CLACommentGate.outputs.admitted == 'true' &&
  (
    (
      github.event_name == 'pull_request_target' &&
      (
        github.event.action == 'opened' ||
        github.event.action == 'edited' ||
        github.event.action == 'reopened' ||
        github.event.action == 'synchronize' ||
        github.event.action == 'ready_for_review'
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
          github.event.comment.body == '#{CLA_SIGN_PHRASE}' &&
          needs.CLACommentGate.outputs.signer_authorized == 'true' &&
          needs.CLACommentGate.outputs.head_sha != '' &&
          needs.CLACommentGate.outputs.base_sha != ''
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

class BoundedYamlTreeBuilder < Psych::TreeBuilder
  def initialize
    super
    @node_count = 0
    @container_depth = 0
  end

  def start_mapping(*args)
    count_node!
    enter_container!
    super
  end

  def start_document(version, tag_directives, implicit)
    has_version = version.respond_to?(:empty?) ? !version.empty? : !version.nil?
    has_tags = tag_directives.respond_to?(:empty?) ? !tag_directives.empty? : !tag_directives.nil?
    fail!("CLA workflow YAML directives are not allowed") if has_version || has_tags
    super
  end

  def end_mapping(*args)
    @container_depth -= 1
    super
  end

  def start_sequence(*args)
    count_node!
    enter_container!
    super
  end

  def end_sequence(*args)
    @container_depth -= 1
    super
  end

  def scalar(*args)
    count_node!
    super
  end

  def alias(*_args)
    fail!("YAML aliases are not allowed")
  end

  private

  def count_node!
    @node_count += 1
    fail!("CLA workflow YAML has too many nodes") if @node_count > MAX_YAML_NODES
  end

  def enter_container!
    @container_depth += 1
    fail!("CLA workflow YAML is nested too deeply") if @container_depth > MAX_YAML_DEPTH
  end
end

YAML_KEY_SCANNER = Psych::ScalarScanner.new(Psych::ClassLoader::Restricted.new([], [])).freeze

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

def review_sort_key(review)
  timestamp = review["submitted_at"]
  fail!("trusted review timestamp is malformed") unless timestamp.is_a?(String)
  fail!("trusted review timestamp is malformed") unless timestamp.match?(
    /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\z/
  )
  review_id = review["id"]
  fail!("pull-request review ID is malformed") unless
    review_id.is_a?(Integer) && review_id.positive? && review_id <= MAX_REVIEW_ID
  [Time.iso8601(timestamp).to_r, review_id]
rescue ArgumentError
  fail!("trusted review timestamp is malformed")
end

def collect_latest_trusted_review!(latest, seen_review_ids, review)
  fail!("pull-request review entry is malformed") unless review.is_a?(Hash)
  review_id = review["id"]
  fail!("pull-request review ID is malformed") unless
    review_id.is_a?(Integer) && review_id.positive? && review_id <= MAX_REVIEW_ID
  fail!("pull-request review pagination repeated an entry") if seen_review_ids.key?(review_id)

  seen_review_ids[review_id] = true
  # Deleted users are represented by a null user object. They cannot match a
  # trusted reviewer ID, so ignore them before enforcing the strict shape used
  # for trusted control-plane approvals. Untrusted reviewers are likewise
  # irrelevant to this gate and must not be able to DoS a policy update with a
  # malformed historical review.
  user = review["user"]
  return unless user.is_a?(Hash)
  user_id = user["id"]
  return unless user_id.is_a?(Integer) && user_id.positive?
  reviewer_id = user_id.to_s
  return unless TRUSTED_REVIEWER_IDS.include?(reviewer_id)

  state = review["state"]
  fail!("pull-request review state is malformed") unless TRUSTED_REVIEW_STATES.include?(state)
  # COMMENTED and PENDING reviews do not change GitHub's approval decision.
  # In particular, a later comment must not erase a valid approval.
  return unless TRUSTED_REVIEW_DECISION_STATES.include?(state)
  fail!("pull-request review commit is malformed") unless review["commit_id"].is_a?(String) && review["commit_id"].match?(SHA)
  fail!("pull-request review user is not a human") unless user["type"] == "User"

  order = review_sort_key(review)
  previous = latest[reviewer_id]
  latest[reviewer_id] = [order, review] if previous.nil? || (order <=> previous[0]).positive?
end

def trusted_review_approves_head?(review, head_sha, pr_author_id)
  # The opener cannot provide the independent control-plane approval, even if
  # the opener is one of the designated maintainers.
  review["state"] == "APPROVED" &&
    review["commit_id"] == head_sha &&
    review.fetch("dismissed_at", nil).nil? &&
    review.dig("user", "id") != pr_author_id
end

def require_trusted_review!(repository, pr_number, head_sha, pr_author_id)
  fail!("pull-request head SHA is malformed") unless head_sha.is_a?(String) && head_sha.match?(SHA)
  fail!("pull-request author ID is malformed") unless
    pr_author_id.is_a?(Integer) && pr_author_id.positive? && pr_author_id <= MAX_REVIEW_ID
  latest = {}
  seen_review_ids = {}
  1.upto(MAX_REVIEW_PAGES) do |page|
    reviews = api_json(
      repository,
      "repos/#{repository}/pulls/#{pr_number}/reviews?per_page=#{MAX_REVIEWS_PER_PAGE}&page=#{page}"
    )
    fail!("pull-request review response is malformed") unless reviews.is_a?(Array)
    fail!("pull-request review page is too large") if reviews.length > MAX_REVIEWS_PER_PAGE

    reviews.each { |review| collect_latest_trusted_review!(latest, seen_review_ids, review) }

    break if reviews.length < MAX_REVIEWS_PER_PAGE
    fail!("pull-request review history is too large") if page == MAX_REVIEW_PAGES
  end
  approved = latest.values.any? do |_order, review|
    trusted_review_approves_head?(review, head_sha, pr_author_id)
  end
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

def reject_yaml_node_features!(node)
  fail!("CLA workflow YAML tags are not allowed") if node.respond_to?(:tag) && node.tag
  fail!("CLA workflow YAML anchors are not allowed") if node.respond_to?(:anchor) && node.anchor
end

def plain_yaml_key_is_string?(value)
  YAML_KEY_SCANNER.tokenize(value).is_a?(String)
rescue Psych::Exception
  false
end

def validate_yaml_tree!(stream)
  fail!("CLA workflow YAML stream is malformed") unless stream.is_a?(Psych::Nodes::Stream)
  fail!("CLA workflow must contain exactly one YAML document") unless stream.children.length == 1
  fail!("CLA workflow YAML document is malformed") unless stream.children.first.is_a?(Psych::Nodes::Document)
  stack = [[stream.children.first, 0]]
  until stack.empty?
    node, depth = stack.pop
    fail!("CLA workflow YAML is malformed") unless node.is_a?(Psych::Nodes::Node)
    reject_yaml_node_features!(node)
    fail!("CLA workflow YAML is nested too deeply") if depth > MAX_YAML_DEPTH

    case node
    when Psych::Nodes::Stream, Psych::Nodes::Document
      stack.concat(node.children.reverse_each.map { |child| [child, depth] })
    when Psych::Nodes::Mapping
      children = node.children
      fail!("CLA workflow YAML mapping has an odd number of entries") unless children.length.even?
      pairs = children.each_slice(2).to_a
      seen_keys = {}
      pairs.each do |key_node, _value_node|
        fail!("CLA workflow has a non-scalar mapping key") unless key_node.is_a?(Psych::Nodes::Scalar)
        reject_yaml_node_features!(key_node)
        if key_node.style == Psych::Nodes::Scalar::PLAIN &&
            !plain_yaml_key_is_string?(key_node.value) && !(depth.zero? && key_node.value == "on")
          fail!("CLA workflow YAML mapping keys must be strings")
        end
        fail!("CLA workflow YAML merge keys are not allowed") if key_node.value == "<<"
        fail!("CLA workflow YAML has duplicate mapping keys") if seen_keys.key?(key_node.value)

        seen_keys[key_node.value] = true
      end
      stack.concat(pairs.reverse_each.map { |_key_node, value_node| [value_node, depth + 1] })
    when Psych::Nodes::Sequence
      stack.concat(node.children.reverse_each.map { |child| [child, depth + 1] })
    when Psych::Nodes::Scalar
      # Scalar anchors and tags were checked above. Their lexical values are
      # intentionally left unchanged for the GitHub-specific `on` check.
    when Psych::Nodes::Alias
      fail!("CLA workflow YAML aliases are not allowed")
    else
      fail!("CLA workflow YAML contains an unsupported node")
    end
  end
end

def parse_workflow(raw)
  builder = BoundedYamlTreeBuilder.new
  Psych::Parser.new(builder).parse(raw)
  stream = builder.root
  validate_yaml_tree!(stream)
  root = stream.children.first.root
  fail!("CLA workflow is not a YAML mapping") unless root.is_a?(Psych::Nodes::Mapping)
  keys = root.children.each_slice(2).map do |key_node, _value_node|
    fail!("CLA workflow has a non-scalar top-level key") unless key_node.is_a?(Psych::Nodes::Scalar)

    key_node.value
  end
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

def expect_policy_error(name)
  raised = false
  begin
    yield
  rescue PolicyError
    raised = true
  end
  fail!("YAML regression case #{name} unexpectedly passed") unless raised
end

def run_yaml_regression_matrix!
  valid = <<~YAML
    name: test
    on: {}
    permissions: {}
    env: {}
    jobs: {}
  YAML
  parse_workflow(valid)
  cases = {
    "duplicate nested key" => <<~YAML,
      name: test
      on: {}
      permissions: {}
      env: {}
      jobs:
        duplicate: one
        duplicate: two
    YAML
    "merge key" => <<~YAML,
      name: test
      on: {}
      permissions: {}
      env: {}
      jobs:
        merged:
          <<: {}
    YAML
    "alias" => <<~YAML,
      name: test
      on: {}
      permissions: {}
      env: {}
      jobs:
        base: &anchor {}
        copied: *anchor
    YAML
    "explicit tag" => <<~YAML,
      name: !!str test
      on: {}
      permissions: {}
      env: {}
      jobs: {}
    YAML
    "multiple documents" => "---\nname: test\non: {}\n---\nname: second\non: {}\n",
    "boolean trigger key" => <<~YAML,
      name: test
      true: {}
      permissions: {}
      env: {}
      jobs: {}
    YAML
    "boolean key collision" => <<~YAML,
      name: test
      on: {}
      yes: {}
      permissions: {}
      env: {}
      jobs: {}
    YAML
    "numeric nested key" => <<~YAML
      name: test
      on: {}
      permissions: {}
      env: {}
      jobs:
        1: value
    YAML
  }
  deep = +"name: test\non: {}\npermissions: {}\nenv: {}\njobs:\n"
  MAX_YAML_DEPTH.times { |index| deep << "  " * (index + 1) << "k#{index}:\n" }
  deep << "  " * (MAX_YAML_DEPTH + 1) << "value\n"
  cases["excessive nesting"] = deep
  cases["YAML directive"] = "%YAML 1.1\n---\nname: test\non: {}\npermissions: {}\nenv: {}\njobs: {}\n"
  many = +"name: test\non: {}\npermissions: {}\nenv: {}\njobs:\n"
  (MAX_YAML_NODES / 2).times { |index| many << "  k#{index}: value\n" }
  cases["excessive nodes"] = many

  cases.each { |name, raw| expect_policy_error(name) { parse_workflow(raw) } }
  puts "PASS: bounded YAML regression matrix (#{cases.length + 1} cases)"
end

# A branch cut before a policy or guard bump on main still carries the older
# bytes, so its head differs from its base without proposing anything. What
# decides that is what landing the head does to main. GitHub's test merge
# commit for the pull request is the tree that the merge button produces for
# both merge commits and squash merges (rebase merging is off). When its
# first parent is a main revision at or after the validated base and its
# second parent is the exact head, a head whose files differ from the base
# changes main only if the test merge's files differ from that first parent.
# Without a clean, current test merge, every difference counts as a change.
def pull_request_changes_files?(base:, head:, landed_parent:, landed:)
  return false if head == base

  landed_parent.nil? || landed.nil? || landed != landed_parent
end

# The policy a pull request proposes: its own files when it changes them,
# otherwise main's files, which are what landing it leaves in place.
def effective_head_policy(base:, head:, landed_parent:, landed:)
  if pull_request_changes_files?(base: base, head: head, landed_parent: landed_parent, landed: landed)
    head
  else
    base
  end
end

def run_test_merge_regression_matrix!
  older = { CLA_WORKFLOW_PATH => "older main policy" }
  newer = { CLA_WORKFLOW_PATH => "newer main policy" }
  other = { CLA_WORKFLOW_PATH => "proposed policy" }
  gone = { CLA_WORKFLOW_PATH => nil }
  cases = [
    ["up to date, untouched", newer, newer, newer, newer, false],
    ["up to date, untouched, no test merge", newer, newer, nil, nil, false],
    ["behind main bump, untouched", newer, older, newer, newer, false],
    ["behind main bump, no test merge", newer, older, nil, nil, true],
    ["behind main bump, parent only", newer, older, newer, nil, true],
    # A head can equal one merge base in a criss-cross history while the
    # merge still lands its bytes. Only the landed tree decides.
    ["reverts main to its older policy", newer, older, newer, older, true],
    ["edits a stale branch", newer, other, newer, other, true],
    ["edits an up-to-date branch", newer, other, newer, other, true],
    ["deletes the policy", newer, gone, newer, gone, true]
  ]
  failures = cases.each_with_object([]) do |(name, base, head, landed_parent, landed, expected), errors|
    actual = pull_request_changes_files?(base: base, head: head, landed_parent: landed_parent, landed: landed)
    errors << "#{name}: expected #{expected}, got #{actual}" unless actual == expected
  end
  fail!("test merge regression matrix failed: #{failures.join('; ')}") unless failures.empty?

  # End to end through the action contract: each label stands for one cla.yml
  # revision, identified by its action reference and workflow digest.
  previous_ref, previous_digest = CLA_ACTION_REVIEWED_MAIN_PINS.fetch(-2)
  revisions = {
    previous: [previous_ref, previous_digest],
    current: [CLA_ACTION_CURRENT_BASE_REF, CURRENT_MAIN_CLA_WORKFLOW_DIGEST],
    final: [CLA_ACTION_FINAL, "0" * 64]
  }
  policy_cases = [
    # Recorded base still at the previous main revision; head never touched cla.yml.
    ["stale base, untouched head", :previous, :previous, :current, :current, true],
    # Main moved on; the branch still carries the previous main revision.
    ["new base, head behind main", :current, :previous, :current, :current, true],
    ["new base, head behind main, no test merge", :current, :previous, nil, nil, false],
    ["new base, up-to-date head", :current, :current, :current, :current, true],
    # The branch edits cla.yml back to the previous main revision. It is a
    # policy change, and a policy change may only move to the final revision.
    ["new base, head reverts to previous main", :current, :previous, :current, :previous, false],
    ["new base, head proposes final", :current, :final, :current, :final, true]
  ]
  snapshot = ->(label) { label && { CLA_WORKFLOW_PATH => label } }
  policy_failures = policy_cases.each_with_object([]) do |(name, base, head, landed_parent, landed, expected), errors|
    effective = effective_head_policy(
      base: snapshot.call(base),
      head: snapshot.call(head),
      landed_parent: snapshot.call(landed_parent),
      landed: snapshot.call(landed)
    )
    base_ref, base_digest = revisions.fetch(base)
    candidate_ref = revisions.fetch(effective.fetch(CLA_WORKFLOW_PATH)).fetch(0)
    actual = begin
      assert_cla_action_transition!(
        base_ref: base_ref,
        candidate_ref: candidate_ref,
        base_workflow_digest: base_digest,
        base_script_digest: nil,
        base_script_path: nil,
        policy_changed: effective != snapshot.call(base)
      )
      true
    rescue PolicyError
      false
    end
    errors << "#{name}: expected #{expected}, got #{actual}" unless actual == expected
  end
  fail!("test merge policy regression matrix failed: #{policy_failures.join('; ')}") unless policy_failures.empty?
  puts "PASS: test merge regression matrix (#{cases.length + policy_cases.length} cases)"
end

def fetch_snapshot(repository, sha, paths)
  paths.to_h { |path| [path, fetch_file(repository, sha, path, allow_missing: true)] }
end

# Returns [first parent, test merge] for the exact head, or nil when GitHub
# reports a conflict or has not produced a current test merge in time. All
# of it is GitHub-computed data in the protected repository.
def pull_request_test_merge(repository, pr_number, base_sha, head_sha)
  TEST_MERGE_ATTEMPTS.times do |attempt|
    sleep(TEST_MERGE_RETRY_SECONDS) if attempt.positive?
    pr = api_json(repository, "repos/#{repository}/pulls/#{pr_number}")
    fail!("pull request metadata is malformed") unless pr.is_a?(Hash)
    fail!("pull request metadata changed while validating") unless pr.dig("head", "sha") == head_sha
    return nil if pr["mergeable"] == false

    merge_sha = pr["merge_commit_sha"]
    next unless pr["mergeable"] == true && merge_sha.is_a?(String) && merge_sha.match?(SHA)

    commit = api_json(repository, "repos/#{repository}/git/commits/#{merge_sha}")
    parents = commit.is_a?(Hash) ? commit["parents"] : nil
    next unless parents.is_a?(Array) && parents.length == 2 && parents.all?(Hash)

    parent_shas = parents.map { |parent| parent["sha"] }
    next unless parent_shas[1] == head_sha && parent_shas[0].is_a?(String) && parent_shas[0].match?(SHA)

    comparison = api_json(repository, "repos/#{repository}/compare/#{base_sha}...#{parent_shas[0]}?per_page=1")
    next unless comparison.is_a?(Hash) && %w[ahead identical].include?(comparison["status"])

    return [parent_shas[0], merge_sha]
  end
  nil
end

def reviewed_cla_base?(base_ref:, base_workflow_digest:, base_script_digest:, base_script_path:)
  expected = REVIEWED_CLA_BASES[base_ref]
  return true if expected &&
    expected[:workflow_digest] == base_workflow_digest &&
    expected[:helper_digest] == base_script_digest &&
    expected[:helper_path] == base_script_path

  # A landed runner successor is a reviewed single-job base with no helper.
  base_script_digest.nil? && base_script_path.nil? &&
    CLA_ACTION_RUNNER_SUCCESSOR_PINS.any? do |reference, _from_digest, to_digest|
      reference == base_ref && to_digest == base_workflow_digest
    end
end

def cla_runner_successor?(base_ref:, candidate_ref:, base_workflow_digest:, candidate_workflow_digest:, base_script_digest:, base_script_path:)
  base_script_digest.nil? && base_script_path.nil? &&
    CLA_ACTION_RUNNER_SUCCESSOR_PINS.any? do |reference, from_digest, to_digest|
      base_ref == reference && candidate_ref == reference &&
        base_workflow_digest == from_digest && candidate_workflow_digest == to_digest
    end
end

def legacy_action_base?(base_ref:, base_workflow_digest:, base_script_digest:, base_script_path:)
  CLA_ACTION_LEGACY_REFS.include?(base_ref) && reviewed_cla_base?(
    base_ref: base_ref,
    base_workflow_digest: base_workflow_digest,
    base_script_digest: base_script_digest,
    base_script_path: base_script_path
  )
end

def legacy_v2_base?(base_workflow_digest:, base_script_digest:)
  legacy_action_base?(
    base_ref: CLA_ACTION_LEGACY_REFS.fetch(0),
    base_workflow_digest: base_workflow_digest,
    base_script_digest: base_script_digest,
    base_script_path: LEGACY_CLA_HELPER_PATH
  )
end

def cla_helper_path(action_ref)
  return REVIEWED_CLA_BASES[action_ref][:helper_path] if REVIEWED_CLA_BASES.key?(action_ref)
  return LEGACY_CLA_HELPER_PATH if action_ref == CLA_ACTION_FINAL

  nil
end

def cla_action_reference(raw, name)
  document = parse_workflow(raw)
  references = []
  walk(document) do |key, value|
    next unless key == "uses" && value.is_a?(String)
    next unless value.start_with?("manaflow-ai/cla-github-action@")

    references << value
  end
  references = references.uniq
  fail!("#{name} must invoke exactly one maintained CLA action revision") unless references.length == 1
  references.first
end

def assert_cla_action_transition!(base_ref:, candidate_ref:, base_workflow_digest:, base_script_digest:, base_script_path:, policy_changed:, candidate_workflow_digest: nil)
  fail!("base CLA action reference is not a reviewed immutable revision") unless
    CLA_ACTION_BASE_REFS.include?(base_ref)
  fail!("candidate CLA action reference is not a reviewed immutable revision") unless
    CLA_ACTION_BASE_REFS.include?(candidate_ref)

  if REVIEWED_CLA_BASES.key?(base_ref)
    fail!("base CLA action is not the exact reviewed workflow/helper pair") unless reviewed_cla_base?(
      base_ref: base_ref,
      base_workflow_digest: base_workflow_digest,
      base_script_digest: base_script_digest,
      base_script_path: base_script_path
    )
  end

  if policy_changed
    runner_successor = cla_runner_successor?(
      base_ref: base_ref,
      candidate_ref: candidate_ref,
      base_workflow_digest: base_workflow_digest,
      candidate_workflow_digest: candidate_workflow_digest,
      base_script_digest: base_script_digest,
      base_script_path: base_script_path
    )
    fail!("CLA action policy changes must migrate directly to the final revision") unless
      candidate_ref == CLA_ACTION_FINAL || runner_successor
  else
    fail!("CLA action changed without a policy change") unless candidate_ref == base_ref
  end
  true
end

def run_action_transition_regression_matrix!
  fc608 = CLA_ACTION_LEGACY_REFS.fetch(0)
  b4d3 = CLA_ACTION_LEGACY_REFS.fetch(1)
  current = CLA_ACTION_CURRENT_BASE_REF
  previous, previous_digest = CLA_ACTION_REVIEWED_MAIN_PINS.fetch(-2)
  successor_ref, successor_from, successor_to = CLA_ACTION_RUNNER_SUCCESSOR_PINS.fetch(0)
  final = CLA_ACTION_FINAL
  cases = [
    ["fc608 no-op", fc608, fc608, false, LEGACY_CLA_WORKFLOW_DIGEST, LEGACY_CLA_RERUN_DIGEST, LEGACY_CLA_HELPER_PATH, true],
    ["b4d3 no-op", b4d3, b4d3, false, LEGACY_B4D3_CLA_WORKFLOW_DIGEST, LEGACY_B4D3_CLA_REFRESH_DIGEST, LEGACY_B4D3_CLA_HELPER_PATH, true],
    ["current main no-op", current, current, false, CURRENT_MAIN_CLA_WORKFLOW_DIGEST, nil, nil, true],
    ["current main to final", current, final, true, CURRENT_MAIN_CLA_WORKFLOW_DIGEST, nil, nil, true],
    ["previous main no-op", previous, previous, false, previous_digest, nil, nil, true],
    ["previous main to final", previous, final, true, previous_digest, nil, nil, true],
    ["previous main ref with current bytes", previous, previous, false, CURRENT_MAIN_CLA_WORKFLOW_DIGEST, nil, nil, false],
    ["current main ref with previous bytes", current, current, false, previous_digest, nil, nil, false],
    ["current main reverted to previous main", current, previous, true, CURRENT_MAIN_CLA_WORKFLOW_DIGEST, nil, nil, false],
    ["fc608 to final", fc608, final, true, LEGACY_CLA_WORKFLOW_DIGEST, LEGACY_CLA_RERUN_DIGEST, LEGACY_CLA_HELPER_PATH, true],
    ["b4d3 to final", b4d3, final, true, LEGACY_B4D3_CLA_WORKFLOW_DIGEST, LEGACY_B4D3_CLA_REFRESH_DIGEST, LEGACY_B4D3_CLA_HELPER_PATH, true],
    ["final policy update", final, final, true, "0" * 64, "1" * 64, LEGACY_CLA_HELPER_PATH, true],
    ["final no-op", final, final, false, "0" * 64, "1" * 64, LEGACY_CLA_HELPER_PATH, true],
    ["unknown base", "manaflow-ai/cla-github-action@#{'a' * 40}", final, true, "0" * 64, nil, nil, false],
    ["unknown candidate", final, "manaflow-ai/cla-github-action@#{'b' * 40}", true, "0" * 64, nil, LEGACY_CLA_HELPER_PATH, false],
    ["current main wrong workflow", current, final, true, "0" * 64, nil, nil, false],
    ["current main has helper", current, final, true, CURRENT_MAIN_CLA_WORKFLOW_DIGEST, "1" * 64, LEGACY_CLA_HELPER_PATH, false],
    ["current main downgraded", current, fc608, true, CURRENT_MAIN_CLA_WORKFLOW_DIGEST, nil, nil, false],
    ["fc608 paired with b4d3 bytes", fc608, final, true, LEGACY_B4D3_CLA_WORKFLOW_DIGEST, LEGACY_B4D3_CLA_REFRESH_DIGEST, LEGACY_B4D3_CLA_HELPER_PATH, false],
    ["b4d3 paired with fc608 bytes", b4d3, final, true, LEGACY_CLA_WORKFLOW_DIGEST, LEGACY_CLA_RERUN_DIGEST, LEGACY_CLA_HELPER_PATH, false],
    ["legacy changed helper", fc608, fc608, false, LEGACY_CLA_WORKFLOW_DIGEST, "1" * 64, LEGACY_CLA_HELPER_PATH, false],
    ["legacy same ref policy change", fc608, fc608, true, LEGACY_CLA_WORKFLOW_DIGEST, LEGACY_CLA_RERUN_DIGEST, LEGACY_CLA_HELPER_PATH, false],
    ["current main to runner successor", successor_ref, successor_ref, true, successor_from, nil, nil, true, successor_to],
    ["runner successor no-op", successor_ref, successor_ref, false, successor_to, nil, nil, true],
    ["runner successor to final", successor_ref, final, true, successor_to, nil, nil, true],
    ["runner successor reverted", successor_ref, successor_ref, true, successor_to, nil, nil, false, successor_from],
    ["unpinned runner-only edit", successor_ref, successor_ref, true, successor_from, nil, nil, false, "0" * 64],
    ["runner successor without candidate bytes", successor_ref, successor_ref, true, successor_from, nil, nil, false],
    ["runner successor from unreviewed bytes", successor_ref, successor_ref, true, "0" * 64, nil, nil, false, successor_to],
    ["runner successor with helper", successor_ref, successor_ref, true, successor_from, "1" * 64, LEGACY_CLA_HELPER_PATH, false, successor_to],
    ["runner successor bytes under previous action", previous, previous, false, successor_to, nil, nil, false]
  ]

  failures = cases.each_with_object([]) do |(name, base_ref, candidate_ref, policy_changed, workflow_digest, script_digest, helper_path, expected, candidate_digest), errors|
    actual = begin
      assert_cla_action_transition!(
        base_ref: base_ref,
        candidate_ref: candidate_ref,
        base_workflow_digest: workflow_digest,
        base_script_digest: script_digest,
        base_script_path: helper_path,
        policy_changed: policy_changed,
        candidate_workflow_digest: candidate_digest
      )
      true
    rescue PolicyError
      false
    end
    errors << "#{name}: expected #{expected}, got #{actual}" unless actual == expected
  end
  fail!("CLA action transition regression matrix failed: #{failures.join('; ')}") unless failures.empty?

  fixtures = [fc608, b4d3, current, final].map do |reference|
    <<~YAML
      name: fixture
      on: {}
      permissions: {}
      env: {}
      jobs:
        cla:
          steps:
            - uses: #{reference}
    YAML
  end
  fixture_refs = fixtures.map { |raw| cla_action_reference(raw, "CLA action fixture") }
  fail!("CLA action reference fixture regression failed") unless fixture_refs == [fc608, b4d3, current, final]
  puts "PASS: CLA action transition regression matrix (#{cases.length} cases, #{fixtures.length} fixtures)"
end

def guard_script_digest(raw)
  normalized = raw.sub(
    /EXPECTED_GUARD_SCRIPT_DIGEST = "[0-9a-f]{64}"/,
    'EXPECTED_GUARD_SCRIPT_DIGEST = "<self-digest>"'
  )
  Digest::SHA256.hexdigest(normalized)
end

def cla_document_version(raw, name)
  first_line = raw.to_s.lines.first.to_s.strip
  match = first_line.match(/\A# Individual Contributor License Agreement \("Agreement"\) (v[0-9]+\.[0-9]+)\z/)
  fail!("#{name} must declare a version in its heading") unless match

  match[1]
end

def workflow_document_contract(raw, name)
  document = parse_workflow(raw)
  contract = {
    generation: document.dig("env", "CLA_GENERATION"),
    signature_paths: [],
    sign_phrases: [],
    document_inputs: []
  }
  walk_paths(document) do |path, value|
    next unless value.is_a?(String)

    case path.last.to_s
    when "path-to-signatures"
      contract[:signature_paths] << value
    when "custom-pr-sign-comment"
      contract[:sign_phrases] << value
    when "path-to-document"
      contract[:document_inputs] << value
    end
  end
  contract[:signature_paths] = contract[:signature_paths].uniq.sort
  contract[:sign_phrases] = contract[:sign_phrases].uniq.sort
  contract[:document_inputs] = contract[:document_inputs].uniq.sort
  fail!("#{name} is missing its signature ledger path") if contract[:signature_paths].empty?
  fail!("#{name} is missing its signing phrase") if contract[:sign_phrases].empty?
  fail!("#{name} is missing its document URL") if contract[:document_inputs].empty?
  contract
end

def document_major(version)
  match = version.to_s.match(/\Av([0-9]+)/)
  fail!("CLA document version is malformed") unless match

  match[1]
end

def expected_signature_path(version)
  "signatures/version#{document_major(version)}/cla.json"
end

def assert_script_document_binding(raw, phrase, signature_path, name)
  source = raw.to_s
  quoted_phrase = ["\"#{phrase}\"", "'#{phrase}'"]
  fail!("#{name} does not contain the reviewed signing phrase") unless
    quoted_phrase.any? { |value| source.include?(value) }
  fail!("#{name} does not bind the reviewed signature ledger path") unless
    source.match?(/SIGNATURES_PATH\s*=\s*['\"]#{Regexp.escape(signature_path)}['\"]/)
end

def assert_cla_document_change_contract(base_cla:, head_cla:, base_workflow:, head_workflow:, base_script:, head_script:)
  # A workflow SHA URL is the action's immutable document binding. Keep the
  # ledger namespace and human-readable version in lockstep so old signatures
  # cannot authorize a changed legal document.
  base_digest = Digest::SHA256.hexdigest(base_cla)
  head_digest = Digest::SHA256.hexdigest(head_cla)
  return false if base_digest == head_digest

  fail!("CLA.md changes require a CLA policy workflow change") if base_workflow == head_workflow
  base_version = cla_document_version(base_cla, "base CLA.md")
  head_version = cla_document_version(head_cla, "proposed CLA.md")
  base_major = document_major(base_version)
  head_major = document_major(head_version)
  base_contract = workflow_document_contract(base_workflow, "base CLA workflow")
  head_contract = workflow_document_contract(head_workflow, "proposed CLA workflow")
  fail!("CLA.md changes must rotate the rerun helper") unless
    base_script.is_a?(String) && head_script.is_a?(String) && base_script != head_script

  fail!("CLA.md changes must rotate the document version") if base_version == head_version
  fail!("CLA document major version must increase") unless head_major.to_i > base_major.to_i
  fail!("CLA.md changes must rotate CLA_GENERATION") if base_contract[:generation] == head_contract[:generation]
  fail!("base CLA workflow uses an unexpected signature ledger path") unless
    base_contract[:signature_paths] == [expected_signature_path(base_version)]
  fail!("CLA.md changes must rotate the signature ledger path") unless
    head_contract[:signature_paths] == [expected_signature_path(head_version)]

  expected_phrase = "I have read the CLA Document #{head_version} and I hereby sign the CLA"
  fail!("proposed CLA workflow uses the wrong document version phrase") unless
    head_contract[:sign_phrases] == [expected_phrase]
  fail!("proposed CLA workflow must bind the document URL to github.workflow_sha") unless
    head_contract[:document_inputs] == [CLA_DOCUMENT_INPUT]
  fail!("proposed CLA generation is not bound to the document version") unless
    head_contract[:generation].to_s.start_with?("#{head_version}-action-")

  base_phrase = "I have read the CLA Document #{base_version} and I hereby sign the CLA"
  assert_script_document_binding(base_script, base_phrase, expected_signature_path(base_version), "base CLA rerun helper")
  assert_script_document_binding(head_script, expected_phrase, expected_signature_path(head_version), "proposed CLA rerun helper")
  fail!("proposed CLA rerun helper still accepts the old document phrase") if
    head_script.include?(base_phrase)
  fail!("proposed CLA rerun helper still reads the old signature ledger") if
    head_script.include?(expected_signature_path(base_version)) &&
    expected_signature_path(base_version) != expected_signature_path(head_version)

  true
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

def assert_cla_runner(value, name)
  # Exact strings only: no pattern, prefix, or parsed expression can admit a
  # different variable, label, or event-derived value.
  fail!("#{name} must use the reviewed CLA runner") unless
    value.is_a?(String) && CLA_RUNNERS.include?(value)
end

def assert_hosted_runner_guard_step(step, name)
  assert_step_keys(step, "#{name} runner guard", %w[name if run])
  # Name, condition, and shell must all come from the same reviewed guard.
  guard = CLA_RUNNER_GUARD_STEPS.find { |guard_name, _if, _run| step["name"] == guard_name }
  fail!("#{name} runner guard has an unexpected name") unless guard
  fail!("#{name} runner guard has an unsafe condition") unless step["if"] == guard[1]
  fail!("#{name} runner guard has an unsafe shell") unless
    normalize_run_text(step["run"]) == normalize_run_text(guard[2])
end

# Splits an expression on the && operators outside parentheses, index
# brackets, and string literals. Brackets nest like parentheses: in
# `fromJSON('[true]')[false && runner.environment == 'github-hosted']` the
# runner term only builds an index and never gates the step. Returns nil when
# the text is unbalanced or mismatched, so a caller fails closed.
def top_level_and_terms(condition)
  terms = []
  open_groups = []
  quoted = false
  start = 0
  index = 0
  while index < condition.length
    char = condition[index]
    if quoted
      if char == "'"
        if condition[index + 1] == "'"
          index += 2
          next
        end
        quoted = false
      end
    elsif char == "'"
      quoted = true
    elsif char == "(" || char == "["
      open_groups << char
    elsif char == ")" || char == "]"
      return nil unless open_groups.pop == (char == ")" ? "(" : "[")
    elsif open_groups.empty? && condition[index, 2] == "&&"
      terms << condition[start...index].strip
      index += 2
      start = index
      next
    end
    index += 1
  end
  return nil if quoted || !open_groups.empty?

  terms << condition[start..].strip
  terms
end

def assert_hosted_runner_step(step, name, runs_on: CLA_RUNNER)
  condition = step.is_a?(Hash) ? step["if"].to_s.gsub(/\s+/, " ").strip : ""
  # The runner identity must be a top-level AND term. A substring check would
  # accept `runner.environment == 'github-hosted' || true`, and a naive split
  # would accept `!(x && runner.environment == 'github-hosted')`; either would
  # execute a privileged action on a self-hosted runner. The ephemeral term
  # carries its own || inside one parenthesized group; no other term may.
  # A job that can land on Blacksmith must gate its steps on the ephemeral
  # term: the hosted-only term would silently skip them there and let the
  # check go green without doing its work.
  accepted = runs_on == CLA_RUNNER ? CLA_RUNNER_STEP_IFS : [CLA_EPHEMERAL_RUNNER_STEP_IF]
  terms = top_level_and_terms(condition)
  fail!("#{name} is not restricted to a GitHub-hosted or Blacksmith runner") unless
    terms &&
    terms.any? { |term| accepted.include?(term) } &&
    terms.none? { |term| term != CLA_EPHEMERAL_RUNNER_STEP_IF && term.include?("||") }
end

def assert_hosted_runner_job_steps(job_value, name)
  job_steps = steps(job_value, name)
  fail!("#{name} must have a runner identity guard") if job_steps.empty?
  assert_hosted_runner_guard_step(job_steps.first, name)
  job_steps.drop(1).each_with_index do |step, index|
    assert_hosted_runner_step(step, "#{name} step #{index + 2}", runs_on: job_value["runs-on"])
  end
end

def guard_step_layout(target, step_count)
  case target
  when GUARD_TRIGGER
    fail!("guard workflow steps are malformed") unless step_count == 3
    {
      verification_index: 1,
      validation_index: 2,
      hosted: false,
      allowed_secret_paths: GUARD_ALLOWED_SECRET_PATHS
    }
  when GUARD_HOSTED_TRIGGER
    fail!("hosted guard workflow steps are malformed") unless step_count == 4
    {
      verification_index: 2,
      validation_index: 3,
      hosted: true,
      allowed_secret_paths: GUARD_HOSTED_ALLOWED_SECRET_PATHS
    }
  else
    fail!("guard workflow has an unsupported trigger or step layout")
  end
end

def assert_comment_binding_contract(gate_outputs, writer_inputs)
  CLA_COMMENT_BINDING_OUTPUTS.each do |name, expected|
    fail!("CLA gate must expose the signer comment #{name} output") unless
      gate_outputs.is_a?(Hash) && gate_outputs[name] == expected
  end
  CLA_COMMENT_BINDING_INPUTS.each do |name, expected|
    fail!("CLA writer must bind the signer comment #{name} input") unless
      writer_inputs.is_a?(Hash) && writer_inputs[name] == expected
  end
end

def assert_lifecycle_admission_contract(expressions, admission_run)
  CLA_LIFECYCLE_ACTIONS.each do |action|
    fragment = "github.event.action == '#{action}'"
    expressions.each_with_index do |expression, index|
      fail!("CLA lifecycle job #{index + 1} is missing #{action}") unless
        expression.is_a?(String) && expression.include?(fragment)
    end
  end

  normalized_run = admission_run.to_s.gsub(/\s+/, " ").strip
  expected_emit = "emit() { [[ -n \"${GITHUB_OUTPUT+x}\" && -n \"${GITHUB_OUTPUT}\" ]] || fail \"GITHUB_OUTPUT is unavailable\" printf 'admitted=%s\\n' \"$1\" >>\"${GITHUB_OUTPUT}\" }"
  fail!("CLA admission shell must define the reviewed output helper") unless
    normalized_run.include?(expected_emit)
  expected_case = "case \"${EVENT_ACTION}\" in #{CLA_LIFECYCLE_ACTIONS.join("|")}) emit true ;;"
  fail!("CLA admission shell is missing the complete pull-request lifecycle case") unless
    normalized_run.include?(expected_case)
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

def assert_exact_typed_inputs(step, expected, name)
  inputs = step["with"]
  assert_exact_keys(inputs, expected.keys, "#{name}.with")
  expected.each do |key, value|
    fail!("#{name}.with.#{key} has the wrong YAML type or value") unless inputs[key].eql?(value)
  end
end

def assert_exact_environment(step, expected, name)
  environment = step["env"]
  assert_exact_keys(environment, expected.keys, "#{name}.env")
  expected.each do |key, value|
    fail!("#{name}.env.#{key} is unsafe") unless environment[key] == value
  end
end

def walk_paths(value, path = [], &block)
  block.call(path, value)
  case value
  when Hash
    value.each { |key, child| walk_paths(child, path + [key.to_s], &block) }
  when Array
    value.each_with_index { |child, index| walk_paths(child, path + [index], &block) }
  end
end

def assert_exact_secret_paths(document, allowed_paths: ALLOWED_SECRET_PATHS)
  expected = {}
  allowed_paths.each { |path| expected[path] = GITHUB_TOKEN_EXPRESSION }
  actual = {}
  walk_paths(document) do |path, value|
    next unless value.is_a?(String) && value.match?(
      /\bsecrets\b|\bgithub\b.*\btoken\b|\btoJSON\s*\(\s*github\b/i
    )

    actual[path] = value
  end
  fail!("workflow token references are not the reviewed contract") unless actual == expected
end

def assert_safe_expression_fields(document, name, allowed_secret_paths: ALLOWED_SECRET_PATHS, reviewed_guard_name: false)
  walk_paths(document) do |path, value|
    next unless value.is_a?(String) && value.match?(EXPRESSION_MARKER)

    joined_path = path.map(&:to_s).join(".")
    fail!("#{name} has an expression in an unreviewed field") unless
      ALLOWED_EXPRESSION_PATHS.any? { |pattern| joined_path.match?(pattern) } ||
      (reviewed_guard_name && joined_path == "jobs.validate.name" && value == GUARD_VALIDATE_NAME) ||
      (path.length == 3 && path[0] == "jobs" && path[2] == "runs-on" && value == CLA_TRUSTED_RUNNER_EXPRESSION)
    if value.match?(GITHUB_CONTEXT_EXPRESSION) && value.match?(GITHUB_TOKEN_EXPRESSION_PATTERN)
      fail!("#{name} may not reference the GitHub token or serialized context")
    end
    if value.match?(/\bsecrets\b/i)
      fail!("#{name} has an unapproved secret expression") unless
        allowed_secret_paths.include?(path) && value == GITHUB_TOKEN_EXPRESSION
    end
  end
end

def assert_safe_run_text(run, name)
  fail!("#{name} must be a shell string") unless run.is_a?(String)
  fail!("#{name} may not interpolate GitHub expressions") if run.match?(GITHUB_CONTEXT_IN_RUN)
  fail!("#{name} may not access a token environment variable") if run.match?(TOKEN_ENV_IN_RUN)
  fail!("#{name} may not contain trailing whitespace") if run.lines.any? { |line| line.chomp.end_with?(" ", "\t") }
end

def normalize_run_text(run)
  normalized = run.to_s.gsub("\r\n", "\n").gsub("\r", "\n")
  normalized.end_with?("\n") ? normalized[0...-1] : normalized
end

def assert_exact_normalized_run(run, expected, expected_digest, name)
  assert_safe_run_text(run, name)
  normalized = normalize_run_text(run)
  fail!("#{name} is not the reviewed shell contract") unless
    normalized == normalize_run_text(expected) && Digest::SHA256.hexdigest(normalized) == expected_digest
end

def run_guard_contract_regression_matrix!
  checks = 0
  expect_failure = lambda do |name, &block|
    failed = false
    begin
      block.call
    rescue PolicyError
      failed = true
    end
    fail!("#{name} guard contract regression failed") unless failed
    checks += 1
  end

  checkout = { "with" => GUARD_CHECKOUT_WITH.dup }
  assert_exact_typed_inputs(checkout, GUARD_CHECKOUT_WITH, "regression guard checkout")
  checks += 1
  expect_failure.call("changed checkout ref") do
    changed = Marshal.load(Marshal.dump(checkout))
    changed["with"]["ref"] = "${{ github.event.pull_request.head.sha }}"
    assert_exact_typed_inputs(changed, GUARD_CHECKOUT_WITH, "regression guard checkout")
  end
  expect_failure.call("changed checkout input type") do
    changed = Marshal.load(Marshal.dump(checkout))
    changed["with"]["fetch-depth"] = "1"
    assert_exact_typed_inputs(changed, GUARD_CHECKOUT_WITH, "regression guard checkout")
  end

  runner_guard = {
    "name" => CLA_HOSTED_RUNNER_GUARD_NAME,
    "if" => CLA_HOSTED_RUNNER_GUARD_IF,
    "run" => CLA_HOSTED_RUNNER_GUARD_RUN
  }
  assert_hosted_runner_guard_step(runner_guard, "regression guard")
  checks += 1
  expect_failure.call("guard runner can be self-hosted") do
    assert_hosted_runner_guard_step(
      runner_guard.merge("if" => "runner.environment == 'github-hosted'"),
      "regression guard"
    )
  end

  current_layout = guard_step_layout(GUARD_TRIGGER, 3)
  fail!("current guard layout regression failed") unless
    current_layout == {
      verification_index: 1,
      validation_index: 2,
      hosted: false,
      allowed_secret_paths: GUARD_ALLOWED_SECRET_PATHS
    }
  checks += 1
  hosted_layout = guard_step_layout(GUARD_HOSTED_TRIGGER, 4)
  fail!("future hosted guard layout regression failed") unless
    hosted_layout == {
      verification_index: 2,
      validation_index: 3,
      hosted: true,
      allowed_secret_paths: GUARD_HOSTED_ALLOWED_SECRET_PATHS
    }
  checks += 1
  expect_failure.call("hosted trigger without runner guard") do
    guard_step_layout(GUARD_HOSTED_TRIGGER, 3)
  end
  expect_failure.call("runner guard without ready trigger") do
    guard_step_layout(GUARD_TRIGGER, 4)
  end

  verification = { "env" => GUARD_VERIFY_ENV.dup, "run" => GUARD_VERIFY_RUN }
  assert_exact_environment(verification, GUARD_VERIFY_ENV, "regression guard verification")
  assert_exact_normalized_run(
    verification["run"], GUARD_VERIFY_RUN, GUARD_VERIFY_RUN_HASH, "regression guard verification run"
  )
  checks += 2
  expect_failure.call("added verification token env") do
    changed = Marshal.load(Marshal.dump(verification))
    changed["env"]["GH_TOKEN"] = GITHUB_TOKEN_EXPRESSION
    assert_exact_environment(changed, GUARD_VERIFY_ENV, "regression guard verification")
  end
  expect_failure.call("changed verification shell") do
    assert_exact_normalized_run(
      "#{verification["run"]}\nprintf 'unexpected\\n'",
      GUARD_VERIFY_RUN,
      GUARD_VERIFY_RUN_HASH,
      "regression guard verification run"
    )
  end
  expect_failure.call("trailing shell whitespace") do
    assert_exact_normalized_run(
      verification["run"].sub("set -euo pipefail", "set -euo pipefail "),
      GUARD_VERIFY_RUN,
      GUARD_VERIFY_RUN_HASH,
      "regression guard verification run"
    )
  end

  validation = { "env" => GUARD_VALIDATE_ENV.dup, "run" => GUARD_VALIDATE_RUN }
  assert_exact_environment(validation, GUARD_VALIDATE_ENV, "regression guard validation")
  assert_exact_normalized_run(
    validation["run"], GUARD_VALIDATE_RUN, GUARD_VALIDATE_RUN_HASH, "regression guard validation run"
  )
  checks += 2
  expect_failure.call("added validation secret env") do
    changed = Marshal.load(Marshal.dump(validation))
    changed["env"]["EXTRA_TOKEN"] = "${{ secrets.OTHER_TOKEN }}"
    assert_exact_environment(changed, GUARD_VALIDATE_ENV, "regression guard validation")
  end
  expect_failure.call("GitHub context in validation shell") do
    assert_exact_normalized_run(
      "#{validation["run"]}\nprintf '%s\\n' '${{ github['token'] }}'",
      GUARD_VALIDATE_RUN,
      GUARD_VALIDATE_RUN_HASH,
      "regression guard validation run"
    )
  end
  # The guard job's condition is the one place where this workflow can decline
  # to run, so admission of that key is exercised against whole documents.
  guard_document = lambda do |condition, name = GUARD_WORKFLOW_NAME|
    job = {
      "name" => name,
      "runs-on" => "ubuntu-24.04",
      "timeout-minutes" => GUARD_TIMEOUT_MINUTES,
      "permissions" => { "contents" => "read", "pull-requests" => "read" },
      "steps" => [
        {
          "name" => "Checkout immutable guard revision",
          "uses" => "actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd",
          "with" => Marshal.load(Marshal.dump(GUARD_CHECKOUT_WITH))
        },
        { "name" => "Verify trusted checkout", "env" => GUARD_VERIFY_ENV.dup, "run" => "#{GUARD_VERIFY_RUN}\n" },
        {
          "name" => "Run trusted CLA regression matrix and validate policy as data",
          "env" => GUARD_VALIDATE_ENV.dup,
          "run" => "#{GUARD_VALIDATE_RUN}\n"
        }
      ]
    }
    job = { "name" => job["name"], "if" => condition }.merge(job) unless condition.nil?
    YAML.dump(
      "name" => GUARD_WORKFLOW_NAME,
      "on" => { "pull_request_target" => Marshal.load(Marshal.dump(GUARD_TRIGGER)) },
      "permissions" => {},
      "jobs" => { "validate" => job }
    )
  end

  safe_if = "${{ !(github.event_name == 'pull_request_target' && github.event.action == 'edited' && !github.event.changes.base && (github.event.changes.body || github.event.changes.title)) }}"
  safe_name = "${{ github.event_name == 'pull_request_target' && github.event.action == 'edited' && !github.event.changes.base && (github.event.changes.body || github.event.changes.title) && 'CLA policy guard metadata (ignored)' || 'CLA policy guard' }}"
  validate_guard_workflow(guard_document.call(nil), authorize: false)
  checks += 1
  validate_guard_workflow(guard_document.call(safe_if, safe_name), authorize: false)
  checks += 1
  validate_guard_workflow(guard_document.call(safe_if.gsub(" && ", "\n  && "), safe_name), authorize: false)
  checks += 1
  [
    [safe_if, GUARD_WORKFLOW_NAME],
    [nil, safe_name],
    ["github.event.action != 'edited' || github.event.changes.base.ref.from != '' || github.event.changes.base.sha.from != ''", GUARD_WORKFLOW_NAME],
    ["false", safe_name],
    [safe_if, safe_name.sub("metadata (ignored)", "metadata")],
    [safe_if, "${{ github.actor }}"],
    [nil, "Wrong required check"],
    [safe_if.sub(" && !github.event.changes.base", ""), safe_name],
    [safe_if, safe_name.sub("!github.event.changes.base", "true")]
  ].each do |condition, name|
    expect_failure.call("guard condition/name pair #{condition.inspect}, #{name.inspect}") do
      validate_guard_workflow(guard_document.call(condition, name), authorize: false)
    end
  end

  # The live guard layout: ready_for_review trigger plus a runner identity
  # step. Either reviewed identity step and any allowlisted runner pass.
  hosted_guard_document = lambda do |runner, identity|
    document = YAML.safe_load(guard_document.call(nil))
    document["on"]["pull_request_target"] = Marshal.load(Marshal.dump(GUARD_HOSTED_TRIGGER))
    document["jobs"]["validate"]["runs-on"] = runner
    document["jobs"]["validate"]["steps"].insert(1, identity)
    YAML.dump(document)
  end
  hosted_identity = {
    "name" => CLA_HOSTED_RUNNER_GUARD_NAME, "if" => CLA_HOSTED_RUNNER_GUARD_IF, "run" => "#{CLA_HOSTED_RUNNER_GUARD_RUN}\n"
  }
  ephemeral_identity = {
    "name" => CLA_EPHEMERAL_RUNNER_GUARD_NAME, "if" => CLA_EPHEMERAL_RUNNER_GUARD_IF, "run" => "#{CLA_EPHEMERAL_RUNNER_GUARD_RUN}\n"
  }
  CLA_RUNNERS.product([hosted_identity, ephemeral_identity]).each do |runner, identity|
    validate_guard_workflow(hosted_guard_document.call(runner, identity), authorize: false)
    checks += 1
  end
  [
    "${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}",
    CLA_TRUSTED_RUNNER_EXPRESSION.gsub("vars.CI_TRUSTED_RUNNER", "vars.LINUX_RUNNER"),
    CLA_TRUSTED_RUNNER_EXPRESSION.sub('"ubuntu-24.04",', '"ubuntu-24.04","self-hosted",'),
    "${{ github.event.pull_request.head.ref }}",
    "self-hosted",
    "ubuntu-latest",
    "blacksmith-8vcpu-ubuntu-2404",
    ["self-hosted", "linux"]
  ].each do |runner|
    expect_failure.call("guard runner #{runner.inspect}") do
      validate_guard_workflow(hosted_guard_document.call(runner, ephemeral_identity), authorize: false)
    end
  end
  expect_failure.call("guard identity with weakened Blacksmith prefix") do
    weakened = ephemeral_identity.merge(
      "if" => "runner.environment != 'github-hosted' && !startsWith(runner.name, 'blacksmith-')"
    )
    validate_guard_workflow(hosted_guard_document.call(CLA_TRUSTED_RUNNER_EXPRESSION, weakened), authorize: false)
  end
  # The selector is admitted as an expression only as a job runs-on value.
  assert_safe_expression_fields({ "jobs" => { "a" => { "runs-on" => CLA_TRUSTED_RUNNER_EXPRESSION } } }, "regression")
  checks += 1
  expect_failure.call("selector outside runs-on") do
    assert_safe_expression_fields({ "jobs" => { "a" => { "name" => CLA_TRUSTED_RUNNER_EXPRESSION } } }, "regression")
  end
  expect_failure.call("selector in a nested runs-on key") do
    assert_safe_expression_fields(
      { "jobs" => { "a" => { "steps" => [{ "runs-on" => CLA_TRUSTED_RUNNER_EXPRESSION }] } } }, "regression"
    )
  end
  expect_failure.call("other runs-on expression") do
    assert_safe_expression_fields({ "jobs" => { "a" => { "runs-on" => "${{ vars.LINUX_RUNNER }}" } } }, "regression")
  end

  puts "PASS: guard workflow contract regression matrix (#{checks} cases)"
end

def assert_safe_run_values(document)
  walk(document) do |key, value|
    assert_safe_run_text(value, "workflow run step") if key == "run"
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

  migration_cases = [
    ["exact legacy v2 bridge", LEGACY_CLA_WORKFLOW_DIGEST, LEGACY_CLA_RERUN_DIGEST, true],
    ["different legacy workflow", "0" * 64, LEGACY_CLA_RERUN_DIGEST, false],
    ["different legacy helper", LEGACY_CLA_WORKFLOW_DIGEST, "0" * 64, false]
  ]
  migration_failures = migration_cases.each_with_object([]) do |(name, workflow_digest, script_digest, expected), failures|
    actual = legacy_v2_base?(
      base_workflow_digest: workflow_digest,
      base_script_digest: script_digest
    )
    failures << "#{name}: expected #{expected}, got #{actual}" unless actual == expected
  end
  fail!("CLA migration regression matrix failed: #{migration_failures.join('; ')}") unless migration_failures.empty?
  puts "PASS: CLA migration regression matrix (#{migration_cases.length} cases)"
end

def run_environment_regression_matrix!
  checks = 0
  assert_exact_environment({ "env" => ADMISSION_ENV.dup }, ADMISSION_ENV, "regression admission")
  checks += 1

  expect_failure = lambda do |name, &block|
    failed = false
    begin
      block.call
    rescue PolicyError
      failed = true
    end
    fail!("#{name} environment regression failed") unless failed
    checks += 1
  end

  expect_failure.call("added variable") do
    assert_exact_environment(
      { "env" => ADMISSION_ENV.merge("EXTRA" => "value") },
      ADMISSION_ENV,
      "regression admission"
    )
  end
  expect_failure.call("missing variable") do
    assert_exact_environment(
      { "env" => ADMISSION_ENV.reject { |key, _value| key == "EVENT_NAME" } },
      ADMISSION_ENV,
      "regression admission"
    )
  end
  expect_failure.call("changed expression") do
    assert_exact_environment(
      { "env" => ADMISSION_ENV.merge("EVENT_NAME" => "${{ secrets.OTHER_TOKEN }}") },
      ADMISSION_ENV,
      "regression admission"
    )
  end

  secret_document = {
    "jobs" => {
      "CLACommentGate" => { "steps" => [{}, {}, { "env" => { "GITHUB_TOKEN" => GITHUB_TOKEN_EXPRESSION } }] },
      "CLALedgerWriter" => { "steps" => [{}, { "env" => { "GITHUB_TOKEN" => GITHUB_TOKEN_EXPRESSION } }] },
      "RerunFailedCLA" => { "steps" => [{}, {}, { "env" => { "GH_TOKEN" => GITHUB_TOKEN_EXPRESSION } }] },
      "LockMergedPullRequest" => { "steps" => [{}, { "env" => { "GITHUB_TOKEN" => GITHUB_TOKEN_EXPRESSION } }] }
    }
  }
  assert_exact_secret_paths(secret_document)
  checks += 1

  expect_failure.call("extra secret path") do
    changed = Marshal.load(Marshal.dump(secret_document))
    changed["jobs"]["CLAAssistant"] = {
      "steps" => [{ "env" => { "LEAK" => "${{ secrets.OTHER_TOKEN }}" } }]
    }
    assert_exact_secret_paths(changed)
  end
  expect_failure.call("github token alias") do
    changed = Marshal.load(Marshal.dump(secret_document))
    changed["jobs"]["CLAAssistant"] = {
      "steps" => [{ "run" => "echo '${{ github.token }}'" }]
    }
    assert_exact_secret_paths(changed)
  end
  expect_failure.call("changed allowed token") do
    changed = Marshal.load(Marshal.dump(secret_document))
    changed.dig("jobs", "CLACommentGate", "steps", 2, "env")["GITHUB_TOKEN"] =
      "${{ secrets.OTHER_TOKEN }}"
    assert_exact_secret_paths(changed)
  end
  expect_failure.call("bracket GitHub context") do
    assert_safe_run_text("echo '${{ github['token'] }}'", "regression run")
  end
  expect_failure.call("serialized GitHub context") do
    assert_safe_run_text("echo '${{ toJSON(github) }}'", "regression run")
  end
  expect_failure.call("nested expression") do
    assert_safe_run_text("echo '${{ format('{0}', 'value') }}'", "regression run")
  end
  expect_failure.call("token environment variable") do
    assert_safe_run_text("echo \"$ACTIONS_RUNTIME_TOKEN\"", "regression run")
  end

  safe_expression_document = {
    "jobs" => {
      "example" => {
        "if" => "${{ github.event_name == 'issue_comment' }}",
        "concurrency" => { "group" => "cla-${{ github.run_id }}" },
        "outputs" => { "result" => "${{ steps.result.outputs.value }}" },
        "steps" => [
          {
            "env" => { "EVENT" => "${{ github.event_name }}" },
            "with" => { "repository" => "${{ github.repository }}" }
          }
        ]
      }
    }
  }
  assert_safe_expression_fields(safe_expression_document, "regression expressions")
  checks += 1
  expect_failure.call("expression in metadata") do
    changed = Marshal.load(Marshal.dump(safe_expression_document))
    changed["jobs"]["example"]["name"] = "${{ github['token'] }}"
    assert_safe_expression_fields(changed, "regression expressions")
  end
  expect_failure.call("serialized context in metadata") do
    changed = Marshal.load(Marshal.dump(safe_expression_document))
    changed["jobs"]["example"]["name"] = "${{ toJSON(github) }}"
    assert_safe_expression_fields(changed, "regression expressions")
  end
  expect_failure.call("indexed secret expression") do
    changed = Marshal.load(Marshal.dump(safe_expression_document))
    changed["jobs"]["example"]["steps"][0]["env"]["EVENT"] = "${{ secrets['OTHER_TOKEN'] }}"
    assert_safe_expression_fields(changed, "regression expressions")
  end

  puts "PASS: CLA environment regression matrix (#{checks} cases)"
end

def run_runner_regression_matrix!
  checks = 0
  cla_jobs = %w[
    CLACommentGate
    CLAAssistant
    CLALedgerWriter
    CLACompatibility
    RerunFailedCLA
    LockMergedPullRequest
  ]
  accepted_runners = [
    "ubuntu-24.04",
    "blacksmith-2vcpu-ubuntu-2404",
    "blacksmith-4vcpu-ubuntu-2404",
    "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || contains(fromJSON('[\"ubuntu-24.04\",\"blacksmith-2vcpu-ubuntu-2404\",\"blacksmith-4vcpu-ubuntu-2404\"]'), vars.CI_TRUSTED_RUNNER) && vars.CI_TRUSTED_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}"
  ]
  fail!("CLA runner allowlist regression failed") unless accepted_runners == CLA_RUNNERS
  cla_jobs.product(accepted_runners).each do |job_name, runner|
    assert_cla_runner(runner, "#{job_name}.runs-on")
    checks += 1
  end
  # The selector is an exact string. Every variant below either names another
  # variable, widens the label list, drops the fork branch, or changes bytes.
  selector = CLA_TRUSTED_RUNNER_EXPRESSION
  rejected_runners = {
    "configured repository variable" => "${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}",
    "alternate repository variable" => "${{ vars.OTHER_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}",
    "bare trusted runner variable" => "${{ vars.CI_TRUSTED_RUNNER }}",
    "event-controlled runner" => "${{ github.event.repository.default_branch }}",
    "event-controlled selector" => selector.sub("vars.CI_TRUSTED_RUNNER) && vars.CI_TRUSTED_RUNNER", "github.event.pull_request.title) && github.event.pull_request.title"),
    "selector renamed to LINUX_RUNNER" => selector.gsub("vars.CI_TRUSTED_RUNNER", "vars.LINUX_RUNNER"),
    "selector reading another variable" => selector.sub("&& vars.CI_TRUSTED_RUNNER ||", "&& vars.LINUX_RUNNER ||"),
    "selector widened to an owned label" => selector.sub('"ubuntu-24.04",', '"ubuntu-24.04","glaeda-std-xcode-26.6",'),
    "selector widened to self-hosted" => selector.sub('"ubuntu-24.04",', '"ubuntu-24.04","self-hosted",'),
    "selector without fork branch" => selector.sub("github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || ", ""),
    "selector falling back to a variable" => selector.sub("|| 'blacksmith-4vcpu-ubuntu-2404' }}", "|| vars.LINUX_RUNNER }}"),
    "selector with trailing comment" => "#{selector} # ephemeral-required",
    "selector with trailing space" => "#{selector} ",
    "selector with changed spacing" => selector.sub("${{ ", "${{  "),
    "self-hosted runner" => "self-hosted",
    "floating GitHub runner" => "ubuntu-latest",
    "other GitHub runner" => "ubuntu-22.04",
    "larger Blacksmith runner" => "blacksmith-8vcpu-ubuntu-2404",
    "older Blacksmith image" => "blacksmith-4vcpu-ubuntu-2204",
    "Blacksmith macOS runner" => "blacksmith-6vcpu-macos-15",
    "uppercase Blacksmith label" => "Blacksmith-4vcpu-ubuntu-2404",
    "owned runner label" => "glaeda-std-xcode-26.6",
    "label list" => ["self-hosted", "blacksmith-4vcpu-ubuntu-2404"],
    "runner group" => { "group" => "Blacksmith scale sets - blacksmith-4vcpu-ubuntu-2404" },
    "missing runner" => nil
  }
  rejected_runners.each do |name, runner|
    expect_policy_error(name) { assert_cla_runner(runner, "CLACommentGate.runs-on") }
    checks += 1
  end

  # Both reviewed guard triples are accepted, so workflows main carries stay
  # valid while they move from the hosted guard to the ephemeral one.
  hosted_guard = {
    "name" => CLA_HOSTED_RUNNER_GUARD_NAME,
    "if" => CLA_HOSTED_RUNNER_GUARD_IF,
    "run" => CLA_HOSTED_RUNNER_GUARD_RUN
  }
  ephemeral_guard = {
    "name" => "Require GitHub-hosted or Blacksmith runner",
    "if" => "(runner.environment != 'github-hosted' && !startsWith(runner.name, 'blacksmith-2vcpu-ubuntu-2404-') && !startsWith(runner.name, 'blacksmith-4vcpu-ubuntu-2404-')) || contains(runner.name, 'glaeda')",
    "run" => "set -euo pipefail\necho \"::error::CLA policy requires a GitHub-hosted or Blacksmith runner\"\nexit 1\n"
  }
  fail!("ephemeral runner guard regression failed") unless
    ephemeral_guard["if"] == CLA_EPHEMERAL_RUNNER_GUARD_IF &&
    normalize_run_text(ephemeral_guard["run"]) == CLA_EPHEMERAL_RUNNER_GUARD_RUN
  assert_hosted_runner_guard_step(hosted_guard, "regression CLA job")
  assert_hosted_runner_guard_step(ephemeral_guard, "regression CLA job")
  checks += 3
  # The names the guard condition admits on a self-hosted runner: current
  # and pre-October 2026 Blacksmith VMs, never an owned glaeda host.
  {
    "blacksmith-4vcpu-ubuntu-2404-56ere4cqq7ryjqvc" => true,
    "blacksmith-2vcpu-ubuntu-2404-56ere4cqq7ryjqvc" => true,
    "blacksmith-4vcpu-ubuntu-2404-Runner-337101a82d" => true,
    "cmuxs-mac-mini-5-glaeda-1" => false,
    "blacksmith-4vcpu-ubuntu-2404-glaeda" => false,
    "blacksmith-8vcpu-ubuntu-2404-56ere4cqq7ryjqvc" => false,
    "blacksmith-4vcpu-ubuntu-2204-56ere4cqq7ryjqvc" => false,
    "blacksmith-4vcpu-ubuntu-2404" => false
  }.each do |runner_name, expected|
    admitted = CLA_EPHEMERAL_RUNNER_PREFIXES.any? { |prefix| runner_name.start_with?(prefix) } &&
      !runner_name.include?(CLA_OWNED_RUNNER_NAME_MARKER)
    fail!("ephemeral runner name regression failed for #{runner_name}") unless admitted == expected
    checks += 1
  end
  rejected_guards = {
    "runner guard condition" => hosted_guard.merge("if" => "runner.environment == 'github-hosted'"),
    "runner guard shell" => hosted_guard.merge("run" => "exit 0"),
    "ephemeral guard shell" => ephemeral_guard.merge("run" => "exit 0"),
    "hosted name with ephemeral condition" => hosted_guard.merge("if" => CLA_EPHEMERAL_RUNNER_GUARD_IF),
    "ephemeral name with hosted condition" => ephemeral_guard.merge("if" => CLA_HOSTED_RUNNER_GUARD_IF),
    "hosted name with ephemeral shell" => hosted_guard.merge("run" => CLA_EPHEMERAL_RUNNER_GUARD_RUN),
    "any Blacksmith-prefixed name" => ephemeral_guard.merge(
      "if" => "runner.environment != 'github-hosted' && !startsWith(runner.name, 'blacksmith-')"
    ),
    "Blacksmith substring" => ephemeral_guard.merge(
      "if" => "runner.environment != 'github-hosted' && !contains(runner.name, 'blacksmith')"
    ),
    "retired -Runner- name prefix" => ephemeral_guard.merge(
      "if" => CLA_EPHEMERAL_RUNNER_GUARD_IF.gsub("-ubuntu-2404-'", "-ubuntu-2404-Runner-'")
    ),
    "larger Blacksmith scale set" => ephemeral_guard.merge(
      "if" => CLA_EPHEMERAL_RUNNER_GUARD_IF.sub("blacksmith-2vcpu", "blacksmith-8vcpu")
    ),
    "owned-name refusal dropped" => ephemeral_guard.merge(
      "if" => CLA_EPHEMERAL_RUNNER_GUARD_IF.sub(" || contains(runner.name, 'glaeda')", "")
    ),
    "self-hosted always admitted" => ephemeral_guard.merge("if" => "false"),
    "extra guard key" => ephemeral_guard.merge("continue-on-error" => true)
  }
  rejected_guards.each do |name, step|
    expect_policy_error(name) { assert_hosted_runner_guard_step(step, "regression CLA job") }
    checks += 1
  end

  ephemeral_term = "((runner.environment == 'github-hosted' || startsWith(runner.name, 'blacksmith-2vcpu-ubuntu-2404-') || startsWith(runner.name, 'blacksmith-4vcpu-ubuntu-2404-')) && !contains(runner.name, 'glaeda'))"
  fail!("ephemeral runner step condition regression failed") unless ephemeral_term == CLA_EPHEMERAL_RUNNER_STEP_IF
  [
    CLA_HOSTED_RUNNER_STEP_IF,
    "github.event_name == 'issue_comment' && runner.environment == 'github-hosted'",
    ephemeral_term,
    "#{ephemeral_term} && github.event_name == 'issue_comment'",
    "github.event_name == 'issue_comment' &&\n  #{ephemeral_term}",
    "steps.cla.outputs.result == ')' && #{ephemeral_term}"
  ].each do |condition|
    assert_hosted_runner_step({ "if" => condition }, "regression CLA action")
    checks += 1
  end
  # Off ubuntu-24.04 only the ephemeral term counts, so a Blacksmith job
  # cannot skip its privileged steps and still report success.
  (CLA_RUNNERS - [CLA_RUNNER]).each do |runner|
    assert_hosted_runner_step(
      { "if" => "github.event_name == 'issue_comment' && #{ephemeral_term}" }, "regression CLA action", runs_on: runner
    )
    checks += 1
    [CLA_HOSTED_RUNNER_STEP_IF, "github.event_name == 'issue_comment' && #{CLA_HOSTED_RUNNER_STEP_IF}"].each do |condition|
      expect_policy_error("hosted-only step on #{runner}") do
        assert_hosted_runner_step({ "if" => condition }, "regression CLA action", runs_on: runner)
      end
      checks += 1
    end
  end
  silent_skip_job = {
    "runs-on" => CLA_TRUSTED_RUNNER_EXPRESSION,
    "steps" => [
      { "name" => CLA_EPHEMERAL_RUNNER_GUARD_NAME, "if" => CLA_EPHEMERAL_RUNNER_GUARD_IF, "run" => CLA_EPHEMERAL_RUNNER_GUARD_RUN },
      { "if" => CLA_HOSTED_RUNNER_STEP_IF, "run" => "echo privileged" }
    ]
  }
  expect_policy_error("selector job with a hosted-only step") do
    assert_hosted_runner_job_steps(silent_skip_job, "regression CLA job")
  end
  ephemeral_job = Marshal.load(Marshal.dump(silent_skip_job))
  ephemeral_job["steps"][1]["if"] = ephemeral_term
  assert_hosted_runner_job_steps(ephemeral_job, "regression CLA job")
  hosted_job = Marshal.load(Marshal.dump(silent_skip_job))
  hosted_job["runs-on"] = CLA_RUNNER
  assert_hosted_runner_job_steps(hosted_job, "regression CLA job")
  checks += 3
  rejected_conditions = {
    "hosted term inside an index" => "always() && fromJSON('[true]')[false && runner.environment == 'github-hosted' && true]",
    "ephemeral term inside an index" => "always() && fromJSON('[true]')[false && #{ephemeral_term} && true]",
    "mismatched index bracket" => "fromJSON('[1]')[0) && #{ephemeral_term} && (true]",
    "unclosed index bracket" => "x[0 && #{ephemeral_term}",
    "missing hosted action condition" => nil,
    "runner condition bypass" => "runner.environment == 'github-hosted' || always()",
    "ephemeral condition bypass" => "#{ephemeral_term} || always()",
    "negated hosted group" => "!(github.event_name == 'push' && runner.environment == 'github-hosted' && true)",
    "negated ephemeral group" => "!(true && #{ephemeral_term})",
    "negated ephemeral term" => "!#{ephemeral_term}",
    "ephemeral term inside or group" => "(#{ephemeral_term} || true) && true",
    "unbalanced ephemeral term" => "#{ephemeral_term}) && (true",
    "quoted parenthesis hides an or" => "x == '(' && #{ephemeral_term} || true",
    "bare Blacksmith prefix" => "(runner.environment == 'github-hosted' || startsWith(runner.name, 'blacksmith-'))",
    "Blacksmith term without hosted" => "(startsWith(runner.name, 'blacksmith-2vcpu-ubuntu-2404-') || startsWith(runner.name, 'blacksmith-4vcpu-ubuntu-2404-'))",
    "ephemeral term without owned-name refusal" => "(runner.environment == 'github-hosted' || startsWith(runner.name, 'blacksmith-2vcpu-ubuntu-2404-') || startsWith(runner.name, 'blacksmith-4vcpu-ubuntu-2404-'))"
  }
  rejected_conditions.each do |name, condition|
    step = condition.nil? ? { "run" => "echo ok" } : { "if" => condition }
    expect_policy_error(name) { assert_hosted_runner_step(step, "regression CLA action") }
    checks += 1
  end
  puts "PASS: CLA runner contract regression matrix (#{checks} cases)"
end

def run_comment_binding_regression_matrix!
  gate_outputs = {
    "admitted" => "${{ steps.admission.outputs.admitted }}",
    "signer_authorized" => "${{ steps.signer_preflight.outputs.signer_authorized }}",
    "head_sha" => "${{ steps.signer_preflight.outputs.head_sha }}",
    "base_sha" => "${{ steps.signer_preflight.outputs.base_sha }}"
  }.merge(CLA_COMMENT_BINDING_OUTPUTS)
  writer_inputs = {
    "path-to-document" => CLA_DOCUMENT_INPUT,
    "path-to-signatures" => CLA_SIGNATURES_PATH,
    "branch" => "cla-signatures",
    "required-base-ref" => "main",
    "custom-pr-sign-comment" => CLA_SIGN_PHRASE,
    "allowlist-ids" => "38676809,67667005",
    "require-opener-as-author" => "true",
    "lock-pullrequest-aftermerge" => "false",
    "expected-head-sha" => "${{ needs.CLACommentGate.outputs.head_sha }}",
    "expected-base-sha" => "${{ needs.CLACommentGate.outputs.base_sha }}"
  }.merge(CLA_COMMENT_BINDING_INPUTS)
  assert_comment_binding_contract(gate_outputs, writer_inputs)
  checks = 1

  CLA_COMMENT_BINDING_OUTPUTS.each_key do |key|
    expect_policy_error("missing #{key} signer output") do
      assert_comment_binding_contract(gate_outputs.reject { |name, _| name == key }, writer_inputs)
    end
    checks += 1
  end
  CLA_COMMENT_BINDING_INPUTS.each_key do |key|
    expect_policy_error("missing #{key} writer input") do
      assert_comment_binding_contract(gate_outputs, writer_inputs.reject { |name, _| name == key })
    end
    checks += 1
  end
  puts "PASS: CLA signer comment binding regression matrix (#{checks} cases)"
end

def run_lifecycle_regression_matrix!
  fragments = CLA_LIFECYCLE_ACTIONS.map { |action| "github.event.action == '#{action}'" }
  expressions = Array.new(4) { fragments.join(" || ") }
  admission_helper = <<~'SH'
    emit() {
      [[ -n "${GITHUB_OUTPUT+x}" && -n "${GITHUB_OUTPUT}" ]] || fail "GITHUB_OUTPUT is unavailable"
      printf 'admitted=%s\n' "$1" >>"${GITHUB_OUTPUT}"
    }
  SH
  admission_run = admission_helper + <<~'SH'
    case "${EVENT_ACTION}" in
      opened|edited|reopened|synchronize|ready_for_review) emit true ;;
      *) fail "Pull-request event action is unsupported" ;;
    esac
  SH
  assert_lifecycle_admission_contract(expressions, admission_run)
  checks = 1

  CLA_LIFECYCLE_ACTIONS.each do |action|
    expect_policy_error("missing #{action} lifecycle expression") do
      changed = expressions.dup
      changed[0] = changed[0].sub("github.event.action == '#{action}'", "")
      assert_lifecycle_admission_contract(changed, admission_run)
    end
    checks += 1
  end
  expect_policy_error("missing lifecycle admission shell case") do
    assert_lifecycle_admission_contract(expressions, admission_run.sub("ready_for_review", ""))
  end
  checks += 1
  expect_policy_error("missing lifecycle admission output helper") do
    assert_lifecycle_admission_contract(expressions, admission_run.sub("emit() {", "helper() {"))
  end
  checks += 1
  puts "PASS: CLA lifecycle path regression matrix (#{checks} cases)"
end

def run_document_contract_regression_matrix!
  workflow = lambda do |version, generation, ledger_path, phrase = nil, document_url = CLA_DOCUMENT_INPUT|
    phrase ||= "I have read the CLA Document #{version} and I hereby sign the CLA"
    <<~YAML
      name: test
      on: {}
      permissions: {}
      env:
        CLA_GENERATION: #{generation}
      jobs:
        writer:
          steps:
            - with:
                path-to-document: '#{document_url}'
                path-to-signatures: '#{ledger_path}'
                custom-pr-sign-comment: '#{phrase}'
    YAML
  end
  document = lambda do |version, body = "terms"|
    "# Individual Contributor License Agreement (\"Agreement\") #{version}\n#{body}\n"
  end
  helper = lambda do |version, ledger_path|
    phrase = "I have read the CLA Document #{version} and I hereby sign the CLA"
    <<~SH
      #!/usr/bin/env bash
      [[ "${COMMENT_BODY}" == "#{phrase}" ]] || exit 1
      readonly SIGNATURES_PATH='#{ledger_path}'
      [[ -n "${SIGNATURES_PATH}" ]]
    SH
  end
  base_cla = document.call("v2.2")
  changed_cla = document.call("v3.0", "revised terms")
  base_script = helper.call("v2.2", "signatures/version2/cla.json")
  rotated_script = helper.call("v3.0", "signatures/version3/cla.json")
  base_workflow = workflow.call(
    "v2.2", "v2.2-action-#{'a' * 40}", "signatures/version2/cla.json"
  )
  unchanged = assert_cla_document_change_contract(
    base_cla: base_cla,
    head_cla: base_cla,
    base_workflow: base_workflow,
    head_workflow: base_workflow,
    base_script: base_script,
    head_script: base_script
  )
  fail!("unchanged CLA document contract was reported as changed") unless unchanged == false
  checks = 1

  expect_policy_error("document-only change") do
    assert_cla_document_change_contract(
      base_cla: base_cla,
      head_cla: changed_cla,
      base_workflow: base_workflow,
      head_workflow: base_workflow,
      base_script: base_script,
      head_script: base_script
    )
  end
  checks += 1

  rotated_workflow = workflow.call(
    "v3.0", "v3.0-action-#{'b' * 40}", "signatures/version3/cla.json"
  )
  assert_cla_document_change_contract(
    base_cla: base_cla,
    head_cla: changed_cla,
    base_workflow: base_workflow,
    head_workflow: rotated_workflow,
    base_script: base_script,
    head_script: rotated_script
  )
  checks += 1

  {
    "same document version" => workflow.call(
      "v2.2", "v3.0-action-#{'b' * 40}", "signatures/version3/cla.json"
    ),
    "same generation" => workflow.call(
      "v3.0", "v2.2-action-#{'a' * 40}", "signatures/version3/cla.json"
    ),
    "same ledger path" => workflow.call(
      "v3.0", "v3.0-action-#{'b' * 40}", "signatures/version2/cla.json"
    ),
    "old ledger namespace" => workflow.call(
      "v3.0", "v3.0-action-#{'b' * 40}", "signatures/version1/cla.json"
    ),
    "minor ledger namespace" => workflow.call(
      "v3.0", "v3.0-action-#{'b' * 40}", "signatures/version3.0/cla.json"
    ),
    "mutable document URL" => workflow.call(
      "v3.0", "v3.0-action-#{'b' * 40}", "signatures/version3/cla.json", nil,
      "https://github.com/${{ github.repository }}/blob/main/CLA.md"
    ),
    "wrong document phrase" => workflow.call(
      "v3.0", "v3.0-action-#{'b' * 40}", "signatures/version3/cla.json",
      "I have read the CLA Document v2.2 and I hereby sign the CLA"
    )
  }.each do |name, candidate|
    expect_policy_error(name) do
      assert_cla_document_change_contract(
        base_cla: base_cla,
        head_cla: changed_cla,
        base_workflow: base_workflow,
        head_workflow: candidate,
        base_script: base_script,
        head_script: rotated_script
      )
    end
    checks += 1
  end
  expect_policy_error("stale rerun helper") do
    assert_cla_document_change_contract(
      base_cla: base_cla,
      head_cla: changed_cla,
      base_workflow: base_workflow,
      head_workflow: rotated_workflow,
      base_script: base_script,
      head_script: base_script
    )
  end
  checks += 1
  expect_policy_error("decreasing document major") do
    older_cla = document.call("v1.0", "reverted terms")
    older_workflow = workflow.call("v1.0", "v1.0-action-#{'c' * 40}", "signatures/version1/cla.json")
    older_script = helper.call("v1.0", "signatures/version1/cla.json")
    assert_cla_document_change_contract(
      base_cla: base_cla,
      head_cla: older_cla,
      base_workflow: base_workflow,
      head_workflow: older_workflow,
      base_script: base_script,
      head_script: older_script
    )
  end
  checks += 1
  puts "PASS: CLA document contract regression matrix (#{checks} cases)"
end

def run_trusted_review_regression_matrix!
  head = "a" * 40
  review = lambda do |id, state, at, commit = head, user = 38676809, dismissed = nil|
    {
      "id" => id,
      "user" => { "id" => user, "type" => "User" },
      "state" => state,
      "commit_id" => commit,
      "submitted_at" => at,
      "dismissed_at" => dismissed
    }
  end
  latest = {}
  seen = {}
  collect_latest_trusted_review!(latest, seen, review.call(2, "COMMENTED", "2026-01-02T00:00:00Z"))
  collect_latest_trusted_review!(latest, seen, review.call(1, "APPROVED", "2026-01-01T00:00:00Z"))
  fail!("trusted review ordering regression failed") unless latest.fetch("38676809")[1]["state"] == "APPROVED"

  latest = {}
  seen = {}
  timestamp = "2026-01-03T00:00:00Z"
  collect_latest_trusted_review!(latest, seen, review.call(4, "COMMENTED", timestamp))
  collect_latest_trusted_review!(latest, seen, review.call(3, "APPROVED", timestamp))
  fail!("trusted review ID tie-break regression failed") unless latest.fetch("38676809")[1]["id"] == 3

  latest = {}
  seen = {}
  collect_latest_trusted_review!(latest, seen, review.call(5, "APPROVED", "2026-01-04T00:00:00Z", head, 38676809))
  collect_latest_trusted_review!(latest, seen, review.call(6, "DISMISSED", "2026-01-05T00:00:00Z", head, 38676809))
  fail!("trusted review dismissal regression failed") unless latest.fetch("38676809")[1]["state"] == "DISMISSED"

  latest = {}
  seen = {}
  collect_latest_trusted_review!(latest, seen, review.call(10, "APPROVED", "2026-01-05T00:00:00Z", head, 67667005))
  fail!("Aziz trusted review regression failed") unless latest.fetch("67667005")[1]["state"] == "APPROVED"

  self_review = review.call(13, "APPROVED", "2026-01-05T00:00:01Z", head, 38676809)
  fail!("trusted reviewer self-approval regression failed") if
    trusted_review_approves_head?(self_review, head, 38676809)
  fail!("trusted independent approval regression failed") unless
    trusted_review_approves_head?(self_review, head, 67667005)

  latest = {}
  seen = {}
  collect_latest_trusted_review!(latest, seen, review.call(7, "APPROVED", "2026-01-06T00:00:00Z", head, 12345))
  fail!("untrusted review was treated as trusted") unless latest.empty?

  latest = {}
  seen = {}
  collect_latest_trusted_review!(latest, seen, { "id" => 8, "state" => "PENDING" })
  fail!("pending review changed trusted state") unless latest.empty?

  latest = {}
  seen = {}
  collect_latest_trusted_review!(latest, seen, { "id" => 11, "user" => nil, "state" => "APPROVED" })
  fail!("deleted reviewer changed trusted state") unless latest.empty?

  latest = {}
  seen = {}
  collect_latest_trusted_review!(latest, seen, { "id" => 12, "user" => { "id" => 12345 }, "state" => "invalid" })
  fail!("malformed untrusted review changed trusted state") unless latest.empty?

  duplicate_failed = false
  begin
    collect_latest_trusted_review!(latest, seen, review.call(9, "APPROVED", "2026-01-06T00:00:00Z"))
    collect_latest_trusted_review!(latest, seen, review.call(9, "APPROVED", "2026-01-06T00:00:01Z"))
  rescue PolicyError
    duplicate_failed = true
  end
  fail!("duplicate review regression failed") unless duplicate_failed
  puts "PASS: trusted review state regression matrix (11 cases)"
end

def validate_workflow(raw)
  document = parse_workflow(raw)

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
  expected_types = %w[opened closed edited reopened synchronize ready_for_review]
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
    "RerunFailedCLA" => %w[name needs if runs-on timeout-minutes concurrency permissions steps],
    "LockMergedPullRequest" => %w[name if runs-on timeout-minutes concurrency permissions steps]
  }
  [gate, assistant, writer, compatibility, rerun, lock].each_with_index do |value, index|
    names = %w[CLACommentGate CLAAssistant CLALedgerWriter CLACompatibility RerunFailedCLA LockMergedPullRequest]
    fail!("#{names[index]} has no runner") unless value.key?("runs-on")
    assert_exact_keys(value, job_keys.fetch(names[index]), names[index])
    assert_safe_job_common(value, names[index])
    assert_cla_runner(value["runs-on"], names[index])
    assert_hosted_runner_job_steps(value, names[index])
  end

  fail!("CLACommentGate must use read-only permissions") unless
    gate["permissions"] == { "contents" => "read", "issues" => "read", "pull-requests" => "read" }
  fail!("CLACompatibility must have no permissions") unless compatibility["permissions"] == {}
  fail!("CLA Assistant result must have no permissions") unless assistant["permissions"] == {}
  fail!("CLACommentGate outputs are not the reviewed contract") unless
    gate["outputs"] == {
      "admitted" => "${{ steps.admission.outputs.admitted }}",
      "signer_authorized" => "${{ steps.signer_preflight.outputs.signer_authorized }}",
      "head_sha" => "${{ steps.signer_preflight.outputs.head_sha }}",
      "base_sha" => "${{ steps.signer_preflight.outputs.base_sha }}"
    }.merge(CLA_COMMENT_BINDING_OUTPUTS)
  fail!("CLALedgerWriter outputs are not the reviewed contract") unless
    writer["outputs"] == {
      "signature_recorded" => "${{ steps.cla_action.outputs.signature_recorded }}",
      "cla_passed" => "${{ steps.cla_action.outputs.cla_passed }}"
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
  fail!("CLALedgerWriter must contain a runner guard and one action step") unless writer_steps.length == 2
  writer_step = writer_steps[1]
  assert_step_keys(writer_step, "CLALedgerWriter step", %w[name id if uses env with])
  assert_hosted_runner_step(writer_step, "CLALedgerWriter action")
  fail!("CLALedgerWriter step must have id cla_action") unless writer_step["id"] == "cla_action"
  assert_action_reference(writer_step["uses"], "CLALedgerWriter step uses")
  fail!("CLALedgerWriter must invoke only the maintained CLA action") unless writer_step["uses"] == CLA_ACTION
  assert_exact_environment(
    writer_step,
    { "GITHUB_TOKEN" => GITHUB_TOKEN_EXPRESSION },
    "CLALedgerWriter step"
  )

  gate_steps = steps(gate, "CLACommentGate")
  fail!("CLACommentGate must contain a runner guard, admission, and preflight") unless gate_steps.length == 3
  admission_step_shape = gate_steps[1]
  assert_step_keys(admission_step_shape, "CLACommentGate admission step", %w[name id if env run])
  assert_hosted_runner_step(admission_step_shape, "CLACommentGate admission")
  fail!("CLACommentGate admission step must have id admission") unless admission_step_shape["id"] == "admission"
  assert_exact_environment(admission_step_shape, ADMISSION_ENV, "CLACommentGate admission step")
  fail!("CLACommentGate admission step must not access a token or network") if
    admission_step_shape["run"].to_s.match?(/\b(gh|curl|wget|git|ssh|sudo|eval|source)\b|\bsecrets\b|\bgithub\.token\b|GITHUB_TOKEN/i)
  preflight_step_shape = gate_steps[2]
  assert_step_keys(preflight_step_shape, "CLACommentGate preflight step", %w[name id if uses env with])
  assert_hosted_runner_step(preflight_step_shape, "CLACommentGate preflight")
  assert_action_reference(preflight_step_shape["uses"], "CLACommentGate preflight uses")
  fail!("CLACommentGate preflight must invoke only the maintained CLA action") unless preflight_step_shape["uses"] == CLA_ACTION
  fail!("CLACommentGate preflight step must have id signer_preflight") unless preflight_step_shape["id"] == "signer_preflight"
  assert_exact_environment(
    preflight_step_shape,
    { "GITHUB_TOKEN" => GITHUB_TOKEN_EXPRESSION },
    "CLACommentGate preflight step"
  )

  result_steps = steps(assistant, "CLAAssistant")
  fail!("CLAAssistant must contain a runner guard and one result step") unless result_steps.length == 2
  assert_step_keys(result_steps[1], "CLAAssistant result step", %w[name if env run])
  assert_hosted_runner_step(result_steps[1], "CLAAssistant result")
  assert_exact_environment(result_steps[1], RESULT_ENV, "CLAAssistant result step")
  compatibility_steps = steps(compatibility, "CLACompatibility")
  fail!("CLACompatibility must contain a runner guard and one result step") unless compatibility_steps.length == 2
  assert_step_keys(compatibility_steps[1], "CLACompatibility result step", %w[name if env run])
  assert_hosted_runner_step(compatibility_steps[1], "CLACompatibility result")
  assert_exact_environment(compatibility_steps[1], COMPATIBILITY_ENV, "CLACompatibility result step")

  rerun_steps = steps(rerun, "RerunFailedCLA")
  fail!("RerunFailedCLA must contain a runner guard, checkout, and guard step") unless rerun_steps.length == 3
  assert_step_keys(rerun_steps[1], "RerunFailedCLA checkout step", %w[name if uses with])
  assert_hosted_runner_step(rerun_steps[1], "RerunFailedCLA checkout")
  assert_step_keys(rerun_steps[2], "RerunFailedCLA guard step", %w[name if env run])
  assert_hosted_runner_step(rerun_steps[2], "RerunFailedCLA helper")
  assert_action_reference(rerun_steps[1]["uses"], "RerunFailedCLA checkout uses")
  fail!("RerunFailedCLA may not invoke the CLA action") if rerun_steps.any? { |step| step["uses"] == CLA_ACTION }
  fail!("RerunFailedCLA guard step must invoke the immutable helper exactly") unless
    rerun_steps[2]["run"] == "bash .github/scripts/rerun-failed-cla.sh"
  assert_exact_environment(rerun_steps[2], RERUN_ENV, "RerunFailedCLA guard step")

  lock_steps = steps(lock, "LockMergedPullRequest")
  fail!("LockMergedPullRequest must contain a runner guard and one action step") unless lock_steps.length == 2
  assert_step_keys(lock_steps[1], "LockMergedPullRequest step", %w[name if uses env with])
  assert_hosted_runner_step(lock_steps[1], "LockMergedPullRequest action")
  assert_action_reference(lock_steps[1]["uses"], "LockMergedPullRequest uses")
  fail!("LockMergedPullRequest must invoke only the maintained CLA action") unless lock_steps[1]["uses"] == CLA_ACTION
  assert_exact_environment(
    lock_steps[1],
    { "GITHUB_TOKEN" => GITHUB_TOKEN_EXPRESSION },
    "LockMergedPullRequest step"
  )
  assert_action_inputs(
    lock_steps[1],
    {
      "mode" => "sign",
      "path-to-signatures" => CLA_SIGNATURES_PATH,
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
  assert_lifecycle_admission_contract(
    [gate["if"], assistant["if"], compatibility["if"], writer_condition],
    admission_run
  )
  # Stop at the first sibling branch. A non-signing recheck branch may need
  # opener identity fields, but those fields must not be duplicated inside the
  # exact signing declaration branch itself.
  sign_branch = admission_run[/if \[\[ "\$\{COMMENT_BODY\}" == "#{Regexp.escape(CLA_SIGN_PHRASE)}" \]\]; then(.*?)(?=\n\s*(?:elif|fi))/m]
  fail!("CLA signing admission implementation is missing") unless sign_branch&.include?("printf 'admitted=true\\n'")
  fail!("CLA signing admission must not duplicate commit identity mapping") if sign_branch.match?(/COMMENT_AUTHOR_ID|PR_AUTHOR_ID/)
  preflight = step_using_with(gate, CLA_ACTION, "mode", "signer-preflight", "CLACommentGate")
  preflight_with = preflight["with"]
  fail!("CLA signer preflight inputs are missing") unless preflight_with.is_a?(Hash)
  {
    "mode" => "signer-preflight",
    "path-to-signatures" => CLA_SIGNATURES_PATH,
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
    rerun["permissions"] == { "actions" => "write", "checks" => "read", "contents" => "read", "issues" => "read", "pull-requests" => "read" }
  fail!("LockMergedPullRequest permissions are not least-privilege") unless
    lock["permissions"] == { "issues" => "write", "pull-requests" => "write" }

  action_step = step_using(writer, CLA_ACTION, "CLALedgerWriter")
  with_values = action_step["with"]
  fail!("CLA action inputs are missing") unless with_values.is_a?(Hash)
  writer_inputs = {
    "path-to-document" => CLA_DOCUMENT_INPUT,
    "path-to-signatures" => CLA_SIGNATURES_PATH,
    "branch" => "cla-signatures",
    "required-base-ref" => "main",
    "custom-pr-sign-comment" => CLA_SIGN_PHRASE,
    "allowlist-ids" => "38676809,67667005",
    "require-opener-as-author" => "true",
    "lock-pullrequest-aftermerge" => "false",
    "expected-head-sha" => "${{ needs.CLACommentGate.outputs.head_sha }}",
    "expected-base-sha" => "${{ needs.CLACommentGate.outputs.base_sha }}"
  }.merge(CLA_COMMENT_BINDING_INPUTS)
  assert_action_inputs(action_step, writer_inputs, "CLALedgerWriter action")
  assert_comment_binding_contract(gate["outputs"], writer_inputs)

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
  # YAML block scalars normalize the expression at runtime. Check the parsed
  # signer step instead of matching raw source, so an explicit runner guard
  # may precede the success() term without creating a source-shape bypass.
  fail!("CLA workflow is missing a successful-step guard") unless
    preflight_step_shape["if"].to_s.gsub(/\s+/, " ").include?("success()")
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
  assert_exact_secret_paths(document)
  assert_safe_expression_fields(document, "CLA workflow")
  assert_safe_run_values(document)

  raw
rescue Psych::Exception => error
  fail!("CLA workflow YAML is invalid: #{error.message.lines.first.to_s.strip}")
end

def validate_script(raw)
  fail!("CLA rerun script is missing a shell shebang") unless raw.start_with?("#!/usr/bin/env bash")
  Tempfile.create(["cla-rerun", ".sh"]) do |file|
    file.write(raw)
    file.close
    _stdout, stderr, status = Open3.capture3("bash", "-n", file.path)
    fail!("CLA rerun script has invalid shell syntax: #{stderr.strip}") unless status.success?
  end
end

def validate_guard_workflow(raw, authorize: true, pr_author_id: nil)
  document = parse_workflow(raw)
  digest = workflow_digest(raw)
  fail!("guard workflow name is not the reviewed context") unless document["name"] == GUARD_WORKFLOW_NAME
  triggers = document["on"] || document[true]
  fail!("guard workflow has no mapping of triggers") unless triggers.is_a?(Hash)
  fail!("guard workflow has unsupported triggers") unless triggers.keys.map(&:to_s).sort == GUARD_TRIGGER_KEYS.sort
  target = triggers["pull_request_target"]
  fail!("guard workflow pull_request_target trigger is malformed") unless target.is_a?(Hash)
  assert_exact_keys(target, GUARD_TRIGGER.keys, "guard workflow pull_request_target trigger")
  fail!("guard workflow must have empty top-level permissions") unless document["permissions"] == {}
  guard_top_level_keys = document.keys.map { |key| key == true ? "on" : key.to_s }
  fail!("guard workflow has unsupported top-level keys") unless
    guard_top_level_keys.uniq.sort == %w[name on permissions jobs].sort
  jobs = document["jobs"]
  fail!("guard workflow jobs are malformed") unless jobs.is_a?(Hash)
  fail!("guard workflow has an unexpected job") unless jobs.keys == ["validate"]
  guard_job = document.dig("jobs", "validate")
  fail!("guard workflow validate job is missing") unless guard_job.is_a?(Hash)
  guard_job_keys = %w[name runs-on timeout-minutes permissions steps]
  guard_job_keys += ["if"] if guard_job.key?("if")
  assert_exact_keys(guard_job, guard_job_keys, "guard workflow validate job")
  assert_string(guard_job["name"], "guard workflow validate job name")
  if guard_job.key?("if")
    fail!("guard workflow validate condition/name is not the reviewed pair") unless
      guard_job["if"].to_s.gsub(/\s+/, " ").strip == GUARD_VALIDATE_IF &&
      guard_job["name"] == GUARD_VALIDATE_NAME
  else
    fail!("unconditional guard must report the required check name") unless
      guard_job["name"] == GUARD_WORKFLOW_NAME
  end
  assert_positive_integer(guard_job["timeout-minutes"], "guard workflow validate timeout")
  fail!("guard workflow validate timeout is not the reviewed value") unless
    guard_job["timeout-minutes"] == GUARD_TIMEOUT_MINUTES
  fail!("guard workflow must use an ephemeral GitHub-hosted or Blacksmith runner") unless
    guard_job["runs-on"].is_a?(String) && CLA_RUNNERS.include?(guard_job["runs-on"])
  fail!("guard workflow must use read-only permissions") unless
    guard_job["permissions"] == { "contents" => "read", "pull-requests" => "read" }
  guard_steps = guard_job["steps"]
  fail!("guard workflow steps are malformed") unless guard_steps.is_a?(Array)
  layout = guard_step_layout(target, guard_steps.length)
  assert_step_keys(guard_steps[0], "guard checkout step", %w[name uses with])
  assert_hosted_runner_guard_step(guard_steps[1], "guard workflow") if layout[:hosted]
  verification_step = guard_steps.fetch(layout[:verification_index])
  validation_step = guard_steps.fetch(layout[:validation_index])
  assert_step_keys(verification_step, "guard checkout verification step", %w[name env run])
  assert_step_keys(validation_step, "guard validation step", %w[name env run])
  fail!("guard workflow checkout step is not the immutable checkout") unless
    guard_steps[0]["uses"] == "actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd"
  assert_exact_typed_inputs(guard_steps[0], GUARD_CHECKOUT_WITH, "guard checkout step")
  fail!("guard checkout step has an unexpected name") unless guard_steps[0]["name"] == "Checkout immutable guard revision"
  fail!("guard checkout step must pin the trusted repository") unless
    guard_steps[0].dig("with", "repository") == "${{ github.repository }}"
  fail!("guard verification step has an unexpected name") unless verification_step["name"] == "Verify trusted checkout"
  assert_exact_environment(verification_step, GUARD_VERIFY_ENV, "guard checkout verification step")
  assert_exact_normalized_run(
    verification_step["run"],
    GUARD_VERIFY_RUN,
    GUARD_VERIFY_RUN_HASH,
    "guard checkout verification step run"
  )
  fail!("guard validation step has an unexpected name") unless
    validation_step["name"] == "Run trusted CLA regression matrix and validate policy as data"
  assert_exact_environment(validation_step, GUARD_VALIDATE_ENV, "guard validation step")
  assert_exact_normalized_run(
    validation_step["run"],
    GUARD_VALIDATE_RUN,
    GUARD_VALIDATE_RUN_HASH,
    "guard validation step run"
  )
  assert_exact_secret_paths(document, allowed_paths: layout[:allowed_secret_paths])
  assert_safe_expression_fields(document, "guard workflow", allowed_secret_paths: layout[:allowed_secret_paths], reviewed_guard_name: true)
  assert_safe_run_values(document)
  uses = []
  walk(document) { |key, value| uses << value if key == "uses" && value.is_a?(String) }
  uses.each do |reference|
    fail!("guard workflow may not use repository-local actions") if reference.start_with?("./")
    fail!("guard workflow uses an unapproved action") unless reference == "actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd"
  end
  if authorize && digest != EXPECTED_GUARD_WORKFLOW_DIGEST
    require_trusted_review!(
      ENV.fetch("GH_REPO"), ENV.fetch("PR_NUMBER"), ENV.fetch("HEAD_SHA"), pr_author_id
    )
  end
rescue Psych::Exception
  fail!("guard workflow YAML is invalid")
end

def validate_guard_script(raw, pr_author_id: nil)
  fail!("guard script is missing a Ruby shebang") unless raw.start_with?("#!/usr/bin/env ruby")
  if guard_script_digest(raw) != EXPECTED_GUARD_SCRIPT_DIGEST
    require_trusted_review!(
      ENV.fetch("GH_REPO"), ENV.fetch("PR_NUMBER"), ENV.fetch("HEAD_SHA"), pr_author_id
    )
  end
  [
    "def parse_workflow",
    "class BoundedYamlTreeBuilder",
    "Psych::Parser.new",
    "MAX_YAML_NODES",
    "MAX_YAML_DEPTH",
    "duplicate mapping keys",
    "merge keys",
    "mapping keys must be strings",
    "run_yaml_regression_matrix!",
    "run_action_transition_regression_matrix!",
    "run_environment_regression_matrix!",
    "run_runner_regression_matrix!",
    "run_comment_binding_regression_matrix!",
    "run_lifecycle_regression_matrix!",
    "run_document_contract_regression_matrix!",
    "run_trusted_review_regression_matrix!",
    "run_test_merge_regression_matrix!",
    "def pull_request_changes_files?",
    "def effective_head_policy",
    "def pull_request_test_merge",
    "parent_shas[1] == head_sha",
    "CLA_LIFECYCLE_ACTIONS",
    "ready_for_review",
    "collect_latest_trusted_review!",
    "def workflow_digest",
    "CLA_ACTION_LEGACY_REFS",
    "CLA_ACTION_CURRENT_BASE_REF",
    "CLA_ACTION_BASE_REFS",
    "CLA_ACTION_FINAL",
    "REVIEWED_CLA_BASES",
    "LEGACY_CLA_WORKFLOW_DIGEST",
    "LEGACY_CLA_RERUN_DIGEST",
    "LEGACY_B4D3_CLA_WORKFLOW_DIGEST",
    "LEGACY_B4D3_CLA_REFRESH_DIGEST",
    "LEGACY_CLA_HELPER_PATH",
    "LEGACY_B4D3_CLA_HELPER_PATH",
    "CURRENT_MAIN_CLA_WORKFLOW_DIGEST",
    "def cla_action_reference",
    "def assert_cla_action_transition!",
    "def reviewed_cla_base?",
    "def legacy_action_base?",
    "def cla_helper_path",
    "Digest::SHA256.hexdigest(raw)",
    "literal on trigger key",
    "def legacy_v2_base?",
    "EXPECTED_WORKFLOW_DIGEST",
    "assert_exact_environment",
    "assert_exact_typed_inputs",
    "assert_exact_secret_paths",
    "assert_safe_expression_fields",
    "assert_cla_runner",
    "CLA_RUNNER",
    "assert_hosted_runner_guard_step",
    "assert_hosted_runner_step",
    "assert_hosted_runner_job_steps",
    "CLA_HOSTED_RUNNER_GUARD_NAME",
    "CLA_HOSTED_RUNNER_GUARD_RUN",
    "CLA_HOSTED_RUNNER_GUARD_IF",
    "CLA_HOSTED_RUNNER_STEP_IF",
    "CLA_RUNNERS",
    "CLA_TRUSTED_RUNNER_EXPRESSION",
    "CLA_RUNNER_GUARD_STEPS",
    "CLA_EPHEMERAL_RUNNER_GUARD_IF",
    "CLA_EPHEMERAL_RUNNER_STEP_IF",
    "CLA_RUNNER_STEP_IFS",
    "def top_level_and_terms",
    "CLA_ACTION_RUNNER_SUCCESSOR_PINS",
    "def cla_runner_successor?",
    "assert_comment_binding_contract",
    "CLA_COMMENT_BINDING_OUTPUTS",
    "CLA_COMMENT_BINDING_INPUTS",
    "assert_lifecycle_admission_contract",
    "GITHUB_OUTPUT+x",
    "admitted=%s",
    "CLA_DOCUMENT_PATH",
    "CLA_DOCUMENT_VERSION",
    "CLA_SIGNATURES_PATH",
    "CLA_SIGNATURES_PATH_PATTERN",
    "document_major",
    "expected_signature_path",
    "assert_script_document_binding",
    "assert_cla_document_change_contract",
    "workflow_document_contract",
    "cla_document_version",
    "CLA_DOCUMENT_INPUT",
    "CLA.md changes require a CLA policy workflow change",
    "CLA.md changes must rotate the document version",
    "CLA.md changes must rotate CLA_GENERATION",
    "CLA.md changes must rotate the signature ledger path",
    "CLA.md changes must rotate the rerun helper",
    "base CLA workflow uses an unexpected signature ledger path",
    "proposed CLA rerun helper still accepts the old document phrase",
    "proposed CLA rerun helper still reads the old signature ledger",
    "assert_safe_run_text",
    "assert_exact_normalized_run",
    "run_guard_contract_regression_matrix!",
    "GUARD_CHECKOUT_WITH",
    "GUARD_TRIGGER_KEYS",
    "GUARD_TRIGGER",
    "GUARD_HOSTED_TRIGGER",
    "guard_step_layout",
    "GUARD_WORKFLOW_NAME",
    "GUARD_TIMEOUT_MINUTES",
    "GUARD_VERIFY_ENV",
    "GUARD_VALIDATE_ENV",
    "GUARD_VERIFY_RUN_HASH",
    "GUARD_VALIDATE_RUN_HASH",
    "GUARD_ALLOWED_SECRET_PATHS",
    "GUARD_HOSTED_ALLOWED_SECRET_PATHS",
    "GITHUB_CONTEXT_IN_RUN",
    "TOKEN_ENV_IN_RUN",
    "TRUSTED_REVIEW_STATES",
    "trusted_review_approves_head?",
    "pr_author_id",
    "pull-request author ID is malformed",
    "base_workflow_digest",
    "validate_workflow(head_workflow)",
    "require_trusted_review!(repository, pr_number, head_sha, pr_author_id) if policy_changed",
    "def validate_workflow",
    "signer-preflight",
    "CLALedgerWriter",
    "base_sha",
    "expected-base-sha",
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
  run_yaml_regression_matrix!
  run_guard_contract_regression_matrix!
  run_action_transition_regression_matrix!
  run_trusted_cla_regression_matrix!
  run_environment_regression_matrix!
  run_runner_regression_matrix!
  run_comment_binding_regression_matrix!
  run_lifecycle_regression_matrix!
  run_document_contract_regression_matrix!
  run_trusted_review_regression_matrix!
  run_test_merge_regression_matrix!
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
  live_author = live_pr["user"]
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
  fail!("pull request author metadata is malformed") unless
    live_author.is_a?(Hash) && live_author["id"].is_a?(Integer) && live_author["id"].positive?
  pr_author_id = live_author["id"]
  head_repository = live_head_repo["full_name"].to_s
  fail!("pull request head repository name is malformed") unless head_repository.match?(REPOSITORY)

  # A fork pull request stores the head commit in the head repository. Fetch
  # base and test-merge files from the protected repository and candidate
  # files from the validated head repository, so normal external
  # contributions are admitted.
  base_guard = fetch_snapshot(repository, base_sha, GUARD_PATHS)
  head_guard = fetch_snapshot(head_repository, head_sha, GUARD_PATHS)
  base_policy = fetch_snapshot(repository, base_sha, CLA_POLICY_PATHS)
  head_policy = fetch_snapshot(head_repository, head_sha, CLA_POLICY_PATHS)
  landed_parent_guard = landed_guard = landed_parent_policy = landed_policy = nil
  if head_guard != base_guard || head_policy != base_policy
    landed_parent_sha, landed_sha = pull_request_test_merge(repository, pr_number, base_sha, head_sha)
    if landed_sha
      landed_parent_guard = fetch_snapshot(repository, landed_parent_sha, GUARD_PATHS)
      landed_guard = fetch_snapshot(repository, landed_sha, GUARD_PATHS)
      landed_parent_policy = fetch_snapshot(repository, landed_parent_sha, CLA_POLICY_PATHS)
      landed_policy = fetch_snapshot(repository, landed_sha, CLA_POLICY_PATHS)
    end
  end
  head_guard_workflow = head_guard.fetch(GUARD_WORKFLOW_PATH)
  head_guard_script = head_guard.fetch(GUARD_SCRIPT_PATH)
  guard_changed = pull_request_changes_files?(
    base: base_guard, head: head_guard, landed_parent: landed_parent_guard, landed: landed_guard
  )
  # A branch whose landing leaves every policy path as main has it proposes
  # no policy, so main's bytes are the candidate. Any head that would change
  # main's policy is still a proposal and is checked below.
  head_policy = effective_head_policy(
    base: base_policy, head: head_policy, landed_parent: landed_parent_policy, landed: landed_policy
  )
  base_workflow = base_policy.fetch(CLA_WORKFLOW_PATH)
  head_workflow = head_policy.fetch(CLA_WORKFLOW_PATH)
  fail!("CLA workflow is missing from the base revision") if base_workflow.nil?
  fail!("CLA workflow is missing from the pull-request revision") if head_workflow.nil?
  base_cla = base_policy.fetch(CLA_DOCUMENT_PATH)
  head_cla = head_policy.fetch(CLA_DOCUMENT_PATH)
  fail!("CLA document is missing") if base_cla.nil? || head_cla.nil?
  base_action_ref = cla_action_reference(base_workflow, "base CLA workflow")
  head_action_ref = cla_action_reference(head_workflow, "proposed CLA workflow")
  base_script_path = cla_helper_path(base_action_ref)
  head_script_path = cla_helper_path(head_action_ref)
  base_script = base_script_path && base_policy.fetch(base_script_path)
  head_script = head_script_path && head_policy.fetch(head_script_path)
  policy_changed = base_workflow != head_workflow ||
    base_script_path != head_script_path ||
    base_script != head_script
  base_workflow_digest = Digest::SHA256.hexdigest(base_workflow)
  base_script_digest = base_script && Digest::SHA256.hexdigest(base_script)
  head_workflow_digest = Digest::SHA256.hexdigest(head_workflow)
  assert_cla_action_transition!(
    base_ref: base_action_ref,
    candidate_ref: head_action_ref,
    base_workflow_digest: base_workflow_digest,
    base_script_digest: base_script_digest,
    base_script_path: base_script_path,
    policy_changed: policy_changed,
    candidate_workflow_digest: head_workflow_digest
  )
  # The pinned runner successor is reviewed by its exact bytes, like the main
  # pin it replaces, so the v3 structural checks below do not apply to it.
  runner_successor = policy_changed && head_script.nil? && cla_runner_successor?(
    base_ref: base_action_ref,
    candidate_ref: head_action_ref,
    base_workflow_digest: base_workflow_digest,
    candidate_workflow_digest: head_workflow_digest,
    base_script_digest: base_script_digest,
    base_script_path: base_script_path
  )
  document_changed = Digest::SHA256.hexdigest(base_cla) != Digest::SHA256.hexdigest(head_cla)
  if policy_changed
    fail!("CLA workflow must use the reviewed document version") unless
      cla_document_version(head_cla, "proposed CLA.md") == CLA_DOCUMENT_VERSION
  end
  if document_changed
    fail!("CLA.md changes are not allowed in a guard-only pull request") if guard_changed
    assert_cla_document_change_contract(
      base_cla: base_cla,
      head_cla: head_cla,
      base_workflow: base_workflow,
      head_workflow: head_workflow,
      base_script: base_script,
      head_script: head_script
    )
  end
  # A policy PR cannot also weaken the validator that reviews it. A guard-only
  # PR remains possible for normal maintenance, with CODEOWNERS providing the
  # human review gate for this trusted control plane.
  fail!("guard and CLA policy files must change in separate pull requests") if guard_changed && policy_changed

  if guard_changed
    fail!("guard workflow cannot be deleted") if head_guard_workflow.nil?
    fail!("guard validator cannot be deleted") if head_guard_script.nil?
    validate_guard_workflow(head_guard_workflow, pr_author_id: pr_author_id)
    validate_guard_script(head_guard_script, pr_author_id: pr_author_id)
  end

  if base_workflow == head_workflow && base_script == head_script
    puts "PASS: CLA policy files are unchanged"
    exit 0
  end

  if base_script && head_script.nil?
    fail!("the pull-request revision deletes the rerun helper used by the base workflow")
  end
  if base_workflow == head_workflow &&
      !reviewed_cla_base?(
        base_ref: base_action_ref,
        base_workflow_digest: base_workflow_digest,
        base_script_digest: base_script_digest,
        base_script_path: base_script_path
      )
    # A guard-only change still has to prove that the policy already running
    # on main is a reviewed v3 policy. Reviewed legacy/current bases are
    # immutable transition states and are handled by the action contract above.
    validate_workflow(head_workflow)
  end
  if base_workflow != head_workflow && runner_successor
    parse_workflow(base_workflow)
    parse_workflow(head_workflow)
  elsif base_workflow != head_workflow
    fail!("CLA helper is missing from the changed workflow revision") if head_script.nil?
    parse_workflow(base_workflow)
    validate_workflow(head_workflow)
  end
  validate_script(head_script) unless head_script.nil?
  # Policy changes always need a current, exact-head trusted approval. The
  # legacy digest bridge only identifies the permitted v2 base bytes. It never
  # skips this review or any strict v3 candidate validation.
  require_trusted_review!(repository, pr_number, head_sha, pr_author_id) if policy_changed

  candidate_dir = ENV["CANDIDATE_DIR"].to_s
  unless candidate_dir.empty?
    FileUtils.mkdir_p(candidate_dir)
    File.binwrite(File.join(candidate_dir, "cla.yml"), head_workflow) if head_workflow
    File.binwrite(File.join(candidate_dir, File.basename(head_script_path)), head_script) if head_script
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
