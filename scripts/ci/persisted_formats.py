#!/usr/bin/env python3
"""Every on-disk format a build leaves for the next build ships its migration.

Leo, 2026-11-24 (ask-1f9e8b7422): "we need to make sure in the future these kinds of cutovers always
have proper migrations. in the future." And 2026-11-25: "we need to not only build, but use."

Four kinds of stored data cross an update, and this one check covers each:

  cmux-tui    Rust `const *VERSION: uN = N;` under cmux-tui/crates/*/src (the acpmux store, terminal and
              agent hosts, caches): registry cmux-tui/persisted-formats/formats.toml.
  app         Swift `static let <x>Version = N` under Packages/*/*/Sources and cmux-next-ios/*/Sources
              (the app's snapshots, stores, records), and TypeScript `const *_VERSION = N` under
              webviews/src: registry persisted-formats/formats.toml, `[[format]]` entries.
  webviews    Every localStorage/sessionStorage key webviews/src names: the same registry's
              `[[storage_key]]` entries. A key's data is lost the moment the code stops naming it.
  settings    schemas/settings/published-keys.txt only grows and retired-keys.json never loses an entry
              (the migration table cmux-config applies); cmux-config's
              cmux_next_persisted_settings_keys test checks each key is a live row or retired.

Each registry's header says what its policies mean. This check reads them at HEAD and at the base commit
and fails when:

  - a registered `file` or `const` is gone, or a policy is missing what it needs (`why`, `fixtures`,
    `test`, `floor`);
  - a stored-format version constant is not registered;
  - a `migrate` format has no fixture for its current version, or its `test` cannot be found;
  - a fixture the base had is edited or deleted, other than below a `floor` this change raises;
  - a version constant goes down;
  - an `unreviewed` entry is new, or an unreviewed format's version changes (give it a policy first);
  - a webviews storage key is not registered, a registered key is no longer named by the code without
    `retired` saying why losing its data is fine, a retired key comes back, or an entry is deleted;
  - a published settings key or a retired-keys.json entry the base had is gone.

The tests a registry names load every fixture through the real reader; this script checks what they
cannot see: the base.

  python3 scripts/ci/persisted_formats.py [--root DIR] [--base REV]

The base defaults to $GITHUB_BASE_SHA, else HEAD^1 (CI's merge commit). A base without a registry
(the change that adds it) skips that registry's comparisons.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

TUI = "cmux-tui"
REGISTRY = f"{TUI}/persisted-formats/formats.toml"
FIXTURES = f"{TUI}/persisted-formats"
APP_REGISTRY = "persisted-formats/formats.toml"
APP_FIXTURES = "persisted-formats"
WEBVIEWS = "webviews/src"
PUBLISHED_KEYS = "schemas/settings/published-keys.txt"
RETIRED_KEYS = "schemas/settings/retired-keys.json"
POLICIES = ("migrate", "rebuild", "unreviewed")
CONST_RE = re.compile(r"^\s*(?:pub(?:\([a-z]+\))?\s+)?const\s+([A-Z0-9_]*VERSION[A-Z0-9_]*)\s*:\s*u\d+\s*=\s*(\d+)\s*;", re.M)
SWIFT_RE = re.compile(r"^\s*(?:(?:public|package|internal|private|fileprivate|nonisolated)\s+)*static\s+let\s+"
                      r"([a-z][A-Za-z0-9]*Version)\s*(?::\s*U?Int\d*)?\s*=\s*(\d+)\s*$", re.M)
TS_RE = re.compile(r"^\s*(?:export\s+)?const\s+([A-Z0-9_]*VERSION)\s*(?::\s*number)?\s*=\s*(\d+)\s*;?\s*$", re.M)
# Names that say the number is stored on disk; a wire, protocol or ABI version is not.
STORED = re.compile(r"RECORD|FORMAT|SCHEMA|STATE|STORE|JOURNAL|CACHE|SNAPSHOT|DB_|FILE|LEDGER|MANIFEST|INDEX")
NOT_STORED = re.compile(r"ABI|PROTOCOL|WIRE")
FIXTURE_RE = re.compile(r"v(\d+)(?:-(\d+))?\.json")
# A webviews storage key: a `cmux.` string held by a *Key/*KEY/*Prefix constant, or any string literal
# handed straight to localStorage/sessionStorage.
STORAGE_CONST_RE = re.compile(r"(?:const|let)\s+\w*(?:[Kk]ey|KEY|[Pp]refix|PREFIX)\w*\s*(?::\s*string)?\s*=\s*"
                              r"[\"'`](cmux\.[A-Za-z0-9_.:\-/]+)[\"'`]")
STORAGE_CALL_RE = re.compile(r"(?:localStorage|sessionStorage)\.(?:getItem|setItem|removeItem)\(\s*"
                             r"[\"'`]([^\"'`$\s]+)[\"'`]")


def git(root: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True)


def show(root: Path, rev: str, path: str) -> str | None:
    out = git(root, "show", f"{rev}:{path}")
    return out.stdout if out.returncode == 0 else None


def read(path: Path) -> str | None:
    return path.read_text(encoding="utf-8", errors="replace") if path.is_file() else None


def pattern_for(file: str) -> re.Pattern[str]:
    return SWIFT_RE if file.endswith(".swift") else TS_RE if file.endswith((".ts", ".tsx")) else CONST_RE


def const_value(text: str | None, name: str, pattern: re.Pattern[str] = CONST_RE) -> int | None:
    if text is None:
        return None
    for found, value in pattern.findall(text):
        if found == name:
            return int(value)
    return None


def is_test_path(rel: str) -> bool:
    name = rel.rsplit("/", 1)[-1]
    stem = name.split(".", 1)[0]
    return ("/tests/" in rel or "/Tests/" in rel or "/__tests__/" in rel or stem.endswith(("_test", "_tests"))
            or stem in ("tests", "test") or ".test." in name or ".spec." in name or "/fixtures/" in rel)


def stored_name(name: str) -> bool:
    upper = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "_", name).upper()
    return bool(STORED.search(upper)) and not NOT_STORED.search(upper)


def grep_files(root: Path, regex: str, globs: tuple[str, ...]) -> list[Path]:
    """The files under `globs` (tracked or not) with a line matching `regex`, through git grep: reading
    every source file is slow on a large tree, and only a few hold a version constant or a storage key."""
    out = git(root, "grep", "--untracked", "-l", "-I", "-E", regex, "--", *(f":(glob){g}" for g in globs))
    if out.returncode not in (0, 1):
        return sorted({p for g in globs for p in root.glob(g)})
    return sorted(root / line for line in out.stdout.splitlines() if line)


def scan_tui(root: Path) -> set[tuple[str, str]]:
    """(file under cmux-tui, const) for every stored-data version constant in crate sources."""
    found = set()
    for path in grep_files(root, r"const +[A-Z0-9_]*VERSION", (f"{TUI}/crates/*/src/**/*.rs",)):
        rel = path.relative_to(root / TUI).as_posix()
        if is_test_path(rel):
            continue
        for name, _ in CONST_RE.findall(read(path) or ""):
            if STORED.search(name) and not NOT_STORED.search(name):
                found.add((rel, name))
    return found


scan_constants = scan_tui


SWIFT_GLOBS = ("Packages/*/*/Sources/**/*.swift", "cmux-next-ios/*/Sources/**/*.swift")
WEB_GLOBS = (f"{WEBVIEWS}/**/*.ts", f"{WEBVIEWS}/**/*.tsx")


def app_sources(root: Path, regex: str, globs: tuple[str, ...]) -> list[Path]:
    return [p for p in grep_files(root, regex, globs)
            if not is_test_path(p.relative_to(root).as_posix()) and "node_modules" not in p.parts]


def scan_app(root: Path) -> set[tuple[str, str]]:
    """(repo-relative file, const) for every stored-data version constant in Swift and webviews sources."""
    found = set()
    paths = [*app_sources(root, r"static +let +[a-z][A-Za-z0-9]*Version", SWIFT_GLOBS),
             *app_sources(root, r"const +[A-Z0-9_]*VERSION", WEB_GLOBS)]
    for path in paths:
        rel = path.relative_to(root).as_posix()
        for name, _ in pattern_for(rel).findall(read(path) or ""):
            # A webviews `*_VERSION` constant is stored unless it says otherwise: pages keep their state in
            # storage, and their wire versions say PROTOCOL.
            if stored_name(name) or (rel.startswith(WEBVIEWS) and not NOT_STORED.search(name)):
                found.add((rel, name))
    return found


def web_sources(root: Path) -> dict[str, str]:
    """The webviews sources that could name a storage key: those with a `cmux.` string or a Storage call."""
    return {p.relative_to(root).as_posix(): read(p) or ""
            for p in app_sources(root, r"[\"'`]cmux[.]|(local|session)Storage[.]", WEB_GLOBS)}


def scan_storage_keys(sources: dict[str, str]) -> dict[str, str]:
    """Every storage key webviews/src names, to the first file naming it."""
    found: dict[str, str] = {}
    for rel, text in sorted(sources.items()):
        for key in [*STORAGE_CONST_RE.findall(text), *STORAGE_CALL_RE.findall(text)]:
            found.setdefault(key, rel)
    return found


def named(key: str, sources: dict[str, str]) -> bool:
    needle = re.compile(r"[\"'`]" + re.escape(key))
    return any(needle.search(text) for text in sources.values())


@dataclass(frozen=True)
class Surface:
    registry: str
    prefix: str  # what an entry's `file` is relative to
    fixtures: str
    scan: Callable[[Path], set[tuple[str, str]]]
    test_hint: str


SURFACES = (
    Surface(REGISTRY, f"{TUI}/", FIXTURES, scan_tui, "a cmux_next_persisted_ test"),
    Surface(APP_REGISTRY, "", APP_FIXTURES, scan_app, "a test that loads every fixture"),
)


def fixture_version(name: str) -> tuple[int, int] | None:
    match = FIXTURE_RE.fullmatch(name)
    return (int(match[1]), int(match[2] or 1)) if match else None


def base_fixtures(root: Path, base: str, folder: str) -> dict[str, str]:
    out = git(root, "ls-tree", "--name-only", f"{base}:{folder}")
    if out.returncode != 0:
        return {}
    return {name: show(root, base, f"{folder}/{name}") or "" for name in out.stdout.split()}


def check(root: Path, base: str | None) -> list[str]:
    errors: list[str] = []
    for surface in SURFACES:
        errors += check_surface(root, base, surface)
    errors += check_storage_keys(root, base)
    errors += check_settings(root, base)
    return errors


def check_surface(root: Path, base: str | None, surface: Surface) -> list[str]:
    errors: list[str] = []
    registry_path = root / surface.registry
    scanned = surface.scan(root)
    if not registry_path.is_file():
        return [f"{surface.registry}: missing"] if scanned or surface.registry == REGISTRY else []
    formats = tomllib.loads(registry_path.read_text(encoding="utf-8")).get("format", [])
    base_text = show(root, base, surface.registry) if base else None
    base_formats = {(f["file"], f["const"]): f for f in tomllib.loads(base_text).get("format", [])} if base_text else None

    seen: set[tuple[str, str]] = set()
    for entry in formats:
        key = (entry.get("file", ""), entry.get("const", ""))
        label = f"{surface.registry}: {entry.get('name') or key}"
        if key in seen:
            errors.append(f"{label}: registered twice")
        seen.add(key)
        policy = entry.get("policy")
        if policy not in POLICIES:
            errors.append(f"{label}: policy must be one of {', '.join(POLICIES)}")
            continue
        pattern = pattern_for(key[0])
        current = const_value(read(root / surface.prefix / key[0]), key[1], pattern)
        if current is None:
            errors.append(f"{label}: no `const {key[1]}` version in {surface.prefix}{key[0]} (moved? update the entry)")
            continue
        old = base_formats.get(key) if base_formats is not None else None
        before = const_value(show(root, base, f"{surface.prefix}{key[0]}"), key[1], pattern) if base else None
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
            errors += check_migrate(root, base, surface, entry, label, current, old)

    if base_formats is not None:
        for key, old in sorted(base_formats.items()):
            if key not in seen and (root / surface.prefix / key[0]).is_file() and \
                    const_value(read(root / surface.prefix / key[0]), key[1], pattern_for(key[0])) is not None:
                errors.append(f"{surface.registry}: {old.get('name') or key}: entry deleted while "
                              f"{surface.prefix}{key[0]} still has {key[1]}")

    for rel, name in sorted(scanned - seen):
        errors.append(f"{surface.prefix}{rel}: {name} looks like a stored format's version and is not in "
                      f"{surface.registry}. Register it as `migrate` (fixtures + {surface.test_hint}) or `rebuild` "
                      f"(a why)")
    return errors


def test_files(root: Path, surface: Surface, file: str) -> tuple[str, list[Path]]:
    """Where a migrate entry's test lives: its crate, its Swift package's Tests, or webviews' tests."""
    parts = Path(file).parts
    if file.endswith(".rs"):
        crate = root / surface.prefix / parts[0] / parts[1]
        return f"{surface.prefix}{parts[0]}/{parts[1]}", list(crate.rglob("*.rs"))
    if file.endswith(".swift") and "Sources" in parts:
        package = Path(*parts[:parts.index("Sources")])
        return f"{package.as_posix()}/Tests", list((root / package / "Tests").rglob("*.swift"))
    tests = [p for p in (root / WEBVIEWS).rglob("*.ts*") if ".test." in p.name and "node_modules" not in p.parts]
    return f"{WEBVIEWS} (*.test.ts)", tests


