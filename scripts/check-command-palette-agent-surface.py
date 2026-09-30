#!/usr/bin/env python3
"""Inventory guard for the command-palette agent surface (`cmux palette list`).

`palette.list` answers an agent with the command-palette rows a window offers.
The listing is derived from the palette's own contributions, so every palette
command an agent should never call has to be named explicitly in
`CommandPaletteAgentSurface.notAgentSurfaceCommandIds` (installing the CLI,
updating the app, taking over the default terminal, connecting a phone,
restarting the socket listener, restarting VS Code serve-web). Those commands
either need a human at the keyboard or would break the agent's own transport.

Nothing in the type system notices a *new* palette command. Without this guard a
command added next month is published to every agent the first time someone
opens the palette, and nobody ever decided that it should be. So the guard keeps
a checked-in inventory of the palette id namespace and fails until each id is
classified:

  * `listedCommandIds`      - agents may see and run it.
  * `excludedCommandIds`    - deliberately absent from the agent surface; must
                              match the Swift constant exactly.
  * `dynamicFamilies`       - an id prefix completed at runtime (settings
                              toggles, Find Work rows), with `agentVisible`
                              saying whether the completed ids reach agents.
  * `notCommandIds`         - a `palette.`-prefixed string that is not a command
                              id at all (debug log tags, the socket method
                              name), each with a reason.

The universe is every `"palette.*"` string literal in the app sources, which is
deliberately cruder than parsing contribution constructions: ids arrive as
literals, as `static let ...CommandId` constants, as enum raw values, as tuple
rows in a loop and as `switch` returns, and a shape-matching parser would go
quietly blind the first time someone writes a new shape. A string scan cannot go
blind, and the cost is the `notCommandIds` bucket.

An id built by interpolation (`"palette.workspaceStatus.\\(status.rawValue)"`)
has no closing quote after the prefix, so the literal scan alone would miss a
whole family of agent-visible commands. A second scan collects the static prefix
in front of each interpolation and requires it to be a declared
`dynamicFamilies` key. The interpolation has to fall on a dot boundary: a prefix
like `palette.openTab` completed mid-segment would name commands no inventory
entry can describe, so the guard rejects it and asks for a dotted prefix.

The Swift exclusion constant is excluded from the scan, so an exclusion whose
command no longer exists fails as a dead entry instead of vouching for itself.

The guard holds a second property, about what a listed row *means*. A palette
contribution carries two predicates: `when` decides whether the command exists
in this context, `enablement` whether it can run right now. The on-screen
palette requires both, so on screen the two are interchangeable. The agent
listing is not symmetric: a false `when` removes the row, a false `enablement`
keeps it and reports `isEnabled: false`. Some context keys are answered by an
availability probe that has not run until the palette refreshes, so they read
false on a panel nobody has probed yet. Gating `when` on one of those tells an
agent the command does not exist, on a window where it does. Such a key is
marked `Probe-backed:` in its doc comment in `CommandPaletteContextKeys.swift`,
listed in the inventory's `probeBackedContextKeys`, and rejected inside any
contribution's `when` argument. The same rule covers the indirect form: a
predicate named `...Enablement` may only be passed to `enablement`.

Reading the `when` arguments needs the contribution constructions, which the id
scan deliberately avoids. Going blind here is cheaper to notice: a construction
whose argument list will not parse is itself a failure, and so is finding no
constructions at all.

What this guard does NOT claim: that every `listedCommandIds` entry is reachable
in the palette today. It is an accounting guard over the id namespace, not a
proof of the rendered list. The package tests in
`CommandPaletteAgentSurfaceTests` cover the filtering rules themselves. Nor does
it decide which keys are probe-backed; it only keeps the marked ones out of
`when` and keeps the marker and the inventory saying the same thing.

Usage:
    scripts/check-command-palette-agent-surface.py [--root PATH]
                                                   [--inventory PATH]
                                                   [--agent-surface-file PATH]
                                                   [--context-keys-file PATH]

Exit codes:
    0  every palette id is classified and every classification is still live
    1  an unclassified id, a dead entry, a bucket collision, an exclusion-list
       mismatch, a missing reason, a probe-backed context key gating `when`, an
       unparsable contribution, or an unreadable/unlocatable input
"""

import argparse
import glob
import json
import os
import re
import sys

SOURCE_GLOBS = (
    "Sources/**/*.swift",
    "Packages/macOS/*/Sources/**/*.swift",
    "CLI/**/*.swift",
)

