#!/usr/bin/env python3
"""Wire Sources/**/*.swift files into the cmux app target.

`scripts/sync-test-wiring` reconciles cmuxTests only; app sources were added
by hand, and a merge that takes main's project.pbxproj silently drops a
branch's new app files. This adds the four entries Xcode needs for each file
(PBXBuildFile, PBXFileReference, group child, app Sources phase), each placed
next to an already-wired file from the same directory, with IDs derived from
the path so reruns and parallel branches agree.

    scripts/wire-app-sources.py                 # wire every unwired file
    scripts/wire-app-sources.py Sources/X.swift # wire these
    scripts/wire-app-sources.py --check         # exit 1 if any is unwired

After a merge that took main's project.pbxproj, run it with no arguments.

Unwired means `lint-pbxproj-test-wiring.sh --target cmux` would flag it:
not a member of the cmux Sources phase and not in
scripts/pbxproj-sources-wiring-allowlist.txt.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PBXPROJ = Path("cmux.xcodeproj/project.pbxproj")
ALLOWLIST = Path("scripts/pbxproj-sources-wiring-allowlist.txt")


def object_id(seed: str) -> str:
    return hashlib.sha1(seed.encode()).hexdigest()[:24].upper()


def app_sources_phase(text: str) -> tuple[int, int]:
    """Span of the cmux app target's PBXSourcesBuildPhase `files = (...)` list."""
    target = re.search(
        r"/\* cmux \*/ = \{\s*isa = PBXNativeTarget;.*?buildPhases = \((.*?)\);",
        text,
        re.S,
    )
    if not target:
        raise SystemExit("wire-app-sources: cmux PBXNativeTarget not found")
    phase_id = re.search(r"([0-9A-Za-z]+) /\* Sources \*/", target.group(1))
    if not phase_id:
        raise SystemExit("wire-app-sources: cmux target has no Sources phase")
    block = re.search(
        re.escape(phase_id.group(1)) + r" /\* Sources \*/ = \{.*?files = \((.*?)\);",
        text,
        re.S,
    )
    if not block:
        raise SystemExit("wire-app-sources: cmux Sources phase block not found")
    return block.start(1), block.end(1)


def wired_names(text: str) -> set[str]:
    start, end = app_sources_phase(text)
    return set(re.findall(r"/\* (.+?) in Sources \*/", text[start:end]))


def unwired_sources(root: Path, text: str) -> list[str]:
    allow = set()
    if (root / ALLOWLIST).exists():
        allow = {
            line.strip()
            for line in (root / ALLOWLIST).read_text().splitlines()
            if line.strip() and not line.startswith("#")
        }
    names = wired_names(text)
    result = []
    for path in sorted((root / "Sources").rglob("*.swift")):
        rel = path.relative_to(root).as_posix()
        if rel not in allow and path.name not in names:
            result.append(rel)
    return result


def quoted(value: str) -> str:
    """OpenStep plists leave only these characters unquoted."""
    return value if re.fullmatch(r"[A-Za-z0-9_./$-]+", value) else f'"{value}"'


def wire(text: str, rel: str) -> str:
    """Adds `rel` (Sources/...) next to a wired sibling from its directory."""
    name = Path(rel).name
    directory = Path(rel).parent.relative_to("Sources").as_posix()
    prefix = "" if directory == "." else directory + "/"
    siblings = re.findall(
        r"\t\t([0-9A-Za-z]+) /\* [^*]*? \*/ = \{isa = PBXFileReference; lastKnownFileType = sourcecode\.swift; path = "
        + re.escape(prefix)
        + r"[^/;]+\.swift; sourceTree = \"<group>\"; \};",
        text,
    )
    start, end = app_sources_phase(text)
    phase = text[start:end]
    sibling_ref = next(
        (ref for ref in siblings if re.search(r"fileRef = " + ref + r" ", text) and ref in text),
        None,
    )
    sibling_build = None
    for ref in siblings:
        build = re.search(r"\t\t([0-9A-Za-z]+) /\* [^*]+ in Sources \*/ = \{isa = PBXBuildFile; fileRef = " + ref + " ", text)
        if build and build.group(1) in phase:
            sibling_ref, sibling_build = ref, build.group(1)
            break
    if not sibling_build:
        raise SystemExit(f"wire-app-sources: no wired sibling in Sources/{prefix} for {rel}")

    ref_id = object_id("fileref:" + rel)
    build_id = object_id("buildfile:" + rel)
    lines = text.split("\n")

    def insert_after(pattern: str, new_line: str, within: tuple[int, int] | None = None) -> None:
        for i, line in enumerate(lines):
            if re.search(pattern, line):
                if within:
                    offset = sum(len(l) + 1 for l in lines[:i])
                    if not within[0] <= offset <= within[1]:
                        continue
                indent = re.match(r"\s*", line).group(0)
                lines.insert(i + 1, indent + new_line)
                return
        raise SystemExit(f"wire-app-sources: anchor {pattern!r} not found for {rel}")

    insert_after(
        r"^\t\t" + sibling_build + r" /\* .* \*/ = \{isa = PBXBuildFile;",
        f"{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref_id} /* {name} */; }};",
    )
    insert_after(
        r"^\t\t" + sibling_ref + r" /\* .* \*/ = \{isa = PBXFileReference;",
        f'{ref_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quoted(prefix + name)}; sourceTree = "<group>"; }};',
    )
    insert_after(r"^\t+" + sibling_ref + r" /\* .* \*/,$", f"{ref_id} /* {name} */,")
    text = "\n".join(lines)
    start, end = app_sources_phase(text)
    lines = text.split("\n")
    insert_after(r"^\t+" + sibling_build + r" /\* .* in Sources \*/,$", f"{build_id} /* {name} in Sources */,", (start, end))
    return "\n".join(lines)


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
            print(f"unwired: {rel}")
        print(f"wire-app-sources: {'ok' if not targets else f'{len(targets)} unwired'}")
        return 1 if targets else 0
    for rel in targets:
        if Path(rel).name in wired_names(text):
            print(f"already wired: {rel}")
            continue
        text = wire(text, rel)
        print(f"wired: {rel}")
    pbxproj.write_text(text)
    if targets:
        # The pre-commit hook and check-pbxproj.sh require normalized output.
        subprocess.run([sys.executable, str(args.root / "scripts/normalize-pbxproj.py"), str(pbxproj)], check=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