def check_migrate(root: Path, base: str | None, surface: Surface, entry: dict, label: str, current: int,
                  old: dict | None) -> list[str]:
    errors = []
    folder, test, floor = entry.get("fixtures"), entry.get("test"), entry.get("floor")
    if not folder or not test or not isinstance(floor, int):
        return [f"{label}: a migrate format names `fixtures`, `test` and `floor`"]
    fixtures = f"{surface.fixtures}/{folder}"
    directory = root / fixtures
    versions = {name: fixture_version(name) for name in os.listdir(directory)} if directory.is_dir() else {}
    for name, version in versions.items():
        if version is None:
            errors.append(f"{fixtures}/{name}: a fixture is named v<N>.json or v<N>-<rev>.json")
    if not any(v and v[0] == current for v in versions.values()):
        errors.append(f"{label}: no fixture of version {current} in {fixtures}; add v{current}.json, "
                      f"a record exactly as this build writes it")
    if floor > current:
        errors.append(f"{label}: floor {floor} is above the current version {current}")
    where, files = test_files(root, surface, entry["file"])
    if not any(test in (read(p) or "") for p in files):
        errors.append(f"{label}: no test `{test}*` in {where}")
    if base:
        old_floor = old.get("floor", floor) if old and old.get("policy") == "migrate" else floor
        for name, text in base_fixtures(root, base, fixtures).items():
            version = fixture_version(name)
            dropped = version is not None and version[0] < floor and floor > old_floor
            path = directory / name
            if dropped:
                continue
            if not path.is_file():
                errors.append(f"{fixtures}/{name}: deleted. Data that shape is still on someone's disk; "
                              f"stop reading it only by raising `floor` past v{version[0] if version else '?'} "
                              f"in the same change")
            elif path.read_text(encoding="utf-8") != text:
                errors.append(f"{fixtures}/{name}: edited. A fixture is what an older build wrote and never "
                              f"changes; add the new shape as a new v<N>-<rev>.json")
    return errors


