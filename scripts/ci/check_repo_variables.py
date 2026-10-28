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
  CI_CLOUD_OVERFLOW_SAVED   the cloud overflow switch's record, present while
                            Blacksmith overflow is off (cloud_overflow_switch.py)
  CI_NEXT_DAEMON_POOL       the pool of feat-cmux-next's daemon tests, which gate
                            the nightly-next promotion (cmux-tui-artifacts.yml)
  CI_PIN_DAEMON_POOL        the pool of cmux-tui-pin-* pushes' daemon tests; empty,
                            they take CI_LIGHT_LANE_RUNNER (cmux-tui-artifacts.yml)

While that record exists, a runner variable holding exactly the failover the
switch wrote there is expected, not drift: an owned pool label in
MACOS_RUNNER_* is otherwise refused.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from pr_runner_pool import PR_XCODE_VARIABLE, SLOTS_VARIABLE, slot_problems  # noqa: E402
from runner_label_policy import HOSTED_MACOS_LABEL, PolicyUnreadable, drifted_runner_variables  # noqa: E402
from cloud_overflow_switch import (RECORD_VARIABLE, TRUSTED_BLACKSMITH_LABELS, TRUSTED_VARIABLE,  # noqa: E402
                                   parse_record)

RUNNER_VARIABLES_ENV = "CMUX_CI_RUNNER_VARIABLES"
DAEMON_POOL_VARIABLE = "CI_NEXT_DAEMON_POOL"
SIDE_LANE_VARIABLE = "CI_SIDE_LANE_RUNNER"
PIN_POOL_VARIABLE = "CI_PIN_DAEMON_POOL"
LIGHT_LANE_VARIABLE = "CI_LIGHT_LANE_RUNNER"


def parse_runner_variables(raw: str) -> dict[str, str]:
    variables: dict[str, str] = {}
    for line in raw.splitlines():
        if not line.strip():
            continue
        name, separator, value = line.strip().partition("=")
        if not separator or not name:
            raise ValueError(f"{RUNNER_VARIABLES_ENV} line {line.strip()!r} is not NAME=value")
        if name in variables:
            raise ValueError(f"{RUNNER_VARIABLES_ENV} repeats {name}: a variable's value spans lines")
        variables[name] = value
    return variables


def pin_pool_findings(pin_pool: str, daemon_pool: str, variables: dict[str, str]) -> tuple[list[str], list[str]]:
    """(problems, warnings) for the pool of cmux-tui-pin-* pushes' daemon tests.

    2026-10-21: every merged pull request pushes a cmux-tui-pin-* branch, and
    its daemon tests flooded the pull request side lane; on CI_NEXT_DAEMON_POOL
    they queue ahead of the tests that gate nightly-next. A set
    CI_PIN_DAEMON_POOL equal to either fails, and so does the light-lane
    fallback equal to the side lane. The fallback equal to CI_NEXT_DAEMON_POOL
    only warns: the light minis serve both until promotion gets its own label
    (claude-sr2). Empty values match nothing.
    """
    side = variables.get(SIDE_LANE_VARIABLE, "").strip()
    fix = f"Fix: set {PIN_POOL_VARIABLE} to a pool neither {DAEMON_POOL_VARIABLE} nor {SIDE_LANE_VARIABLE} uses"
    if pin_pool:
        for other, label, why in (
            (DAEMON_POOL_VARIABLE, daemon_pool, "ahead of the daemon tests that gate the nightly-next promotion"),
            (SIDE_LANE_VARIABLE, side, "in the pull request side lane"),
        ):
            if label and pin_pool == label:
                return [f"{PIN_POOL_VARIABLE}={pin_pool!r} is also {other}, so every cmux-tui-pin-* push queues "
                        f"its daemon tests {why}. {fix}"], []
        return [], []
    light = variables.get(LIGHT_LANE_VARIABLE, "").strip()
    via = f"{LIGHT_LANE_VARIABLE}={light!r} ({PIN_POOL_VARIABLE} is empty, so cmux-tui-pin-* daemon tests take it)"
    if light and light == side:
        return [f"{via} is also {SIDE_LANE_VARIABLE}, so every cmux-tui-pin-* push queues its daemon tests "
                f"in the pull request side lane. {fix}"], []
    if light and light == daemon_pool:
        return [], [f"{via} is also {DAEMON_POOL_VARIABLE}: pin pushes share {light!r} with the daemon tests "
                    f"that gate the nightly-next promotion. {fix}"]
    return [], []


