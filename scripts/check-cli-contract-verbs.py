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
    several routes and all of them count. Most verbs are `case "…"` arms of
    `switch command`, but roughly a third are handled before the switch is
    reached, and those early routes come in three shapes: `if command == "…"`,
    `if command == SomeType.someConstant`, and `SomeType(command: command, …)`,
    an initializer that returns nil unless it recognizes the verb. `cmux diff`
    and `cmux version` are the first shape; the sudo broker entrypoints are the
    second; the owned-process supervisors are the third. A guard that read only
    the switch would be blind to the cheapest way to add a verb to this file.
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
  * a `command ==` whose right side is neither a string literal nor a resolvable
    `Type.constant` fails by line. Skipping it was how four hidden verbs stayed
    out of the contract: the guard matched only literals, so a comparison
    against a named constant read as no comparison at all.
  * a named type in either of the two indirect shapes is resolved by reading the
    file that declares it, and failing to find that file, the constant or any
    verb in it is a failure too. Nothing here is hard-coded to a type name.
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
    1  an undocumented verb, an unreadable dispatch shape, a missing anchor, or
       an unreadable input
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
COMMAND_COMPARE = re.compile(r"\bcommand ==[ ]*")
# `command == SudoExecutionRunner.hiddenCommand`: a verb named once, next to its
# implementation, instead of spelled out at the comparison.
MEMBER_REFERENCE = re.compile(r"\A([A-Z]\w*)\.(\w+)")
# `if let supervisor = try OwnedProcessSupervisor(command: command, …)`: an
# initializer that returns nil for a verb it does not own, so the verbs live in
# its own file. Only a capitalized callee is a type; the lowercase helpers taking
# the same argument label (`runGuideCommand(command:)`) are predicates, not
# routes.
COMMAND_INITIALIZER = re.compile(r"\b([A-Z]\w*)\(command: command\b")
NESTED_SWITCH_COMMAND = re.compile(r"^(\s*)switch command \{\s*$")
STATIC_MEMBER = r"\bstatic\s+(?:let|var)\s+{0}\b[^=]*=[ ]*"
TYPE_DECLARATION = r"\b(?:struct|class|enum|actor|protocol|extension)\s+{0}\b"
SKIPPED_DIRS = frozenset({
    ".git", ".build", ".swiftpm", "DerivedData", "build", "node_modules",
    "Pods", "Carthage", ".venv",
})
# The first cell of a table row. A pipe closes the cell only when it is not
# escaped: several rows spell an alternation inside their command (`--from
# <channel\|path>`), and reading the cell only up to the first pipe would cut a
# row's verb off mid-backtick and silently undocument it. Leading and trailing
# spaces are optional so a table written compactly (`|Command|Contract|`) counts
# too, rather than being skipped without a word.
ROW_FIRST_CELL = re.compile(r"^\|\s*(.+?)\s*(?<!\\)\|")
COMMAND_SECTIONS = ("## Top-Level Commands", "## Command Families")
COMMAND_HEADING = "Command"


def repo_root_dir():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read_lines(path):
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read().splitlines()


def location(root, path, line):
    """Returns `relative/path.swift:12`, the form an editor can jump to."""
    return "{0}:{1}".format(os.path.relpath(path, root), line)


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


def parse_case_arms(lines, blanked, switch, end, case_prefix=CASE_ARM):
    """Returns ({verb: line number}, unreadable patterns) for the switch body."""
    verbs = {}
    unreadable = []
    index = switch + 1
    while index < end:
        if not blanked[index].startswith(case_prefix):
            index += 1
            continue
        first = index
        pattern = lines[index][len(case_prefix):]
        masked = blanked[index][len(case_prefix):]
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