def check_storage_keys(root: Path, base: str | None) -> list[str]:
    sources = web_sources(root)
    scanned = scan_storage_keys(sources)
    registry_path = root / APP_REGISTRY
    if not registry_path.is_file():
        return [f"{APP_REGISTRY}: missing (webviews storage keys)"] if scanned else []
    entries = tomllib.loads(registry_path.read_text(encoding="utf-8")).get("storage_key", [])
    base_text = show(root, base, APP_REGISTRY) if base else None
    base_keys = {e["key"]: e for e in tomllib.loads(base_text).get("storage_key", [])} if base_text else {}
    errors: list[str] = []
    seen: set[str] = set()
    for entry in entries:
        key = entry.get("key", "")
        label = f"{APP_REGISTRY}: storage key {key!r}"
        if key in seen:
            errors.append(f"{label}: registered twice")
        seen.add(key)
        retired = entry.get("retired")
        if retired is not None and not (isinstance(retired, str) and retired.strip()):
            errors.append(f"{label}: `retired` says why losing what the key held costs no work")
        if named(key, sources):
            if retired:
                errors.append(f"{label}: retired, and {WEBVIEWS} names it again. Never reuse a retired key: an "
                              f"older build's data under it has another shape; pick a new key")
        elif not retired:
            errors.append(f"{label}: {WEBVIEWS} no longer names it, so what it held is gone after the update. "
                          f"Keep reading it once and move its value to the new key (the migration), or mark the "
                          f"entry `retired = \"why losing it costs no work\"`")
    for key in sorted(set(base_keys) - seen):
        errors.append(f"{APP_REGISTRY}: storage key {key!r}: entry deleted; entries are never deleted, mark it "
                      f"`retired` instead")
    for key, rel in sorted(scanned.items()):
        if key not in seen:
            errors.append(f"{rel}: storage key {key!r} is not in {APP_REGISTRY}; add a [[storage_key]] entry")
    return errors


