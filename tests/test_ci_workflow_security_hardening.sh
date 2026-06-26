#!/usr/bin/env bash
# Guards the GitHub Actions hardening from issue #5979:
# - no checkout step persists credentials by default
# - no workflow grants write/OIDC scopes at top level
# - release-only write/OIDC scopes stay on the jobs that publish/sign
# - the Claude action remains pinned to a full commit SHA
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_DIR="$ROOT_DIR/.github/workflows"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for workflow in "$WORKFLOW_DIR"/*.yml; do
  awk '
    function finish_checkout() {
      if (in_checkout && !saw_persist_false) {
        printf "%s:%d checkout must set persist-credentials: false\n", FILENAME, checkout_line
        failed=1
      }
      in_checkout=0
      saw_persist_false=0
    }
    /^[[:space:]]*-[[:space:]]+name:/ { finish_checkout() }
    /uses:[[:space:]]+actions\/checkout@/ {
      finish_checkout()
      in_checkout=1
      checkout_line=NR
      next
    }
    in_checkout && /persist-credentials:[[:space:]]+false/ {
      saw_persist_false=1
    }
    END {
      finish_checkout()
      exit failed ? 1 : 0
    }
  ' "$workflow" || fail "$(basename "$workflow") has a checkout with persisted credentials"
done

if awk '
  /^permissions:/ { in_permissions=1; next }
  in_permissions && /^[^[:space:]]/ { in_permissions=0 }
  in_permissions && /^[[:space:]]+[A-Za-z0-9_-]+:[[:space:]]+write[[:space:]]*$/ {
    printf "%s:%d top-level write permission: %s\n", FILENAME, NR, $0
    failed=1
  }
  END { exit failed ? 0 : 1 }
' "$WORKFLOW_DIR"/*.yml; then
  fail "workflow-level write permissions must stay job-scoped"
fi

grep -Eq 'uses: anthropics/claude-code-action@[0-9a-f]{40}([[:space:]]|$)' \
  "$WORKFLOW_DIR/claude.yml" \
  || fail "claude.yml must pin anthropics/claude-code-action to a full commit SHA"

for workflow in nightly.yml release.yml; do
  for permission in "contents: write" "attestations: write" "id-token: write"; do
    grep -Fq "$permission" "$WORKFLOW_DIR/$workflow" \
      || fail "$workflow must retain job-scoped $permission for publishing"
  done
done

if grep -Fq "git ls-remote origin refs/heads/main" "$WORKFLOW_DIR/nightly.yml"; then
  fail "nightly.yml HEAD checks must not rely on checkout-persisted origin credentials"
fi
nightly_head_checks="$(grep -Fc 'gh api "repos/${GITHUB_REPOSITORY}/git/ref/heads/main"' "$WORKFLOW_DIR/nightly.yml")"
[ "$nightly_head_checks" -eq 2 ] \
  || fail "nightly.yml must use authenticated gh api lookups for both current-main HEAD checks"
nightly_head_tokens="$(grep -Fc 'GH_TOKEN: ${{ github.token }}' "$WORKFLOW_DIR/nightly.yml")"
[ "$nightly_head_tokens" -ge 2 ] \
  || fail "nightly.yml current-main HEAD checks must set GH_TOKEN"

for permission in "contents: read" "id-token: write"; do
  count="$(grep -Fc "$permission" "$WORKFLOW_DIR/cloud-vm-migrate.yml")"
  [ "$count" -ge 2 ] || fail "cloud-vm-migrate.yml must grant $permission on migration jobs"
done

grep -Fq 'zizmor: ignore[dangerous-triggers]' "$WORKFLOW_DIR/update-homebrew.yml" \
  || fail "update-homebrew.yml must document the guarded workflow_run trust boundary"
grep -Fq 'WORKFLOW_RUN_HEAD_REPOSITORY' "$WORKFLOW_DIR/update-homebrew.yml" \
  || fail "update-homebrew.yml must validate the workflow_run repository"
grep -Fq 'WORKFLOW_RUN_EVENT' "$WORKFLOW_DIR/update-homebrew.yml" \
  || fail "update-homebrew.yml must validate the triggering workflow event"
grep -Fq 'x-access-token:${HOMEBREW_TAP_TOKEN}@github.com/manaflow-ai/homebrew-cmux.git' \
  "$WORKFLOW_DIR/update-homebrew.yml" \
  || fail "update-homebrew.yml must push with an explicit tokenized URL after checkout credentials are disabled"
if grep -Eq '>>[[:space:]]+\$GITHUB_OUTPUT' "$WORKFLOW_DIR/update-homebrew.yml"; then
  fail "update-homebrew.yml must quote GITHUB_OUTPUT writes"
fi

echo "PASS: GitHub Actions workflow security hardening guards hold"