DEFAULT_INVENTORY = os.path.join(
    "scripts", "command-palette-agent-surface-inventory.json"
)
DEFAULT_AGENT_SURFACE_FILE = os.path.join(
    "Packages", "macOS", "CmuxCommandPalette", "Sources", "CmuxCommandPalette",
    "AgentSurface", "CommandPaletteAgentSurface.swift",
)
DEFAULT_CONTEXT_KEYS_FILE = os.path.join(
    "Packages", "macOS", "CmuxCommandPalette", "Sources", "CmuxCommandPalette",
    "Context", "CommandPaletteContextKeys.swift",
)

CONTRIBUTION_CALL = "CommandPaletteCommandContribution("
ARGUMENT_LABEL = re.compile(r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*:")
CONTEXT_KEY_DECLARATION = re.compile(
    r"^\s*public static let (?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*="
)
PROBE_BACKED_MARKER = "Probe-backed:"
ENABLEMENT_IDENTIFIER = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*Enablement)\b")

PALETTE_LITERAL = re.compile(r'"(palette\.[A-Za-z0-9_.\-]+)"')
# The static head of an interpolated id: `"palette.foo.\(bar)"`.
INTERPOLATED_PALETTE_PREFIX = re.compile(r'"(palette\.[A-Za-z0-9_.\-]*)\\\(')
EXCLUSION_CONSTANT = re.compile(
    r"notAgentSurfaceCommandIds[^=]*=\s*\[(?P<body>.*?)\]", re.DOTALL
)
QUOTED = re.compile(r'"([^"]*)"')


def repo_root_dir():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def scan_source_files(root, skip_paths):
    skipped = {os.path.abspath(path) for path in skip_paths}
    files = []
    for pattern in SOURCE_GLOBS:
        for path in glob.glob(os.path.join(root, pattern), recursive=True):
            if os.path.abspath(path) in skipped:
                continue
            files.append(path)
    return sorted(set(files))


def collect_palette_literals(root, skip_paths):
    """Returns (whole literals, interpolation prefixes), each id -> [files].

    Both maps are keyed the same way, so a family prefix collected from an
    interpolation is accounted for exactly like a literal one.
    """
    literals = {}
    prefixes = {}
    for path in scan_source_files(root, skip_paths):
        with open(path, "r", encoding="utf-8") as handle:
            source = handle.read()
        relative = os.path.relpath(path, root)
        for match in PALETTE_LITERAL.finditer(source):
            literals.setdefault(match.group(1), set()).add(relative)
        for match in INTERPOLATED_PALETTE_PREFIX.finditer(source):
            prefixes.setdefault(match.group(1), set()).add(relative)
    return (
        {key: sorted(value) for key, value in literals.items()},
        {key: sorted(value) for key, value in prefixes.items()},
    )


def parse_swift_exclusions(path):
    """Returns the ids listed in `notAgentSurfaceCommandIds`.

    Raises ValueError when the constant cannot be located: a rename must fail
    the guard rather than turn it into a no-op.
    """
    with open(path, "r", encoding="utf-8") as handle:
        source = handle.read()
    match = EXCLUSION_CONSTANT.search(source)
    if match is None:
        raise ValueError(
            "could not locate `notAgentSurfaceCommandIds` (renamed or removed?)"
        )
    ids = QUOTED.findall(match.group("body"))
    if not ids:
        raise ValueError("`notAgentSurfaceCommandIds` parsed as empty")
    return ids


