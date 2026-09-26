#!/usr/bin/env python3
"""Which runner labels this repository may use, applied to values rather than text.

`tests/test_ci_self_hosted_guard.sh` already decides this for workflow *text*:
`check_no_self_hosted_fleet_runners` refuses a `runs-on:` naming a physical
fleet host, a Tart VM, or a paid label outside the approved set. Every guard in
this repository works the same way, on files.

Runner choice does not live in files. It lives in `MACOS_RUNNER_*` repository
variables, and a variable's value never appears in a diff, so none of those
guards can see it. `warp-macos-26-arm64-12x` sat in the release and large-nightly runner
variables from 2026-09-20 to 2026-09-23 even though
the guard rejects that exact label on sight -- it matches the `macos-26` fleet
pattern and is absent from the allow-list.

This module applies the guard's own patterns to a label value. It does not keep
a second copy of them: it reads them out of the guard script, and
`tests/test_runner_label_policy.py` fails if that read stops working, so the
two cannot drift apart.
"""

from __future__ import annotations

import re
from functools import cache
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUARD_SCRIPT = ROOT / "tests" / "test_ci_self_hosted_guard.sh"


class PolicyUnreadable(RuntimeError):
    """The guard script no longer declares a pattern this module needs.

    Raised rather than falling back to a built-in copy: a silently stale
    pattern would report "no drift" forever, which is worse than not running.
    """


GUARD_FUNCTION = "check_no_self_hosted_fleet_runners"


def _guard_function(source: str) -> str:
    """The body of the guard function that owns the patterns.

    Reading only this body is what stops a same-named local elsewhere in the
    2000-line script from being taken for the policy.
    """
    match = re.search(rf"^{GUARD_FUNCTION}\(\) \{{\n(.*?)^\}}", source, re.M | re.S)
    if match is None:
        raise PolicyUnreadable(
            f"{GUARD_SCRIPT.name} no longer defines `{GUARD_FUNCTION}`; "
            f"runner label policy cannot be read from it"
        )
    return match.group(1)


def _shell_local(body: str, name: str) -> str:
    """The single-quoted value of the one `local <name>='...'` in a function.

    Any other assignment to the name (`name+=...`, a second `local`) raises:
    reading only the first piece of a pattern built in several steps would
    narrow the policy without anything failing.
    """
    assignments = re.findall(rf"^\s*(?:local\s+)?{re.escape(name)}\+?=", body, re.M)
    match = re.search(rf"^\s*local {re.escape(name)}='([^']*)'\s*$", body, re.M)
    if match is None or len(assignments) != 1:
        raise PolicyUnreadable(
            f"{GUARD_SCRIPT.name} no longer declares `{name}` as exactly one "
            f"`local {name}='...'` in {GUARD_FUNCTION}; runner label policy "
            f"cannot be read from it"
        )
    return match.group(1)


@cache
def _patterns() -> tuple[re.Pattern[str], re.Pattern[str], re.Pattern[str]]:
    """The guard's fleet, allowed and self-hosted patterns, compiled.

    A guard file that cannot be read or a pattern Python cannot compile raises
    PolicyUnreadable like any other unreadable policy, so the report says so
    instead of failing outright.
    """
    try:
        body = _guard_function(GUARD_SCRIPT.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError) as error:
        raise PolicyUnreadable(f"{GUARD_SCRIPT.name} could not be read: {error}") from error
    compiled = []
    for name in ("fleet", "allowed", "selfhosted"):
        try:
            compiled.append(re.compile(f"({_shell_local(body, name)})"))
        except re.error as error:
            raise PolicyUnreadable(
                f"{GUARD_SCRIPT.name} declares a `{name}` pattern Python cannot compile: {error}"
            ) from error
    return compiled[0], compiled[1], compiled[2]


@cache
def _owned_pattern() -> re.Pattern[str]:
    """The guard's owned pool label shape (glaeda-std-xcode-26.6), compiled."""
    try:
        body = _guard_function(GUARD_SCRIPT.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError) as error:
        raise PolicyUnreadable(f"{GUARD_SCRIPT.name} could not be read: {error}") from error
    try:
        return re.compile(f"({_shell_local(body, 'owned')})")
    except re.error as error:
        raise PolicyUnreadable(
            f"{GUARD_SCRIPT.name} declares an `owned` pattern Python cannot compile: {error}"
        ) from error


