#!/usr/bin/env python3
"""The repository variables a signing job takes its runner from, read from the workflows, and what they may hold.

A job that holds signing, notarization or release material runs on an
ephemeral runner (Blacksmith or GitHub's hosted Linux), never a reused machine
(tests/test_ci_signing_keychain_is_deleted_before_bundle_code.py rule 7 on
feat-cmux-next; "blacksmith runners we can simply trust", Leo, 2026-10-24).
Some of those jobs read their runner from a repository variable, so such a
variable may hold only an ephemeral label, or be unset (its readers then fall
back to a Blacksmith literal).

Which variables those are is not a hand list: signing_variables() reads every
workflow's jobs and collects the `vars.NAME` each signing job's runs-on reads.
A signing job is one that names a signing secret (SIGNING_SECRET) or runs in a
release environment (RELEASE_ENVIRONMENT), the same tests rule 6 and rule 7
use. A picker job a runs-on reads through `needs.X.outputs` is its own routing
and is not followed here. Variables that hold no runner label (the overflow
record, the paid-overflow gate) are not runner variables and are left out.

The variables are repository-wide, but the workflows that read them live on
more than one branch: the scheduled overflow switch runs from main while most
signing jobs live on feat-cmux-next. SIGNING_WORKFLOW_DIRS (os.pathsep
separated) names the other branches' checked-out workflow directories; the
switch's workflow checks out feat-cmux-next's. If one it names cannot be read,
signing_variables() fails closed: every runner variable counts as one a signing
job reads.

Its readers:
- cloud_overflow_switch.py, which never writes a non-ephemeral label to one;
- check_repo_variables.py, which never excuses one holding such a label.
"""

from __future__ import annotations

import functools
import json
import os
import re
from collections.abc import Iterable
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
DIRS_ENV = "SIGNING_WORKFLOW_DIRS"
EPHEMERAL_LABEL = re.compile(r"^(blacksmith-|ubuntu-)[a-z0-9.-]+$")
# Rule 7's tests (tests/test_ci_signing_keychain_is_deleted_before_bundle_code.py).
SIGNING_SECRET = re.compile(
    r"secrets(\.|\[\s*(format\(\s*)?\\?['\"])(APPLE_|ASC_API_|IOS_|SPARKLE_|NIGHTLY_SPARKLE_|CMUX_RELEASE_APP_"
    r"|CONTENT_SIGNING_)",
    re.IGNORECASE,
)
RELEASE_ENVIRONMENT = re.compile(r"\b(release|release-next|content-signing|nightly-next-promote|release-surface-ack)\b")
VARIABLE = re.compile(r"vars(?:\.([A-Za-z0-9_]+)|\[\s*['\"]([A-Za-z0-9_]+)['\"]\s*\])", re.IGNORECASE)
# Read in runs-on as switches, never as a label.
NOT_RUNNER_LABELS = frozenset({"CI_CLOUD_OVERFLOW_SAVED", "CI_PAID_MACOS_OVERFLOW"})
# Every variable that can name a runner, for failing closed.
RUNNER_VARIABLE_NAME = re.compile(r"^(LINUX_RUNNER|CI_TRUSTED_RUNNER|MACOS_RUNNER_[A-Z0-9_]+)$")


def signing_job(job: dict) -> bool:
    text = json.dumps(job)
    return bool(SIGNING_SECRET.search(text)) or bool(RELEASE_ENVIRONMENT.search(json.dumps(job.get("environment") or "")))


def runs_on_variables(job: dict) -> set[str]:
    names = {(dotted or bracketed).upper() for dotted, bracketed in VARIABLE.findall(str(job.get("runs-on", "")))}
    return names - NOT_RUNNER_LABELS


def derive(directories: Iterable[Path]) -> frozenset[str]:
    """The variables a signing job's runs-on reads, across every workflow in `directories`.

    A directory that does not exist or holds no workflow raises: reading
    nothing would mean protecting nothing.
    """
    found: set[str] = set()
    for directory in directories:
        paths = sorted([*directory.glob("*.yml"), *directory.glob("*.yaml")]) if directory.is_dir() else []
        if not paths:
            raise FileNotFoundError(f"no workflows in {directory}")
        for path in paths:
            # BaseLoader keeps `on:` a string key and every value a string, as GitHub reads them.
            document = yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
            if not isinstance(document, dict):
                continue
            for job in (document.get("jobs") or {}).values():
                if isinstance(job, dict) and signing_job(job):
                    found |= runs_on_variables(job)
    return frozenset(found)


def workflow_directories(env: dict[str, str] | None = None) -> list[Path]:
    env = dict(os.environ) if env is None else env
    extra = [Path(part) for part in (env.get(DIRS_ENV) or "").split(os.pathsep) if part.strip()]
    return [ROOT / ".github" / "workflows", *[path if path.is_absolute() else ROOT / path for path in extra]]


@functools.lru_cache(maxsize=None)
def _signing_variables(directories: tuple[Path, ...]) -> frozenset[str] | None:
    try:
        return derive(directories)
    except (OSError, yaml.YAMLError):
        return None


def signing_variables(env: dict[str, str] | None = None) -> frozenset[str] | None:
    """The derived set, or None when a named workflow directory could not be read (fail closed)."""
    return _signing_variables(tuple(workflow_directories(env)))


def is_signing_variable(name: str, env: dict[str, str] | None = None) -> bool:
    """Whether a signing job may read `name`; GitHub reads variable names without regard to case."""
    upper = (name or "").strip().upper()
    derived = signing_variables(env)
    if derived is None:
        return bool(RUNNER_VARIABLE_NAME.match(upper))
    return upper in derived


def ephemeral_label(value: str | None) -> bool:
    """Whether a runner label names an ephemeral runner (blacksmith-* or ubuntu-*)."""
    return bool(EPHEMERAL_LABEL.match((value or "").strip()))


def allowed_value(name: str, value: str | None, env: dict[str, str] | None = None) -> bool:
    """Whether `name` may hold `value`: any value unless a signing job reads it; then unset or ephemeral."""
    if not is_signing_variable(name, env):
        return True
    return not (value or "").strip() or ephemeral_label(value)