def warnings(env: dict[str, str]) -> list[str]:
    """Shared pools that do not fail the run yet (pin_pool_findings)."""
    try:
        variables = {k: v for k, v in parse_runner_variables(env.get(RUNNER_VARIABLES_ENV, "")).items() if v.strip()}
    except ValueError:
        return []  # problems() reports it
    return pin_pool_findings(env.get(PIN_POOL_VARIABLE, "").strip(), env.get(DAEMON_POOL_VARIABLE, "").strip(),
                             variables)[1]


def problems(env: dict[str, str]) -> list[str]:
    found: list[str] = []
    try:
        record = parse_record(env.get(RECORD_VARIABLE))
    except ValueError as error:
        record = None
        found.append(f"{RECORD_VARIABLE}: {error}; the switch cannot turn overflow back on. "
                     "Fix: restore the values it names by hand and delete it")
    switched = {name: change.get("after") for name, change in ((record or {}).get("changed") or {}).items()
                if isinstance(change, dict)}
    raw = env.get(RUNNER_VARIABLES_ENV, "")
    if not raw.strip():
        found.append(f"{RUNNER_VARIABLES_ENV} is empty: the workflow passed no runner variables to check")
    else:
        try:
            variables = {k: v for k, v in parse_runner_variables(raw).items() if v.strip()}
            daemon_pool = env.get(DAEMON_POOL_VARIABLE, "").strip()
            if daemon_pool and daemon_pool == variables.get(SIDE_LANE_VARIABLE, "").strip():
                # 2026-10-21: both named glaeda-side-std; the daemon tests queued 3 h behind
                # pull request side lanes and no nightly-next was promoted.
                found.append(f"{DAEMON_POOL_VARIABLE}={daemon_pool!r} is also {SIDE_LANE_VARIABLE}, so the daemon tests "
                             "that gate the nightly-next promotion queue behind pull request side lanes. "
                             "Fix: point it at a pool pull requests do not fill, or clear it for the promote pool")
            found.extend(pin_pool_findings(env.get(PIN_POOL_VARIABLE, "").strip(), daemon_pool, variables)[0])
            for name, value, reason in drifted_runner_variables(variables):
                if switched.get(name) == value and not HOSTED_MACOS_LABEL.search(value.strip().lower()):
                    continue  # the overflow switch's failover while Blacksmith is down; never a hosted Mac
                found.append(f"{name}={value!r}: {reason}")
            trusted = variables.get(TRUSTED_VARIABLE, "").strip()
            if trusted and trusted != "ubuntu-24.04" and trusted not in TRUSTED_BLACKSMITH_LABELS:
                # Its readers accept only these, so any other value silently falls back to Blacksmith 4 vCPU.
                found.append(f"{TRUSTED_VARIABLE}={trusted!r}: its readers accept only ubuntu-24.04, "
                             + ", ".join(sorted(TRUSTED_BLACKSMITH_LABELS)) + "; anything else falls back")
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
    warned = warnings(dict(os.environ))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    lines = [f"- {p}" for p in found] or ["- every checked repository variable reads as intended"]
    lines += [f"- warning: {w}" for w in warned]
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write("### Repository variables\n\n" + "\n".join(lines) + "\n")
    for warning in warned:
        print(f"::warning title=Repository variable::{warning}")
    for problem in found:
        print(f"::error title=Repository variable::{problem}")
    if not found:
        print("repository variables: ok")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
