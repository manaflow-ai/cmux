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


def orphans(project: dict, root: Path) -> list[tuple[str, str]]:
    objects = project["objects"]
    main_group = objects[project["rootObject"]]["mainGroup"]
    reachable: set[str] = set()
    synchronized_roots: list[str] = []
    pending = [main_group]
    while pending:
        oid = pending.pop()
        if oid in reachable or oid not in objects:
            continue
        reachable.add(oid)
        if objects[oid].get("isa") == "PBXFileSystemSynchronizedRootGroup":
            path = objects[oid].get("path")
            if path:
                synchronized_roots.append(path)
        pending.extend(objects[oid].get("children", []))
    built: dict[str, None] = {}
    for obj in objects.values():
        if obj.get("isa", "").endswith("BuildPhase"):
            for build_file in obj.get("files", []):
                ref = objects.get(build_file, {}).get("fileRef")
                if ref:
                    built[ref] = None
    # Only plain file references: product references and package products live elsewhere.
    missing = []
    for ref in built:
        if ref not in objects or objects[ref].get("isa") != "PBXFileReference":
            continue
        obj = objects[ref]
        if obj.get("sourceTree") == "BUILT_PRODUCTS_DIR" or ref in reachable:
            continue
        path = obj.get("path") or obj.get("name") or ref
        if obj.get("sourceTree") == "SOURCE_ROOT" and (root / path).exists():
            continue
        if obj.get("sourceTree") == "<group>" and any(
            (root / sync_root / path).exists() for sync_root in synchronized_roots
        ):
            continue
        missing.append((ref, path))
    return sorted(missing)


def main() -> int:
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else PBXPROJ
    root = path.parent.parent if path.parent.name.endswith(".xcodeproj") else path.parent
    found = orphans(parse(path.read_text(encoding="utf-8")), root)
    for ref, name in found:
        print(f"::error file=cmux.xcodeproj/project.pbxproj::{name} ({ref}) is built but no group under the main "
              "group holds it; Xcode recovers it under a group with a new id on every load, so every build "
              "re-plans. Add it to the group that holds its siblings.", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
