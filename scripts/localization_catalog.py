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
# cmux NEXT's catalogs carry translation debt from before this check covered them. With this
# file present, `check` is a ratchet: each catalog may keep up to its recorded count of each
# debt kind, never more, and a catalog not listed may have none. `check --write-baseline`
# lowers the counts after a cleanup and refuses to raise one. main has no such file and no
# debt, so there every parity error still fails.
DEBT_BASELINE = "localization-debt-baseline.json"
DEBT_KINDS = ("needs_review", "identical", "other")
# New cmux NEXT strings land as machine translations awaiting review (`needs_review`, which
# scripts/cmux-next/check-l10n.sh counts as present): 269 more in one hour on 2026-10-21. Growth
# of that kind is reported, not failed; copied English and malformed entries never grow.
DEBT_ENFORCED = ("identical", "other")
# What decides a catalog's debt besides the catalog: base debt is only counted with the
# base's own rules when the pull request leaves these unchanged.
RULE_FILES = ("localization_catalog.py", "localization-allowed-omissions.json", "localization-plurals.json")


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


def catalog_locales(entries: list[Member]) -> tuple[str, ...]:
    """The locales a catalog carries: the required macOS ones, then every other locale any of its
    entries has (the agent pane's catalog carries 21)."""
    present = {locale for entry in entries for locale in entry.value.get("localizations", {})}
    return LOCALES + tuple(sorted(present - set(LOCALES)))


def discover(root: Path) -> list[Path]:
    paths = set((root / "Resources").rglob("*.xcstrings"))
    paths.update((root / "Packages/macOS").glob("*/Sources/**/*.xcstrings"))
    return sorted(paths)


def load_metadata(name: str) -> dict:
    with (ROOT / "scripts" / name).open(encoding="utf-8") as handle:
        try:
            return json.load(handle, object_pairs_hook=unique_object)
        except ValueError as error:
            raise ValueError(f"scripts/{name}: {error}") from error


def placeholders(value: str) -> list[str]:
    return FORMAT.findall(value)


def substitution_name(token: str) -> str | None:
    match = re.fullmatch(r"%(?:\d+\$)?#@([^@]+)@", token)
    return match[1] if match else None


TOKEN = re.compile(
    r"%(?:(?P<argument>\d+)\$)?(?P<flags>[-+ #0']*)(?P<width>\d+|\*(?:\d+\$)?)?"
    r"(?:\.(?P<precision>\d+|\*(?:\d+\$)?))?(?P<conversion>(?:hh|ll|[hlLqjzt])?[diouxXfFeEgGaAcCsSp@])"
)


def tokens(value: str, substitutions: dict | None = None):
    """Yield (arguments, canonical) for each placeholder in text order.

    ``arguments`` lists the (argument, specifier) pairs the placeholder
    consumes. A ``*`` width or precision takes an integer argument of its own,
    before the value, so one placeholder can account for up to three; those
    carry the specifier ``*``. ``canonical`` is the placeholder with every
    argument position written out, so implicit and explicit numbering compare
    equal.
    """
    # Foundation numbers unnumbered placeholders on their own counter, so
    # "%1$@ %@" formats the first argument twice. Report what it formats.
    next_argument = 1

    def position(explicit: str | None) -> int:
        nonlocal next_argument
        if explicit:
            return int(explicit)
        next_argument += 1
        return next_argument - 1

    for token in placeholders(value):
        if token == "%%":
            yield [(0, "%")], "%%"
            continue
        name = substitution_name(token)
        if name is not None:
            substitution = (substitutions or {}).get(name, {})
            argument = substitution.get("argNum")
            specifier = substitution.get("formatSpecifier")
            if type(argument) is not int or argument < 1 or not isinstance(specifier, str):
                raise ValueError(f"invalid substitution {token}")
            next_argument += 1
            yield [(argument, specifier)], f"%{argument}${specifier}"
            continue
        match = TOKEN.fullmatch(token)
        arguments = []
        specifier = match["flags"]
        canonical = match["flags"]
        for prefix, field in (("", match["width"]), (".", match["precision"])):
            if field is None:
                continue
            if field.startswith("*"):
                argument = position(field[1:-1])
                arguments.append((argument, "*"))
                specifier += f"{prefix}*{argument}$"
                canonical += f"{prefix}*{argument}$"
            else:
                specifier += prefix + field
                canonical += prefix + field
        argument = position(match["argument"])
        arguments.append((argument, specifier + match["conversion"]))
        yield arguments, f"%{argument}${canonical}{match['conversion']}"


