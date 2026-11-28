#!/usr/bin/env bash
# The privacy and egress registries, judged on the change that edits the code they list: egress_scan_guards.sh
#
# docs/privacy.md, config/network/allowlist.json, tests/egress_ungated.json and tests/egress_seeded.json each list
# what NEXT's source does (an outbound host, a connectivity host, an egress gate site, a seeded-secret test). These
# four tests live in ci-guards.yml's `ci` group, which a feat-cmux-next pull request never runs (fast-guards skips
# that base) and guard-steps-reached routes only on workflow, script and test changes, so a Swift or Rust change
# that adds a host or site merged green and the tip went red: 5 fix-forwards in the 7 days to 11-28 (#57217,
# #58104, #58409, #59244, #57325). ci/steps.toml `egress-scan-guards` runs them on the landing head of any change
# to the scanned source or a registry, each through new_red_only.sh so a red the base already has only warns.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
export CMUX_GUARDS_BASE_SHA="${CMUX_GUARDS_BASE_SHA:-$(git rev-parse -q --verify 'HEAD^1^{commit}' 2>/dev/null || true)}"
rc=0
for t in test_outbound_hosts test_network_allowlist test_egress_gate test_egress_seeded; do
  echo "::group::$t"
  scripts/ci/new_red_only.sh "$t" -- python3 "tests/$t.py" || rc=1
  echo "::endgroup::"
done
exit "$rc"
