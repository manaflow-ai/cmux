#!/usr/bin/env python3
"""Find familiar-intent regions touched by a pull-request patch.

The caller supplies the pull-request file patches as JSON. This checker is
deliberately advisory: it always exits successfully and emits a small JSON
result for the trusted pull_request_target workflow to turn into a comment.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


ATTRIBUTE = re.compile(r"(?P<key>[A-Za-z][A-Za-z0-9_-]*)=(?P<value>\"[^\"]*\"|[^\s]+)")
INTENT = re.compile(r"@intent\b(?P<rest>.*)")
DELTA = re.compile(r"(?im)^\s*Intent-Delta\s*:\s*(?P<value>\S.*)$")


def has_intent_delta(body: str) -> bool:
    """An optional ``Intent-Delta:`` line names the delta; a missing line, or ``none``, names none."""
    return any(match.group("value").strip().lower() != "none" for match in DELTA.finditer(body or ""))


def marker(line: str) -> dict[str, str] | None:
    match = INTENT.search(line)
    if not match:
        return None
    attrs = {
        item.group("key"): item.group("value").strip('"')
        for item in ATTRIBUTE.finditer(match.group("rest"))
    }
    if attrs.get("stability") != "familiar" or not attrs.get("owner"):
        return None
    owner = attrs["owner"].lstrip("@")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*", owner):
        return None
    return {"owner": owner, "stability": "familiar"}


def touched_markers(files: list[dict[str, Any]]) -> list[dict[str, str]]:
    findings: list[dict[str, str]] = []
    for file in files:
        path = str(file.get("filename") or file.get("path") or "")
        patch = file.get("patch")
        if not path or not isinstance(patch, str):
            continue
        # A marker in the same unified-diff hunk as a changed line identifies
        # the familiar region without treating an unrelated file marker as
        # touched. GitHub's patch always contains at least one +/- line.
        hunk_lines: list[str] = []
        for line in patch.splitlines():
            if line.startswith("@@"):
                findings.extend(_markers_in_hunk(path, hunk_lines))
                hunk_lines = []
            hunk_lines.append(line)
        findings.extend(_markers_in_hunk(path, hunk_lines))
    unique: dict[tuple[str, str], dict[str, str]] = {}
    for finding in findings:
        unique[(finding["path"], finding["owner"])] = finding
    return list(unique.values())


def _markers_in_hunk(path: str, lines: list[str]) -> list[dict[str, str]]:
    if not any(line.startswith(("+", "-")) and not line.startswith(("+++", "---")) for line in lines):
        return []
    owners = {found["owner"] for line in lines if (found := marker(line))}
    return [{"path": path, "owner": owner} for owner in sorted(owners)]


def inspect(body: str, files: list[dict[str, Any]]) -> dict[str, Any]:
    findings = touched_markers(files)
    return {
        "intent_delta": has_intent_delta(body),
        "warnings": findings if findings and not has_intent_delta(body) else [],
        "touched_familiar": findings,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--body-file", type=Path, required=True)
    parser.add_argument("--files-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        body = args.body_file.read_text(encoding="utf-8")
        files = json.loads(args.files_json.read_text(encoding="utf-8"))
        if not isinstance(files, list):
            raise ValueError("files JSON must be a list")
        result = inspect(body, files)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        # A warning hook must not become a merge gate because a patch was
        # unavailable (binary files and oversized patches are normal cases).
        result = {"intent_delta": False, "warnings": [], "touched_familiar": [], "error": str(error)}
    args.output.write_text(json.dumps(result, sort_keys=True), encoding="utf-8")
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
