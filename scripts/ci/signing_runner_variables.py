#!/usr/bin/env python3
"""The repository variables a few signing jobs take their runner from, and what they may hold.

These hold only an ephemeral label (Blacksmith or GitHub-hosted), or are unset
(their readers then fall back to a Blacksmith literal). Not for secrecy: a
signing secret may run on our own runners (Leo, 2026-11-19: "if 99.99999% of
the code is ours, there's literally nothing to be concerned about if we
literally dont allow forks to run on ours automatically"). The jobs that read
these carry no whole-mini claim (tests/test_ci_signing_owned_mac.py), so an
owned mini here would put their signing keychain beside another job's.
Owned-Mac signing goes through its own claim-gated routing.

Its readers:
- cloud_overflow_switch.py, which never writes a non-ephemeral label to one;
- check_repo_variables.py, which never excuses one holding such a label;
- tests/test_ci_signing_owned_mac.py, which counts a read of one as an
  ephemeral route.
"""

from __future__ import annotations

import re

# LINUX_RUNNER left this list on 2026-11-19: it names our own Linux runners for the jobs that hold no signing
# secret, and the Linux signing jobs (the nightly notarization polls and publish, the iOS nightly's
# previous-build, the nightly-next train) take their own routes, since nightlies never run on Blacksmith.
EPHEMERAL_RUNNER_VARIABLES = ("MACOS_RUNNER_26",)
EPHEMERAL_LABEL = re.compile(r"^(blacksmith-|ubuntu-|macos-)[a-z0-9.-]+$")


def ephemeral_label(value: str | None) -> bool:
    """Whether a runner label names an ephemeral runner (blacksmith-*, ubuntu-* or GitHub-hosted macos-*)."""
    return bool(EPHEMERAL_LABEL.match((value or "").strip()))


def allowed_value(name: str, value: str | None) -> bool:
    """Whether `name` may hold `value`: any value for other variables; unset or ephemeral for these.

    GitHub reads variable names without regard to case, so this does too.
    """
    if (name or "").strip().upper() not in EPHEMERAL_RUNNER_VARIABLES:
        return True
    return not (value or "").strip() or ephemeral_label(value)