def load_inventory(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def split_swift_arguments(source, open_paren):
    """Splits the argument list of the call whose `(` is at `open_paren`.

    Returns (arguments, index past the `)`), where each argument is the raw
    text between the top-level commas, or (None, None) when the list does not
    balance. The scan tracks string literals and their `\\(...)`
    interpolations, `//` comments and nesting, so a predicate closure holding
    commas, parens or a comment stays one argument. A closer that does not
    match its opener counts as not balancing: the scan has lost the shape, and
    guessing past that point is how a guard goes quiet.
    """
    closers = {"(": ")", "[": "]", "{": "}"}
    stack = []
    pieces = []
    piece_start = None
    interpolations = []
    in_string = False
    index = open_paren
    length = len(source)
    while index < length:
        char = source[index]
        if in_string:
            if char == "\\" and index + 1 < length:
                if source[index + 1] == "(":
                    interpolations.append(len(stack))
                    stack.append(")")
                    in_string = False
                    index += 2
                    continue
                index += 2
                continue
            if char == '"':
                in_string = False
            index += 1
            continue
        if char == '"':
            in_string = True
            index += 1
            continue
        if char == "/" and index + 1 < length and source[index + 1] == "/":
            newline = source.find("\n", index)
            index = length if newline == -1 else newline
            continue
        if char in closers:
            stack.append(closers[char])
            if len(stack) == 1:
                piece_start = index + 1
            index += 1
            continue
        if char in ")]}":
            if not stack or stack[-1] != char:
                return None, None
            stack.pop()
            if interpolations and len(stack) == interpolations[-1]:
                interpolations.pop()
                in_string = True
                index += 1
                continue
            if not stack:
                pieces.append(source[piece_start:index])
                return pieces, index + 1
            index += 1
            continue
        if char == "," and len(stack) == 1:
            pieces.append(source[piece_start:index])
            piece_start = index + 1
            index += 1
            continue
        index += 1
    return None, None


def collect_when_arguments(root, skip_paths):
    """Returns (`when` arguments, number of contributions read).

    Each entry is (relative path, line, text), and text is None for a
    construction whose argument list would not parse: the guard has to fail on
    that rather than skip the file.
    """
    arguments = []
    contributions = 0
    for path in scan_source_files(root, skip_paths):
        with open(path, "r", encoding="utf-8") as handle:
            source = handle.read()
        relative = os.path.relpath(path, root)
        index = source.find(CONTRIBUTION_CALL)
        while index != -1:
            contributions += 1
            line = source.count("\n", 0, index) + 1
            pieces, end = split_swift_arguments(
                source, index + len(CONTRIBUTION_CALL) - 1
            )
            if pieces is None:
                arguments.append((relative, line, None))
                break
            for piece in pieces:
                match = ARGUMENT_LABEL.match(piece)
                if match is not None and match.group(1) == "when":
                    arguments.append((relative, line, piece))
            index = source.find(CONTRIBUTION_CALL, end)
    return arguments, contributions


def parse_probe_backed_markers(path):
    """Returns the context keys whose doc comment says `Probe-backed:`.

    Raises ValueError when the file declares no context keys at all, so a move
    or a rename fails the guard instead of emptying it.
    """
    with open(path, "r", encoding="utf-8") as handle:
        lines = handle.read().splitlines()
    marked = set()
    declared = set()
    doc = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("///"):
            doc.append(stripped)
            continue
        match = CONTEXT_KEY_DECLARATION.match(line)
        if match is not None:
            name = match.group("name")
            declared.add(name)
            if any(PROBE_BACKED_MARKER in entry for entry in doc):
                marked.add(name)
        if stripped:
            doc = []
    if not declared:
        raise ValueError("declares no `public static let` context keys")
    return marked, declared


def check_probe_backed_keys(
    probe_backed,
    when_arguments,
    contribution_count,
    probe_backed_markers,
    declared_context_keys,
):
    """Returns the violations of the `when` rule for probe-backed keys."""
    violations = []

    if not isinstance(probe_backed, dict) or not probe_backed:
        violations.append(
            "probeBackedContextKeys must be a non-empty object; a key answered "
            "by an availability probe belongs in it with a reason"
        )
        probe_backed = probe_backed if isinstance(probe_backed, dict) else {}
    for name, reason in sorted(probe_backed.items()):
        if not isinstance(reason, str) or not reason.strip():
            violations.append(
                "probeBackedContextKeys {0} needs a reason".format(name)
            )
        if name not in declared_context_keys:
            violations.append(
                "probeBackedContextKeys {0} is not a declared context key; "
                "remove it or fix the name".format(name)
            )
        elif name not in probe_backed_markers:
            violations.append(
                "probeBackedContextKeys {0} is no longer marked `{1}` in its "
                "doc comment; the marker and the inventory have to agree"
                .format(name, PROBE_BACKED_MARKER)
            )
    for name in sorted(probe_backed_markers - set(probe_backed)):
        violations.append(
            "context key {0} is marked `{1}` but is not listed in "
            "probeBackedContextKeys".format(name, PROBE_BACKED_MARKER)
        )

    if contribution_count == 0:
        violations.append(
            "found no `{0}` constructions under the scanned sources; the "
            "`when` rule cannot be checked".format(CONTRIBUTION_CALL)
        )

    for relative, line, text in when_arguments:
        if text is None:
            violations.append(
                "{0}:{1}: could not read the argument list of this "
                "contribution; the `when` rule cannot be checked".format(
                    relative, line
                )
            )
            continue
        for name in sorted(probe_backed):
            if "CommandPaletteContextKeys.{0}".format(name) in text:
                violations.append(
                    "{0}:{1}: `when` gates on the probe-backed context key {2}; "
                    "an unprobed panel would drop this row from `cmux palette "
                    "list`, where absence means the command does not exist. "
                    "Move the test into `enablement`, where it reports "
                    "isEnabled false instead".format(relative, line, name)
                )
        indirect = ENABLEMENT_IDENTIFIER.search(text)
        if indirect is not None:
            violations.append(
                "{0}:{1}: `when` uses the predicate {2}; a name ending in "
                "Enablement may only be passed to `enablement`".format(
                    relative, line, indirect.group(1)
                )
            )

    return violations


def check(
    universe,
    interpolated_prefixes,
    inventory,
    swift_exclusions,
    when_arguments,
    contribution_count,
    probe_backed_markers,
    declared_context_keys,
):
    """Returns a list of human-readable violations."""
    violations = []

    listed = inventory.get("listedCommandIds", [])
    excluded = inventory.get("excludedCommandIds", [])
    families = inventory.get("dynamicFamilies", {})
    not_commands = inventory.get("notCommandIds", {})

    for name, entries in (("listedCommandIds", listed), ("excludedCommandIds", excluded)):
        if not isinstance(entries, list):
            violations.append("{0} must be a list".format(name))
            continue
        # A non-string entry cannot be compared, sorted or matched against the
        # sources, so it is reported here and left out of the rest: a guard that
        # dies on a typo in its own inventory tells nobody which line to fix.
        nonstrings = [entry for entry in entries if not isinstance(entry, str)]
        for entry in nonstrings:
            violations.append(
                "{0} entry {1!r} must be a string".format(name, entry)
            )
        entries = [entry for entry in entries if isinstance(entry, str)]
        duplicates = sorted({entry for entry in entries if entries.count(entry) > 1})
        for entry in duplicates:
            violations.append("{0} lists {1} more than once".format(name, entry))
        if entries != sorted(entries):
            violations.append("{0} must stay sorted".format(name))
        for entry in entries:
            if entry.endswith("."):
                violations.append(
                    "{0} entry {1} ends with a dot; a runtime-completed prefix "
                    "belongs in dynamicFamilies".format(name, entry)
                )

    for prefix, record in sorted(families.items()):
        if not prefix.endswith("."):
            violations.append(
                "dynamicFamilies key {0} must end with a dot (it is an id "
                "prefix completed at runtime)".format(prefix)
            )
        if not isinstance(record, dict) or not record.get("reason"):
            violations.append("dynamicFamilies {0} needs a reason".format(prefix))
        elif not isinstance(record.get("agentVisible"), bool):
            violations.append(
                "dynamicFamilies {0} needs agentVisible true or false".format(prefix)
            )

    for entry, reason in sorted(not_commands.items()):
        if not isinstance(reason, str) or not reason.strip():
            violations.append("notCommandIds {0} needs a reason".format(entry))

    violations.extend(
        check_probe_backed_keys(
            inventory.get("probeBackedContextKeys"),
            when_arguments,
            contribution_count,
            probe_backed_markers,
            declared_context_keys,
        )
    )

    families_declared = set(families)
    universe = dict(universe)
    for prefix, files in sorted(interpolated_prefixes.items()):
        where = ", ".join(files)
        if not prefix.endswith("."):
            violations.append(
                "interpolated palette id {0}\\(...) (seen in {1}) completes "
                "mid-segment; give the family a prefix that ends at a dot so "
                "the inventory can name it".format(prefix, where)
            )
            continue
        if prefix not in families_declared:
            violations.append(
                "interpolated palette id family {0} (seen in {1}) is not "
                "declared in dynamicFamilies".format(prefix, where)
            )
            continue
        universe.setdefault(prefix, files)

    def string_entries(value):
        return {entry for entry in value if isinstance(entry, str)} if isinstance(value, list) else set()

    buckets = {
        "listedCommandIds": string_entries(listed),
        "excludedCommandIds": string_entries(excluded),
        "dynamicFamilies": set(families),
        "notCommandIds": set(not_commands),
    }
    classified = set()
    for name, entries in sorted(buckets.items()):
        for entry in sorted(entries & classified):
            violations.append(
                "{0} also appears in another bucket: {1}".format(name, entry)
            )
        classified |= entries

    for entry in sorted(set(universe) - classified):
        violations.append(
            "unclassified palette id {0} (seen in {1}); add it to "
            "listedCommandIds, excludedCommandIds, dynamicFamilies or "
            "notCommandIds".format(entry, ", ".join(universe[entry]))
        )

    for name, entries in sorted(buckets.items()):
        for entry in sorted(entries - set(universe)):
            violations.append(
                "{0} entry {1} no longer appears in the app sources; remove "
                "it".format(name, entry)
            )

    swift_set = set(swift_exclusions)
    inventory_excluded = buckets["excludedCommandIds"]
    for entry in sorted(swift_set - inventory_excluded):
        violations.append(
            "notAgentSurfaceCommandIds excludes {0} but the inventory does "
            "not".format(entry)
        )
    for entry in sorted(inventory_excluded - swift_set):
        violations.append(
            "the inventory excludes {0} but notAgentSurfaceCommandIds does "
            "not".format(entry)
        )
    duplicates = sorted({e for e in swift_exclusions if swift_exclusions.count(e) > 1})
    for entry in duplicates:
        violations.append(
            "notAgentSurfaceCommandIds lists {0} more than once".format(entry)
        )

    return violations


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Check that every command-palette id is classified for the agent surface."
    )
    parser.add_argument("--root", default=repo_root_dir(),
                        help="repository root to scan (default: this checkout)")
    parser.add_argument("--inventory", default=None,
                        help="inventory JSON (default: <root>/" + DEFAULT_INVENTORY + ")")
    parser.add_argument("--agent-surface-file", default=None,
                        help="Swift file declaring notAgentSurfaceCommandIds")
    parser.add_argument("--context-keys-file", default=None,
                        help="Swift file declaring CommandPaletteContextKeys")
    args = parser.parse_args(argv)

    root = os.path.abspath(args.root)
    inventory_path = args.inventory or os.path.join(root, DEFAULT_INVENTORY)
    agent_surface_path = args.agent_surface_file or os.path.join(
        root, DEFAULT_AGENT_SURFACE_FILE
    )
    context_keys_path = args.context_keys_file or os.path.join(
        root, DEFAULT_CONTEXT_KEYS_FILE
    )

    try:
        inventory = load_inventory(inventory_path)
    except (OSError, ValueError) as error:
        print("check-command-palette-agent-surface: cannot read {0}: {1}".format(
            inventory_path, error), file=sys.stderr)
        return 1

    try:
        swift_exclusions = parse_swift_exclusions(agent_surface_path)
    except (OSError, ValueError) as error:
        print("check-command-palette-agent-surface: {0}: {1}".format(
            agent_surface_path, error), file=sys.stderr)
        return 1

    try:
        probe_backed_markers, declared_context_keys = parse_probe_backed_markers(
            context_keys_path
        )
    except (OSError, ValueError) as error:
        print("check-command-palette-agent-surface: {0}: {1}".format(
            context_keys_path, error), file=sys.stderr)
        return 1

    universe, interpolated_prefixes = collect_palette_literals(
        root, skip_paths=[agent_surface_path]
    )
    if not universe and not interpolated_prefixes:
        print(
            "check-command-palette-agent-surface: found no palette ids under "
            "{0}; the scan globs are wrong".format(root),
            file=sys.stderr,
        )
        return 1

    when_arguments, contribution_count = collect_when_arguments(
        root, skip_paths=[agent_surface_path]
    )
    violations = check(
        universe,
        interpolated_prefixes,
        inventory,
        swift_exclusions,
        when_arguments,
        contribution_count,
        probe_backed_markers,
        declared_context_keys,
    )
    if violations:
        print("check-command-palette-agent-surface: FAILED", file=sys.stderr)
        for violation in violations:
            print("  - {0}".format(violation), file=sys.stderr)
        print(
            "\nWhat an agent can reach through `cmux palette list`, and what a "
            "listed row means, are both decisions. Classify the id or the "
            "probe-backed context key in {0}.".format(
                os.path.relpath(inventory_path, root)
            ),
            file=sys.stderr,
        )
        return 1

    print(
        "check-command-palette-agent-surface: ok ({0} palette ids, {1} "
        "interpolated families, {2} contributions, {3} when predicates)".format(
            len(universe),
            len(interpolated_prefixes),
            contribution_count,
            len(when_arguments),
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