def signature(value: str, substitutions: dict | None = None) -> list[tuple[int, str]]:
    return [pair for arguments, _ in tokens(value, substitutions) for pair in arguments]


def canonical_text(value: str) -> str:
    """Compare implicit and explicit argument positions without changing their order."""
    rendered = iter(canonical for _, canonical in tokens(value))
    return FORMAT.sub(lambda match: next(rendered), value)


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
            # Numbered placeholders may appear in any order; what must match
            # is which arguments are consumed and with which specifiers.
            if sorted(actual) != sorted(expected):
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


def debt_kind(error: str) -> str:
    if "state is 'needs_review'" in error:
        return "needs_review"
    if "identical to English" in error:
        return "identical"
    return "other"


def catalog_name(path: Path, root: Path) -> str:
    """A catalog's baseline key: its path from the repository root."""
    path, root = path.resolve(), root.resolve()
    return path.relative_to(root).as_posix() if path.is_relative_to(root) else path.as_posix()


def debt_counts(findings: list[tuple[str, str]]) -> dict[str, dict[str, int]]:
    """Per catalog (repository-relative path), how many errors of each debt kind it has."""
    counts: dict[str, dict[str, int]] = {}
    for catalog, error in findings:
        kinds = counts.setdefault(catalog, {})
        kind = debt_kind(error)
        kinds[kind] = kinds.get(kind, 0) + 1
    return {catalog: dict(sorted(kinds.items())) for catalog, kinds in sorted(counts.items())}


def load_debt_baseline(path: Path) -> dict[str, dict[str, int]] | None:
    if not path.exists():
        return None
    data = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    catalogs = data.get("catalogs") if isinstance(data, dict) else None
    if not isinstance(catalogs, dict):
        raise ValueError(f"{path}: expected an object with a catalogs object")
    for catalog, kinds in catalogs.items():
        if not isinstance(kinds, dict) or any(kind not in DEBT_KINDS or not isinstance(count, int) or count < 1
                                              for kind, count in kinds.items()):
            raise ValueError(f"{path}: {catalog}: counts must be positive integers of {', '.join(DEBT_KINDS)}")
    return catalogs


def debt_raises(counts: dict[str, dict[str, int]], baseline: dict[str, dict[str, int]],
                kinds: tuple[str, ...] = DEBT_KINDS) -> list[str]:
    """Each catalog and kind whose count is above the baseline's (absent counts as 0)."""
    raised = []
    for catalog in sorted(set(counts) | set(baseline)):
        for kind in kinds:
            now, allowed = counts.get(catalog, {}).get(kind, 0), baseline.get(catalog, {}).get(kind, 0)
            if now > allowed:
                raised.append(f"{catalog}: {kind} {allowed} -> {now}")
    return raised


def catalog_keys(path: Path) -> set[str]:
    """The string keys a catalog file holds (empty when it cannot be read as a catalog)."""
    try:
        return {entry.key for entry in catalog_entries(path.read_text(encoding="utf-8"))}
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return set()


def same_strings(old: set[str], new: set[str]) -> bool:
    """Most of OLD's keys are in NEW and most of NEW's keys came from OLD: the same catalog moved
    (perhaps edited on the way), not an unrelated catalog that happens to share its file name."""
    shared = len(old & new)
    return bool(old) and bool(new) and shared * 2 > len(old) and shared * 2 > len(new)


