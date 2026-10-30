#!/usr/bin/env python3
"""No fleet host names in gallery fixtures.

Gallery fixtures are public sample data that the gallery and `cmux-ci capture` render into
screenshots. They name machines in the style of "studio-mac" or "build-box", never one of the
team's own CI and dev hosts: those names are internal, and the capture privacy check refuses any
still that shows one (WorkspaceHoverCardGallery named "air-blue", so no capture of the sidebar
hover-card gallery could pass).

The capture check's term list lives outside this repository, so this check matches the shapes
those host names take rather than listing every host:
  - a size or tone word joined to a color ("huge-blue", "Air Blue"),
  - a numbered fleet Mac ("cmux16", "cmux10s"),
  - a macOS default host name ("someones-mac-mini"),
  - a named fleet host ("cmux-<person>", "aws-m4pro-3", the fleet daemon's name).

Fixture files: Swift `*Gallery*.swift` and `*Showcase*.swift` under Packages/, Swift `*Fixture*.swift`
under a Packages/ Sources/ folder (the debug fixtures `cmux-ci capture` renders, such as
SidebarNestedFixture; vendored code under Vendor/ is left out), and under
webviews/src every `*.gallery.ts(x)`, every file whose name says fixture, and every file in a
`fixtures/` folder.

Runs in the `cmux-next checks` job and the pre-push gate (scripts/cmux-next/prepush-gate.py).
Usage: scripts/cmux-next/check-fixture-host-names.py [repo-root]
Prints `path:line: rule: source` for each hit and exits 1 when there is one.
"""

from __future__ import annotations

import os
import re
import sys

RULE = "fleet host name in a gallery fixture (use a neutral name such as studio-mac or build-box)"
HOST = re.compile(
    r"(?<![\w-])(?:"
    r"(?:air|big|huge|cosmic|tiny|small)[- ](?:blue|red|gray|grey|green)"
    r"|cmux\d+'?s?"
    r"|[a-z0-9]+(?:-[a-z0-9]+)*s?-mac-mini(?:-[a-z0-9]+)*"
    r"|cmux-(?:lawrence|austin|sshtest)[a-z0-9-]*"
    r"|aws-m\d[a-z0-9-]*"
    r"|glaeda[a-z0-9-]*"
    r")(?![\w-])",
    re.IGNORECASE,
)
SWIFT_FIXTURE = re.compile(r"(Gallery|Showcase)[^/]*\.swift$")
SWIFT_SOURCE_FIXTURE = re.compile(r"/Sources/(?:[^/]+/)*[^/]*Fixture[^/]*\.swift$")
WEB_FIXTURE = re.compile(r"\.gallery\.tsx?$|/fixtures/|fixture[^/]*$", re.IGNORECASE)


def is_fixture(rel: str) -> bool:
    """True for a gallery fixture file; `rel` is its path from the repository root."""
    if rel.startswith("Packages/"):
        return bool(SWIFT_FIXTURE.search(rel)) or (
            bool(SWIFT_SOURCE_FIXTURE.search(rel)) and "/Vendor/" not in rel)
    if rel.startswith("webviews/src/"):
        return bool(WEB_FIXTURE.search(rel))
    return False


def scan_file(rel: str, text: str) -> list[str]:
    """The hits in one file."""
    return [f"{rel}:{i}: {RULE}: {line.strip()[:160]}"
            for i, line in enumerate(text.splitlines(), 1) if HOST.search(line)]


def fixture_files(root: str) -> list[str]:
    """Every fixture file under `root`, as sorted paths from it."""
    found = []
    for top in ("Packages", "webviews/src"):
        for directory, dirs, names in os.walk(os.path.join(root, top)):
            dirs[:] = [d for d in dirs if d not in ("node_modules", ".build", "dist")]
            for name in names:
                rel = os.path.relpath(os.path.join(directory, name), root).replace(os.sep, "/")
                if is_fixture(rel):
                    found.append(rel)
    return sorted(found)


def scan(root: str) -> tuple[list[str], int]:
    """(hits, files scanned) for the tree at `root`."""
    files = fixture_files(root)
    hits = []
    for rel in files:
        try:
            with open(os.path.join(root, rel), encoding="utf-8") as stream:
                hits += scan_file(rel, stream.read())
        except (OSError, UnicodeDecodeError):
            continue
    return hits, len(files)


def main(argv: list[str]) -> int:
    root = os.path.abspath(argv[1] if len(argv) > 1 else os.path.join(os.path.dirname(__file__), "../.."))
    hits, count = scan(root)
    for hit in hits:
        print(hit)
    if hits:
        print(f"{len(hits)} fleet host name(s) in gallery fixtures; rename each to a neutral machine name.",
              file=sys.stderr)
        return 1
    print(f"Fixture host names: ok ({count} fixture files)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
