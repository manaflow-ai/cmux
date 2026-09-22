#!/usr/bin/env python3
"""The trusted complexity check must not take Bun configuration from the tree it judges.

Bun loads bunfig.toml (including preload scripts) and .env from its working
directory. The workflow runs on pull_request_target, so a check started inside
the pull request's checkout would run that pull request's code.

The two check steps are compared whole. A list of forbidden shell forms
(`|| true`, `|| ( true )`, `set +e`, ...) can always be extended by one more
form; an exact step cannot be weakened without this test changing with it.

The pull-request check is also allowed to be skipped when the pull request
changes no file under web/, because the tree it would read is then identical to
the base whose baseline it is compared against. That decision has to be made
from the base branch without reading the candidate, so the step producing it is
checked here too: it may only run for pull_request_target, must not check
anything out, and must reach its conclusion through the API alone.
"""

from __future__ import annotations

import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "web-complexity-trusted.yml"
CANDIDATE_WORKFLOW = ROOT / ".github" / "workflows" / "web-complexity.yml"

# --config takes its value with "=". As a separate argument Bun runs the config
# file as the script, exits 0, and the check never happens.
BUN = 'bun --no-env-file --config="$GITHUB_WORKSPACE/trusted/.bunfig-empty.toml" scripts/check-complexity.mjs'

EXPECTED_CHECKS = [
    {
        "name": "Check pull-request or merge-group source with trusted policy",
        "if": "github.event_name != 'push' && steps.web-changes.outputs.skip != 'true'",
        "working-directory": "trusted/web",
        "run": (
            "set -euo pipefail\n"
            f"{BUN} \\\n"
            '  --repo-root "$GITHUB_WORKSPACE/candidate" \\\n'
            '  --tool-root "$GITHUB_WORKSPACE/trusted" \\\n'
            '  --base-baseline "$GITHUB_WORKSPACE/trusted/web/oxlint-complexity-baseline.txt" \\\n'
            '  --head "$CANDIDATE_SHA"\n'
        ),
    },
    {
        "name": "Check main push with trusted policy",
        "if": "github.event_name == 'push'",
        "working-directory": "trusted/web",
        "env": {"BEFORE_SHA": "${{ github.event.before }}", "HEAD_SHA": "${{ github.sha }}"},
        "run": (
            "set -euo pipefail\n"
            'if [ -n "${BEFORE_SHA:-}" ] && [ "$BEFORE_SHA" != "0000000000000000000000000000000000000000" ]; then\n'
            f'  {BUN} --base "$BEFORE_SHA" --head "$HEAD_SHA"\n'
            "else\n"
            f"  {BUN}\n"
            "fi\n"
        ),
    },
]


def main() -> int:
    document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    job = document["jobs"]["complexity"]

    candidate_text = CANDIDATE_WORKFLOW.read_text(encoding="utf-8")
    pull_request_block = candidate_text.split("  pull_request:\n", 1)[1].split("  push:\n", 1)[0]
    if "    paths:\n      - web/**\n" not in pull_request_block:
        print("FAIL: contributor complexity workflow must only queue for web/** pull-request changes")
        return 1
    if ".github/workflows/web-complexity.yml" in pull_request_block:
        print("FAIL: editing the candidate workflow must not self-queue the candidate complexity job")
        return 1
    if job.get("continue-on-error"):
        print("FAIL: the complexity job must not continue on error")
        return 1
    steps = job["steps"]
    detectors = [step for step in steps if step.get("id") == "web-changes"]
    if len(detectors) != 1:
        print("FAIL: the trusted workflow must have exactly one web-changes detection step")
        return 1
    detect = detectors[0]
    if detect.get("if") != "github.event_name == 'pull_request_target'":
        print("FAIL: web-change detection must only run for pull_request_target")
        return 1
    if "uses" in detect or "checkout" in str(detect.get("run", "")):
        print("FAIL: web-change detection must not check out any tree")
        return 1
    if "github.event.pull_request" in str(detect.get("run", "")):
        print("FAIL: web-change detection must not interpolate pull-request fields into its script")
        return 1
    if "--paginate" not in str(detect.get("run", "")):
        print("FAIL: web-change detection must read every page of the pull request's files")
        return 1
    # The gate has to be the detector's own output, and it has to fail open:
    # anything other than a positive "skip" still runs the check.
    gate = "steps.web-changes.outputs.skip != 'true'"
    guarded = [step for step in steps if gate in str(step.get("if", ""))]
    if len(guarded) < 6:
        print("FAIL: the expensive trusted steps must all be gated on the web-change detector")
        return 1
    if detect["if"].startswith("$") or any(
        "outputs.skip ==" in str(step.get("if", "")) for step in steps
    ):
        print("FAIL: the web-change gate must fail open, skipping only on an explicit skip=true")
        return 1

    checks = [step for step in steps if "check-complexity.mjs" in str(step.get("run", "")) and "bun " in step["run"]]
    if checks != EXPECTED_CHECKS:
        print(
            "FAIL: the complexity check steps changed. They must run from trusted/web, start Bun with "
            "--no-env-file and the empty --config=, and fail the job when the check fails. "
            "Update EXPECTED_CHECKS in the same reviewed change."
        )
        return 1
    print("PASS: trusted web complexity runs from the trusted checkout with an empty Bun config")
    return 0


if __name__ == "__main__":
    sys.exit(main())
