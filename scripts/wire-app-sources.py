#!/usr/bin/env python3
"""Wire Sources/**/*.swift files into the cmux app target.

`scripts/sync-test-wiring` reconciles cmuxTests only; app sources were added
by hand, and a merge that takes main's project.pbxproj silently drops a
branch's new app files. This adds the four entries Xcode needs for each file
(PBXBuildFile, PBXFileReference, group child, app Sources phase) and
normalizes the project.

    scripts/wire-app-sources.py                 # wire every unwired file
    scripts/wire-app-sources.py Sources/X.swift # wire these
    scripts/wire-app-sources.py --check         # exit 1 if any is unwired

After a merge that took main's project.pbxproj, run it with no arguments.

Paths are resolved through the real group tree from the `Sources` group, so
a file lands in the deepest group that owns its directory (the Sources group
itself for `Sidebar/X.swift`, the Cloud group for `Cloud/X.swift`), with a
path relative to that group. Wired means a cmux Sources-phase build file
refers to that resolved path; files in scripts/pbxproj-sources-wiring-
allowlist.txt are left alone. IDs are derived from the path, so reruns and
parallel branches agree.
"""

from __future__ import annotations

import argparse
import hashlib
import posixpath
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PBXPROJ = Path("cmux.xcodeproj/project.pbxproj")
ALLOWLIST = Path("scripts/pbxproj-sources-wiring-allowlist.txt")

FILE_REF = re.compile(
    # Not line-anchored: the project has lines holding two entries.
    r"(?P<id>[0-9A-Za-z]+) /\* [^*]*? \*/ = \{isa = PBXFileReference;(?P<body>[^}\n]*)\};"
)
BUILD_FILE = re.compile(
    r"(?P<id>[0-9A-Za-z]+) /\* [^*]*? \*/ = \{isa = PBXBuildFile; fileRef = (?P<ref>[0-9A-Za-z]+) "
)
GROUP = re.compile(
    r"^\t+(?P<id>[0-9A-Za-z]+) /\* [^\n]*? \*/ = \{\n\t+isa = PBXGroup;\n\t+children = \(\n(?P<children>.*?)\t+\);\n(?P<rest>.*?)\n\t+\};$",
    re.M | re.S,
)
CHILD_ID = re.compile(r"^\t+([0-9A-Za-z]+) /\*", re.M)


def setting(body: str, key: str) -> str | None:
    match = re.search(r"\b" + key + r' = ("(?:[^"\\]|\\.)*"|[^;]+);', body)
    if not match:
        return None
    value = match.group(1)
    return value[1:-1] if value.startswith('"') else value


def quoted(value: str) -> str:
    """OpenStep plists leave only these characters unquoted."""
    return value if re.fullmatch(r"[A-Za-z0-9_./$-]+", value) else f'"{value}"'


def object_id(seed: str) -> str:
    return hashlib.sha1(seed.encode()).hexdigest()[:24].upper()


@dataclass
class Group:
    id: str
    directory: str  # repo-relative
    depth: int
    children: list[str] = field(default_factory=list)
    children_span: tuple[int, int] = (0, 0)


@dataclass
class Project:
    text: str
    groups: dict[str, Group]
    ref_paths: dict[str, str]  # file ref id -> repo-relative path, under Sources
    app_phase_span: tuple[int, int]

    @property
    def wired_paths(self) -> set[str]:
        start, end = self.app_phase_span
        phase_ids = set(CHILD_ID.findall(self.text[start:end]))
        return {
            self.ref_paths[match.group("ref")]
            for match in BUILD_FILE.finditer(self.text)
            if match.group("id") in phase_ids and match.group("ref") in self.ref_paths
        }


def parse(text: str) -> Project:
    refs = {m.group("id"): m.group("body") for m in FILE_REF.finditer(text)}
    raw_groups = {}
    for match in GROUP.finditer(text):
        raw_groups[match.group("id")] = (
            CHILD_ID.findall(match.group("children")),
            setting(match.group("rest"), "path"),
            setting(match.group("rest"), "sourceTree"),
            match.span("children"),
        )
    root_id = next(
        (gid for gid, (_, path, tree, _) in raw_groups.items() if path == "Sources" and tree == '<group>'),
        None,
    )
    if root_id is None:
        raise SystemExit("wire-app-sources: the Sources group was not found")

    groups: dict[str, Group] = {}
    ref_paths: dict[str, str] = {}

    def walk(gid: str, directory: str, depth: int) -> None:
        children, _, _, span = raw_groups[gid]
        groups[gid] = Group(gid, directory, depth, children, span)
        for child in children:
            if child in raw_groups:
                _, path, tree, _ = raw_groups[child]
                if tree == "<group>":
                    walk(child, posixpath.normpath(posixpath.join(directory, path)) if path else directory, depth + 1)
            elif child in refs and setting(refs[child], "sourceTree") == "<group>":
                path = setting(refs[child], "path")
                if path:
                    ref_paths[child] = posixpath.normpath(posixpath.join(directory, path))

    walk(root_id, "Sources", 0)
    # Some refs are repo-relative (`sourceTree = SOURCE_ROOT`) wherever they sit.
    for ref, body in refs.items():
        if setting(body, "sourceTree") == "SOURCE_ROOT" and setting(body, "path"):
            ref_paths[ref] = posixpath.normpath(setting(body, "path"))
    return Project(text, groups, ref_paths, app_sources_phase(text))


