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

The Swift exclusion constant is excluded from the scan, so an exclusion whose
command no longer exists fails as a dead entry instead of vouching for itself.

What this guard does NOT claim: that every `listedCommandIds` entry is reachable
in the palette today. It is an accounting guard over the id namespace, not a
proof of the rendered list. The package tests in
`CommandPaletteAgentSurfaceTests` cover the filtering rules themselves.

Usage:
    scripts/check-command-palette-agent-surface.py [--root PATH]
                                                   [--inventory PATH]
                                                   [--agent-surface-file PATH]

Exit codes:
    0  every palette id is classified and every classification is still live
    1  an unclassified id, a dead entry, a bucket collision, an exclusion-list
       mismatch, a missing reason, or an unreadable/unlocatable input
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

PALETTE_LITERAL = re.compile(r'"(palette\.[A-Za-z0-9_.\-]+)"')
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
    """Returns {palette id literal: sorted list of root-relative files}."""
    found = {}
    for path in scan_source_files(root, skip_paths):
        with open(path, "r", encoding="utf-8") as handle:
            source = handle.read()
        relative = os.path.relpath(path, root)
        for match in PALETTE_LITERAL.finditer(source):
            found.setdefault(match.group(1), set()).add(relative)
    return {key: sorted(value) for key, value in found.items()}


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


def check(universe, inventory, swift_exclusions):
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

    buckets = {
        "listedCommandIds": set(listed if isinstance(listed, list) else []),
        "excludedCommandIds": set(excluded if isinstance(excluded, list) else []),
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
    args = parser.parse_args(argv)

    root = os.path.abspath(args.root)
    inventory_path = args.inventory or os.path.join(root, DEFAULT_INVENTORY)
    agent_surface_path = args.agent_surface_file or os.path.join(
        root, DEFAULT_AGENT_SURFACE_FILE
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

    universe = collect_palette_literals(root, skip_paths=[agent_surface_path])
    if not universe:
        print(
            "check-command-palette-agent-surface: found no palette ids under "
            "{0}; the scan globs are wrong".format(root),
            file=sys.stderr,
        )
        return 1

    violations = check(universe, inventory, swift_exclusions)
    if violations:
        print("check-command-palette-agent-surface: FAILED", file=sys.stderr)
        for violation in violations:
            print("  - {0}".format(violation), file=sys.stderr)
        print(
            "\nEvery palette command an agent can reach through `cmux palette "
            "list` is a decision. Classify the id in {0}.".format(
                os.path.relpath(inventory_path, root)
            ),
            file=sys.stderr,
        )
        return 1

    print("check-command-palette-agent-surface: ok ({0} palette ids)".format(
        len(universe)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
