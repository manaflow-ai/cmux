#!/usr/bin/env python3
"""Fail when a file a build phase uses belongs to no group in the project.

Xcode files such a reference under a synthesized "Recovered References" group whose id is new on every
project load. The project's PIF then differs on every build, so Xcode can never reuse its build
description and re-plans every build, no-ops included. #12976 fixed the first case; two more files
(MacDevicesComposition.swift, SurfaceCatalogSnapshot+DeviceVisibility.swift) slipped back in unnoticed.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PBXPROJ = ROOT / "cmux.xcodeproj/project.pbxproj"

OBJECT_RE = re.compile(r"^\t+(?P<id>[0-9A-Za-z]+)(?: /\* (?P<name>[^*]*?) \*/)? = \{(?P<body>.*?)\};$", re.M | re.S)
FILE_REF_RE = re.compile(r"\bfileRef = (?P<id>[0-9A-Za-z]+)\b")
CHILDREN_RE = re.compile(r"\bchildren = \((?P<ids>[^)]*)\);", re.S)
FILES_RE = re.compile(r"\bfiles = \((?P<ids>[^)]*)\);", re.S)
ID_RE = re.compile(r"\b([0-9A-Za-z]{8,24})\b(?= /\*)")


def main() -> int:
    text = (Path(sys.argv[1]) if len(sys.argv) > 1 else PBXPROJ).read_text(encoding="utf-8")
    objects = {m["id"]: (m["name"] or m["id"], m["body"]) for m in OBJECT_RE.finditer(text)}
    in_group: set[str] = set()
    in_phase: set[str] = set()
    for body in (b for _, b in objects.values()):
        if "isa = PBXGroup;" in body or "isa = PBXVariantGroup;" in body or "isa = XCVersionGroup;" in body:
            children = CHILDREN_RE.search(body)
            if children:
                in_group.update(ID_RE.findall(children["ids"]))
        elif re.search(r"isa = PBX\w+BuildPhase;", body):
            files = FILES_RE.search(body)
            if files:
                in_phase.update(ID_RE.findall(files["ids"]))
    # Only build files a phase lists count: a stale PBXBuildFile no phase uses builds nothing.
    used: dict[str, str] = {}
    for bid in in_phase:
        ref = FILE_REF_RE.search(objects.get(bid, ("", ""))[1])
        if ref:
            used[ref["id"]] = objects[bid][0]
    orphans = sorted(ref for ref in used if ref not in in_group and ref in objects
                     and "isa = PBXFileReference;" in objects[ref][1])
    for ref in orphans:
        print(f"::error file=cmux.xcodeproj/project.pbxproj::{objects[ref][0]} ({ref}) is built but belongs to no "
              "group; Xcode recovers it under a group with a new id on every load, so every build re-plans. "
              "Add it to the group that holds its siblings.", file=sys.stderr)
    return 1 if orphans else 0


if __name__ == "__main__":
    sys.exit(main())