def parse_command_routes(lines, blanked, start, end):
    """Reads the early routes above the switch, in all three of their shapes.

    Returns ({verb: line number}, constants, initializers, unreadable), where
    `constants` are the `command == Type.member` sites and `initializers` the
    `Type(command: command, …)` ones, both to be resolved against the file that
    declares the named type. These are the same kind of top-level route as a
    case arm and are held to the same contract.
    """
    verbs = {}
    constants = []
    initializers = []
    unreadable = []
    for i in range(start, end + 1):
        for match in COMMAND_COMPARE.finditer(blanked[i]):
            value = literal_at(lines[i], blanked[i], match.end())
            if value is not None:
                verbs.setdefault(value, i + 1)
                continue
            member = MEMBER_REFERENCE.match(blanked[i][match.end():])
            if member is not None:
                constants.append((i + 1, member.group(1), member.group(2)))
                continue
            unreadable.append((i + 1, lines[i].strip()))
        for match in COMMAND_INITIALIZER.finditer(blanked[i]):
            initializers.append((i + 1, match.group(1)))
    return verbs, constants, initializers, unreadable


def swift_sources(root):
    """Returns every Swift file in the checkout, for resolving a named type."""
    paths = []
    for directory, subdirectories, filenames in os.walk(root):
        subdirectories[:] = sorted(
            name for name in subdirectories if name not in SKIPPED_DIRS
        )
        for name in sorted(filenames):
            if name.endswith(".swift"):
                paths.append(os.path.join(directory, name))
    return paths


def files_declaring(root, names):
    """Returns {type name: [files declaring it]} in one pass over the sources."""
    patterns = {
        name: re.compile(TYPE_DECLARATION.format(re.escape(name))) for name in names
    }
    declaring = {name: [] for name in names}
    for path in swift_sources(root):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                body = handle.read()
        except OSError:
            continue
        for name, pattern in patterns.items():
            if name in body and pattern.search(body):
                declaring[name].append(path)
    return declaring


def static_string_members(path, member):
    """Returns {literal: line number} for `static let <member> = "…"` in code."""
    lines = read_lines(path)
    blanked = blank_noncode(lines)
    pattern = re.compile(STATIC_MEMBER.format(re.escape(member)))
    values = {}
    for i, masked in enumerate(blanked):
        match = pattern.search(masked)
        if match is None:
            continue
        value = literal_at(lines[i], masked, match.end())
        if value is not None:
            values.setdefault(value, i + 1)
    return values


def command_literals_in_file(path):
    """Returns ({verb: line number}, unreadable) for one type's own dispatch.

    An initializer that owns its verbs recognizes them either by comparison
    (`guard command == "…" || command == "…"`) or by switching on them, so both
    shapes are read, with the same fail-closed stance as the top-level parse.
    """
    lines = read_lines(path)
    blanked = blank_noncode(lines)
    verbs = {}
    unreadable = []
    for i, masked in enumerate(blanked):
        for match in COMMAND_COMPARE.finditer(masked):
            value = literal_at(lines[i], masked, match.end())
            if value is None:
                unreadable.append((i + 1, lines[i].strip()))
            else:
                verbs.setdefault(value, i + 1)
    for i, line in enumerate(lines):
        match = NESTED_SWITCH_COMMAND.match(line)
        if match is None or blanked[i].strip() != line.strip():
            continue
        end = block_end(blanked, i)
        if end is None:
            unreadable.append((i + 1, "switch command { is never closed"))
            continue
        arms, arm_unreadable = parse_case_arms(
            lines, blanked, i, end, match.group(1) + "case "
        )
        for verb, arm_line in arms.items():
            verbs.setdefault(verb, arm_line)
        unreadable.extend(arm_unreadable)
    return verbs, unreadable


