#!/usr/bin/env bash
# The package-conventions-lint job (test-ios.yml): the mechanical namespace
# repair, a clean-checkout assertion that turns any safe rewrite into an
# actionable failure, then the non-mutating lint as the backstop.
#
#   scripts/ci/package-conventions-gate.sh [--pr]
#
# --pr: the checkout is a pull request's merge commit, and only findings in the
# files the PR changes fail it (scripts/ci/pr_owned_findings.py). One violation
# that reached the base branch used to fail every PR that touched Packages/.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
pr=false
[ "${1:-}" = --pr ] && pr=true

logs="$(mktemp -d)"
trap 'rm -rf "$logs"' EXIT
status=0
if ! ./scripts/lint-ios-package-conventions.sh --namespace-fix 2>&1 | tee "$logs/fix.log"; then
  echo "::error::Namespace/convention lint failed. Run ./scripts/lint-ios-package-conventions.sh --namespace-fix locally, review the edits, then commit them."
  [ "$pr" = true ] || exit 1
  status=1
fi
git diff --name-only -- ios Packages > "$logs/fixed.txt"
if [ -s "$logs/fixed.txt" ]; then
  echo "::error::Namespace lint found safe rewrites. Run ./scripts/lint-ios-package-conventions.sh --namespace-fix locally, review the edits, then commit them."
  git diff --stat -- ios Packages
  [ "$pr" = true ] || exit 1
  status=1
fi
# Mechanical enforcement of the modular-refactor conventions over the iOS line
# (no singletons / Combine / locks / timer hacks / KVO / namespace-enums) plus
# the repo-wide namespace-type rule (no all-static "namespace" types in any
# package). Exits non-zero on any unjustified ERROR; sanctioned exceptions carry
# a lint:allow / TRANSITIONAL / carve-out marker, and pre-existing debt is
# grandfathered in the lint baseline files under scripts/.
if [ "$pr" = false ]; then
  ./scripts/lint-ios-package-conventions.sh
  exit
fi
./scripts/lint-ios-package-conventions.sh 2>&1 | tee "$logs/lint.log" || status=1
[ "$status" = 0 ] && exit 0
python3 scripts/ci/pr_owned_findings.py \
  --finding '^ERROR\s+\S+\s+(?P<path>[^:\s]+):\d+' \
  --rules '^(scripts/(lint-ios-package-conventions\.sh|lint_swift_namespaces\.py|swift_source_mask\.py|ci/package-conventions-gate\.sh|ci/pr_owned_findings\.py)|\.github/workflows/test-ios\.yml)$' \
  --baselines '^scripts/(lint-ios-package-conventions-baseline|lint-namespace-types-(baseline|ratchet))\.txt$' \
  --fixed "$logs/fixed.txt" \
  "$logs/fix.log" "$logs/lint.log"
