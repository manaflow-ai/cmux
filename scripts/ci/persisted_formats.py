#!/usr/bin/env python3
"""Every on-disk format a cmux-tui build leaves for the next build ships its migration.

Leo, 2026-11-24 (ask-1f9e8b7422): "we need to make sure in the future these kinds of cutovers always
have proper migrations. in the future."

The registry is cmux-tui/persisted-formats/formats.toml; its header says what each policy means. This
check reads it at HEAD and at the base commit and fails when:

  - a registered `file` or `const` is gone, or a policy is missing what it needs (`why`, `fixtures`,
    `test`, `floor`);
  - a version constant under cmux-tui/crates/*/src that names stored data is not registered;
  - a `migrate` format has no fixture for its current version, or its `test` is not in its crate;
  - a fixture the base had is edited or deleted, other than below a `floor` this change raises;
  - a version constant goes down;
  - an `unreviewed` entry is new, or an unreviewed format's version changes (give it a policy first).

The Rust tests the registry names (cmux_next_persisted_*) load every fixture through the real reader;
this script checks what they cannot see: the base.

  python3 scripts/ci/persisted_formats.py [--root DIR] [--base REV]

The base defaults to $GITHUB_BASE_SHA, else HEAD^1 (CI's merge commit). A base without the registry
(the change that adds it) skips the comparisons.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tomllib
from pathlib import Path

TUI = "cmux-tui"
REGISTRY = f"{TUI}/persisted-formats/formats.toml"
FIXTURES = f"{TUI}/persisted-formats"
POLICIES = ("migrate", "rebuild", "unreviewed")
CONST_RE = re.compile(r"^\s*(?:pub(?:\([a-z]+\))?\s+)?const\s+([A-Z0-9_]*VERSION[A-Z0-9_]*)\s*:\s*u\d+\s*=\s*(\d+)\s*;", re.M)
# Names that say the number is stored on disk; a wire, protocol or ABI version is not.
STORED = re.compile(r"RECORD|FORMAT|SCHEMA|STATE|STORE|JOURNAL|CACHE|SNAPSHOT|DB_|FILE|LEDGER|MANIFEST|INDEX")
NOT_STORED = re.compile(r"ABI|PROTOCOL|WIRE")
FIXTURE_RE = re.compile(r"v(\d+)(?:-(\d+))?\.json")


def git(root: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True)


def show(root: Path, rev: str, path: str) -> str | None:
    out = git(root, "show", f"{rev}:{path}")
    return out.stdout if out.returncode == 0 else None


def const_value(text: str | None, name: str) -> int | None:
    if text is None:
        return None
    for found, value in CONST_RE.findall(text):
        if found == name:
            return int(value)
    return None


def scan_constants(root: Path) -> set[tuple[str, str]]:
    """(file under cmux-tui, const) for every stored-data version constant in crate sources."""
    found = set()
    for path in sorted((root / TUI / "crates").glob("*/src/**/*.rs")):
        rel = path.relative_to(root / TUI).as_posix()
        if "/tests/" in rel or path.stem.endswith(("_test", "_tests")) or path.stem == "tests":
            continue
        for name, _ in CONST_RE.findall(path.read_text(encoding="utf-8", errors="replace")):
            if STORED.search(name) and not NOT_STORED.search(name):
                found.add((rel, name))
    return found


def fixture_version(name: str) -> tuple[int, int] | None:
    match = FIXTURE_RE.fullmatch(name)
    return (int(match[1]), int(match[2] or 1)) if match else None


def base_fixtures(root: Path, base: str, folder: str) -> dict[str, str]:
    out = git(root, "ls-tree", "--name-only", f"{base}:{FIXTURES}/{folder}")
    if out.returncode != 0:
        return {}
    return {name: show(root, base, f"{FIXTURES}/{folder}/{name}") or "" for name in out.stdout.split()}


def check(root: Path, base: str | None) -> list[str]:
    errors: list[str] = []
    registry_path = root / REGISTRY
    if not registry_path.is_file():
        return [f"{REGISTRY}: missing"]
    formats = tomllib.loads(registry_path.read_text(encoding="utf-8")).get("format", [])
    base_text = show(root, base, REGISTRY) if base else None
    base_formats = {(f["file"], f["const"]): f for f in tomllib.loads(base_text).get("format", [])} if base_text else None

    seen: set[tuple[str, str]] = set()
    for entry in formats:
        key = (entry.get("file", ""), entry.get("const", ""))
        label = f"{REGISTRY}: {entry.get('name') or key}"
        if key in seen:
            errors.append(f"{label}: registered twice")
        seen.add(key)
        policy = entry.get("policy")
        if policy not in POLICIES:
            errors.append(f"{label}: policy must be one of {', '.join(POLICIES)}")
            continue
        source = root / TUI / key[0]
        current = const_value(source.read_text(encoding="utf-8", errors="replace") if source.is_file() else None, key[1])
        if current is None:
            errors.append(f"{label}: no `const {key[1]}: uN = N;` in {TUI}/{key[0]} (moved? update the entry)")
            continue
        old = base_formats.get(key) if base_formats is not None else None
        before = const_value(show(root, base, f"{TUI}/{key[0]}"), key[1]) if base else None
        if before is not None and current < before:
            errors.append(f"{label}: {key[1]} went down from {before} to {current}; an older build's data at "
                          f"{before} would read as {current}. Raise it past {before} instead")

        if policy == "rebuild" and not entry.get("why"):
            errors.append(f"{label}: a rebuild format says `why` losing it across an update costs no work")
        elif policy == "unreviewed":
            if base_formats is not None and (old is None or old.get("policy") != "unreviewed"):
                errors.append(f"{label}: a new entry cannot be unreviewed; give it `migrate` (with fixtures and a "
                              f"test) or `rebuild` (with a why)")
            if before is not None and current != before:
                errors.append(f"{label}: {key[1]} changed from {before} to {current} while the format is unreviewed. "
                              f"Say what an update does with the old data: policy `migrate` with fixtures of the old "
                              f"and new shapes and a test that loads them, or `rebuild` with a why")
        elif policy == "migrate":
            errors += check_migrate(root, base, entry, label, current, old)

    for rel, name in sorted(scan_constants(root) - seen):
        errors.append(f"{TUI}/{rel}: {name} looks like a stored format's version and is not in {REGISTRY}. "
                      f"Register it as `migrate` (fixtures + a cmux_next_persisted_ test) or `rebuild` (a why)")
    return errors


def check_migrate(root: Path, base: str | None, entry: dict, label: str, current: int, old: dict | None) -> list[str]:
    errors = []
    folder, test, floor = entry.get("fixtures"), entry.get("test"), entry.get("floor")
    if not folder or not test or not isinstance(floor, int):
        return [f"{label}: a migrate format names `fixtures`, `test` and `floor`"]
    directory = root / FIXTURES / folder
    versions = {name: fixture_version(name) for name in os.listdir(directory)} if directory.is_dir() else {}
    for name, version in versions.items():
        if version is None:
            errors.append(f"{FIXTURES}/{folder}/{name}: a fixture is named v<N>.json or v<N>-<rev>.json")
    if not any(v and v[0] == current for v in versions.values()):
        errors.append(f"{label}: no fixture of version {current} in {FIXTURES}/{folder}; add v{current}.json, "
                      f"a record exactly as this build writes it")
    if floor > current:
        errors.append(f"{label}: floor {floor} is above the current version {current}")
    crate = root / TUI / Path(entry["file"]).parts[0] / Path(entry["file"]).parts[1]
    if not any(f"fn {test}" in p.read_text(encoding="utf-8", errors="replace") for p in crate.rglob("*.rs")):
        errors.append(f"{label}: no test `{test}*` in {TUI}/{crate.relative_to(root / TUI)}")
    if base:
        old_floor = old.get("floor", floor) if old and old.get("policy") == "migrate" else floor
        for name, text in base_fixtures(root, base, folder).items():
            version = fixture_version(name)
            dropped = version is not None and version[0] < floor and floor > old_floor
            path = directory / name
            if dropped:
                continue
            if not path.is_file():
                errors.append(f"{FIXTURES}/{folder}/{name}: deleted. Data that shape is still on someone's disk; "
                              f"stop reading it only by raising `floor` past v{version[0] if version else '?'} "
                              f"in the same change")
            elif path.read_text(encoding="utf-8") != text:
                errors.append(f"{FIXTURES}/{folder}/{name}: edited. A fixture is what an older build wrote and never "
                              f"changes; add the new shape as a new v<N>-<rev>.json")
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=None)
    parser.add_argument("--base", default=None)
    args = parser.parse_args(argv)
    root = args.root or Path(git(Path.cwd(), "rev-parse", "--show-toplevel").stdout.strip() or ".")
    base = args.base or os.environ.get("GITHUB_BASE_SHA") or None
    if base is None:
        parent = git(root, "rev-parse", "--verify", "-q", "HEAD^1")
        base = parent.stdout.strip() if parent.returncode == 0 else None
    errors = check(root, base)
    for error in errors:
        print(f"persisted-formats: {error}", file=sys.stderr)
    if errors:
        print(f"persisted-formats: {len(errors)} problem(s); see {REGISTRY}'s header", file=sys.stderr)
        return 1
    print(f"persisted-formats: ok (base {base or 'none'})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
