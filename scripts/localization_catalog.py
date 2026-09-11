#!/usr/bin/env python3
"""Extract, merge, and validate macOS XCStrings translations (Python 3.9+)."""

from __future__ import annotations

import argparse
import copy
import json
import os
import re
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
LOCALES = ("en", "de", "fr", "ar", "es", "zh-Hant", "zh-Hans", "ko", "ja")
CATEGORIES = {
    "ar": {"zero", "one", "two", "few", "many", "other"},
    "fr": {"one", "many", "other"},
    "es": {"one", "many", "other"},
}
OMISSION_CLASSES = {"brand", "technical", "format", "price", "syntax"}
FORMAT = re.compile(
    r"%%|%(?:\d+\$)?#@[^@]+@|%(?:\d+\$)?[-+ #0']*(?:\d+|\*(?:\d+\$)?)?"
    r"(?:\.(?:\d+|\*(?:\d+\$)?))?(?:hh|ll|[hlLqjzt])?[diouxXfFeEgGaAcCsSp@]"
)
MARKER = re.compile(r"\bTODO\b|(?i:\b(?:TRANSLATE_ME|MACHINE_TRANSLATION)\b|__CMUX_TOKEN_\d+__|<translated>)")
BIDI = re.compile("[\u202a-\u202e\u2066-\u2069]")


@dataclass
class Member:
    key: str
    value: object
    start: int
    end: int


def unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate object member {key!r}")
        result[key] = value
    return result


def members(text: str, start: int = 0, *, strict_values: bool = False) -> list[Member]:
    decoder = json.JSONDecoder(object_pairs_hook=unique_object if strict_values else None)
    position = start + 1
    result = []
    while True:
        while text[position].isspace() or text[position] == ",":
            position += 1
        if text[position] == "}":
            return result
        key, position = decoder.raw_decode(text, position)
        while text[position].isspace():
            position += 1
        if text[position] != ":":
            raise ValueError("expected object member separator")
        position += 1
        while text[position].isspace():
            position += 1
        try:
            value, end = decoder.raw_decode(text, position)
        except ValueError as error:
            raise ValueError(f"{key}: {error}") from error
        result.append(Member(key, value, position, end))
        position = end


def catalog_entries(text: str) -> list[Member]:
    parsed = json.loads(text)
    if parsed.get("sourceLanguage") != "en" or not isinstance(parsed.get("strings"), dict):
        raise ValueError("expected an English-source string catalog")
    unexpected = set(parsed) - {"sourceLanguage", "strings", "version"}
    if unexpected:
        raise ValueError(f"records outside the strings object: {', '.join(sorted(unexpected))}")
    root_members = members(text, len(text) - len(text.lstrip()))
    unique_object([(item.key, None) for item in root_members])
    strings = next(item for item in root_members if item.key == "strings")
    # String records remain lossless; every object inside each record must be unique.
    return members(text, strings.start, strict_values=True)


def discover(root: Path) -> list[Path]:
    paths = set((root / "Resources").rglob("*.xcstrings"))
    paths.update((root / "TunnelExtension").rglob("*.xcstrings"))
    paths.update((root / "Packages/macOS").glob("*/Sources/**/*.xcstrings"))
    return sorted(paths)


def load_metadata(name: str) -> dict:
    with (ROOT / "scripts" / name).open(encoding="utf-8") as handle:
        return json.load(handle)


def placeholders(value: str) -> list[str]:
    return FORMAT.findall(value)


def substitution_name(token: str) -> str | None:
    match = re.fullmatch(r"%(?:\d+\$)?#@([^@]+)@", token)
    return match[1] if match else None


def signature(value: str, substitutions: dict | None = None) -> list[tuple[int, str]]:
    result = []
    next_argument = 1
    for token in placeholders(value):
        if token == "%%":
            result.append((0, "%"))
            continue
        name = substitution_name(token)
        if name is not None:
            substitution = (substitutions or {}).get(name, {})
            argument = substitution.get("argNum")
            specifier = substitution.get("formatSpecifier")
            if type(argument) is not int or argument < 1 or not isinstance(specifier, str):
                raise ValueError(f"invalid substitution {token}")
        else:
            match = re.fullmatch(r"%(?:(\d+)\$)?(.*)", token)
            argument = int(match[1]) if match[1] else next_argument
            specifier = match[2]
        result.append((argument, specifier))
        next_argument += 1
    return result


