#!/usr/bin/env bash
# ACTIONS_RUNNER_HOOK_JOB_STARTED for the one-job GitHub Actions runner VMs on the fleet Macs (runner-guest.sh; README.md
# "GitHub Actions runner VMs"). Modelled on build-fleet/swift-linux-builder/lane-build-runners/fork-guard.sh: the same
# fail-closed shape, a stricter verdict (same repository only; runner_slots_test.py checks it refuses all the lane guard
# refuses) and no housekeeping hook after it: the VM is deleted when its
# one job ends. These runners carry only our labels (cmux-fleet-linux-x64, cmux-gcp-linux-arm64) and routing keeps
# fork PRs off them; this is the second line: a pull_request (or pull_request_target) job whose head is not this
# repository never runs here, since a guest reaches what its Mac reaches (README "Open questions", cmuxterm-hq#14966).
set -u
if [[ $OSTYPE == darwin* ]] && ((BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] >= 501)); then BASH_COMPAT=50; fi  # macOS heredoc pipe hang: tests/test_bash_heredoc_pipe_guard.py
case "${GITHUB_EVENT_NAME:-}" in
  pull_request|pull_request_target|pull_request_review|pull_request_review_comment)
    # Fail closed: the job runs only on an explicit "ok". An unreadable or unparsable payload, a missing python3 or
    # anything else the verdict block did not print "ok" for refuses the job.
    verdict=""
    if [ -r "${GITHUB_EVENT_PATH:-}" ]; then
      verdict=$(python3 - "$GITHUB_EVENT_PATH" "${GITHUB_REPOSITORY:-}" 2>/dev/null <<'PY'
import json, sys
event = json.load(open(sys.argv[1]))
repo = sys.argv[2].strip().lower()
pr = event.get("pull_request") if isinstance(event, dict) else None
head = ((pr.get("head") or {}).get("repo") or {}) if isinstance(pr, dict) else {}
name = (head.get("full_name") or "") if isinstance(head, dict) else ""
# Same repository only (coordinator, 2026-11-20): a PR job runs here only when its head IS this repository. A fork
# (a member's own included), another repository of the org, a deleted fork (head.repo null) and a payload with no
# pull_request all refuse. Stricter than the lane runners' guard: whatever that refuses, this refuses too.
if not repo or "/" not in repo:
    print("refuse a job with no GITHUB_REPOSITORY")
elif not isinstance(pr, dict) or not pr:
    print("refuse a pull request event with no pull_request")
elif not name:
    print("refuse a deleted fork or a head with no repository")
elif name.lower() != repo:
    print(f"refuse {name}")
else:
    print("ok")
PY
) || verdict=""
    fi
    case "$verdict" in
      ok) ;;
      refuse*) echo "::error::fleet Mac runner fork guard: a pull request from ${verdict#refuse } (not this repository) does not run on a fleet Mac runner VM; re-run it on Blacksmith"; exit 1 ;;
      *) echo "::error::fleet Mac runner fork guard: the pull request event payload (${GITHUB_EVENT_PATH:-unset}) could not be read or judged, so this job does not run on a fleet Mac runner VM; re-run it on Blacksmith"; exit 1 ;;
    esac ;;
esac
exit 0
