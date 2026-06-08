#!/usr/bin/env bash
# Ensures CI installs Bun through the retrying repo-owned installer, pinned to
# an explicit semver, instead of relying on setup-bun's short download retry.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

check_ci_job_bun_setup() {
  local job="$1" expected="$2"
  if ! awk -v job="$job" -v expected="$expected" '
    $0 ~ "^  "job":" { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }
    in_job && index($0, expected) { found=1 }
    END { exit(found ? 0 : 1) }
  ' .github/workflows/ci.yml; then
    echo "FAIL: $job in ci.yml must install Bun with: $expected" >&2
    exit 1
  fi
}

check_workflow_bun_setup() {
  local workflow="$1" expected="$2"
  local unexpected="$3"
  if grep -nF "$unexpected" "$workflow"; then
    echo "FAIL: $workflow runs Bun setup from web/, so it must use $expected" >&2
    exit 1
  fi
  if ! grep -Fq "$expected" "$workflow"; then
    echo "FAIL: $workflow must install Bun with: $expected" >&2
    exit 1
  fi
}

found_setup=0
while IFS= read -r workflow; do
  if grep -n 'uses: oven-sh/setup-bun@' "$workflow"; then
    echo "FAIL: $workflow must use scripts/ci/setup-bun-with-retry.sh instead of oven-sh/setup-bun" >&2
    exit 1
  fi

  while IFS=: read -r line_number _; do
    found_setup=1
    line="$(sed -n "${line_number}p" "$workflow")"
    if ! grep -Eq 'setup-bun-with-retry\.sh[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+([[:space:]]|$)' <<<"$line"; then
      echo "FAIL: $workflow:$line_number setup-bun-with-retry.sh must pin Bun to an explicit semver"
      exit 1
    fi
  done < <(grep -n 'setup-bun-with-retry\.sh' "$workflow" || true)
done < <(git -C "$ROOT_DIR" ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml')

if [[ "$found_setup" -eq 0 ]]; then
  echo "FAIL: no setup-bun-with-retry.sh workflow calls found" >&2
  exit 1
fi

check_ci_job_bun_setup "web-typecheck" "../scripts/ci/setup-bun-with-retry.sh 1.3.13"
check_ci_job_bun_setup "web-db-migrations" "../scripts/ci/setup-bun-with-retry.sh 1.3.13"
check_ci_job_bun_setup "react-apps-check" "./scripts/ci/setup-bun-with-retry.sh 1.3.13"
check_workflow_bun_setup ".github/workflows/cloud-vm-migrate.yml" "../scripts/ci/setup-bun-with-retry.sh 1.3.13" "run: ./scripts/ci/setup-bun-with-retry.sh"
check_workflow_bun_setup ".github/workflows/cloud-vm-smoke.yml" "../scripts/ci/setup-bun-with-retry.sh 1.3.13" "run: ./scripts/ci/setup-bun-with-retry.sh"

echo "PASS: Bun setup uses retrying semver-pinned installer"
