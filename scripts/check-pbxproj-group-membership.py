#!/usr/bin/env python3
"""Fail when a file a build phase uses is not reachable from the project's main group.

Xcode files such a reference under a synthesized "Recovered References" group whose id is new on every
project load. The project's PIF then differs on every build, so Xcode can never reuse its build
description and re-plans every build, no-ops included. #12976 fixed the first case; two more files
(MacDevicesComposition.swift, SurfaceCatalogSnapshot+DeviceVisibility.swift) slipped back in unnoticed.

The project is parsed with normalize-pbxproj.py's tokenizer, so indentation, several objects on one line
and id length do not matter.
"""

from __future__ import annotations

import importlib.util
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PBXPROJ = ROOT / "cmux.xcodeproj/project.pbxproj"

_spec = importlib.util.spec_from_file_location("normalize_pbxproj", Path(__file__).with_name("normalize-pbxproj.py"))
_normalize = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_normalize)


def parse(text: str) -> dict:
    """Parse an OpenStep plist into dicts, lists and strings (quotes stripped, comments dropped)."""
    _normalize.validate_syntax(text)
    tokens = []
    for match in _normalize.OPENSTEP_TOKEN_RE.finditer(text):
        if match["comment"]:
            continue
        token = match.group()
        if match["string"]:
            token = ("str", re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m[1], m[1]), token[1:-1]))
        tokens.append(token)
    index = 0

    def value():
        nonlocal index
        token = tokens[index]
        index += 1
        if token == "{":
            result = {}
            while tokens[index] != "}":
                key = value()
                index += 1  # "="
                result[key] = value()
                index += 1  # ";"
            index += 1
            return result
        if token == "(":
            result = []
            while tokens[index] != ")":
                result.append(value())
                if tokens[index] == ",":
                    index += 1
            index += 1
            return result
        return token[1] if isinstance(token, tuple) else token

    return value()


def orphans(project: dict) -> list[tuple[str, str]]:
    objects = project["objects"]
    main_group = objects[project["rootObject"]]["mainGroup"]
    reachable: set[str] = set()
    pending = [main_group]
    while pending:
        oid = pending.pop()
        if oid in reachable or oid not in objects:
            continue
        reachable.add(oid)
        pending.extend(objects[oid].get("children", []))
    built: dict[str, None] = {}
    for obj in objects.values():
        if obj.get("isa", "").endswith("BuildPhase"):
            for build_file in obj.get("files", []):
                ref = objects.get(build_file, {}).get("fileRef")
                if ref:
                    built[ref] = None
    # Only plain file references: product references and package products live elsewhere.
    return sorted((ref, objects[ref].get("path") or objects[ref].get("name") or ref) for ref in built
                  if ref in objects and objects[ref].get("isa") == "PBXFileReference"
                  and objects[ref].get("sourceTree") != "BUILT_PRODUCTS_DIR" and ref not in reachable)


def main() -> int:
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else PBXPROJ
    found = orphans(parse(path.read_text(encoding="utf-8")))
    for ref, name in found:
        print(f"::error file=cmux.xcodeproj/project.pbxproj::{name} ({ref}) is built but no group under the main "
              "group holds it; Xcode recovers it under a group with a new id on every load, so every build "
              "re-plans. Add it to the group that holds its siblings.", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
