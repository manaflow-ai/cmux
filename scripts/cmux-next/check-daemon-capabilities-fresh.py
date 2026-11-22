#!/usr/bin/env python3
"""Fails when plans/cmux-next/daemon-capabilities.json is stale against DaemonEndpoint.swift.

The JSON is exported by DaemonCapabilityExportTests (a Swift test, so it needs a
build) and read by check-daemon-capabilities.sh, which runs only inside an app
build. A Swift-only change to the lists (67b13e24e84d moved sidebar-layout-v1
to `optional`) then breaks every tagged build. This check reads the lists from
the Swift source, with no build, in the Linux checks job and in safe-push.

It reads `DaemonCapabilities`: the string constants (`public let name = "..."`),
the literal `required` list and the identifier lists `optional` and
`unservedByBundledDaemon`. An identifier it cannot resolve to a constant fails
the check, so a new way to build a list cannot slip past it silently.

Usage: check-daemon-capabilities-fresh.py [--repo ROOT] [--rev REV]
  --rev reads both files from a commit instead of the working tree.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

SWIFT = "Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/Connection/DaemonEndpoint.swift"
JSON = "plans/cmux-next/daemon-capabilities.json"
REGENERATE = ("CMUX_UPDATE_DAEMON_CAPABILITIES=1 swift test --package-path Packages/macOS/CmuxNext "
              "--filter DaemonCapabilityExportTests (on a fleet Mac or cmux-lawrence-2), then commit "
              + JSON)
LISTS = ("required", "optional", "unservedByBundledDaemon")


def read(root: Path, rev: str | None, path: str) -> str:
    if rev is None:
        return (root / path).read_text(encoding="utf-8")
    return subprocess.run(["git", "-C", str(root), "show", f"{rev}:{path}"],
                          check=True, capture_output=True, text=True).stdout


def strip_comments(source: str) -> str:
    """Drops // and /* */ comments outside string literals, keeping line breaks."""
    out, i, n = [], 0, len(source)
    while i < n:
        if source.startswith("//", i):
            j = source.find("\n", i)
            i = n if j < 0 else j
        elif source.startswith("/*", i):
            j = source.find("*/", i + 2)
            out.append("\n" * source.count("\n", i, n if j < 0 else j))
            i = n if j < 0 else j + 2
        elif source[i] == '"':
            j = i + 1
            while j < n and source[j] != '"':
                j += 2 if source[j] == "\\" else 1
            out.append(source[i:j + 1])
            i = j + 1
        else:
            out.append(source[i])
            i += 1
    return "".join(out)


def struct_body(source: str, name: str) -> str:
    match = re.search(r"\bstruct\s+" + name + r"\b[^{]*\{", source)
    if not match:
        sys.exit(f"check-daemon-capabilities-fresh: no `struct {name}` in {SWIFT}")
    depth, i = 1, match.end()
    while depth and i < len(source):
        depth += {"{": 1, "}": -1}.get(source[i], 0)
        i += 1
    return source[match.end():i - 1]


def swift_lists(source: str) -> dict[str, list[str]]:
    body = struct_body(strip_comments(source), "DaemonCapabilities")
    constants = dict(re.findall(r'\blet\s+([A-Za-z_]\w*)\s*=\s*"([^"]*)"', body))
    required = re.search(r"\blet\s+required\s*:\s*\[String\]\s*=\s*\[(.*?)\]", body, re.S)
    if not required:
        sys.exit(f"check-daemon-capabilities-fresh: no literal `required` list in {SWIFT}")
    lists = {"required": re.findall(r'"([^"]*)"', required.group(1))}
    unresolved = []
    for name in ("optional", "unservedByBundledDaemon"):
        match = re.search(r"\bvar\s+" + name + r"\s*:\s*\[String\]\s*\{\s*\[(.*?)\]\s*\}", body, re.S)
        if not match:
            sys.exit(f"check-daemon-capabilities-fresh: no `var {name}: [String] {{ [...] }}` in {SWIFT}")
        values = []
        for item in (part.strip() for part in match.group(1).split(",")):
            if not item:
                continue
            if item.startswith('"') and item.endswith('"'):
                values.append(item[1:-1])
            elif item in constants:
                values.append(constants[item])
            else:
                unresolved.append(f"{name}: {item}")
        lists[name] = values
    if unresolved:
        sys.exit("check-daemon-capabilities-fresh: cannot resolve " + ", ".join(unresolved)
                 + f" to a `let name = \"...\"` constant in DaemonCapabilities; extend this check "
                 "or list the constant, so the export and this check read the same lists")
    return lists


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--rev")
    args = parser.parse_args()
    swift = swift_lists(read(args.repo, args.rev, SWIFT))
    stored = json.loads(read(args.repo, args.rev, JSON))
    problems = []
    for name in LISTS:
        want, have = swift[name], stored.get(name, [])
        if len(set(want)) != len(want):
            problems.append(f"{name}: listed twice in Swift: {sorted({c for c in want if want.count(c) > 1})}")
        missing, extra = sorted(set(want) - set(have)), sorted(set(have) - set(want))
        if missing:
            problems.append(f"{name}: in DaemonEndpoint.swift, not in the JSON: {', '.join(missing)}")
        if extra:
            problems.append(f"{name}: in the JSON, not in DaemonEndpoint.swift: {', '.join(extra)}")
    where = f" at {args.rev}" if args.rev else ""
    if problems:
        print(f"check-daemon-capabilities-fresh: {JSON} is stale{where}:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print(f"  Regenerate: {REGENERATE}", file=sys.stderr)
        return 1
    counts = ", ".join(f"{len(swift[name])} {name}" for name in LISTS)
    print(f"check-daemon-capabilities-fresh: {JSON} matches DaemonEndpoint.swift{where} ({counts})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