def canonical_text(value: str) -> str:
    """Compare implicit and explicit argument positions without changing their order."""
    arguments = iter(signature(value))
    return FORMAT.sub(lambda match: "%%" if (part := next(arguments))[0] == 0
                      else f"%{part[0]}${part[1]}", value)


def expand_text(value: str, substitutions: dict, category: str = "other") -> str:
    def replace(match):
        token = match[0]
        name = substitution_name(token)
        if name is None:
            return token
        substitution = substitutions.get(name, {})
        plural = substitution.get("variations", {}).get("plural", {})
        node = plural.get(category, plural.get("other", substitution))
        leaf = node.get("stringUnit", {}).get("value")
        argument = substitution.get("argNum")
        if not isinstance(leaf, str) or type(argument) is not int or argument < 1:
            raise ValueError(f"{token}: missing source substitution value or argument")
        return FORMAT.sub(lambda item: "%%" if item[0] == "%%" else
                          "%" + str(argument) + "$" + re.sub(r"^%(?:[0-9]+\$)?", "", item[0]), leaf)
    return FORMAT.sub(replace, value)


def source(entry: dict) -> str:
    english = entry.get("localizations", {}).get("en", {})
    unit = english.get("stringUnit") or english.get("variations", {}).get("plural", {}).get("other", {}).get("stringUnit", {})
    value = unit.get("value")
    if not isinstance(value, str):
        raise ValueError("missing English source value")
    return expand_text(value, english.get("substitutions", {}))


def plural_nodes(localization: dict):
    plural = localization.get("variations", {}).get("plural")
    if plural is not None:
        yield 1, plural
    for substitution in localization.get("substitutions", {}).values():
        plural = substitution.get("variations", {}).get("plural")
        if plural is not None:
            yield substitution.get("argNum"), plural


def units(localization: dict, prefix: str = ""):
    if "stringUnit" in localization:
        yield prefix, localization["stringUnit"]
    for dimension, variants in localization.get("variations", {}).items():
        for variant, node in variants.items():
            yield from units(node, f"{prefix}/{dimension}/{variant}")


def omission(key: str, english: str, metadata: dict) -> bool:
    record = metadata.get(key, {})
    return record.get("source") == english and record.get("class") in OMISSION_CLASSES


def identity_allowed(key: str, english: str, locale: str, metadata: dict) -> bool:
    record = metadata.get(key, {})
    return omission(key, english, metadata) or (
        record.get("source") == english
        and isinstance(record.get("identityLocales", {}).get(locale), str)
        and bool(record.get("identityLocales", {}).get(locale))
    )


def identity_values(key: str, english: str, locale: str, metadata: dict) -> set[str]:
    record = metadata.get(key, {})
    rule = record.get("identityLocales", {}).get(locale)
    if record.get("source") != english or not isinstance(rule, dict) or not rule.get("reason"):
        return set()
    return {canonical_text(value) for value in rule.get("values", []) if isinstance(value, str)}


