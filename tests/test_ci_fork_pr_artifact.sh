#!/usr/bin/env bash
# Regression test for https://github.com/manaflow-ai/cmux/issues/5976.
# The "Fork PR artifact" workflow gives maintainers a self-serve, secret-safe
# way to build a downloadable macOS app artifact from an explicitly approved
# fork PR head SHA. This guard locks the security-critical properties so a
# future edit cannot silently turn it into a fork-code-runs-with-secrets path:
#   - it is workflow_dispatch only (no pull_request/push trigger that an
#     untrusted fork could fire),
#   - it builds the exact reviewed head SHA (validated as a full 40-char SHA),
#   - checkout pins that SHA and never persists credentials,
#   - the build stays unsigned and on a paid macOS runner, and
#   - it uploads the app artifact.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WF="$ROOT_DIR/.github/workflows/fork-pr-artifact.yml"

fail() {
  echo "FAIL: $1"
  exit 1
}

[[ -f "$WF" ]] || fail "fork-pr-artifact.yml workflow is missing"

# 1. Trigger must be workflow_dispatch ONLY. A pull_request or push trigger
#    would let untrusted fork code run with repo context before approval.
if ! awk '
  /^on:/ { in_on=1; next }
  in_on && /^[^[:space:]#]/ { in_on=0 }
  in_on && /^[[:space:]]+workflow_dispatch:/ { saw_dispatch=1 }
  in_on && /^[[:space:]]+(pull_request|pull_request_target|push):/ { saw_bad=1 }
  END { exit !(saw_dispatch && !saw_bad) }
' "$WF"; then
  fail "workflow must trigger on workflow_dispatch only (no pull_request/push)"
fi

# 2. Must require the reviewed head SHA as an input.
grep -Eq '^[[:space:]]+head_sha:' "$WF" \
  || fail "workflow must expose a head_sha input"

# 3. Must validate that head_sha is a full 40-character commit SHA so the build
#    target is exact and cannot be a movable branch name.
grep -Fq '^[0-9a-f]{40}$' "$WF" \
  || fail "workflow must validate head_sha is a full 40-character commit SHA"

# 4. Every checkout must pin the approved SHA and must not persist credentials
#    (fork build scripts must never see the workflow token). Assert each
#    checkout step's own `with:` block carries both properties.
if ! awk '
  /uses: actions\/checkout@/ { in_co=1; pinned=0; nocreds=0; total++; next }
  in_co && /ref: \$\{\{ needs\.verify-sha\.outputs\.sha \}\}/ { pinned=1 }
  in_co && /persist-credentials: false/ { nocreds=1 }
  in_co && /^[[:space:]]*- name:/ { if (pinned && nocreds) good++; in_co=0 }
  END {
    if (in_co && pinned && nocreds) good++
    exit !(total >= 2 && good == total)
  }
' "$WF"; then
  fail "every actions/checkout must pin ref to the verified SHA and set persist-credentials: false"
fi

# 5. The build must stay unsigned (no release secrets needed before approval).
grep -Fq 'CODE_SIGNING_ALLOWED=NO' "$WF" \
  || fail "app build must stay unsigned (CODE_SIGNING_ALLOWED=NO)"

# 5b. No Actions cache at all. ACTIONS_RUNTIME_TOKEN is present in any job that
#     uploads artifacts, so even a restore-only cache action is not enough —
#     fork-authored build code could call the cache API directly and poison a
#     cache scope that trusted CI/release builds restore (spm-*, zig-packages-*,
#     ghosttykit-*). This workflow must never reference the shared cache
#     namespace; it rebuilds cold instead.
if grep -Eq 'uses:[[:space:]]*actions/cache' "$WF"; then
  fail "fork build must not use any actions/cache action (cache poisoning risk); build cold instead"
fi

# 5c. The artifact must be release-equivalent: assert the app was built against
#     the macOS 26 SDK (matches CI's release-build), so runner/Xcode drift
#     cannot publish a non-release-equivalent fork artifact.
grep -Fq '[[ "$SDK_VERSION" == 26.* ]]' "$WF" \
  || fail "app validation must assert the macOS 26 SDK (SDK_VERSION == 26.*) like release-build"

# 6. Both macOS jobs must run on a paid macOS runner, never a free GitHub runner.
for job in ghostty-cli-helper build-app; do
  if ! awk -v job="$job" '
    $0 ~ "^  "job":" { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }
    in_job && /runs-on:.*(vars\.MACOS_RUNNER|blacksmith-[0-9]+vcpu-macos-|warp-macos-[0-9]+-arm64|depot-macos-)/ { saw=1 }
    END { exit !saw }
  ' "$WF"; then
    fail "$job must run on a paid macOS runner (vars.MACOS_RUNNER_* or a Blacksmith/Warp/Depot label)"
  fi
done

# 7. Must upload the built app as an artifact.
if ! awk '
  /- name: Upload unsigned app artifact/ { in_step=1; next }
  in_step && /^[[:space:]]*- name:/ { in_step=0 }
  in_step && /uses: actions\/upload-artifact@/ { saw_action=1 }
  in_step && /if-no-files-found:[[:space:]]*error/ { saw_required=1 }
  END { exit !(saw_action && saw_required) }
' "$WF"; then
  fail "workflow must upload the unsigned app as a required artifact"
fi

echo "PASS: fork-pr-artifact.yml is a maintainer-gated, SHA-pinned, unsigned artifact path"
