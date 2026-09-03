#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
VALIDATOR = File.join(ROOT, "scripts/ci/validate-cla-policy.rb")
REPOSITORY = "example/cmux"
PR_NUMBER = "7"
BASE_SHA = "1" * 40
EVENT_HEAD_SHA = "2" * 40
NEW_HEAD_SHA = "3" * 40
GENERIC_REJECTION = "::error::CLA policy validation rejected the proposed policy"
SUPERSEDED_NOTICE = "::notice::CLA policy validation skipped because this revision was superseded"

FAKE_GH = <<~'RUBY'
  #!/usr/bin/env ruby
  # frozen_string_literal: true

  require "base64"
  require "json"

  repository = ENV.fetch("FAKE_GH_REPOSITORY")
  root = ENV.fetch("FAKE_GH_ROOT")
  mode = ENV.fetch("FAKE_GH_MODE")
  base_sha = ENV.fetch("FAKE_GH_BASE_SHA")
  event_head_sha = ENV.fetch("FAKE_GH_EVENT_HEAD_SHA")
  new_head_sha = ENV.fetch("FAKE_GH_NEW_HEAD_SHA")
  pr_number = ENV.fetch("FAKE_GH_PR_NUMBER")
  endpoint = ARGV.last.to_s

  emit = lambda do |payload|
    puts JSON.generate(payload)
    exit 0
  end

  case endpoint
  when "repos/#{repository}"
    emit.call("id" => 10_001)
  when "repos/#{repository}/pulls/#{pr_number}"
    if mode == "api_failure"
      warn "gh: simulated upstream failure (HTTP 500)"
      exit 1
    end

    live_base_sha = mode == "changed_base" ? "4" * 40 : base_sha
    live_head_sha = case mode
                    when "superseded" then new_head_sha
                    when "malformed_head" then "not-a-commit"
                    else event_head_sha
                    end
    emit.call(
      "number" => pr_number.to_i,
      "state" => "open",
      "base" => {
        "ref" => "main",
        "sha" => live_base_sha,
        "repo" => { "full_name" => repository, "id" => 10_001 }
      },
      "head" => {
        "ref" => "feature/cla-race",
        "sha" => live_head_sha,
        "repo" => { "full_name" => repository, "id" => 10_001 }
      },
      "user" => { "id" => 20_002 }
    )
  else
    match = endpoint.match(%r{\Arepos/#{Regexp.escape(repository)}/contents/(.+)\?ref=[0-9a-f]{40}\z})
    unless match
      warn "gh: unexpected fake endpoint"
      exit 1
    end

    allowed_paths = [
      ".github/workflows/cla.yml",
      ".github/workflows/cla-policy-guard.yml",
      "scripts/ci/validate-cla-policy.rb",
      "CLA.md"
    ]
    path = match[1]
    unless allowed_paths.include?(path)
      warn "gh: unexpected fake content path"
      exit 1
    end
    if mode == "superseded"
      warn "gh: superseded validation must not fetch candidate content"
      exit 1
    end

    bytes = File.binread(File.join(root, path))
    emit.call(
      "type" => "file",
      "encoding" => "base64",
      "content" => Base64.strict_encode64(bytes)
    )
  end
RUBY

Case = Struct.new(:name, :mode, :success, :message, keyword_init: true)

cases = [
  Case.new(
    name: "matching immutable snapshot",
    mode: "matching",
    success: true,
    message: "PASS: CLA policy files are unchanged"
  ),
  Case.new(
    name: "superseded event head",
    mode: "superseded",
    success: true,
    message: SUPERSEDED_NOTICE
  ),
  Case.new(
    name: "malformed live head",
    mode: "malformed_head",
    success: false,
    message: GENERIC_REJECTION
  ),
  Case.new(
    name: "changed live base",
    mode: "changed_base",
    success: false,
    message: GENERIC_REJECTION
  ),
  Case.new(
    name: "GitHub API failure",
    mode: "api_failure",
    success: false,
    message: GENERIC_REJECTION
  )
]

failures = []
Dir.mktmpdir("cla-policy-stale-head") do |tmpdir|
  fake_bin = File.join(tmpdir, "bin")
  FileUtils.mkdir_p(fake_bin)
  fake_gh = File.join(fake_bin, "gh")
  File.write(fake_gh, FAKE_GH)
  FileUtils.chmod(0o755, fake_gh)

  cases.each do |test_case|
    env = {
      "PATH" => [fake_bin, ENV.fetch("PATH")].join(File::PATH_SEPARATOR),
      "GH_REPO" => REPOSITORY,
      "PR_NUMBER" => PR_NUMBER,
      "BASE_SHA" => BASE_SHA,
      "HEAD_SHA" => EVENT_HEAD_SHA,
      "FAKE_GH_REPOSITORY" => REPOSITORY,
      "FAKE_GH_ROOT" => ROOT,
      "FAKE_GH_MODE" => test_case.mode,
      "FAKE_GH_BASE_SHA" => BASE_SHA,
      "FAKE_GH_EVENT_HEAD_SHA" => EVENT_HEAD_SHA,
      "FAKE_GH_NEW_HEAD_SHA" => NEW_HEAD_SHA,
      "FAKE_GH_PR_NUMBER" => PR_NUMBER
    }
    stdout, stderr, status = Open3.capture3(env, "ruby", VALIDATOR)
    output = stdout + stderr

    if status.success? != test_case.success
      failures << "#{test_case.name}: expected success=#{test_case.success}, got exit #{status.exitstatus}"
    end
    failures << "#{test_case.name}: missing public result" unless output.include?(test_case.message)
    if test_case.success
      failures << "#{test_case.name}: emitted a rejection" if output.include?(GENERIC_REJECTION)
    else
      failures << "#{test_case.name}: exposed an internal diagnostic" if
        output.include?("not-a-commit") || output.include?("HTTP 500") || output.include?("changed while validating")
    end
    if test_case.mode == "superseded" && [BASE_SHA, EVENT_HEAD_SHA, NEW_HEAD_SHA].any? { |sha| output.include?(sha) }
      failures << "#{test_case.name}: exposed a revision in the public notice"
    end
  end
end

unless failures.empty?
  warn failures.join("\n")
  exit 1
end

puts "PASS: CLA policy superseded-run regression matrix (#{cases.length} cases)"
