#!/usr/bin/env python3
"""String catalogs kept as one file per key: `<Table>.xcstrings.d/<key>.xcstrings`, built into `<Table>.xcstrings`.

Two pull requests that each add a string to one catalog file conflict on GitHub whenever their entries land at the
same place (scripts/xcstrings-edit.py appends at the end by default), and GitHub runs no merge driver. Measured with
scripts/ci/conflict_hotspots.py over the 7,359 PRs merged into feat-cmux-next in the 14 days to 2026-11-25, the three
busiest catalogs conflicted 115 times (CmuxNextSettings 57, the agent pane's 42, CmuxNextSettingsWindow 16); replayed
with one file per key, 5 do (both sides edited the same key). cmuxterm-hq docs/rfd/drafts/conflict-free-tests-deploy.md.

The layout. A table directory `<Table>.xcstrings.d/` holds one file per key, `<key>.xcstrings`, and each file is a
whole string catalog with that one key (sourceLanguage, strings, version), so every check that reads `*.xcstrings`
(scripts/lint-xcstrings.py, scripts/cmux-next/check-l10n.sh, scripts/localization_catalog.py, the path routers and
sparse checkouts) reads the entries as it read the catalog. The table itself (`<Table>.xcstrings`) is build output,
never committed (cmuxterm-hq docs/handbook/generated-file-conflict.md: commit no derived value whose conflict GitHub
sees first):

- Swift: the StringCatalogsPlugin build-tool plugin (Packages/macOS/CmuxNext/Plugins) runs `build-target` on its
  target's directory into the plugin work directory, and SwiftPM and Xcode compile the table from there. The target
  excludes the directory, so its files are never tables of their own.
- Web: webviews/scripts/pages/catalog.mjs reads the directory where gen-strings.mjs names it.
- Anything else reads it with `load()` here, or `cat` for the whole table as text.

  string_catalogs.py build DIR --out FILE          write DIR's table to FILE (only when it changed)
  string_catalogs.py build-target TARGET_DIR OUT   every *.xcstrings.d under TARGET_DIR into OUT/<Table>.xcstrings;
                                                   removes tables OUT holds that no directory makes (the plugin)
  string_catalogs.py cat DIR                       print DIR's table
  string_catalogs.py split CATALOG --into DIR      write each key of CATALOG (an edited or older copy of the
                                                   table, Xcode's included) as DIR's file for that key; --prune also
                                                   deletes the files of keys CATALOG does not have
  string_catalogs.py add DIR KEY --en TEXT [--comment TEXT]   one new English-only key (manual extraction)
  string_catalogs.py adopt [TABLE ...]             in a merge or rebase where one side edited a table file and the
                                                   other made it a directory: carry the edited side's key changes
                                                   (git's base stage -> its stage) into the directory and remove
                                                   the file; default: every such conflicted table
  string_catalogs.py check [DIR ...]               every file is one key named by its file, no two names differ only
                                                   in case (a Mac checkout cannot hold both), no table file committed
                                                   beside its directory; default: every directory in the repository
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SUFFIX = ".xcstrings.d"
ENTRY = ".xcstrings"
# A key is a file name on every platform the repository is checked out on.
KEY = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.\-]{0,200}$")
HEADER = {"sourceLanguage": "en", "version": "1.0"}
# A file named like a generated one is refused by the generated-files check (scripts/ci/generated_files_guard.py).
GENERATED_NAME = re.compile(r"\.generated\.|\+Generated\.")


def dumps(value: object) -> str:
    """Xcode's catalog format: two-space indent, `" : "` between a member's name and value."""
    return json.dumps(value, ensure_ascii=False, indent=2, separators=(",", " : ")) + "\n"


def table_of(directory: Path) -> Path:
    """`X.xcstrings.d` -> `X.xcstrings` beside it."""
    return directory.with_name(directory.name[: -len(SUFFIX)] + ENTRY)


def entry_file(directory: Path, key: str) -> Path:
    if not KEY.match(key):
        raise ValueError(f"{key!r}: a key of a one-file-per-key catalog is letters, digits, _ . - (it is a file name)")
    if GENERATED_NAME.search(key + ENTRY):
        raise ValueError(f"{key!r}: {key}{ENTRY} reads as a generated file (scripts/ci/generated-files.json "
                         "conventions: *.generated.*, *+Generated.*); name the key otherwise, e.g. ...generatedFiles")
    return directory / (key + ENTRY)


def entry_text(key: str, entry: dict, header: dict | None = None) -> str:
    head = header or HEADER
    return dumps({"sourceLanguage": head["sourceLanguage"], "strings": {key: entry}, "version": head["version"]})


def read_entry(path: Path) -> tuple[dict, str, dict]:
    """(header, key, entry) of one entry file; ValueError when it is not one key named by its file."""
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or set(data) != {"sourceLanguage", "strings", "version"} \
            or not isinstance(data["strings"], dict) or len(data["strings"]) != 1:
        raise ValueError(f"{path}: an entry file is a catalog of exactly one key (sourceLanguage, strings, version)")
    (key, entry), = data["strings"].items()
    if path.name != key + ENTRY:
        raise ValueError(f"{path}: holds {key!r}; its name must be {key}{ENTRY}")
    return {"sourceLanguage": data["sourceLanguage"], "version": data["version"]}, key, entry


def entry_files(directory: Path) -> list[Path]:
    return sorted(p for p in directory.iterdir() if p.is_file() and p.name.endswith(ENTRY))


def load(directory: Path | str) -> dict:
    """The table a directory makes: {sourceLanguage, strings (by key), version}."""
    directory = Path(directory)
    header, strings = None, {}
    for path in entry_files(directory):
        head, key, entry = read_entry(path)
        if header is not None and head != header:
            raise ValueError(f"{path}: sourceLanguage/version {head} differ from the directory's {header}")
        header = head
        strings[key] = entry
    head = header or HEADER
    return {"sourceLanguage": head["sourceLanguage"], "strings": strings, "version": head["version"]}


def write_if_changed(path: Path, text: str) -> bool:
    try:
        if path.read_text(encoding="utf-8") == text:
            return False
    except OSError:
        pass
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix="." + path.name, suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.replace(tmp, path)
    return True


def build(directory: Path, out: Path) -> bool:
    return write_if_changed(out, dumps(load(directory)))


def directories(root: Path) -> list[Path]:
    """Every table directory git tracks under ROOT (or, outside a checkout, on disk)."""
    try:
        listed = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--", f"*{SUFFIX}/*{ENTRY}"],
                                capture_output=True, check=True).stdout.decode("utf-8").split("\0")
        found = {(root / p).parent for p in listed if p}
    except (OSError, subprocess.CalledProcessError):
        found = {p for p in root.rglob(f"*{SUFFIX}") if p.is_dir()}
    return sorted(found)


def build_target(target: Path, out: Path) -> list[Path]:
    made = []
    for directory in sorted(p for p in target.rglob(f"*{SUFFIX}") if p.is_dir()):
        table = out / table_of(directory).name
        if table in made:
            raise ValueError(f"{directory}: two directories make {table.name}")
        build(directory, table)
        made.append(table)
    for stale in out.glob(f"*{ENTRY}") if out.is_dir() else []:
        if stale not in made:
            stale.unlink()
    return made


def split(catalog: Path, directory: Path, prune: bool = False) -> tuple[int, int]:
    """Write each key of CATALOG as its file; (written, deleted)."""
    data = json.loads(catalog.read_text(encoding="utf-8"))
    header = {"sourceLanguage": data.get("sourceLanguage", "en"), "version": data.get("version", "1.0")}
    written = 0
    directory.mkdir(parents=True, exist_ok=True)
    for key, entry in data["strings"].items():
        if write_if_changed(entry_file(directory, key), entry_text(key, entry, header)):
            written += 1
    deleted = 0
    if prune:
        for path in entry_files(directory):
            if path.name[: -len(ENTRY)] not in data["strings"]:
                path.unlink()
                deleted += 1
    return written, deleted


def _stage(root: Path, stage: int, path: str) -> dict | None:
    shown = subprocess.run(["git", "-C", str(root), "show", f":{stage}:{path}"], capture_output=True)
    return json.loads(shown.stdout.decode("utf-8")).get("strings", {}) if shown.returncode == 0 else None


def adopt(root: Path, tables: list[str]) -> list[str]:
    """Carry each conflicted TABLE's edited side into its directory; the lines it reports."""
    if not tables:
        listed = subprocess.run(["git", "-C", str(root), "diff", "--name-only", "--diff-filter=U", "-z"],
                                capture_output=True, check=True).stdout.decode("utf-8").split("\0")
        tables = [p for p in listed if p.endswith(ENTRY) and (root / (p + ".d")).is_dir()]
    done = []
    for table in tables:
        directory = root / (table + ".d")
        if not directory.is_dir():
            raise ValueError(f"{table}: no {table}.d beside it to adopt into")
        before = _stage(root, 1, table) or {}
        edited = [side for side in (_stage(root, 2, table), _stage(root, 3, table)) if side is not None]
        if len(edited) != 1:
            raise ValueError(f"{table}: not a conflict where one side edited it and the other removed it")
        after, = edited
        header = load(directory)
        header = {"sourceLanguage": header["sourceLanguage"], "version": header["version"]}
        added = changed = removed = 0
        for key in sorted(set(before) | set(after)):
            if before.get(key) == after.get(key):
                continue
            path = entry_file(directory, key)
            if key not in after:
                if path.exists():
                    path.unlink()
                    removed += 1
            elif before.get(key) != after[key]:
                changed += key in before
                added += key not in before
                write_if_changed(path, entry_text(key, after[key], header))
        subprocess.run(["git", "-C", str(root), "rm", "-q", "--cached", "--", table], capture_output=True, check=True)
        (root / table).unlink(missing_ok=True)
        subprocess.run(["git", "-C", str(root), "add", "--", str(directory.relative_to(root))], check=True)
        done.append(f"{table}: +{added} ~{changed} -{removed} key(s) carried into {directory.name}")
    return done