def published_keys(text: str | None) -> set[str]:
    return {line.strip() for line in (text or "").splitlines() if line.strip() and not line.startswith("#")}


def retired_settings(text: str | None) -> set[str]:
    try:
        return {entry["key"] for entry in json.loads(text or "{}").get("retired", [])}
    except (ValueError, KeyError, TypeError, AttributeError):
        return set()


def check_settings(root: Path, base: str | None) -> list[str]:
    if not base:
        return []
    errors = []
    for key in sorted(published_keys(show(root, base, PUBLISHED_KEYS)) - published_keys(read(root / PUBLISHED_KEYS))):
        errors.append(f"{PUBLISHED_KEYS}: {key} removed. The record only grows: a key that is no longer a row "
                      f"gets an entry in {RETIRED_KEYS} (replaced_by for a rename, the migration) and stays here")
    for key in sorted(retired_settings(show(root, base, RETIRED_KEYS)) - retired_settings(read(root / RETIRED_KEYS))):
        errors.append(f"{RETIRED_KEYS}: {key} removed. An entry is never deleted: it is how an old cmux-next.json, "
                      f"setup or theme naming the key migrates")
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
        print(f"persisted-formats: {len(errors)} problem(s); see {REGISTRY}'s and {APP_REGISTRY}'s headers",
              file=sys.stderr)
        return 1
    print(f"persisted-formats: ok (base {base or 'none'})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
