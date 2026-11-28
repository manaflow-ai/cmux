#!/usr/bin/env python3
"""Compare Swift `defaultValue` literals with the catalog English they localize (Python 3.9+).

`localization_catalog.py check` takes its baseline from the catalog itself: every
locale is compared with the entry's own `en` value. A catalog `en` value that lost
or gained a format specifier relative to the Swift `defaultValue` therefore passes,
because every locale agrees with `en` and nothing reads the Swift source. At
runtime `String(format:)` then silently drops the argument, or reads past the
argument list. This check reads the Swift source and compares the two signatures.

Known mismatches that are waiting on a copy decision live in
scripts/localization-default-mismatches.json, keyed by catalog key with a reason.
An entry that no longer mismatches is an error, so the list only shrinks.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ALLOWLIST = "scripts/localization-default-mismatches.json"
# Test targets and fixtures use catalog keys with their own default text on
# purpose; vendored and generated trees are not cmux copy.
SKIP_DIRS = frozenset((
    ".build", ".git", "DerivedData", "Examples", "Prototypes", "Tests", "artifacts",
    "cmuxCLITestSupport", "cmuxCLITests", "cmuxTests", "cmuxUITests", "experiments",
    "node_modules", "scripts", "tests", "tests_v2", "vendor",
))


def load_changes_module():
    spec = importlib.util.spec_from_file_location("cmux_localize_changes", ROOT / "scripts/localize_changes.py")
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load scripts/localize_changes.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


CHANGES = load_changes_module()
CATALOG = CHANGES.CATALOG


def swift_files(root: Path) -> list[Path]:
    return sorted(path for path in root.rglob("*.swift")
                  if SKIP_DIRS.isdisjoint(path.relative_to(root).parts[:-1]))


def swift_defaults(root: Path) -> dict[str, tuple[str, str]]:
    """Map each key to (defaultValue, Swift path).

    Call sites that disagree about a key's default are dropped, as are calls the
    shared extractor cannot read (interpolated or unsupported literals); both are
    already reported by localize_changes.py, and neither yields one signature.
    """
    defaults: dict[str, tuple[str, str]] = {}
    conflicts: set[str] = set()
    for path in swift_files(root):
        relative = path.relative_to(root).as_posix()
        messages, _ = CHANGES.parse_swift_messages(relative, path.read_text(encoding="utf-8"), conflicts=conflicts)
        for key, message in messages.items():
            previous = defaults.get(key)
            if previous is not None and previous[0] != message.source:
                conflicts.add(key)
            else:
                defaults[key] = (message.source, relative)
    for key in conflicts:
        defaults.pop(key, None)
    return defaults


def catalog_index(root: Path) -> dict[str, list[tuple[str, object]]]:
    index: dict[str, list[tuple[str, object]]] = {}
    for path in CATALOG.discover(root):
        for entry in CATALOG.catalog_entries(path.read_text(encoding="utf-8")):
            index.setdefault(entry.key, []).append((path.relative_to(root).as_posix(), entry.value))
    return index


def load_allowlist(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or not all(isinstance(reason, str) and reason.strip() for reason in data.values()):
        raise ValueError(f"{path}: expected an object mapping catalog keys to a non-empty reason")
    return data


def arguments(text: str) -> list[tuple[int, str]]:
    """The (argument, specifier) pairs a format string consumes, in argument order."""
    return sorted(CATALOG.signature(text))


def check(root: Path, allowlist: dict[str, str]) -> tuple[list[str], int]:
    """Return (errors, comparison count); a key carried by several catalogs is compared with each."""
    errors: list[str] = []
    index = catalog_index(root)
    compared = 0
    still_mismatched: set[str] = set()
    for key, (default, swift_path) in sorted(swift_defaults(root).items()):
        catalogs = []
        for catalog_path, entry in index.get(key, []):
            try:
                catalogs.append((catalog_path, arguments(CATALOG.source(entry))))
            except ValueError:
                continue  # localization_catalog.py check already names a malformed entry
        try:
            expected = arguments(default)
        except ValueError:
            continue  # e.g. a %#@name@ substitution in Swift text; localize_changes.py owns that review
        for catalog_path, actual in catalogs:
            compared += 1
            if expected == actual:
                continue
            if key in allowlist:
                still_mismatched.add(key)
                continue
            # The same key can live in more than one product's catalog with
            # different copy; name the siblings so the fix lands in the right one.
            siblings = "".join(f"; {other} carries {sibling!r}" for other, sibling in catalogs if other != catalog_path)
            errors.append(
                f"{catalog_path}:{key}: catalog en placeholders {actual!r} != "
                f"Swift defaultValue {expected!r} ({swift_path}){siblings}"
            )
    for key in sorted(set(allowlist) - still_mismatched):
        errors.append(f"{ALLOWLIST}: {key} no longer mismatches its Swift defaultValue; remove the entry")
    return errors, compared


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--allowlist", type=Path, help=f"default: <root>/{ALLOWLIST}")
    parser.add_argument("--limit", type=int, default=40, help="maximum printed diagnostics; 0 prints all")
    args = parser.parse_args(argv)
    if args.limit < 0:
        parser.error("limit must be nonnegative")
    root = args.root.resolve()
    errors, compared = check(root, load_allowlist(args.allowlist or root / ALLOWLIST))
    for error in errors[:args.limit or None]:
        print(error, file=sys.stderr)
    noun = "mismatch" if len(errors) == 1 else "mismatches"
    print(f"{compared} Swift defaultValue/catalog en comparisons: {len(errors)} {noun}")
    return int(bool(errors))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