def follow_moves(current: dict[str, dict[str, int]], previous: dict[str, dict[str, int]], root: Path,
                 previous_root: Path | None = None) -> tuple[dict[str, dict[str, int]], list[str]]:
    """PREVIOUS's counts with each moved catalog's counts under its new path, and the moves.

    A catalog moved between packages keeps its debt: a key of PREVIOUS that CURRENT does not
    list and whose file left ROOT passes its counts to the one new key of CURRENT with the same
    file name. Without this, every `git mv` of a catalog reads as new debt at the new path and a
    raised baseline. Most catalogs are named Localizable.xcstrings, so when the old file is in
    PREVIOUS_ROOT (the base tree) the candidate must also hold mostly the same string keys
    (``same_strings``), even when it is the only one with that name: deleting one package's
    catalog and adding an unrelated one with new untranslated strings must not hand the new one
    the old debt allowance. Several matching candidates are narrowed to the byte-identical one.
    A move it cannot pair stays unpaired, so the check still fails.
    """
    followed, moves = dict(previous), []
    new = [catalog for catalog in current if catalog not in previous and (root / catalog).is_file()]
    for old in sorted(catalog for catalog in previous if catalog not in current and not (root / catalog).exists()):
        candidates = [catalog for catalog in new if Path(catalog).name == Path(old).name]
        if previous_root is not None and (previous_root / old).is_file():
            old_keys = catalog_keys(previous_root / old)
            candidates = [catalog for catalog in candidates if same_strings(old_keys, catalog_keys(root / catalog))]
            if len(candidates) > 1:
                content = (previous_root / old).read_bytes()
                candidates = [catalog for catalog in candidates if (root / catalog).read_bytes() == content]
        if len(candidates) != 1:
            continue
        followed[candidates[0]] = followed.pop(old)
        new.remove(candidates[0])
        moves.append(f"{old} -> {candidates[0]}")
    return followed, moves


def debt_findings(root: Path, locales, omissions: dict, counts: dict) -> list[tuple[str, str]]:
    """(catalog, error) for every parity error in the catalogs under root."""
    findings = []
    for path in discover(root):
        catalog = catalog_name(path, root)
        for entry in catalog_entries(path.read_text(encoding="utf-8")):
            for locale in locales:
                findings.extend((catalog, error) for error in check_entry(entry, locale, omissions, counts))
    return findings


def debt_json(catalogs: dict[str, dict[str, int]]) -> str:
    return json.dumps({"catalogs": catalogs}, indent=2, sort_keys=True) + "\n"


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


def merge_text(text: str, locale: str, rows: list[dict], omissions: dict) -> tuple[str, int]:
    """Validate and compose one locale without changing the source catalog."""
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
    return text, len(changes)


