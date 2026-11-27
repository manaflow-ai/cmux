#!/usr/bin/env python3
"""GitHub workflow path filters: the `paths` glob, which events a filter admits, and the YAML read.

The pure half of workflow_paths_cover_inputs.py (which walks the tree's tests and re-exports these): a router that
only matches changed paths against a filter (pr_router.py, docs_only_paths.py, pr_ran_line.py, self_edit_sweep.py)
imports this file and reads nothing of the tree but the workflows it names.
"""
from __future__ import annotations

import functools
import re
import sys
import warnings
from pathlib import Path

EVENTS = ("pull_request", "pull_request_target", "push")
FILTERS = ("paths", "paths-ignore")
EVENT_TERM = re.compile(r"github\.event_name\s*(==|!=)\s*'([a-z_]+)'")


@functools.lru_cache(maxsize=None)
def glob_regex(pattern: str) -> re.Pattern:
    """A GitHub paths-filter glob: `**` crosses directories, `*` and `?` do not, `[..]` is a class."""
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out, i = out + "(?:.*/)?", i + 3
        elif pattern.startswith("**", i):
            out, i = out + ".*", i + 2
        elif pattern[i] == "*":
            out, i = out + "[^/]*", i + 1
        elif pattern[i] == "?":
            out, i = out + "[^/]", i + 1
        elif pattern[i] == "[" and "]" in pattern[i + 2:]:
            end = pattern.index("]", i + 2)
            body = pattern[i + 1:end]
            body = ("^" + body[1:]) if body.startswith("!") else body
            klass = "[" + body.replace("\\", "\\\\") + "]"
            try:
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore")
                    re.compile(klass)
            except re.error:
                klass = re.escape(pattern[i:end + 1])
            out, i = out + klass, end + 1
        else:
            out, i = out + re.escape(pattern[i]), i + 1
    return re.compile(out + r"\Z")


def admits(kind: str, patterns: list[str], path: str) -> bool:
    """Whether a change to `path` alone starts the event under this filter (later patterns win; `!` negates)."""
    matched = False
    for pattern in patterns:
        pattern = str(pattern)
        negated = pattern.startswith("!")
        if glob_regex(pattern[1:] if negated else pattern).match(path):
            matched = not negated
    return not matched if kind == "paths-ignore" else matched


def triggers(document) -> dict:
    events = document.get("on", document.get(True)) if isinstance(document, dict) else None
    if isinstance(events, str):
        return {events: {}}
    if isinstance(events, list):
        return {e: {} for e in events}
    return events if isinstance(events, dict) else {}


def filtered_events(document) -> dict[str, tuple[str, list[str]]]:
    """{event: (filter kind, patterns)} for each push / pull_request event that has a path filter."""
    out = {}
    for event, config in triggers(document).items():
        if event in EVENTS and isinstance(config, dict):
            for kind in FILTERS:
                if kind in config:
                    out[event] = (kind, [str(p) for p in (config.get(kind) or [])])
    return out


def may_run_for(condition, event: str) -> bool:
    """False only when an `if:` made of `&&` terms has one that names another event."""
    text = str(condition or "")
    if "||" in text or "!(" in text:
        return True
    for op, name in EVENT_TERM.findall(text):
        if (op == "==") != (name == event):
            return False
    return True


def load_yaml(path: Path):
    import yaml  # noqa: PLC0415 - the one dependency; CI installs PyYAML

    return yaml.safe_load(path.read_text(encoding="utf-8"))


def mapping(value) -> dict:
    return value if isinstance(value, dict) else {}