def check(dirs: list[Path], root: Path) -> list[str]:
    errors = []
    for directory in dirs:
        seen: dict[str, str] = {}
        header = None
        for path in entry_files(directory):
            rel = path.relative_to(root) if path.is_relative_to(root) else path
            try:
                head, key, _ = read_entry(path)
                entry_file(directory, key)
            except ValueError as error:
                errors.append(f"{rel}: {error}")
                continue
            if header is not None and head != header:
                errors.append(f"{rel}: sourceLanguage/version differ from the rest of {directory.name}")
            header = head
            if key.lower() in seen:
                errors.append(f"{rel}: {key!r} and {seen[key.lower()]!r} differ only in case")
            seen[key.lower()] = key
        others = [p.name for p in directory.iterdir() if not p.name.endswith(ENTRY) and p.name != "README.md"]
        if others:
            errors.append(f"{directory}: holds {sorted(others)[:5]}; only <key>{ENTRY} files (and README.md) go here")
        table = table_of(directory)
        tracked = subprocess.run(["git", "-C", str(root), "ls-files", "--error-unmatch", "--", str(table)],
                                 capture_output=True).returncode == 0
        if tracked:
            errors.append(f"{table.relative_to(root)}: committed beside {directory.name}; it is build output. "
                          "In a merge or rebase that conflicts on it, `string_catalogs.py adopt` carries your side's "
                          f"key changes into {directory.name} and removes it")
    return errors


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("dir", type=Path)
    b.add_argument("--out", type=Path, required=True)
    bt = sub.add_parser("build-target")
    bt.add_argument("target", type=Path)
    bt.add_argument("out", type=Path)
    c = sub.add_parser("cat")
    c.add_argument("dir", type=Path)
    s = sub.add_parser("split")
    s.add_argument("catalog", type=Path)
    s.add_argument("--into", type=Path, required=True)
    s.add_argument("--prune", action="store_true")
    a = sub.add_parser("add")
    a.add_argument("dir", type=Path)
    a.add_argument("key")
    a.add_argument("--en", required=True)
    a.add_argument("--comment")
    ad = sub.add_parser("adopt")
    ad.add_argument("tables", nargs="*")
    ad.add_argument("--root", type=Path, default=ROOT)
    k = sub.add_parser("check")
    k.add_argument("dirs", nargs="*", type=Path)
    k.add_argument("--root", type=Path, default=ROOT)
    args = ap.parse_args(argv)
    try:
        if args.cmd == "build":
            print(f"{args.out}: {'written' if build(args.dir, args.out) else 'unchanged'}")
        elif args.cmd == "build-target":
            made = build_target(args.target, args.out)
            print(f"{len(made)} string table(s) in {args.out}")
        elif args.cmd == "cat":
            sys.stdout.write(dumps(load(args.dir)))
        elif args.cmd == "split":
            written, deleted = split(args.catalog, args.into, args.prune)
            print(f"{args.into}: {written} file(s) written, {deleted} deleted")
        elif args.cmd == "add":
            path = entry_file(args.dir, args.key)
            if path.exists():
                print(f"{path}: {args.key} exists; edit its file", file=sys.stderr)
                return 1
            entry = {"extractionState": "manual",
                     "localizations": {"en": {"stringUnit": {"state": "translated", "value": args.en}}}}
            if args.comment:
                entry = {"comment": args.comment, **entry}
            write_if_changed(path, entry_text(args.key, entry))
            print(path)
        elif args.cmd == "adopt":
            for line in adopt(args.root, args.tables):
                print(line)
        else:
            errors = check(args.dirs or directories(args.root), args.root)
            for error in errors:
                print(error, file=sys.stderr)
            if errors:
                return 1
            print("string catalogs: every table directory is one file per key")
    except (OSError, ValueError, KeyError) as error:
        print(f"string_catalogs.py: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