POOL_ORDER_VARIABLE = "CI_PR_POOL_ORDER"


def pool_order_reason(order: str) -> str | None:
    """Why CI_PR_POOL_ORDER is not allowed, or None when it is fine.

    The one variable that may name an owned pool: scripts/ci/pr_runner_pool.py
    reads it for same-repository pull request runs only, and drops owned labels
    unless CI_PR_POOL_OWNED is 1. Every other entry is held to the workflow
    policy, so the order cannot smuggle in a label the guard refuses.
    """
    for label in (entry.strip() for entry in order.split(",")):
        if not label or _owned_pattern().fullmatch(label):
            continue
        if _owned_pattern().fullmatch(label.lower()):
            # pr_runner_pool.py matches owned labels exactly, so this entry
            # would turn the whole preference off instead of naming the pool.
            return f"`{label}` is an owned pool label in the wrong case; write it in lowercase"
        reason = forbidden_reason(label)
        if reason is not None:
            return f"`{label}` {reason}"
    return None


SIDE_LANE_VARIABLE = "CI_SIDE_LANE_RUNNER"
# The light minis' side label for the smallest side-lane jobs (attempt 1);
# held to the same rule as CI_SIDE_LANE_RUNNER.
LIGHT_LANE_VARIABLE = "CI_LIGHT_LANE_RUNNER"
SIDE_LANE_VARIABLES = (SIDE_LANE_VARIABLE, LIGHT_LANE_VARIABLE)
SIDE_LANE_PREFIX = "glaeda-side-"


def side_lane_reason(label: str) -> str | None:
    """Why CI_SIDE_LANE_RUNNER or CI_LIGHT_LANE_RUNNER is not allowed, or None when it is fine.

    The picker-less side lanes (ci-owned-pool-rescue.yml lists them) read these
    variables as their whole runs-on, so they are the runner variables that may
    name an owned side label, glaeda-side-<class>-xcode-<version>: the side
    runners a pool keeps beside its root runners. Anything else is held to the
    workflow policy like every other runner variable.
    """
    if label.startswith(SIDE_LANE_PREFIX) and _owned_pattern().fullmatch(
        "glaeda-" + label[len(SIDE_LANE_PREFIX):]
    ):
        return None
    return forbidden_reason(label)


def forbidden_reason(label: str) -> str | None:
    """Why this runner label is not allowed, or None when it is fine.

    Mirrors the guard exactly: strip the approved cloud labels first, then look
    for a forbidden pattern in what is left. Stripping first is what lets
    `blacksmith-6vcpu-macos-26` through while `warp-macos-26-arm64-12x` is
    caught, even though both contain `macos-26`.
    """
    if not label:
        return None
    fleet, allowed, selfhosted = _patterns()
    remainder = allowed.sub("", label)
    # GitHub matches runner labels without regard to case, so the fleet and
    # cloud patterns do too; the bare self-hosted labels are case-sensitive
    # on purpose (`macOS`, not the `macos` inside cloud labels).
    if fleet.search(allowed.sub("", label.lower())):
        return (
            "names the self-hosted fleet or a macOS image outside the approved "
            "cloud labels"
        )
    if selfhosted.search(remainder):
        return "targets a self-hosted runner directly"
    return None


def drifted_runner_variables(
    variables: dict[str, str],
) -> list[tuple[str, str, str]]:
    """(name, value, reason) for every runner variable holding a bad label.

    Sorted by name so the report is stable between windows and a reader can
    diff two reports without spurious reordering.
    """
    drifted = []
    for name, value in variables.items():
        if not isinstance(value, str):
            continue
        if name == POOL_ORDER_VARIABLE:
            reason = pool_order_reason(value.strip())
        elif name in SIDE_LANE_VARIABLES:
            reason = side_lane_reason(value.strip())
        elif "RUNNER" not in name:
            continue
        else:
            reason = forbidden_reason(value.strip())
        if reason is not None:
            drifted.append((name, value.strip(), reason))
    return sorted(drifted)
