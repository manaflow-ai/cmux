#!/usr/bin/env python3
"""Compile CmuxNext string catalogs (.xcstrings) into <lang>.lproj/<table>.strings for the Linux build.

On macOS, SwiftPM runs xcstringstool and the bundle gets one compiled table per catalog and language.
On Linux it copies the catalog's JSON, which Foundation cannot read, so every String(localized:) falls
back to its default (p15-oracle-228). This script writes what xcstringstool writes:

  Packages/macOS/CmuxNext/.build-linux/lproj/<Target>/<lang>.lproj/<table>.strings   (binary plist)

and links that folder into the target as Sources/<Target>/LinuxStringTables (Tests/<Target>/... for
test targets), because SwiftPM only takes resources from inside a target's folder. The Linux mode of
Package.swift (CMUX_SWIFTPM_TARGET_LINUX=1) adds .process("LinuxStringTables") to every target that
has a catalog, so a build without this script's output fails on that missing folder.

  compile-xcstrings.py [--package DIR] [--target NAME ...] [--check]

With no --target, every target folder (Sources/* and Tests/*) that holds a catalog is compiled, and the
output and link of a target that no longer has one are removed. A second run writes nothing.
--check writes nothing and exits 1 when any table or link is missing or stale. Python stdlib only.

Plural and device variations become their "other" form: xcstringstool writes them to a .stringsdict,
and swift-corelibs-foundation (Swift 6.2) crashes reading one. Substitutions are refused.
"""
import argparse
import json
import os
import plistlib
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
DEFAULT_PACKAGE = os.path.join(REPO, "Packages", "macOS", "CmuxNext")
OUTPUT = os.path.join(".build-linux", "lproj")
LINK = "LinuxStringTables"
TARGET_PARENTS = ("Sources", "Tests")


class CatalogError(Exception):
    """A catalog this compiler cannot turn into tables; the message names the file and key."""


def unit_value(localization, where):
    """The text of one localization: its string unit, or the "other" form of its variations."""
    if "substitutions" in localization:
        raise CatalogError(f"{where}: substitutions are not supported")
    if "stringUnit" in localization:
        return localization["stringUnit"].get("value")
    variations = localization.get("variations")
    if variations is None:
        return None
    unknown = set(variations) - {"plural", "device"}
    if unknown:
        raise CatalogError(f"{where}: {', '.join(sorted(unknown))} variations are not supported")
    kind = "plural" if "plural" in variations else "device"
    other = variations[kind].get("other")
    if other is None:
        raise CatalogError(f"{where}: {kind} variations without an 'other' form")
    return unit_value(other, where)


def compile_catalog(path):
    """({language: {key: value}}, variation key count) for one .xcstrings file."""
    with open(path, encoding="utf-8") as f:
        catalog = json.load(f)
    source = catalog["sourceLanguage"]
    tables = {}
    variations = 0
    for key, entry in catalog.get("strings", {}).items():
        localizations = entry.get("localizations") or {}
        if any("variations" in loc for loc in localizations.values()):
            variations += 1
        translatable = entry.get("shouldTranslate", True)
        for language, localization in localizations.items():
            if not translatable and language != source:
                continue
            value = unit_value(localization, f"{path}: {key} ({language})")
            if value is not None:
                tables.setdefault(language, {})[key] = value
    return tables, variations


def catalog_targets(package):
    """{target name: its folder} for every Sources/* and Tests/* folder that holds a catalog."""
    found = {}
    for parent in TARGET_PARENTS:
        root = os.path.join(package, parent)
        if not os.path.isdir(root):
            continue
        for name in sorted(os.listdir(root)):
            folder = os.path.join(root, name)
            if os.path.isdir(folder) and not os.path.islink(folder) and catalogs(folder):
                if name in found:
                    raise CatalogError(f"two target folders named {name}")
                found[name] = folder
    return found


def catalogs(folder):
    """Every .xcstrings under folder, sorted; the generated link is not followed."""
    paths = []
    for current, dirs, files in os.walk(folder):
        dirs[:] = sorted(d for d in dirs if not d.startswith(".") and d != LINK)
        paths += [os.path.join(current, name) for name in sorted(files) if name.endswith(".xcstrings")]
    return paths


def target_outputs(folder, target):
    """({output path relative to the lproj root: bytes}, variation key count) for one target."""
    outputs = {}
    variations = 0
    for path in catalogs(folder):
        table = os.path.basename(path)[: -len(".xcstrings")]
        languages, count = compile_catalog(path)
        variations += count
        for language, strings in languages.items():
            relative = os.path.join(target, f"{language}.lproj", f"{table}.strings")
            if relative in outputs:
                raise CatalogError(f"two catalogs named {table}.xcstrings in {folder}")
            outputs[relative] = plistlib.dumps(strings, fmt=plistlib.FMT_BINARY, sort_keys=True)
    return outputs, variations


