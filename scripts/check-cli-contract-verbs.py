#!/usr/bin/env python3
"""Coverage guard: every top-level CLI verb is in `docs/cli-contract.md`.

`docs/cli-contract.md` is the contract an agent reads to find out what the cmux
CLI can do. A verb that is not in it is a verb nobody finds, and nothing else
notices the gap: a new `case "…"` in the top-level dispatch ships a working
command whose only documentation is help text you have to already know to ask
for. An agent-reachability audit read this file, concluded that saved layouts
had no CLI path, and was wrong only because `cmux layout` had never been
written down.

So the guard reads both sides and fails until they agree:

  * the dispatch: every `case "…"` arm of `switch command` inside
    `CMUXCLI.run()`, which is the one place a top-level verb is routed.
  * the contract: the first cell of every table row in the document, where a row
    may name a verb and its aliases. That is the top-level table plus the family
    tables below it, so a verb documented with its family (the tmux
    compatibility set) counts as documented.

There is deliberately no exemption list. The table already carries internal
entrypoints (`vm-pty-attach`, `__tmux-compat`) as one-line "Internal …" rows,
which is cheaper than an inventory file and keeps one place to look. A verb an
agent should not call is still a verb someone will meet in a stack trace.

The dispatch parse refuses to go quiet. A case arm whose pattern is not a
comma-separated list of string literals fails the guard by name, so a pattern
shape this script cannot read is a failure instead of a silently skipped verb.
A missing `func run()` or `switch command` fails for the same reason: a rename
must break the guard, not turn it into a no-op.

What this guard does NOT claim: that every documented row still dispatches. The
table documents subcommands (`window displays`), verbs routed inside a
namespace, and legacy spellings, so the reverse direction is not a clean
comparison and is left to review.

Usage:
    scripts/check-cli-contract-verbs.py [--root PATH]

Exit codes:
    0  every dispatched verb appears in the contract
    1  an undocumented verb, an unreadable case pattern, a missing anchor, or an
       unreadable input
"""

import argparse
import os
import re
import sys

CLI_SOURCE = os.path.join("CLI", "cmux.swift")
DOC_PATH = os.path.join("docs", "cli-contract.md")

RUN_FUNC = re.compile(r"^    func run\(\) async throws \{")
COMMAND_SWITCH = re.compile(r"^        switch command \{")
CASE_ARM = "        case "
TABLE_HEADING = "## Top-Level Commands"
QUOTED = re.compile(r'"[^"]*"')


def repo_root_dir():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def mask_strings(text):
    """Blanks every quoted run, keeping the text's length and indices."""
    return QUOTED.sub(lambda match: "\x00" * len(match.group(0)), text)


def parse_dispatch(path):
    """Returns {verb: line number} for the top-level command switch.

    Raises ValueError when an anchor is missing or a case pattern cannot be
    read, so neither a rename nor a new pattern shape can make this a no-op.
    """
    with open(path, "r", encoding="utf-8") as handle:
        lines = handle.read().splitlines()

    start = next((i for i, line in enumerate(lines) if RUN_FUNC.match(line)), None)
    if start is None:
        raise ValueError("could not locate `func run() async throws` (renamed?)")
    switch = next(
        (i for i in range(start, len(lines)) if COMMAND_SWITCH.match(lines[i])), None
    )
    if switch is None:
        raise ValueError("could not locate `switch command {` inside `run()`")

    depth = 0
    end = None
    for i in range(switch, len(lines)):
        depth += lines[i].count("{") - lines[i].count("}")
        if i > switch and depth == 0:
            end = i
            break
    if end is None:
        raise ValueError("`switch command {` is never closed")

    verbs = {}
    unreadable = []
    index = switch + 1
    while index < end:
        if not lines[index].startswith(CASE_ARM):
            index += 1
            continue
        first = index
        accumulated = lines[index][len(CASE_ARM):]
        while ":" not in mask_strings(accumulated):
            index += 1
            if index >= end:
                raise ValueError("case arm at line {0} has no `:`".format(first + 1))
            accumulated += " " + lines[index].strip()
        pattern = accumulated[: mask_strings(accumulated).index(":")]
        tokens = re.findall(r'"([^"]*)"', pattern)
        if re.sub(r"[\s,]+", "", QUOTED.sub("", pattern)) or not tokens:
            unreadable.append((first + 1, pattern.strip()))
        for token in tokens:
            verbs.setdefault(token, first + 1)
        index += 1

    if unreadable:
        raise ValueError(
            "case pattern(s) this guard cannot read: "
            + "; ".join("line {0}: {1}".format(line, text) for line, text in unreadable)
        )
    if not verbs:
        raise ValueError("`switch command {` parsed as having no verbs")
    return verbs


def parse_documented_verbs(path):
    """Returns the verbs named in the first cell of any table in the contract.

    The top-level table has to exist, because its heading is where a reader is
    sent, but a verb documented in a family table below it (the tmux
    compatibility set) is documented all the same.
    """
    with open(path, "r", encoding="utf-8") as handle:
        body = handle.read()
    if TABLE_HEADING not in body:
        raise ValueError("could not locate `{0}`".format(TABLE_HEADING))
    documented = set()
    rows = 0
    for line in body.splitlines():
        match = re.match(r"^\| (.+?) \| ", line)
        if match is None:
            continue
        cell = match.group(1).strip()
        if cell in ("Command", "---", ":---"):
            continue
        rows += 1
        for token in re.findall(r"`([^`]+)`", cell):
            documented.add(token.split()[0])
    if not rows:
        raise ValueError("the contract parsed as having no table rows")
    return documented


def check(dispatched, documented):
    """Returns a list of human-readable violations."""
    return [
        "top-level verb {0} (dispatched at {1}:{2}) is in no `{3}` table; give "
        "it a row".format(verb, CLI_SOURCE, dispatched[verb], DOC_PATH)
        for verb in sorted(set(dispatched) - documented)
    ]


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Check that every top-level CLI verb is in the contract."
    )
    parser.add_argument("--root", default=repo_root_dir(),
                        help="repository root to read (default: this checkout)")
    args = parser.parse_args(argv)

    root = os.path.abspath(args.root)

    try:
        dispatched = parse_dispatch(os.path.join(root, CLI_SOURCE))
    except (OSError, ValueError) as error:
        print("check-cli-contract-verbs: {0}: {1}".format(CLI_SOURCE, error),
              file=sys.stderr)
        return 1

    try:
        documented = parse_documented_verbs(os.path.join(root, DOC_PATH))
    except (OSError, ValueError) as error:
        print("check-cli-contract-verbs: {0}: {1}".format(DOC_PATH, error),
              file=sys.stderr)
        return 1

    violations = check(dispatched, documented)
    if violations:
        print("check-cli-contract-verbs: FAILED", file=sys.stderr)
        for violation in violations:
            print("  - {0}".format(violation), file=sys.stderr)
        print(
            "\nAn agent finds a verb by reading {0}. A verb missing from it is a "
            "verb nobody runs. One row, one line, internal verbs included."
            .format(DOC_PATH),
            file=sys.stderr,
        )
        return 1

    print(
        "check-cli-contract-verbs: ok ({0} dispatched verbs, {1} documented "
        "entries)".format(len(dispatched), len(documented))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
