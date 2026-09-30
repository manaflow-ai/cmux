#!/usr/bin/env python3
"""Coverage guard: every top-level CLI verb is in `docs/cli-contract.md`.

`docs/cli-contract.md` is the contract an agent reads to find out what the cmux
CLI can do. A verb that is not in it is a verb nobody finds, and nothing else
notices the gap: a new verb in the top-level dispatch ships a working command
whose only documentation is help text you have to already know to ask for. An
agent-reachability audit read this file, concluded that saved layouts had no CLI
path, and was wrong only because `cmux layout` had never been written down.

So the guard reads both sides and fails until they agree:

  * the dispatch: every top-level verb routed inside `CMUXCLI.run()`. There are
    two routes and both count. Most verbs are `case "…"` arms of
    `switch command`, but roughly a third are handled before the switch is
    reached, as `if command == "…" { … return }` early returns, and `cmux diff`
    and `cmux version` live there. A guard that read only the switch would be
    blind to the cheapest way to add a verb to this file.
  * the contract: the first cell of every row of every table whose first
    header cell is `Command`, where one cell may name a verb and its aliases. A
    verb documented with its family (the tmux compatibility set, the `vm` and
    `surface` subcommand tables) counts as documented. Rows of the document's
    other tables do not count: they list flags, environment variables and JSON
    fields, and a field named `state`, `delete` or `sessions` must not vouch for
    a verb of that name.

There is deliberately no exemption list. The table already carries internal
entrypoints (`vm-pty-attach`, `__tmux-compat`) as one-line "Internal …" rows,
which is cheaper than an inventory file and keeps one place to look. A verb an
agent should not call is still a verb someone will meet in a stack trace.

The dispatch parse refuses to go quiet:

  * a case arm whose pattern is not a comma-separated list of string literals
    fails the guard by name, so a pattern shape this script cannot read is a
    failure instead of a silently skipped verb.
  * a missing `func run()` or `switch command` fails for the same reason: a
    rename must break the guard, not turn it into a no-op.
  * braces are counted over code only, with string literals (including
    multiline and raw ones) and comments blanked first, and the line that closes
    the switch has to look like the close of a switch. A stray `}` inside a
    message string used to end the scan early and drop every arm after it while
    still reporting success.

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
SWITCH_CLOSE = "        }"
BLANK = "\x00"
CASE_ARM = "        case "
COMMAND_COMPARE = re.compile(r"\bcommand == (?=" + BLANK + ")")
COMMAND_SECTIONS = ("## Top-Level Commands", "## Command Families")
COMMAND_HEADING = "Command"


def repo_root_dir():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def blank_noncode(lines):
    """Returns `lines` with string literals and comments blanked out.

    Every returned line has the same length as its input, so an index into one
    is an index into the other. String contents become NUL so a caller can tell
    "there was a literal here" from "there was nothing here"; comments become
    spaces. Braces survive only in code, which is what the brace counter needs.
    """
    blanked = []
    in_block_comment = False
    in_multiline_string = False
    for line in lines:
        out = []
        index = 0
        width = len(line)
        while index < width:
            if in_block_comment:
                if line.startswith("*/", index):
                    in_block_comment = False
                    out.append("  ")
                    index += 2
                else:
                    out.append(" ")
                    index += 1
                continue
            if in_multiline_string:
                if line.startswith('"""', index):
                    in_multiline_string = False
                    out.append(BLANK * 3)
                    index += 3
                else:
                    out.append(BLANK)
                    index += 1
                continue
            if line.startswith("//", index):
                out.append(" " * (width - index))
                index = width
                continue
            if line.startswith("/*", index):
                in_block_comment = True
                out.append("  ")
                index += 2
                continue
            if line.startswith('"""', index):
                in_multiline_string = True
                out.append(BLANK * 3)
                index += 3
                continue
            if line.startswith('#"', index):
                close = line.find('"#', index + 2)
                stop = width if close < 0 else close + 2
                out.append(BLANK * (stop - index))
                index = stop
                continue
            if line[index] == '"':
                cursor = index + 1
                while cursor < width:
                    if line[cursor] == "\\":
                        cursor += 2
                        continue
                    if line[cursor] == '"':
                        cursor += 1
                        break
                    cursor += 1
                stop = min(cursor, width)
                out.append(BLANK * (stop - index))
                index = stop
                continue
            out.append(line[index])
            index += 1
        blanked.append("".join(out)[:width].ljust(width))
    return blanked


def block_end(blanked, opening):
    """Returns the index of the line closing the block opened on `opening`."""
    depth = 0
    for i in range(opening, len(blanked)):
        depth += blanked[i].count("{") - blanked[i].count("}")
        if i > opening and depth == 0:
            return i
    return None


def literal_at(line, blanked_line, start):
    """Reads the string literal beginning at `start`, or None outside code."""
    if start >= len(line) or line[start] != '"' or blanked_line[start] != BLANK:
        return None
    cursor = start + 1
    value = []
    while cursor < len(line):
        if line[cursor] == "\\":
            return None
        if line[cursor] == '"':
            return "".join(value)
        value.append(line[cursor])
        cursor += 1
    return None