def files_under(root):
    """Paths relative to root of every file under it."""
    found = set()
    for current, _, files in os.walk(root):
        found |= {os.path.relpath(os.path.join(current, name), root) for name in files}
    return found


def sync_tables(out, target, outputs, check):
    """Write changed tables of one target and remove stale ones; returns the paths that differed."""
    target_root = os.path.join(out, target)
    stale = {os.path.join(target, p) for p in files_under(target_root)} - set(outputs)
    changed = []
    for relative, data in sorted(outputs.items()):
        path = os.path.join(out, relative)
        try:
            with open(path, "rb") as f:
                if f.read() == data:
                    continue
        except FileNotFoundError:
            pass
        changed.append(relative)
        if not check:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as f:
                f.write(data)
    for relative in sorted(stale):
        changed.append(relative)
        if not check:
            os.remove(os.path.join(out, relative))
    if not check and os.path.isdir(target_root):
        for current, _, _ in os.walk(target_root, topdown=False):
            if not os.listdir(current):
                os.rmdir(current)
    return changed


def sync_link(folder, target_root, check):
    """Point folder/LinuxStringTables at target_root (None: remove the link); returns the paths that differed."""
    link = os.path.join(folder, LINK)
    want = os.path.relpath(target_root, folder) if target_root else None
    have = os.readlink(link) if os.path.islink(link) else None
    if os.path.lexists(link) and have is None:
        raise CatalogError(f"{link} exists and is not a link; move it away")
    if want is not None and not check:
        # A target whose catalogs are empty still gets a folder, so the link resolves.
        os.makedirs(target_root, exist_ok=True)
    if have == want:
        return []
    if not check:
        if have is not None:
            os.remove(link)
        if want is not None:
            os.symlink(want, link)
    return [link]


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--package", default=DEFAULT_PACKAGE, help="the CmuxNext package folder")
    parser.add_argument("--target", action="append", help="a target to compile (repeatable)")
    parser.add_argument("--check", action="store_true", help="write nothing; exit 1 if any output is stale")
    args = parser.parse_args(argv)
    if not args.check and not sys.platform.startswith("linux"):
        # SwiftPM on macOS compiles the catalogs itself and would also see the linked tables.
        print("compile-xcstrings: Linux only; macOS compiles .xcstrings itself", file=sys.stderr)
        return 2
    package = os.path.abspath(args.package)
    out = os.path.join(package, OUTPUT)
    changed = []
    try:
        targets = catalog_targets(package)
        if args.target:
            unknown = sorted(set(args.target) - set(targets))
            if unknown:
                raise CatalogError(f"no catalogs in target {', '.join(unknown)}")
            targets = {name: targets[name] for name in args.target}
        else:
            # Targets that lost their last catalog: drop their tables and their link.
            for gone in sorted(set(os.listdir(out)) - set(targets)) if os.path.isdir(out) else []:
                changed += sync_tables(out, gone, {}, args.check)
                for parent in TARGET_PARENTS:
                    folder = os.path.join(package, parent, gone)
                    if os.path.isdir(folder):
                        changed += sync_link(folder, None, args.check)
        for target, folder in targets.items():
            outputs, variations = target_outputs(folder, target)
            changed += sync_tables(out, target, outputs, args.check)
            changed += sync_link(folder, os.path.join(out, target), args.check)
            languages = len({os.path.dirname(p) for p in outputs})
            tables = len({os.path.basename(p) for p in outputs})
            note = f", {variations} keys with variations as their 'other' form" if variations else ""
            print(f"{target}: {tables} tables x {languages} languages{note}")
    except (CatalogError, KeyError, json.JSONDecodeError) as error:
        print(f"compile-xcstrings: {error}", file=sys.stderr)
        return 2
    if not args.check:
        # Build output: the folder ignores itself, as build-app-ffi.sh --linux does for ffi/.
        ignore = os.path.join(package, ".build-linux", ".gitignore")
        if not os.path.exists(ignore):
            os.makedirs(os.path.dirname(ignore), exist_ok=True)
            with open(ignore, "w", encoding="utf-8") as f:
                f.write("*\n")
    verb = "stale" if args.check else "updated"
    print(f"{len(changed)} files {verb} under {os.path.relpath(out, os.getcwd())}")
    return 1 if args.check and changed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
