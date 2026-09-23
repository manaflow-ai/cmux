#!/usr/bin/env python3
"""Which runner labels this repository may use, applied to values rather than text.

`tests/test_ci_self_hosted_guard.sh` already decides this for workflow *text*:
`check_no_self_hosted_fleet_runners` refuses a `runs-on:` naming a physical
fleet host, a Tart VM, or a paid label outside the approved set. Every guard in
this repository works the same way, on files.

Runner choice does not live in files. It lives in `MACOS_RUNNER_*` repository
variables, and a variable's value never appears in a diff, so none of those
guards can see it. `warp-macos-26-arm64-12x` sat in `MACOS_RUNNER_26_RELEASE`
and `MACOS_RUNNER_26_NIGHTLY_BUILD` from 2026-09-20 to 2026-09-23 even though
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
def _patterns() -> tuple[str, str, str]:
    body = _guard_function(GUARD_SCRIPT.read_text(encoding="utf-8"))
    return (
        _shell_local(body, "fleet"),
        _shell_local(body, "allowed"),
        _shell_local(body, "selfhosted"),
    )


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
    remainder = re.sub(f"({allowed})", "", label)
    if re.search(f"({fleet})", remainder):
        return (
            "names the self-hosted fleet or a macOS image outside the approved "
            "cloud labels"
        )
    if re.search(f"({selfhosted})", remainder):
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
        if "RUNNER" not in name:
            continue
        if not isinstance(value, str):
            continue
        reason = forbidden_reason(value.strip())
        if reason is not None:
            drifted.append((name, value.strip(), reason))
    return sorted(drifted)