def validate_localization(english: str, localization: dict, locale: str, allow_identity: bool = False,
                          source_localization: dict | None = None,
                          allowed_identity_values: set[str] | None = None) -> list[str]:
    errors = []
    expected = signature(english)
    expected_arguments = {argument: specifier for argument, specifier in expected if argument}
    source_values = {canonical_text(english)}
    reference = source_localization or {}
    reference_categories = ("zero", "one", "two", "few", "many", "other") if reference.get("substitutions") else ("other",)
    for _, source_unit in units(reference):
        value = source_unit.get("value")
        if isinstance(value, str):
            for category in reference_categories:
                source_values.add(canonical_text(expand_text(value, reference.get("substitutions", {}), category)))
    for substitution in reference.get("substitutions", {}).values():
        for _, source_unit in units(substitution):
            value = source_unit.get("value")
            if isinstance(value, str):
                source_values.add(canonical_text(value))

    def validate_unit(location, unit):
        value = unit.get("value")
        if unit.get("state") != "translated":
            errors.append(f"{location}: state is {unit.get('state')!r}")
        if not isinstance(value, str) or not value.strip():
            errors.append(f"{location}: empty value")
            return None
        if MARKER.search(value):
            errors.append(f"{location}: unfinished translation marker")
        if BIDI.search(value):
            errors.append(f"{location}: bidi controls require explicit review")
        return value

    def check_identity(location, value, *, numeric_leaf=False):
        if locale == "en" or allow_identity:
            return
        # A numeric substitution leaf may legitimately be only its format token;
        # the parent supplies translated words. Text-bearing leaves may not copy English.
        if numeric_leaf and not FORMAT.sub("", value).strip():
            return
        if canonical_text(value) in (allowed_identity_values or set()):
            return
        if canonical_text(value) in source_values:
            errors.append(f"{location}: identical to English; translate or document an invariant literal")

    substitutions = localization.get("substitutions", {})
    expansion_categories = ("zero", "one", "two", "few", "many", "other") if substitutions else ("other",)
    found_units = list(units(localization))
    if not found_units:
        errors.append("missing translated string unit or variations")
    referenced = set()
    for location, unit in found_units:
        value = validate_unit(location, unit)
        if value is None:
            continue
        referenced.update(name for token in placeholders(value) if (name := substitution_name(token)) is not None)
        try:
            actual = signature(value, substitutions)
            if actual != expected:
                errors.append(f"{location}: placeholders {actual!r} != {expected!r}")
            for category in expansion_categories:
                expanded = expand_text(value, substitutions, category)
                check_identity(location, expanded)
                if expanded.count("\n") != english.count("\n"):
                    errors.append(f"{location}: line breaks do not match source")
        except ValueError as error:
            errors.append(f"{location}: {error}")
    for name, substitution in substitutions.items():
        argument = substitution.get("argNum")
        specifier = substitution.get("formatSpecifier")
        if name not in referenced:
            errors.append(f"substitution {name}: not referenced by parent text")
        if type(argument) is not int or argument not in expected_arguments:
            errors.append(f"substitution {name}: invalid argument number")
            continue
        if specifier != expected_arguments[argument]:
            errors.append(f"substitution {name}: format specifier does not match source")
        leaves = list(units(substitution))
        if not leaves:
            errors.append(f"substitution {name}: missing translated value")
        for location, unit in leaves:
            location = f"substitution {name}{location}"
            value = validate_unit(location, unit)
            if value is not None:
                if placeholders(value) != [f"%{specifier}"]:
                    errors.append(f"{location}: count placeholder does not match source")
                check_identity(location, value, numeric_leaf=True)
    required = CATEGORIES.get(locale, {"other"} if locale in {"zh-Hans", "zh-Hant", "ko", "ja"} else {"one", "other"})
    for argument, variants in plural_nodes(localization):
        if required - set(variants):
            errors.append(f"argument {argument}: missing plural categories {sorted(required - set(variants))}")
        for category, node in variants.items():
            if not list(units(node)):
                errors.append(f"argument {argument}/{category}: missing translated string unit")
    return list(dict.fromkeys(errors))


def check_entry(entry: Member, locale: str, omissions: dict, counts: dict) -> list[str]:
    english = source(entry.value)
    allowed = omission(entry.key, english, omissions)
    localization = entry.value.get("localizations", {}).get(locale)
    if localization is None:
        return [] if allowed and locale not in {"en", "ja"} else ["missing locale entry"]
    errors = validate_localization(english, localization, locale, identity_allowed(entry.key, english, locale, omissions),
                                   entry.value.get("localizations", {}).get("en"),
                                   identity_values(entry.key, english, locale, omissions))
    count = counts.get(entry.key)
    if count:
        if canonical_text(count["source"]) != canonical_text(english):
            errors.append("count source changed; review plural argument metadata")
        present = {argument for argument, _ in plural_nodes(localization)}
        for argument in count["arguments"]:
            if argument not in present:
                errors.append(f"count argument {argument} has no plural variation")
    return errors


def render(value: dict, indent: int) -> str:
    return json.dumps(value, ensure_ascii=False, indent=2).replace("\n", "\n" + " " * indent)


def replace_locale(text: str, entry: Member, locale: str, localization: dict) -> tuple[int, int, str]:
    container = next(item for item in members(text, entry.start) if item.key == "localizations")
    existing = members(text, container.start)
    selected = [item for item in existing if item.key == locale]
    if len(selected) > 1:
        raise ValueError(f"{entry.key}: duplicate {locale} entries")
    if selected:
        item = selected[0]
        return item.start, item.end, render(localization, 8)
    insertion = existing[-1].end if existing else container.start + 1
    addition = ("," if existing else "") + f"\n        {json.dumps(locale)}: " + render(localization, 8)
    return insertion, insertion, addition


