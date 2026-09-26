#!/usr/bin/env python3
"""Fail when a routing repository variable holds a value its reader ignores.

`gh variable set` changes CI routing without a pull request, so no PR check
ever sees the new value. The readers are forgiving on purpose: a malformed
CI_OWNED_POOL_SLOTS counts as zero minis and a forbidden runner label is
refused at dispatch, so a bad value shows up only as PRs quietly routed to
Blacksmith or lanes that never start. This runs the same validators the
readers use, on a schedule (.github/workflows/ci-repo-variables.yml), and turns
a bad value into a red run with an error annotation that names the fix.

Inputs, from the workflow's expression context (no token can read variables):
  CMUX_CI_RUNNER_VARIABLES  NAME=value per line, the runner-label variables
  CI_OWNED_POOL_SLOTS       the owned pool sizes pr_runner_pool.py reads
  CMUX_CI_XCODE_APP_PR      pairs a class entry in the slots with an Xcode
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from pr_runner_pool import PR_XCODE_VARIABLE, SLOTS_VARIABLE, slot_problems  # noqa: E402
from runner_label_policy import PolicyUnreadable, drifted_runner_variables  # noqa: E402

RUNNER_VARIABLES_ENV = "CMUX_CI_RUNNER_VARIABLES"


def parse_runner_variables(raw: str) -> dict[str, str]:
    variables: dict[str, str] = {}
    for line in raw.splitlines():
        if not line.strip():
            continue
        name, separator, value = line.strip().partition("=")
        if not separator or not name:
            raise ValueError(f"{RUNNER_VARIABLES_ENV} line {line.strip()!r} is not NAME=value")
        variables[name] = value
    return variables


def problems(env: dict[str, str]) -> list[str]:
    found: list[str] = []
    raw = env.get(RUNNER_VARIABLES_ENV, "")
    if not raw.strip():
        found.append(f"{RUNNER_VARIABLES_ENV} is empty: the workflow passed no runner variables to check")
    else:
        try:
            variables = {k: v for k, v in parse_runner_variables(raw).items() if v.strip()}
            for name, value, reason in drifted_runner_variables(variables):
                found.append(f"{name}={value!r}: {reason}")
        except (ValueError, PolicyUnreadable) as error:
            found.append(str(error))
    for problem in slot_problems(env.get(SLOTS_VARIABLE), env.get(PR_XCODE_VARIABLE)):
        found.append(
            f"{problem}. The picker counts that as no owned machines. "
            "Fix: build-fleet/mini-ops/set-owned-slots.sh in cmuxterm-hq"
        )
    return found


def main() -> int:
    found = problems(dict(os.environ))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    lines = [f"- {p}" for p in found] or ["- every checked repository variable reads as intended"]
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write("### Repository variables\n\n" + "\n".join(lines) + "\n")
    for problem in found:
        print(f"::error title=Repository variable::{problem}")
    if not found:
        print("repository variables: ok")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
