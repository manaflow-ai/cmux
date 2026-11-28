#!/usr/bin/env bash
# take-canonical-root.sh
#
# Hold the canonical root before a persistent runner clears or replaces it.
# Glaeda owns the root-to-token mapping; this helper never infers a root from
# RUNNER_NAME. If the runner hook already holds a different root, its export is
# missing and this command fails closed rather than touching an unknown path.
set -euo pipefail

root="${CMUX_CI_CANONICAL_ROOT:-/private/tmp/cmux-ci}"
helper="${CMUX_CI_CANONICAL_ROOT_HELPER:-/Users/Shared/cmux-build-fleet/bin/glaeda-canonical-root}"

case "$root" in
  /private/tmp/cmux-ci|/private/tmp/cmux-ci-[2-9]|/private/tmp/cmux-ci-[1-9][0-9]) ;;
  *) echo "take-canonical-root: unexpected requested root $root" >&2; exit 1 ;;
esac

if [ -x "$helper" ]; then
  status=0
  "$helper" take "$root" --wait "${CMUX_CI_CANONICAL_ROOT_WAIT_SECONDS:-1800}" >/dev/null || status=$?
  case "$status" in
    0) ;;
    2) echo "take-canonical-root: controller holds a different root; canonical-root export is required" >&2; exit 1 ;;
    *) echo "take-canonical-root: could not hold a canonical root (helper exit $status)" >&2; exit 1 ;;
  esac
elif [[ "${CMUX_PRODUCT_RUNNER:-}" == glaeda-* ]]; then
  echo "take-canonical-root: owned runner has no Glaeda root helper" >&2
  exit 1
fi

printf '%s\n' "$root"