def resolve_named_routes(root, constants, initializers):
    """Resolves both indirect shapes by reading the files declaring their types.

    Returns {verb: location}. Raises ValueError when a type, a constant or a
    type's own verbs cannot be found, so an unreadable indirect route fails the
    guard instead of contributing nothing.
    """
    if not constants and not initializers:
        return {}
    names = {name for _, name, _ in constants} | {name for _, name in initializers}
    declaring = files_declaring(root, names)
    missing = sorted(
        "`{0}` (used at {1}:{2})".format(name, CLI_SOURCE, line)
        for line, name in (
            [(line, name) for line, name, _ in constants]
            + [(line, name) for line, name in initializers]
        )
        if not declaring[name]
    )
    if missing:
        raise ValueError(
            "could not find the file declaring " + ", ".join(missing)
            + ". The verb lives with the type, so an unresolvable type is an "
              "unreadable route."
        )

    verbs = {}
    for line, name, member in constants:
        found = {}
        for path in declaring[name]:
            for value, declared in static_string_members(path, member).items():
                found.setdefault(value, (path, declared))
        if len(found) != 1:
            raise ValueError(
                "`command == {0}.{1}` at {2}:{3} resolved to {4} string "
                "constant(s) named `{1}`; expected exactly one so the verb is "
                "readable".format(name, member, CLI_SOURCE, line, len(found))
            )
        value, (path, declared) = next(iter(found.items()))
        verbs.setdefault(value, location(root, path, declared))

    for line, name in initializers:
        found = {}
        unreadable = []
        for path in declaring[name]:
            owned, path_unreadable = command_literals_in_file(path)
            for value, declared in owned.items():
                found.setdefault(value, (path, declared))
            unreadable.extend(
                (path, number, text) for number, text in path_unreadable
            )
        if unreadable:
            raise ValueError(
                "`{0}(command:)` at {1}:{2} owns a command comparison this guard "
                "cannot read: ".format(name, CLI_SOURCE, line)
                + "; ".join(
                    "{0}: {1}".format(location(root, path, number), text)
                    for path, number, text in unreadable
                )
            )
        if not found:
            raise ValueError(
                "`{0}(command:)` at {1}:{2} is a dispatch route, but its "
                "declaration names no verb this guard can read. It recognizes "
                "its verbs somewhere; the guard has to see them."
                .format(name, CLI_SOURCE, line)
            )
        for value, (path, declared) in found.items():
            verbs.setdefault(value, location(root, path, declared))
    return verbs


def parse_dispatch(root):
    """Returns {verb: location} for every top-level verb `run()` routes.

    Raises ValueError when an anchor is missing, a case pattern or a command
    comparison cannot be read, or the switch does not close where a switch
    should, so neither a rename nor a new shape can make this a no-op.
    """
    path = os.path.join(root, CLI_SOURCE)
    lines = read_lines(path)
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

    arms, unreadable = parse_case_arms(lines, blanked, switch, end)
    if unreadable:
        raise ValueError(
            "case pattern(s) this guard cannot read: "
            + "; ".join("line {0}: {1}".format(line, text) for line, text in unreadable)
        )
    if not arms:
        raise ValueError("`switch command {` parsed as having no verbs")
    verbs = {verb: location(root, path, line) for verb, line in arms.items()}

    compared, constants, initializers, unreadable = parse_command_routes(
        lines, blanked, start, run_end
    )
    if unreadable:
        raise ValueError(
            "`command ==` comparison(s) whose right side this guard cannot read: "
            + "; ".join(
                "line {0}: {1}".format(line, text) for line, text in unreadable
            )
            + ". Compare against a string literal or a `Type.constant` this "
              "script can resolve; a comparison it skips is a verb the contract "
              "never has to mention."
        )
    for verb, line in compared.items():
        verbs.setdefault(verb, location(root, path, line))
    for verb, where in resolve_named_routes(root, constants, initializers).items():
        verbs.setdefault(verb, where)
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
        match = ROW_FIRST_CELL.match(line)
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
        "top-level verb {0} (dispatched at {1}) is in no `{2}` command "
        "table; give it a row".format(verb, dispatched[verb], DOC_PATH)
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
        dispatched = parse_dispatch(root)
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
