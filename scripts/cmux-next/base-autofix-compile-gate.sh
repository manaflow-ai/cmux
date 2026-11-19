#!/usr/bin/env bash
# Compiles a base autofix candidate that changes Swift before base-autofix-push.sh pushes it.
#
# 8f33d7030 (2026-11-17) was a base autofix commit that turned an enum into a struct
# (lint_swift_namespaces.py --fix) while another file still imported it with `import enum`.
# The push went straight to feat-cmux-next, and every compile of the base was red for hours.
# A repair that changes a Swift file therefore lands only after the build fleet compiles the
# exact candidate commit: fleet-compile-check.yml (the app executable, Debug) posts
# fleet/compile-check on it.
#
# Usage: scripts/cmux-next/base-autofix-compile-gate.sh REMOTE SHA
#   REMOTE: the push remote (its credentials come from the caller's GIT_CONFIG_* extraheader).
#   SHA: the candidate commit. The fleet fetches it from GitHub, so the gate first pushes it to a
#   staging branch, autofix-compile/<sha12> (no workflow runs on that name), and deletes that branch
#   when it has a verdict.
# Environment: COMPILE_GATE_TOKEN, a token with actions: write (the dispatch) and statuses: read;
#   GITHUB_REPOSITORY. CMUX_BASE_AUTOFIX_COMPILE_WAIT is the wait in seconds (default 2400).
#   The wait reads the status once a minute with the workflow token: at most 40 reads, and only in a run
#   whose repair changes Swift (rare: the namespace rewrite), against the budget every workflow shares
#   (tests/test_ci_no_github_token_polling.py).
# Exit: 0 the candidate compiled; 1 it did not compile; 2 no verdict (no token, refused push or
#   dispatch, an error status, or the wait ran out). The caller lands Swift changes only on 0.
set -uo pipefail
remote="${1:?usage: $0 REMOTE SHA}"
sha="${2:?usage: $0 REMOTE SHA}"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::compile gate: '$sha' is not a full commit sha" >&2; exit 2; }
repo="${GITHUB_REPOSITORY:-}"
token="${COMPILE_GATE_TOKEN:-}"
if [[ -z "$repo" || -z "$token" ]]; then
  echo "::error::compile gate: no COMPILE_GATE_TOKEN or GITHUB_REPOSITORY; no verdict for ${sha:0:12}" >&2
  exit 2
fi
ref="refs/heads/autofix-compile/${sha:0:12}"
if ! git push --quiet "$remote" "$sha:$ref"; then
  echo "::error::compile gate: could not push ${sha:0:12} to $ref for the fleet to fetch; no verdict" >&2
  exit 2
fi
trap 'git push --quiet "$remote" ":$ref" >/dev/null 2>&1 || true' EXIT
if ! GH_TOKEN="$token" gh workflow run fleet-compile-check.yml -R "$repo" --ref feat-cmux-next -f sha="$sha" >/dev/null; then
  echo "::error::compile gate: could not dispatch fleet-compile-check.yml for ${sha:0:12}; no verdict" >&2
  exit 2
fi
echo "Compile gate: the build fleet compiles ${sha:0:12} (fleet-compile-check.yml); waiting for fleet/compile-check."
deadline=$((SECONDS + ${CMUX_BASE_AUTOFIX_COMPILE_WAIT:-2400}))
while ((SECONDS < deadline)); do
  # The newest fleet/compile-check status on the candidate (GitHub lists statuses newest first).
  state="$(GH_TOKEN="$token" gh api "repos/$repo/commits/$sha/statuses?per_page=100" \
    --jq '[.[] | select(.context == "fleet/compile-check")][0].state // ""' 2>/dev/null)" || state=""
  case "$state" in
    success) echo "Compile gate: ${sha:0:12} compiled."; exit 0 ;;
    failure) echo "::error::compile gate: ${sha:0:12} does not compile (fleet/compile-check failure); its Swift changes are not pushed" >&2; exit 1 ;;
    error) echo "::error::compile gate: the build fleet gave no verdict for ${sha:0:12} (fleet/compile-check error)" >&2; exit 2 ;;
  esac
  sleep "${CMUX_BASE_AUTOFIX_COMPILE_POLL:-60}"
done
echo "::error::compile gate: no fleet/compile-check verdict for ${sha:0:12} within ${CMUX_BASE_AUTOFIX_COMPILE_WAIT:-2400} s" >&2
exit 2
