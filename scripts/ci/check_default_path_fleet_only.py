#!/usr/bin/env python3
"""Catch a fleet-only behavior added to a path every user runs.

A pull request that adds, in a default user path (the app, acpmux, the CLI, the website), a line that:
  - names the fleet's own tooling or hosts (a fleet harness, a subrouter route, a fleet registry), or
  - turns a behavior ON for everyone by default that the fleet tunes (an env switch whose unset value is
    on, `unwrap_or(true)` on a setting under agents.*, a `default = true` setting on a compaction,
    routing, model-switch or analytics key), or
  - sets cookies or loads analytics on the website without the consent path,
fails here, unless the line (or the one above it) carries `fleet-only-ok: REASON` (the reason says why
every user wants it) or the change is under a fleet-config path. Fleet-only behavior belongs behind a
setting that is off unless the person turns it on.

Usage: check_default_path_fleet_only.py [--base REF] [--head REF]   (diff REF_BASE...REF_HEAD)
       check_default_path_fleet_only.py --stdin                     (a unified diff on stdin)
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys

# Paths every user runs. A path outside these (CI, docs, tests, fleet config) is not checked.
DEFAULT_PATHS = (
    "Sources/",
    "Packages/",
    "CLI/",
    "Resources/",
    "cmux-tui/crates/",
    "web/app/",
    "web/messages/",
)
SKIP_PARTS = ("/tests/", "/Tests/", "_tests.rs", "/fixtures/", "/fleet/", "/Fleet/")

OK_MARK = "fleet-only-ok:"

# (name, regex over an added line)
RULES = (
    (
        "names the fleet's own tooling",
        re.compile(r"claude-sr2|\bsr2\b|subrouter|X-Subrouter|--harness\s+claude-|\bjcmux\b|fleet-registry|leo-workspace", re.I),
    ),
    (
        "an env switch that is ON unless set to 0/off",
        re.compile(r"!\s*matches!\([^\n]*?Some\(\s*\"(0|off|false|no)\""),
    ),
    (
        "a fleet-tuned setting that defaults on",
        re.compile(
            r"(compact|autocompact|surgery|dedupe|failover|capacity_?fallback|coldWake|cacheCompact|fanout|spendWarn|budget|route|routing)"
            r"[^\n]{0,80}(unwrap_or\(true\)|default_true|=\s*true\b|: true\b)",
            re.I,
        ),
    ),
    (
        "cookies or analytics on the website",
        re.compile(r"posthog\.init|persistence:\s*[\"']localStorage\+cookie|document\.cookie\s*=|opt_in_capturing|disable_persistence:\s*false", re.I),
    ),
    (
        "a model switch the person did not pick",
        re.compile(r"set_model\([^)]*(sonnet|haiku)|fallback_model\s*=\s*[\"'](sonnet|haiku)", re.I),
    ),
)


def in_default_path(path: str) -> bool:
    if not path.startswith(DEFAULT_PATHS):
        return False
    return not any(part in path for part in SKIP_PARTS)


def findings(diff: str) -> list[tuple[str, int, str, str]]:
    """(path, line, rule, text) for each added line in a default path that trips a rule."""
    out: list[tuple[str, int, str, str]] = []
    path, line, prev = "", 0, ""
    for raw in diff.splitlines():
        if raw.startswith("+++ "):
            path = raw[6:] if raw.startswith("+++ b/") else ""
            continue
        if raw.startswith("@@"):
            m = re.search(r"\+(\d+)", raw)
            line = int(m.group(1)) - 1 if m else 0
            prev = ""
            continue
        if raw.startswith("+") and not raw.startswith("+++"):
            line += 1
            text = raw[1:]
            if path and in_default_path(path) and OK_MARK not in text and OK_MARK not in prev:
                for name, rx in RULES:
                    if rx.search(text):
                        out.append((path, line, name, text.strip()))
                        break
            prev = text
        elif raw.startswith(" "):
            line += 1
            prev = raw[1:]
        else:
            prev = ""
    return out


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="HEAD^1")
    ap.add_argument("--head", default="HEAD")
    ap.add_argument("--stdin", action="store_true")
    args = ap.parse_args(argv)
    if args.stdin:
        diff = sys.stdin.read()
    else:
        diff = subprocess.run(
            ["git", "diff", "-U1", "--no-color", args.base, args.head],
            check=True, capture_output=True, text=True,
        ).stdout
    found = findings(diff)
    for path, line, name, text in found:
        print(f"{path}:{line}: {name}: {text[:160]}")
    if found:
        print(
            "\nThese lines put a fleet-only behavior on a path every user runs. Next: put it behind a setting that"
            " is off unless the person turns it on (the fleet sets it in its own config), or remove it."
            f" Override, when every user wants it: add `{OK_MARK} <why>` on the line or the line above."
        )
        return 1
    print("default-path fleet-only check: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
