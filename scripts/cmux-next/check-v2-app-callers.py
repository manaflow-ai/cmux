#!/usr/bin/env python3
"""Check the row 7f inventory of app-side v1 list callers.

The inventory is deliberately lexical.  It covers the Swift source tree, including the
comments and the Home capture fixture that describe the old wire.  A migration removes its
inventory entry with the old call; adding a call without an entry is a failure in the same
change.  This keeps the v1 fallback visible until its replacement has a recorded run.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any, Iterable


DEFAULT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST = Path(__file__).with_name("v2-app-callers.json")
SOURCE_ROOT = "Packages/macOS/CmuxNext/Sources"
METHODS = ("_acpmux/watch", "_acpmux/sessions", "session/list")

# Match a method as a complete method name.  In particular, `_acpmux/watch_take_over` and
# `_acpmux/sessions/restart_harness` are different methods and are intentionally excluded.
METHOD_RE = {method: re.compile(re.escape(method) + r"(?![A-Za-z0-9_])") for method in METHODS}
EXCLUDED_RE = re.compile(
    r"(?:_acpmux/watch_take_over|_acpmux/sessions/restart_harness)(?![A-Za-z0-9_])"
)


def _relative(path: Path, root: Path) -> str:
    return path.relative_to(root).as_posix()


def _source_files(root: Path) -> Iterable[Path]:
    source = root / SOURCE_ROOT
    if not source.is_dir():
        return ()
    return sorted(path for path in source.rglob("*.swift") if path.is_file())


def _counts(root: Path) -> tuple[Counter[tuple[str, str]], list[str]]:
    counts: Counter[tuple[str, str]] = Counter()
    errors: list[str] = []
    for path in _source_files(root):
        relative = _relative(path, root)
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as error:
            errors.append(f"{relative}: cannot read source: {error}")
            continue
        for line in text.splitlines():
            # Remove only the exact excluded method token.  The surrounding comment or JSON
            # remains visible, while the prefix `_acpmux/watch` is not counted as a watch call.
            if EXCLUDED_RE.search(line):
                line = EXCLUDED_RE.sub("", line)
            for method, pattern in METHOD_RE.items():
                found = len(pattern.findall(line))
                if found:
                    counts[(relative, method)] += found
    return counts, errors


def _manifest_entries(value: Any, manifest_path: Path) -> tuple[list[dict[str, Any]], list[str]]:
    if isinstance(value, dict):
        raw = value.get("callers")
    else:
        raw = value
    if not isinstance(raw, list):
        return [], [f"{manifest_path}: expected a callers array"]
    entries: list[dict[str, Any]] = []
    errors: list[str] = []
    required = ("path", "symbol", "method", "count", "owner", "kind")
    for index, entry in enumerate(raw):
        if not isinstance(entry, dict):
            errors.append(f"{manifest_path}: callers[{index}] is not an object")
            continue
        missing = [field for field in required if field not in entry]
        if missing:
            errors.append(f"{manifest_path}: callers[{index}] missing {', '.join(missing)}")
            continue
        if entry["method"] not in METHODS:
            errors.append(f"{manifest_path}: callers[{index}] has unknown method {entry['method']!r}")
        if not isinstance(entry["path"], str) or not entry["path"].endswith(".swift"):
            errors.append(f"{manifest_path}: callers[{index}] path is not a Swift path")
        if not isinstance(entry["symbol"], str) or not entry["symbol"].strip():
            errors.append(f"{manifest_path}: callers[{index}] has an empty symbol")
        if not isinstance(entry["owner"], str) or not entry["owner"].strip():
            errors.append(f"{manifest_path}: callers[{index}] has an empty owner")
        if entry["kind"] not in {"emitter", "relay", "fixture", "comment"}:
            errors.append(f"{manifest_path}: callers[{index}] has unknown kind {entry['kind']!r}")
        if isinstance(entry["count"], bool) or not isinstance(entry["count"], int) or entry["count"] <= 0:
            errors.append(f"{manifest_path}: callers[{index}] count must be a positive integer")
        entries.append(entry)
    return entries, errors


def check_inventory(root: Path, manifest_path: Path) -> list[str]:
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return [f"{manifest_path}: cannot read manifest: {error}"]
    entries, errors = _manifest_entries(manifest, manifest_path)
    actual, read_errors = _counts(root)
    errors.extend(read_errors)

    expected: Counter[tuple[str, str]] = Counter()
    seen: set[tuple[str, str, str]] = set()
    for entry in entries:
        key = (entry["path"], entry["method"])
        identity = (*key, entry["symbol"])
        if identity in seen:
            errors.append(f"{manifest_path}: duplicate caller {identity}")
        seen.add(identity)
        if isinstance(entry["count"], int) and not isinstance(entry["count"], bool):
            expected[key] += entry["count"]

    for key in sorted(set(actual) | set(expected)):
        observed = actual.get(key, 0)
        listed = expected.get(key, 0)
        path, method = key
        if observed and not listed:
            errors.append(f"unlisted app caller: {path} ({method}, observed {observed})")
        elif listed and not observed:
            errors.append(f"stale app caller entry: {path} ({method}, manifest {listed}, observed 0)")
        elif observed != listed:
            errors.append(f"stale app caller count: {path} ({method}, manifest {listed}, observed {observed})")

    # A path in the manifest must remain in the source tree even if its method count is malformed.
    source_paths = {_relative(path, root) for path in _source_files(root)}
    for entry in entries:
        if entry["path"] not in source_paths:
            errors.append(f"stale app caller path: {entry['path']}")
    return errors


def _recording_methods(value: Any) -> Iterable[str]:
    """Yield methods from common request-recording shapes (JSON or JSONL)."""
    if isinstance(value, dict):
        method = value.get("method")
        if isinstance(method, str):
            yield method
        for child in value.values():
            yield from _recording_methods(child)
    elif isinstance(value, list):
        for child in value:
            yield from _recording_methods(child)


def check_recording(
    path: Path, list_capable: bool | None, fallback_methods: set[str] | None = None
) -> list[str]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        return [f"{path}: cannot read recording: {error}"]
    values: list[Any] = []
    try:
        values.append(json.loads(text))
    except json.JSONDecodeError:
        for number, line in enumerate(text.splitlines(), 1):
            if not line.strip():
                continue
            try:
                values.append(json.loads(line))
            except json.JSONDecodeError as error:
                return [f"{path}:{number}: invalid JSON: {error}"]
    capability = list_capable
    for value in values:
        if isinstance(value, dict):
            for key in ("list_capable", "supports_list", "list"):
                if isinstance(value.get(key), bool):
                    capability = value[key]
    if capability is None:
        return [f"{path}: recording must declare list_capable (or pass --list-capable/--no-list-capable)"]
    counts = Counter(method for value in values for method in _recording_methods(value) if method in METHODS)
    if capability:
        return [f"{path}: list-capable recording emitted {method} ({count})" for method, count in sorted(counts.items()) if count]
    if fallback_methods is not None:
        return [
            f"{path}: old-daemon recording emitted unnamed fallback {method} ({count})"
            for method, count in sorted(counts.items())
            if count and method not in fallback_methods
        ]
    return []


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="repository root")
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--recording", type=Path, action="append", default=[])
    capability = parser.add_mutually_exclusive_group()
    capability.add_argument("--list-capable", action="store_true", help="recording supports list/v2")
    capability.add_argument("--no-list-capable", action="store_true", help="recording is a v1 fallback")
    args = parser.parse_args(argv)

    errors = check_inventory(args.root.resolve(), args.manifest.resolve())
    fallback_methods: set[str] | None = None
    try:
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
        entries, _ = _manifest_entries(manifest, args.manifest)
        fallback_methods = {entry["method"] for entry in entries if entry.get("owner") == "7f"}
    except (OSError, json.JSONDecodeError):
        pass
    recording_capability = True if args.list_capable else False if args.no_list_capable else None
    for recording in args.recording:
        errors.extend(check_recording(recording.resolve(), recording_capability, fallback_methods))
    if errors:
        for error in errors:
            print(f"v2 app callers: {error}", file=sys.stderr)
        return 1
    print("v2 app callers: inventory and recordings pass")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