def atomic_write(path: Path, text: str) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(temporary, path.stat().st_mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def apply_changes(text: str, changes: list[tuple[int, int, str]]) -> str:
    pieces = []
    position = 0
    for start, end, replacement in sorted(changes, key=lambda change: (change[0], change[1])):
        if start < position:
            raise ValueError("overlapping catalog edits")
        pieces.extend((text[position:start], replacement))
        position = end
    pieces.append(text[position:])
    return "".join(pieces)


def merge(path: Path, locale: str, rows: list[dict], omissions: dict) -> int:
    text = path.read_text(encoding="utf-8")
    indexed = {}
    for entry in catalog_entries(text):
        indexed.setdefault((entry.key, canonical_text(source(entry.value))), []).append(entry)
    changes = []
    seen = set()
    for row in rows:
        identity = (row["key"], canonical_text(row["source"]))
        if identity in seen or identity not in indexed:
            raise ValueError(f"{row['key']}: duplicate row, unknown key, or stale English source")
        seen.add(identity)
        for entry in indexed[identity]:
            current = entry.value.get("localizations", {}).get(locale, {})
            if "localization" in row:
                localization = row["localization"]
            else:
                if "variations" in current or "substitutions" in current:
                    raise ValueError(f"{entry.key}: provide the full localization to update variations")
                localization = copy.deepcopy(current)
                localization.setdefault("stringUnit", {}).update(state="translated", value=row["value"])
            errors = validate_localization(source(entry.value), localization, locale,
                                           identity_allowed(entry.key, source(entry.value), locale, omissions),
                                           entry.value.get("localizations", {}).get("en"),
                                           identity_values(entry.key, source(entry.value), locale, omissions))
            if errors:
                raise ValueError(f"{entry.key}: {'; '.join(errors)}")
            if localization != current:
                changes.append(replace_locale(text, entry, locale, localization))
    text = apply_changes(text, changes)
    catalog_entries(text)
    if changes:
        atomic_write(path, text)
    return len(changes)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "extract", "merge"))
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--catalog", type=Path)
    parser.add_argument("--locale", choices=LOCALES)
    parser.add_argument("--input", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--batch-size", type=int, default=100)
    parser.add_argument("--batch", type=int, default=0)
    parser.add_argument("--limit", type=int, default=40, help="maximum printed diagnostics; 0 prints all")
    args = parser.parse_args()
    if args.batch_size < 1 or args.batch < 0 or args.limit < 0:
        parser.error("batch size must be positive; batch and limit must be nonnegative")
    omissions = load_metadata("localization-allowed-omissions.json")
    counts = load_metadata("localization-plurals.json")
    if args.command == "merge":
        if not args.catalog or not args.locale or not args.input:
            parser.error("merge requires --catalog, --locale, and --input")
        rows = json.loads(args.input.read_text(encoding="utf-8"))
        print(f"Updated {merge(args.catalog, args.locale, rows, omissions)} locale entries")
        return 0
    paths = [args.catalog] if args.catalog else discover(args.root)
    if not paths:
        raise ValueError("no macOS catalogs found")
    if args.command == "extract" and not args.locale:
        parser.error("extract requires --locale")
    rows, diagnostics = [], []
    locales = [args.locale] if args.locale else LOCALES
    for path in paths:
        entries = catalog_entries(path.read_text(encoding="utf-8"))
        for entry in entries:
            for locale in locales:
                errors = check_entry(entry, locale, omissions, counts)
                diagnostics.extend(f"{path}:{entry.key}:{locale}: {error}" for error in errors)
                if errors and args.command == "extract":
                    rows.append({"catalog": str(path), "key": entry.key, "source": source(entry.value),
                                 "comment": entry.value.get("comment"), "placeholders": placeholders(source(entry.value)),
                                 "locale": locale, "issues": errors})
    if args.command == "extract":
        start = args.batch * args.batch_size
        output = json.dumps({"total": len(rows), "entries": rows[start:start + args.batch_size]}, ensure_ascii=False, indent=2) + "\n"
        if args.output:
            args.output.write_text(output, encoding="utf-8")
        else:
            print(output, end="")
        return 0
    for diagnostic in diagnostics[:args.limit or None]:
        print(diagnostic, file=sys.stderr)
    print(f"{len(paths)} catalogs, {len(locales)} locales: {len(diagnostics)} parity errors")
    return int(bool(diagnostics))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