def app_sources_phase(text: str) -> tuple[int, int]:
    """Span of the cmux app target's PBXSourcesBuildPhase `files = (...)` list."""
    target = re.search(
        r"/\* cmux \*/ = \{\s*isa = PBXNativeTarget;.*?buildPhases = \((.*?)\);", text, re.S
    )
    if not target:
        raise SystemExit("wire-app-sources: cmux PBXNativeTarget not found")
    phase_id = re.search(r"([0-9A-Za-z]+) /\* Sources \*/", target.group(1))
    if not phase_id:
        raise SystemExit("wire-app-sources: cmux target has no Sources phase")
    block = re.search(
        re.escape(phase_id.group(1)) + r" /\* Sources \*/ = \{.*?files = \((.*?)\);", text, re.S
    )
    if not block:
        raise SystemExit("wire-app-sources: cmux Sources phase block not found")
    return block.start(1), block.end(1)


def allowlisted(root: Path) -> set[str]:
    path = root / ALLOWLIST
    if not path.exists():
        return set()
    entries = set()
    for line in path.read_text().splitlines():
        entry = line.split("#", 1)[0].strip()  # same as the lint: inline comments allowed
        if entry:
            entries.add(entry)
    return entries


def unwired_sources(root: Path, text: str) -> list[str]:
    wired = parse(text).wired_paths
    allow = allowlisted(root)
    return [
        rel
        for rel in (path.relative_to(root).as_posix() for path in sorted((root / "Sources").rglob("*.swift")))
        if rel not in allow and rel not in wired
    ]


def owning_group(project: Project, rel: str) -> Group:
    """The deepest group whose directory contains `rel`; among groups with
    the same directory, one that already holds a file from that directory."""
    directory = posixpath.dirname(rel)
    candidates = [
        group
        for group in project.groups.values()
        if directory == group.directory or directory.startswith(group.directory + "/")
    ]
    if not candidates:
        raise SystemExit(f"wire-app-sources: {rel} is outside the Sources group")
    deepest = max(len(group.directory) for group in candidates)
    candidates = [group for group in candidates if len(group.directory) == deepest]

    def holds_sibling(group: Group) -> bool:
        return any(posixpath.dirname(project.ref_paths.get(child, "")) == directory for child in group.children)

    return max(candidates, key=lambda group: (holds_sibling(group), group.depth))


def wire(text: str, rel: str) -> str:
    project = parse(text)
    if rel in project.wired_paths:
        return text
    name = posixpath.basename(rel)
    group = owning_group(project, rel)
    group_path = posixpath.relpath(rel, group.directory)
    ref_id = object_id("fileref:" + rel)
    build_id = object_id("buildfile:" + rel)

    # Insert from the end of the file backwards so earlier offsets stay valid.
    insertions = [
        (project.app_phase_span[1], f"\t\t\t\t{build_id} /* {name} in Sources */,\n", True),
        (group.children_span[1], f"\t\t\t\t{ref_id} /* {name} */,\n", True),
        (
            text.index("/* Begin PBXFileReference section */\n") + len("/* Begin PBXFileReference section */\n"),
            f'\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
            f'path = {quoted(group_path)}; sourceTree = "<group>"; }};\n',
            False,
        ),
        (
            text.index("/* Begin PBXBuildFile section */\n") + len("/* Begin PBXBuildFile section */\n"),
            f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref_id} /* {name} */; }};\n",
            False,
        ),
    ]
    for offset, line, before_closing in sorted(insertions, key=lambda item: item[0], reverse=True):
        if before_closing:
            # The span ends right before the closing `\t\t\t);`; keep the
            # list's last line terminated.
            offset = text.rindex("\n", 0, offset) + 1
        text = text[:offset] + line + text[offset:]
    return text


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("paths", nargs="*", help="Sources/... files; default: every unwired one")
    parser.add_argument("--check", action="store_true", help="list unwired files and exit 1 if any")
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args(argv)

    pbxproj = args.root / PBXPROJ
    text = pbxproj.read_text()
    targets = args.paths or unwired_sources(args.root, text)
    if args.check:
        for rel in targets:
            print(f"unwired: {rel}", flush=True)
        print(f"wire-app-sources: {'ok' if not targets else f'{len(targets)} unwired'}", flush=True)
        return 1 if targets else 0
    changed = False
    for rel in targets:
        if rel in parse(text).wired_paths:
            print(f"already wired: {rel}", flush=True)
            continue
        text = wire(text, rel)
        changed = True
        print(f"wired: {rel}", flush=True)
    if changed:
        pbxproj.write_text(text)
        # The pre-commit hook and check-pbxproj.sh require normalized output.
        subprocess.run([sys.executable, str(args.root / "scripts/normalize-pbxproj.py"), str(pbxproj)], check=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
