#!/usr/bin/env python3
"""A ratchet guard reports each of its findings to the guard runner, so a red on the base never masks a new one.

The cmux-next CI guard group (cmux-next-guards.yml) fails a pull request only on the guard steps it turns red:
scripts/ci/guards_new_reds.py compares the head's red steps with the base's. A ratchet guard (an allowlist or a
baseline: send-path caps, short timeouts and gates, outbound hosts, errno, test determinism, upload retention,
bare urlopen) fails as one step whatever it found. Once one finding turned such a step red on feat-cmux-next, every
later pull request that added another finding to it saw "red on the base too" and landed: on 2026-11-11 twelve
steps sat red on the branch with findings from a dozen merges piled in them (cmux-next guards run 43029632892).

run_ci_guards.py already compares checks inside a step: a step that writes "<passed 0|1><TAB><check>" lines to
$CMUX_GUARD_CHECK_RESULTS gets one "<step> :: <check>" result per check, and a check red on the change that the
base does not have is the change's, however red the step is on the base. report() writes a guard's findings
there. A finding's check name is its text with line numbers taken out (`path:123:` and `L123`), so a finding that
only moved is still the base's, and an added one, in a file already red or not, is the change's. The same
text twice is counted ("(copy 2)"), so one more copy of a violation the base has is the change's too.

Outside the guard runner ($CMUX_GUARD_CHECK_RESULTS unset) report() does nothing. A guard that can scan another
tree (`--root`, a self-test's fixture repository) passes the tree it scanned: only findings in the checkout the
runner judges ($GITHUB_WORKSPACE) are reported, so a self-test's planted findings never become the step's checks.
"""
from __future__ import annotations

import hashlib
import os
import re
from collections import Counter
from typing import Iterable

CHECK_RESULTS_ENV = "CMUX_GUARD_CHECK_RESULTS"
# `path.swift:116:`, `path.rs:65 `, `(line 12)`-free: a line number after a path, and `L48` line labels.
_LINE_NUMBER = re.compile(r"(?<=[\w)\]])(:\d+)(?=[:\s,)]|$)|\bL\d+\b")
_SPACE = re.compile(r"\s+")
MAX_CHECK_CHARS = 300


def _normalized(finding: str) -> str:
    return _SPACE.sub(" ", _LINE_NUMBER.sub("", str(finding))).strip()


def _capped(text: str) -> str:
    if len(text) <= MAX_CHECK_CHARS:
        return text
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()[:12]
    return f"{text[:MAX_CHECK_CHARS - len(digest) - 3].rstrip()} #{digest}"


def check_name(finding: str) -> str:
    """The finding as a check name: one line, no line numbers, at most MAX_CHECK_CHARS characters. A longer one
    is cut and ends with a hash of its whole text, so two findings that share their first characters stay two
    checks (a cut alone made a new finding the same check as a base one, and the base's red masked it)."""
    return _capped(_normalized(finding))


def check_names(findings: Iterable[str]) -> list[str]:
    """One check name per finding, sorted. Findings that read the same once their line numbers are out (the same
    violation twice in one file) are counted, not merged: the second is "<text> (copy 2)" and so on. A change
    that adds one more copy of a violation the base has adds a check the base lacks; copies that only moved keep
    their names."""
    counts = Counter(text for text in (_normalized(finding) for finding in findings) if text)
    names = []
    for text, count in counts.items():
        names.append(_capped(text))
        names.extend(_capped(f"{text} (copy {copy})") for copy in range(2, count + 1))
    return sorted(names)


def report(findings: Iterable[str], env: dict[str, str] | None = None,
           root: "str | os.PathLike[str] | None" = None) -> int:
    """Append each finding as a failed check of the running guard step; returns how many were written.
    With `root`, nothing is written unless it is the checkout the guard runner judges ($GITHUB_WORKSPACE)."""
    env = os.environ if env is None else env
    path = env.get(CHECK_RESULTS_ENV, "")
    workspace = env.get("GITHUB_WORKSPACE", "")
    if root is not None and workspace and os.path.realpath(root) != os.path.realpath(workspace):
        return 0
    names = check_names(findings)
    if not path or not names:
        return 0
    with open(path, "a", encoding="utf-8") as out:
        for name in names:
            out.write(f"0\t{name}\n")
    return len(names)
