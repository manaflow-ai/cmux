#!/usr/bin/env python3
"""The repository variables a signing job may take its runner from, and what they may hold.

A job that holds a signing secret runs on an ephemeral runner (Blacksmith or
GitHub's hosted Linux), never a reused machine
(tests/test_ci_signing_keychain_is_deleted_before_bundle_code.py rule 7). A
few such jobs read their runner from these variables, so the variables may
hold only an ephemeral label, or be unset (their readers then fall back to a
Blacksmith literal). Owned-Mac signing goes through its own routing, never
through one of these.

This is the one list. Its readers:
- the rule 7 test, which lets a signing job's runs-on read only these;
- cmux-next-guards.yml's signing-runner-variables job, which turns red when
  one holds anything else (the rule 7 test asserts it checks exactly these);
- cloud_overflow_switch.py, which never writes a non-ephemeral label to one;
- check_repo_variables.py, which never excuses one holding such a label.
"""

from __future__ import annotations

import re

EPHEMERAL_RUNNER_VARIABLES = ("LINUX_RUNNER", "MACOS_RUNNER_26")
EPHEMERAL_LABEL = re.compile(r"^(blacksmith-|ubuntu-)[a-z0-9.-]+$")


def ephemeral_label(value: str | None) -> bool:
    """Whether a runner label names an ephemeral runner (blacksmith-* or ubuntu-*)."""
    return bool(EPHEMERAL_LABEL.match((value or "").strip()))


def allowed_value(name: str, value: str | None) -> bool:
    """Whether `name` may hold `value`: any value for other variables; unset or ephemeral for these.

    GitHub reads variable names without regard to case, so this does too.
    """
    if (name or "").strip().upper() not in EPHEMERAL_RUNNER_VARIABLES:
        return True
    return not (value or "").strip() or ephemeral_label(value)
