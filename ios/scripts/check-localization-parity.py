#!/usr/bin/env python3
"""Check that every iOS string catalog has complete, valid locale coverage."""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path


LOCALES = ("en", "de", "fr", "ar", "es", "zh-Hant", "zh-Hans", "ko", "ja")
PLACEHOLDER = re.compile(
    r"%(?:\{[^}]+\})?(?:\d+\$)?[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?"
    r"(?:hh|h|ll|l|L|j|z|t|q)?[A-Za-z@]"
)
ALLOWLIST_NAME = "localization-identical-allowlist.json"


def catalog_paths(root: Path) -> list[Path]:
    paths = set(root.glob("ios/**/*.xcstrings"))
    paths.update(root.glob("Packages/iOS/**/*.xcstrings"))
    paths.add(
        root
        / "Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/Resources/Localizable.xcstrings"
    )
    return sorted(path for path in paths if path.is_file())


def string_units(node: object, path: tuple[str, ...] = ()) -> list[tuple[tuple[str, ...], dict]]:
    if isinstance(node, dict):
        units: list[tuple[tuple[str, ...], dict]] = []
        string_unit = node.get("stringUnit")
        if isinstance(string_unit, dict):
            units.append((path, string_unit))
        for key, value in node.items():
            if key != "stringUnit":
                units.extend(string_units(value, path + (key,)))
        return units
    if isinstance(node, list):
        units = []
        for index, value in enumerate(node):
            units.extend(string_units(value, path + (str(index),)))
        return units
    return []


def placeholder_map(localization: object) -> dict[tuple[str, ...], Counter[str]]:
    return {
        path: Counter(PLACEHOLDER.findall(unit.get("value", "")))
        for path, unit in string_units(localization)
    }


def expected_placeholders(
    path: tuple[str, ...], source_placeholders: dict[tuple[str, ...], Counter[str]]
) -> Counter[str] | None:
    if path in source_placeholders:
        return source_placeholders[path]
    fallback_path = plural_fallback_path(path)
    if fallback_path in source_placeholders:
        return source_placeholders[fallback_path]
    return None


def plural_fallback_path(path: tuple[str, ...]) -> tuple[str, ...] | None:
    plural_categories = {"zero", "one", "two", "few", "many", "other"}
    for index, component in enumerate(path):
        if component in plural_categories and component != "other":
            return path[:index] + ("other",) + path[index + 1 :]
    return None


def load_allowlist(
    root: Path,
) -> tuple[set[tuple[str, str, str]], set[tuple[str, str, str, tuple[str, ...]]]]:
    path = root / "ios/scripts" / ALLOWLIST_NAME
    if not path.exists():
        return set(), set()
    body = json.loads(path.read_text(encoding="utf-8"))
    entry_allowlist = {
        (catalog, key, locale)
        for catalog, keys in body.items()
        if catalog != "unit_paths"
        for key, locales in keys.items()
        for locale in locales
    }
    unit_allowlist = {
        (
            catalog,
            key,
            locale,
            tuple(path.split("/")) if path != "default" else (),
        )
        for catalog, keys in body.get("unit_paths", {}).items()
        for key, locales in keys.items()
        for locale, paths in locales.items()
        for path in paths
    }
    return entry_allowlist, unit_allowlist


def check_catalog(
    root: Path,
    path: Path,
    allowlist: tuple[set[tuple[str, str, str]], set[tuple[str, str, str, tuple[str, ...]]]],
) -> list[str]:
    relative_path = path.relative_to(root).as_posix()
    body = json.loads(path.read_text(encoding="utf-8"))
    strings = body.get("strings")
    if not isinstance(strings, dict):
        return [f"{relative_path}: missing string catalog 'strings' object"]

    errors: list[str] = []
    entry_allowlist, unit_allowlist = allowlist
    for key in sorted(strings):
        entry = strings[key]
        localizations = entry.get("localizations", {}) if isinstance(entry, dict) else {}
        if not isinstance(localizations, dict):
            errors.append(f"{relative_path}:{key}: missing localizations object")
            continue

        unexpected = sorted(set(localizations) - set(LOCALES))
        if unexpected:
            errors.append(f"{relative_path}:{key}: unexpected locales {', '.join(unexpected)}")

        source = localizations.get("en")
        source_units = string_units(source)
        if not source_units:
            errors.append(f"{relative_path}:{key}: English source has no string units")
            continue
        source_by_path = {unit_path: unit for unit_path, unit in source_units}
        source_placeholders = placeholder_map(source)

        for locale in LOCALES:
            localization = localizations.get(locale)
            if localization is None:
                errors.append(f"{relative_path}:{key}: missing locale {locale}")
                continue
            units = string_units(localization)
            if not units:
                errors.append(f"{relative_path}:{key}:{locale}: no string units")
                continue
            locale_by_path = {unit_path: unit for unit_path, unit in units}
            for unit_path in source_by_path:
                if unit_path in locale_by_path:
                    continue
                fallback_path = plural_fallback_path(unit_path)
                if fallback_path is not None and fallback_path in locale_by_path:
                    continue
                errors.append(
                    f"{relative_path}:{key}:{locale}: missing string unit at "
                    f"{'/'.join(unit_path) or 'default'}"
                )
            untranslated_states = sorted(
                {unit.get("state", "missing") for _, unit in units if unit.get("state") != "translated"}
            )
            if untranslated_states:
                states = ", ".join(untranslated_states)
                errors.append(f"{relative_path}:{key}:{locale}: state must be translated ({states})")
            if any(not isinstance(unit.get("value"), str) or not unit["value"].strip() for _, unit in units):
                errors.append(f"{relative_path}:{key}:{locale}: empty or non-string value")
            for unit_path, unit in units:
                expected = expected_placeholders(unit_path, source_placeholders)
                actual = Counter(PLACEHOLDER.findall(unit.get("value", "")))
                if expected is not None and actual != expected:
                    errors.append(
                        f"{relative_path}:{key}:{locale}: placeholders do not match English "
                        f"at {'/'.join(unit_path) or 'default'} ({dict(actual)} != {dict(expected)})"
                    )
            if locale != "en":
                whole_entry_identical = (
                    {unit_path for unit_path, _ in units} == set(source_by_path)
                    and all(
                        unit.get("value") == source_by_path[unit_path].get("value")
                        for unit_path, unit in units
                    )
                )
                for unit_path, unit in units:
                    source_unit = source_by_path.get(unit_path)
                    if source_unit is None or unit.get("value") != source_unit.get("value"):
                        continue
                    identity = (relative_path, key, locale, unit_path)
                    entry_identity = (relative_path, key, locale)
                    if identity in unit_allowlist or (
                        whole_entry_identical and entry_identity in entry_allowlist
                    ):
                        continue
                    errors.append(
                        f"{relative_path}:{key}:{locale}: English-identical value is not allowlisted "
                        f"at {'/'.join(unit_path) or 'default'}"
                    )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    root = args.root.resolve()
    paths = catalog_paths(root)
    if not paths:
        print("error: no iOS string catalogs found", file=sys.stderr)
        return 1

    allowlist = load_allowlist(root)
    errors = [error for path in paths for error in check_catalog(root, path, allowlist)]
    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        print(f"{len(errors)} localization parity error(s) across {len(paths)} catalog(s)", file=sys.stderr)
        return 1
    print(f"Localization parity passed for {len(paths)} catalog(s) and {len(LOCALES)} locales")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
