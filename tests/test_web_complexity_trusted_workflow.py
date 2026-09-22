#!/usr/bin/env python3
"""The trusted complexity check must not take Bun configuration from the tree it judges.

Bun loads bunfig.toml (including preload scripts) and .env from its working
directory. The workflow runs on pull_request_target, so a check started inside
the pull request's checkout would run that pull request's code.

The two check steps are compared whole. A list of forbidden shell forms
(`|| true`, `|| ( true )`, `set +e`, ...) can always be extended by one more
form; an exact step cannot be weakened without this test changing with it.
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
        "if": "github.event_name != 'push' && steps.scope.outputs.run == 'true'",
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
        "if": "github.event_name == 'push' && steps.scope.outputs.run == 'true'",
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
    workflow_text = WORKFLOW.read_text(encoding="utf-8")
    document = yaml.safe_load(workflow_text)
    job = document["jobs"]["complexity"]

    if "types: [opened, reopened, synchronize]" not in workflow_text or " edited," in workflow_text or "ready_for_review" in workflow_text:
        print("FAIL: trusted complexity must not retrigger for PR metadata edits or ready-state flips")
        return 1

    candidate_text = CANDIDATE_WORKFLOW.read_text(encoding="utf-8")
    pull_request_block = candidate_text.split("  pull_request:\n", 1)[1].split("  push:\n", 1)[0]
    if "    paths:\n      - web/**\n" not in pull_request_block:
        print("FAIL: contributor complexity workflow must only queue for web/** pull-request changes")
        return 1
    if ".github/workflows/web-complexity.yml" in pull_request_block:
        print("FAIL: editing the candidate workflow must not self-queue the candidate complexity job")
        return 1

    scope = next((step for step in job["steps"] if step.get("name") == "Detect complexity scope"), None)
    if scope is None or 'path.startswith("web/")' not in scope.get("run", ""):
        print("FAIL: trusted complexity must cheaply scope pull requests before web setup")
        return 1
    for step_name in (
        "Checkout trusted policy revision",
        "Verify trusted checkout",
        "Setup Bun",
        "Install trusted web tooling",
        "Create empty trusted Bun config",
    ):
        step = next(step for step in job["steps"] if step.get("name") == step_name)
        if step.get("if") != "steps.scope.outputs.run == 'true'":
            print(f"FAIL: {step_name} must skip unrelated pull requests")
            return 1
    if job.get("continue-on-error"):
        print("FAIL: the complexity job must not continue on error")
        return 1
    checks = [step for step in job["steps"] if "check-complexity.mjs" in str(step.get("run", "")) and "bun " in step["run"]]
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