def merge(path: Path, locale: str, rows: list[dict], omissions: dict) -> int:
    text, changes = merge_text(path.read_text(encoding="utf-8"), locale, rows, omissions)
    if changes:
        atomic_write(path, text)
    return changes


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
    parser.add_argument("--baseline", type=Path, help=f"debt baseline (default: scripts/{DEBT_BASELINE} under --root)")
    parser.add_argument("--write-baseline", action="store_true",
                        help="check: rewrite the debt baseline to the current counts; refuses to raise any")
    parser.add_argument("--base-baseline", type=Path,
                        help="check: also fail when the baseline is above this one (the base branch's copy)")
    parser.add_argument("--base-root", type=Path,
                        help="check: the base tree's catalogs; debt the base already has warns instead of failing")
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
    rows, diagnostics, findings = [], [], []
    locales = [args.locale] if args.locale else LOCALES
    for path in paths:
        entries = catalog_entries(path.read_text(encoding="utf-8"))
        catalog = catalog_name(path, args.root)
        for entry in entries:
            for locale in locales:
                errors = check_entry(entry, locale, omissions, counts)
                diagnostics.extend(f"{path}:{entry.key}:{locale}: {error}" for error in errors)
                findings.extend((catalog, error) for error in errors)
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
    baseline_path = args.baseline or args.root / "scripts" / DEBT_BASELINE
    baseline = load_debt_baseline(baseline_path)
    if args.base_root and not args.base_baseline:
        parser.error("--base-root needs --base-baseline: the base's debt is judged against its own baseline")
    if (args.write_baseline or args.base_baseline or args.base_root) and (args.catalog or args.locale):
        parser.error("--write-baseline, --base-baseline and --base-root judge every catalog and locale")
    debt = debt_counts(findings)
    if args.write_baseline:
        if baseline is not None:
            baseline, moves = follow_moves(debt, baseline, args.root)
            for move in moves:
                print(f"note: a catalog moved and keeps its baseline: {move}")
            raised = debt_raises(debt, baseline, DEBT_ENFORCED)
            if raised:
                print("refusing to raise the localization debt baseline:", file=sys.stderr)
                for line in raised:
                    print(f"  {line}", file=sys.stderr)
                return 1
            # A reported kind keeps the lower count, so it only goes down too.
            for catalog, kinds in debt.items():
                for kind in DEBT_KINDS:
                    if kind not in DEBT_ENFORCED and kind in kinds:
                        kinds[kind] = min(kinds[kind], baseline.get(catalog, {}).get(kind, 0))
            debt = {catalog: {kind: count for kind, count in kinds.items() if count}
                    for catalog, kinds in debt.items()}
            debt = {catalog: kinds for catalog, kinds in debt.items() if kinds}
        baseline_path.write_text(debt_json(debt), encoding="utf-8")
        print(f"wrote {baseline_path}: {sum(sum(kinds.values()) for kinds in debt.values())} errors in {len(debt)} catalogs")
        return 0
    if baseline is None or args.locale:
        for diagnostic in diagnostics[:args.limit or None]:
            print(diagnostic, file=sys.stderr)
        print(f"{len(paths)} catalogs, {len(locales)} locales: {len(diagnostics)} parity errors")
        return int(bool(diagnostics))
    if args.catalog:
        only = catalog_name(args.catalog, args.root)
        baseline = {catalog: kinds for catalog, kinds in baseline.items() if catalog == only}
    failed = False
    allowed = baseline
    if args.base_root:
        # A pull request runs on its merge with the base, so debt the base added past its own
        # baseline is in every pull request's count; only the push that added it fails.
        base_baseline = load_debt_baseline(args.base_baseline) or {}
        changed = [name for name in RULE_FILES if not (args.base_root / "scripts" / name).is_file()
                   or (args.base_root / "scripts" / name).read_bytes() != (ROOT / "scripts" / name).read_bytes()]
        if changed:
            print(f"note: this change changes {', '.join(changed)}, so debt the base has is not excused")
        base_debt = {} if changed else debt_counts(debt_findings(args.base_root, locales, omissions, counts))
        for line in debt_raises(base_debt, base_baseline, DEBT_ENFORCED):
            print(f"warning: the base is already over its baseline, not this change: {line}")
        allowed = {catalog: {kind: baseline.get(catalog, {}).get(kind, 0)
                             + max(0, base_debt.get(catalog, {}).get(kind, 0) - base_baseline.get(catalog, {}).get(kind, 0))
                             for kind in DEBT_KINDS}
                   for catalog in set(baseline) | set(base_debt)}
    raised = debt_raises(debt, allowed, DEBT_ENFORCED)
    reviews = debt_raises(debt, baseline, tuple(kind for kind in DEBT_KINDS if kind not in DEBT_ENFORCED))
    for line in reviews:
        print(f"note: more strings await review than the baseline records: {line}")
    if raised:
        failed = True
        over = {line.split(": ", 1)[0] for line in raised}
        shown = [d for d, (catalog, _) in zip(diagnostics, findings) if catalog in over]
        for diagnostic in shown[:args.limit or None]:
            print(diagnostic, file=sys.stderr)
        print(f"localization debt grew past {baseline_path.name}; translate the new strings:", file=sys.stderr)
        for line in raised:
            print(f"  {line}", file=sys.stderr)
    if args.base_baseline:
        base, moves = follow_moves(baseline, load_debt_baseline(args.base_baseline) or {}, args.root, args.base_root)
        for move in moves:
            print(f"note: a catalog moved and keeps the base's baseline: {move}")
        grown = debt_raises(baseline, base)
        if grown:
            failed = True
            print(f"{baseline_path.name} may only go down; it rose above the base's:", file=sys.stderr)
            for line in grown:
                print(f"  {line}", file=sys.stderr)
    lowered = [catalog for catalog, kinds in baseline.items()
               if any(debt.get(catalog, {}).get(kind, 0) < count for kind, count in kinds.items())]
    if lowered and not failed:
        print(f"{len(lowered)} catalogs are below the baseline; lower it with: "
              f"python3 scripts/localization_catalog.py check --write-baseline")
    print(f"{len(paths)} catalogs, {len(locales)} locales: {len(diagnostics)} parity errors, "
          f"{'over' if raised else 'within'} the debt baseline")
    return int(failed)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
