#!/usr/bin/env bash
# The package-conventions-lint job (test-ios.yml): the mechanical namespace
# repair, a clean-checkout assertion that turns any safe rewrite into an
# actionable failure, then the non-mutating lint as the backstop.
#
#   scripts/ci/package-conventions-gate.sh [--pr]
#
# --pr: the checkout is a pull request's merge commit.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
logs="$(mktemp -d)"
trap 'rm -rf "$logs"' EXIT

if ! ./scripts/lint-ios-package-conventions.sh --namespace-fix 2>&1 | tee "$logs/fix.log"; then
  echo "::error::Namespace/convention lint failed. Run ./scripts/lint-ios-package-conventions.sh --namespace-fix locally, review the edits, then commit them."
  exit 1
fi
if ! git diff --quiet -- ios Packages; then
  echo "::error::Namespace lint found safe rewrites. Run ./scripts/lint-ios-package-conventions.sh --namespace-fix locally, review the edits, then commit them."
  git diff --stat -- ios Packages
  exit 1
fi
# Mechanical enforcement of the modular-refactor conventions over the iOS line
# (no singletons / Combine / locks / timer hacks / KVO / namespace-enums) plus
# the repo-wide namespace-type rule (no all-static "namespace" types in any
# package). Exits non-zero on any unjustified ERROR; sanctioned exceptions carry
# a lint:allow / TRANSITIONAL / carve-out marker, and pre-existing debt is
# grandfathered in the lint baseline files under scripts/.
./scripts/lint-ios-package-conventions.sh