def parse_case_arms(lines, blanked, switch, end):
    """Returns ({verb: line number}, unreadable patterns) for the switch body."""
    verbs = {}
    unreadable = []
    index = switch + 1
    while index < end:
        if not blanked[index].startswith(CASE_ARM):
            index += 1
            continue
        first = index
        pattern = lines[index][len(CASE_ARM):]
        masked = blanked[index][len(CASE_ARM):]
        while ":" not in masked:
            index += 1
            if index >= end:
                raise ValueError("case arm at line {0} has no `:`".format(first + 1))
            pattern += " " + lines[index].strip()
            masked += " " + blanked[index].strip()
        stop = masked.index(":")
        pattern = pattern[:stop]
        masked = masked[:stop]
        tokens = [
            literal_at(pattern, masked, position)
            for position, character in enumerate(masked)
            if character == BLANK and (position == 0 or masked[position - 1] != BLANK)
        ]
        residue = re.sub(r"[\s,]+", "", masked.replace(BLANK, ""))
        if residue or not tokens or None in tokens:
            unreadable.append((first + 1, pattern.strip()))
        else:
            for token in tokens:
                verbs.setdefault(token, first + 1)
        index += 1
    return verbs, unreadable


def parse_command_comparisons(lines, blanked, start, end):
    """Returns {verb: line number} for `command == "…"` inside `run()`.

    These are the early-return handlers above the switch. They are the same kind
    of top-level route and are held to the same contract.
    """
    verbs = {}
    for i in range(start, end + 1):
        for match in COMMAND_COMPARE.finditer(blanked[i]):
            value = literal_at(lines[i], blanked[i], match.end())
            if value:
                verbs.setdefault(value, i + 1)
    return verbs


def parse_dispatch(path):
    """Returns {verb: line number} for every top-level verb `run()` routes.

    Raises ValueError when an anchor is missing, a case pattern cannot be read,
    or the switch does not close where a switch should, so neither a rename nor
    a new pattern shape can make this a no-op.
    """
    with open(path, "r", encoding="utf-8") as handle:
        lines = handle.read().splitlines()
    blanked = blank_noncode(lines)

    start = next((i for i, line in enumerate(lines) if RUN_FUNC.match(line)), None)
    if start is None:
        raise ValueError("could not locate `func run() async throws` (renamed?)")
    run_end = block_end(blanked, start)
    if run_end is None:
        raise ValueError("`func run() async throws` is never closed")
    switch = next(
        (i for i in range(start, run_end) if COMMAND_SWITCH.match(lines[i])), None
    )
    if switch is None:
        raise ValueError("could not locate `switch command {` inside `run()`")
    end = block_end(blanked, switch)
    if end is None:
        raise ValueError("`switch command {` is never closed")
    if lines[end].rstrip() != SWITCH_CLOSE:
        raise ValueError(
            "line {0} does not close `switch command {{`: {1!r}. Brace counting "
            "walked off the switch, so the arms below it were never read."
            .format(end + 1, lines[end][:60])
        )

    verbs, unreadable = parse_case_arms(lines, blanked, switch, end)
    if unreadable:
        raise ValueError(
            "case pattern(s) this guard cannot read: "
            + "; ".join("line {0}: {1}".format(line, text) for line, text in unreadable)
        )
    if not verbs:
        raise ValueError("`switch command {` parsed as having no verbs")
    for verb, line in parse_command_comparisons(lines, blanked, start, run_end).items():
        verbs.setdefault(verb, line)
    return verbs


def parse_documented_verbs(path):
    """Returns the verbs named in the first cell of a command table row.

    Only tables whose first header cell is `Command` count, and the first cell
    of a row may name a verb and its aliases. A verb documented with its family
    (the tmux compatibility set, the `vm` and `surface` subcommand tables) counts
    as documented. The document's other tables describe flags, environment
    variables and JSON payload fields, and letting those vouch for a verb would
    mean the `sessions` field of `cmux sessions --json` silently documents the
    `sessions` verb, which is how that verb went undocumented for so long.
    """
    with open(path, "r", encoding="utf-8") as handle:
        body = handle.read()
    missing = [heading for heading in COMMAND_SECTIONS if heading not in body]
    if missing:
        raise ValueError("could not locate {0}".format(", ".join(
            "`{0}`".format(heading) for heading in missing)))

    documented = set()
    tables = 0
    rows = 0
    collecting = False
    for line in body.splitlines():
        match = re.match(r"^\| (.+?) \|", line)
        if match is None:
            collecting = False
            continue
        cell = match.group(1).strip()
        if cell == COMMAND_HEADING:
            collecting = True
            tables += 1
            continue
        if not collecting or set(cell) <= set("-: "):
            continue
        rows += 1
        for token in re.findall(r"`([^`]+)`", cell):
            documented.add(token.split()[0])
    if not tables or not rows:
        raise ValueError(
            "no `| {0} |` table rows found; the contract's table layout changed"
            .format(COMMAND_HEADING)
        )
    return documented, rows


def check(dispatched, documented):
    """Returns a list of human-readable violations."""
    return [
        "top-level verb {0} (dispatched at {1}:{2}) is in no `{3}` command "
        "table; give it a row".format(verb, CLI_SOURCE, dispatched[verb], DOC_PATH)
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
        documented, rows = parse_documented_verbs(os.path.join(root, DOC_PATH))
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
        "check-cli-contract-verbs: ok ({0} dispatched verbs, {1} command table "
        "rows)".format(len(dispatched), rows)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
