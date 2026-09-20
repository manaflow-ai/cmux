#!/usr/bin/env python3
"""The trusted complexity check must not take Bun configuration from the tree it judges.

Bun loads bunfig.toml (including preload scripts) and .env from its working
directory. The workflow runs on pull_request_target, so a check started inside
the pull request's checkout would run that pull request's code.
"""

from __future__ import annotations

import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "web-complexity-trusted.yml"
ISOLATION = '--no-env-file --config="$GITHUB_WORKSPACE/trusted/.bunfig-empty.toml" scripts/check-complexity.mjs'


def main() -> int:
    document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    checks = [
        step
        for job in document["jobs"].values()
        for step in job["steps"]
        if any(
            line.strip().startswith("bun ") and "check-complexity.mjs" in line
            for line in str(step.get("run", "")).splitlines()
        )
    ]
    if len(checks) < 2:
        print("FAIL: expected a pull-request check and a push check in web-complexity-trusted.yml")
        return 1
    for step in checks:
        name = step.get("name", "?")
        if step.get("working-directory") != "trusted/web":
            print(f"FAIL: '{name}' must run from trusted/web, not from the checkout it judges")
            return 1
        invocations = [line.strip() for line in step["run"].splitlines() if line.strip().startswith("bun ")]
        loose = [line for line in invocations if not line.startswith(f"bun {ISOLATION}")]
        if not invocations or loose:
            print(f"FAIL: '{name}' must start every check with: bun {ISOLATION}")
            return 1
    print("PASS: trusted web complexity runs from the trusted checkout with an empty Bun config")
    return 0


if __name__ == "__main__":
    sys.exit(main())
