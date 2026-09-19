#!/usr/bin/env python3
"""Prepare, import, and validate localization work for the current git diff."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT = SCRIPT_DIR.parent
CATALOG_SPEC = importlib.util.spec_from_file_location("cmux_localization_catalog", SCRIPT_DIR / "localization_catalog.py")
if CATALOG_SPEC is None or CATALOG_SPEC.loader is None:
    raise RuntimeError("unable to load scripts/localization_catalog.py")
CATALOG = importlib.util.module_from_spec(CATALOG_SPEC)
sys.modules[CATALOG_SPEC.name] = CATALOG
CATALOG_SPEC.loader.exec_module(CATALOG)

SWIFT_CALL = re.compile(
    r"(?P<kind>String\s*\(\s*localized:|LocalizedStringResource\s*\()\s*"
    r'(?P<key>"(?:\\.|[^"\\])*")'
    r"(?P<middle>[\s\S]{0,1200}?)"
    r'defaultValue\s*:\s*(?P<value>"(?:\\.|[^"\\])*")',
)
SWIFT_COMMENT = re.compile(r'comment\s*:\s*(?P<comment>"(?:\\.|[^"\\])*")')
WEB_LOCALES = re.compile(r"export\s+const\s+locales\s*=\s*\[(?P<body>[\s\S]*?)\]\s*as\s+const")
QUOTED = re.compile(r'"((?:\\.|[^"\\])*)"|\'((?:\\.|[^\'\\])*)\'')
INTEGER_FORMAT = re.compile(r"%(?:\d+\$)?(?:hh|ll|[hlLqjzt])?[diouxX]")


@dataclass(frozen=True)
class SwiftMessage:
    path: str
    key: str
    source: str
    comment: str | None = None


@dataclass
class PreparationResult:
    changed_keys: list[tuple[Path, str]]
    prepared: int
    stale: int
    attention: list[str]


def run_git(root: Path, *args: str, check: bool = True) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and result.returncode:
        detail = result.stderr.strip() or result.stdout.strip() or f"git {' '.join(args)} failed"
        raise ValueError(detail)
    return result.stdout


def resolve_root() -> Path:
    output = run_git(Path.cwd(), "rev-parse", "--show-toplevel")
    return Path(output.strip()).resolve()


def resolve_base(root: Path, requested: str | None) -> str:
    requested = requested or os.environ.get("CMUX_LOCALIZATION_BASE")
    if requested:
        run_git(root, "rev-parse", "--verify", requested)
        return run_git(root, "merge-base", "HEAD", requested).strip()
    for candidate in ("refs/remotes/upstream/main", "refs/remotes/origin/main", "refs/heads/main"):
        if run_git(root, "rev-parse", "--verify", candidate, check=False).strip():
            return run_git(root, "merge-base", "HEAD", candidate).strip()
    raise ValueError("cannot determine localization diff base; pass --base <ref>")


def changed_files(root: Path, base: str) -> list[str]:
    tracked = {
        line for line in run_git(root, "diff", "--name-only", "--diff-filter=ACMRT", base, "--").splitlines()
        if line
    }
    untracked = {
        line for line in run_git(root, "ls-files", "--others", "--exclude-standard").splitlines()
        if line
    }
    return sorted(tracked | untracked)


def base_text(root: Path, base: str, path: str) -> str:
    result = subprocess.run(
        ["git", "show", f"{base}:{path}"],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.stdout if result.returncode == 0 else ""


def decode_swift_string(literal: str) -> str:
    if not (literal.startswith('"') and literal.endswith('"')):
        raise ValueError("unsupported Swift string literal")
    value = literal[1:-1]
    if "\\(" in value:
        raise ValueError("interpolated defaultValue requires manual catalog review")
    result: list[str] = []
    index = 0
    escapes = {"n": "\n", "r": "\r", "t": "\t", '"': '"', "\\": "\\", "0": "\0"}
    while index < len(value):
        if value[index] != "\\":
            result.append(value[index])
            index += 1
            continue
        index += 1
        if index >= len(value) or value[index] not in escapes:
            raise ValueError("unsupported Swift escape in defaultValue")
        result.append(escapes[value[index]])
        index += 1
    return "".join(result)


def parse_swift_messages(path: str, text: str) -> tuple[dict[str, SwiftMessage], list[str]]:
    messages: dict[str, SwiftMessage] = {}
    attention: list[str] = []
    for match in SWIFT_CALL.finditer(text):
        try:
            key = decode_swift_string(match.group("key"))
            source = decode_swift_string(match.group("value"))
            comment_match = SWIFT_COMMENT.search(match.group("middle"))
            comment = decode_swift_string(comment_match.group("comment")) if comment_match else None
        except ValueError as error:
            attention.append(f"{path}: {error}")
            continue
        previous = messages.get(key)
        candidate = SwiftMessage(path=path, key=key, source=source, comment=comment)
        if previous and previous.source != candidate.source:
            attention.append(f"{path}: localization key {key!r} has multiple default values")
            continue
        messages[key] = candidate
    markers = text.count("String(localized:") + text.count("LocalizedStringResource(")
    if markers > len(messages):
        attention.append(
            f"{path}: {markers - len(messages)} localized call(s) use a form this helper cannot safely prepare; review them manually"
        )
    return messages, attention


def changed_swift_messages(root: Path, base: str, paths: Iterable[str]) -> tuple[list[SwiftMessage], list[str]]:
    changed: list[SwiftMessage] = []
    attention: list[str] = []
    for path in paths:
        if not path.endswith(".swift"):
            continue
        current_path = root / path
        if not current_path.is_file():
            continue
        current, current_attention = parse_swift_messages(path, current_path.read_text(encoding="utf-8"))
        previous, _ = parse_swift_messages(path, base_text(root, base, path))
        attention.extend(current_attention)
        for key, message in sorted(current.items()):
            if key not in previous or previous[key].source != message.source:
                changed.append(message)
    return changed, attention


def discover_web_locales(root: Path) -> tuple[str, ...]:
    routing = (root / "web/i18n/routing.ts").read_text(encoding="utf-8")
    match = WEB_LOCALES.search(routing)
    if not match:
        raise ValueError("cannot parse web/i18n/routing.ts locale list")
    locales = tuple(left or right for left, right in QUOTED.findall(match.group("body")))
    if not locales or len(locales) != len(set(locales)):
        raise ValueError("web/i18n/routing.ts contains no locales or duplicate locales")
    return locales


def macos_locales() -> tuple[str, ...]:
    return tuple(CATALOG.LOCALES)


def catalog_index(root: Path) -> tuple[list[Path], dict[str, list[tuple[Path, object]]]]:
    paths = CATALOG.discover(root)
    index: dict[str, list[tuple[Path, object]]] = {}
    for path in paths:
        for entry in CATALOG.catalog_entries(path.read_text(encoding="utf-8")):
            index.setdefault(entry.key, []).append((path, entry))
    return paths, index


def choose_catalog(root: Path, message: SwiftMessage, paths: list[Path], index: dict[str, list[tuple[Path, object]]], override: Path | None) -> Path:
    existing = index.get(message.key, [])
    if len(existing) == 1:
        return existing[0][0]
    if len(existing) > 1:
        exact = [path for path, entry in existing if CATALOG.canonical_text(CATALOG.source(entry.value)) == CATALOG.canonical_text(message.source)]
        if len(exact) == 1:
            return exact[0]
        raise ValueError(f"{message.path}: localization key {message.key!r} exists in multiple catalogs")
    if override:
        selected = override if override.is_absolute() else root / override
        if selected not in paths:
            raise ValueError(f"--catalog {override} is not a discovered macOS string catalog")
        return selected
    parts = Path(message.path).parts
    if len(parts) >= 3 and parts[:2] == ("Packages", "macOS"):
        package_root = root / Path(*parts[:3])
        candidates = [path for path in paths if package_root in path.parents]
        if len(candidates) == 1:
            return candidates[0]
        if len(candidates) > 1:
            raise ValueError(f"{message.path}: package has multiple string catalogs; pass --catalog")
    default = root / "Resources/Localizable.xcstrings"
    if default in paths:
        return default
    raise ValueError(f"{message.path}: cannot infer catalog for new key {message.key!r}; pass --catalog")


def string_unit(value: str, state: str = "translated") -> dict:
    return {"stringUnit": {"state": state, "value": value}}


def insert_catalog_entry(path: Path, key: str, source: str, comment: str | None) -> None:
    text = path.read_text(encoding="utf-8")
    entries = CATALOG.catalog_entries(text)
    if any(entry.key == key for entry in entries):
        return
    root_members = CATALOG.members(text, len(text) - len(text.lstrip()))
    strings = next(item for item in root_members if item.key == "strings")
    record: dict = {"extractionState": "manual", "localizations": {"en": string_unit(source)}}
    if comment:
        record = {"comment": comment, **record}
    insertion = entries[-1].end if entries else strings.start + 1
    addition = ("," if entries else "") + f"\n    {json.dumps(key, ensure_ascii=False)}: " + CATALOG.render(record, 4)
    updated = CATALOG.apply_changes(text, [(insertion, insertion, addition)])
    CATALOG.catalog_entries(updated)
    CATALOG.atomic_write(path, updated)


def mark_needs_review(localization: dict) -> dict:
    value = json.loads(json.dumps(localization, ensure_ascii=False))
    touched = False

    def visit(node: object) -> None:
        nonlocal touched
        if not isinstance(node, dict):
            return
        unit = node.get("stringUnit")
        if isinstance(unit, dict):
            unit["state"] = "needs_review"
            touched = True
        for child in node.values():
            if isinstance(child, dict):
                visit(child)

    visit(value)
    return value if touched else localization


def update_simple_source(path: Path, key: str, new_source: str) -> tuple[bool, str | None]:
    text = path.read_text(encoding="utf-8")
    matches = [entry for entry in CATALOG.catalog_entries(text) if entry.key == key]
    if len(matches) != 1:
        return False, f"{path}: key {key!r} is duplicated; update it manually"
    entry = matches[0]
    current_source = CATALOG.source(entry.value)
    if CATALOG.canonical_text(current_source) == CATALOG.canonical_text(new_source):
        return False, None
    english = entry.value.get("localizations", {}).get("en", {})
    if "variations" in english or "substitutions" in english:
        return False, f"{path}: key {key!r} has plural/variant English; update its source manually to preserve plural semantics"
    localizations = entry.value.get("localizations", {})
    changes = [CATALOG.replace_locale(text, entry, "en", string_unit(new_source))]
    for locale, localization in localizations.items():
        if locale == "en":
            continue
        changes.append(CATALOG.replace_locale(text, entry, locale, mark_needs_review(localization)))
    updated = CATALOG.apply_changes(text, changes)
    CATALOG.catalog_entries(updated)
    CATALOG.atomic_write(path, updated)
    return True, None


def prepare_macos(root: Path, messages: list[SwiftMessage], override: Path | None, counts: dict) -> PreparationResult:
    paths, index = catalog_index(root)
    attention: list[str] = []
    changed_keys: list[tuple[Path, str]] = []
    prepared = stale = 0
    seen: set[tuple[Path, str]] = set()
    for message in messages:
        try:
            path = choose_catalog(root, message, paths, index, override)
        except ValueError as error:
            attention.append(str(error))
            continue
        identity = (path, message.key)
        if identity in seen:
            continue
        seen.add(identity)
        existing = index.get(message.key, [])
        if not existing:
            if message.key in counts or INTEGER_FORMAT.search(message.source):
                attention.append(
                    f"{message.path}: new count-like key {message.key!r} needs an explicit plural catalog entry and localization-plurals metadata"
                )
                continue
            insert_catalog_entry(path, message.key, message.source, message.comment)
            prepared += 1
            index.setdefault(message.key, []).append((path, next(entry for entry in CATALOG.catalog_entries(path.read_text(encoding="utf-8")) if entry.key == message.key)))
        else:
            changed, problem = update_simple_source(path, message.key, message.source)
            if problem:
                attention.append(problem)
                continue
            stale += int(changed)
        changed_keys.append(identity)
    return PreparationResult(changed_keys=changed_keys, prepared=prepared, stale=stale, attention=attention)


def changed_catalog_keys(root: Path, base: str, paths: Iterable[str]) -> PreparationResult:
    """Find English catalog source changes and stale only untouched translations."""
    changed_keys: list[tuple[Path, str]] = []
    attention: list[str] = []
    stale = 0
    for relative in sorted(set(paths)):
        if not relative.endswith(".xcstrings"):
            continue
        path = root / relative
        if not path.is_file():
            continue
        try:
            previous_text = base_text(root, base, relative)
            previous_entries = CATALOG.catalog_entries(previous_text) if previous_text else []
            current_entries = CATALOG.catalog_entries(path.read_text(encoding="utf-8"))
        except (ValueError, json.JSONDecodeError) as error:
            attention.append(f"{relative}: cannot inspect catalog diff: {error}")
            continue
        previous_by_key: dict[str, list[object]] = {}
        current_counts: dict[str, int] = {}
        for entry in previous_entries:
            previous_by_key.setdefault(entry.key, []).append(entry)
        for entry in current_entries:
            current_counts[entry.key] = current_counts.get(entry.key, 0) + 1
        for key in sorted(current_counts):
            if current_counts[key] != 1:
                attention.append(f"{relative}: key {key!r} is duplicated; review it manually")
                continue
            old_matches = previous_by_key.get(key, [])
            if len(old_matches) > 1:
                attention.append(f"{relative}: base key {key!r} is duplicated; review it manually")
                continue
            current_text = path.read_text(encoding="utf-8")
            entry = next(item for item in CATALOG.catalog_entries(current_text) if item.key == key)
            try:
                current_source = CATALOG.source(entry.value)
                old_source = CATALOG.source(old_matches[0].value) if old_matches else None
            except ValueError as error:
                attention.append(f"{relative}: key {key!r}: {error}")
                continue
            if old_source is not None and CATALOG.canonical_text(old_source) == CATALOG.canonical_text(current_source):
                continue
            changed_keys.append((path, key))
            if not old_matches:
                continue
            old = old_matches[0]
            current_localizations = entry.value.get("localizations", {})
            old_localizations = old.value.get("localizations", {})
            changes: list[tuple[int, int, str]] = []
            for locale, localization in current_localizations.items():
                if locale == "en" or old_localizations.get(locale) != localization:
                    continue
                reviewed = mark_needs_review(localization)
                if reviewed != localization:
                    changes.append(CATALOG.replace_locale(current_text, entry, locale, reviewed))
            if changes:
                updated = CATALOG.apply_changes(current_text, changes)
                CATALOG.catalog_entries(updated)
                CATALOG.atomic_write(path, updated)
                stale += 1
    return PreparationResult(changed_keys=changed_keys, prepared=0, stale=stale, attention=attention)


def load_work(path: Path) -> dict:
    if not path.exists():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or data.get("version") != 1:
        raise ValueError(f"{path}: unsupported localization work packet")
    return data


def translation_index(work: dict) -> dict[tuple[str, str, str, str], dict]:
    result = {}
    for row in work.get("entries", []):
        if not isinstance(row, dict):
            continue
        identity = (row.get("catalog"), row.get("key"), row.get("source"), row.get("locale"))
        if all(isinstance(part, str) for part in identity):
            result[identity] = row
    return result


def apply_completed(root: Path, work: dict, omissions: dict) -> int:
    grouped: dict[tuple[str, str], list[dict]] = {}
    for row in work.get("entries", []):
        if not isinstance(row, dict) or ("value" not in row and "localization" not in row):
            continue
        if "value" in row and (not isinstance(row["value"], str) or not row["value"].strip()):
            continue
        if "localization" in row and not isinstance(row["localization"], dict):
            raise ValueError(f"{row.get('key')}: localization must be an object")
        grouped.setdefault((row["catalog"], row["locale"]), []).append({
            key: row[key] for key in ("key", "source", "value", "localization") if key in row
        })
    updated = 0
    for (catalog_path, locale), rows in sorted(grouped.items()):
        updated += CATALOG.merge(root / catalog_path, locale, rows, omissions)
    return updated


def extract_changed(root: Path, changed_keys: list[tuple[Path, str]], omissions: dict, counts: dict, prior: dict) -> list[dict]:
    preserved = translation_index(prior)
    rows: list[dict] = []
    for path, key in sorted(changed_keys, key=lambda item: (str(item[0]), item[1])):
        text = path.read_text(encoding="utf-8")
        entries = [entry for entry in CATALOG.catalog_entries(text) if entry.key == key]
        for entry in entries:
            english = CATALOG.source(entry.value)
            for locale in macos_locales():
                errors = CATALOG.check_entry(entry, locale, omissions, counts)
                if not errors:
                    continue
                row = {
                    "catalog": str(path.relative_to(root)),
                    "key": key,
                    "source": english,
                    "comment": entry.value.get("comment"),
                    "placeholders": CATALOG.placeholders(english),
                    "locale": locale,
                    "issues": errors,
                }
                current = entry.value.get("localizations", {}).get(locale)
                if current is not None:
                    row["currentLocalization"] = current
                old = preserved.get((row["catalog"], key, english, locale), {})
                if "value" in old:
                    row["value"] = old["value"]
                if "localization" in old:
                    row["localization"] = old["localization"]
                rows.append(row)
    return rows


def flatten_messages(value: object, prefix: str = "") -> dict[str, str]:
    result: dict[str, str] = {}
    if isinstance(value, str):
        result[prefix] = value
    elif isinstance(value, dict):
        for key, child in value.items():
            child_prefix = f"{prefix}.{key}" if prefix else str(key)
            result.update(flatten_messages(child, child_prefix))
    return result


def json_at(root: Path, path: str) -> dict:
    value = json.loads((root / path).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{path}: expected a JSON object")
    return value


def base_json(root: Path, base: str, path: str) -> dict:
    text = base_text(root, base, path)
    if not text:
        return {}
    value = json.loads(text)
    return value if isinstance(value, dict) else {}


def web_work(root: Path, base: str, paths: Iterable[str], locales: tuple[str, ...]) -> tuple[list[dict], list[str], int]:
    english_path = "web/messages/en.json"
    if english_path not in paths:
        missing = [locale for locale in locales if not (root / f"web/messages/{locale}.json").is_file()]
        return [], [f"web/messages/{locale}.json: missing catalog declared by web/i18n/routing.ts" for locale in missing], 0
    current_en = flatten_messages(json_at(root, english_path))
    previous_en = flatten_messages(base_json(root, base, english_path))
    changed = {key: value for key, value in current_en.items() if previous_en.get(key) != value}
    rows: list[dict] = []
    attention: list[str] = []
    for locale in locales:
        message_path = root / f"web/messages/{locale}.json"
        if not message_path.is_file():
            attention.append(f"{message_path.relative_to(root)}: missing catalog declared by web/i18n/routing.ts")
            continue
        if locale == "en":
            continue
        localized = flatten_messages(json.loads(message_path.read_text(encoding="utf-8")))
        previous_localized = flatten_messages(base_json(root, base, f"web/messages/{locale}.json"))
        for key, source in sorted(changed.items()):
            value = localized.get(key)
            issues: list[str] = []
            if value is None:
                issues.append("missing message key")
            elif not value.strip():
                issues.append("empty translation")
            elif key in previous_en and previous_en[key] != source and previous_localized.get(key) == value:
                issues.append("translation was unchanged after the English source changed; review it")
            if issues:
                row = {"catalog": f"web/messages/{locale}.json", "key": key, "source": source, "locale": locale, "issues": issues}
                if value is not None:
                    row["currentValue"] = value
                rows.append(row)
    return rows, attention, len(changed)


def default_work_path(root: Path) -> Path:
    relative = run_git(root, "rev-parse", "--git-path", "cmux-localization/work.json").strip()
    path = Path(relative)
    return path if path.is_absolute() else root / path


def write_work(path: Path, base: str, entries: list[dict], web_entries: list[dict], attention: list[str], web_locales: tuple[str, ...]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "version": 1,
        "base": base,
        "macOSLocales": list(macos_locales()),
        "webLocales": list(web_locales),
        "entries": entries,
        "webEntries": web_entries,
        "attention": sorted(dict.fromkeys(attention)),
    }
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def run_validator(root: Path) -> tuple[int, str, str]:
    result = subprocess.run(
        [sys.executable, str(root / "scripts/localization_catalog.py"), "check", "--root", str(root)],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    return result.returncode, result.stdout.strip(), result.stderr.strip()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", help="git ref to compare against; defaults to upstream/main, origin/main, or main")
    parser.add_argument("--catalog", type=Path, help="catalog to use for otherwise ambiguous new Swift keys")
    parser.add_argument("--work-file", type=Path, help="machine-readable translation packet (default: git metadata directory)")
    args = parser.parse_args(argv)

    root = resolve_root()
    base = resolve_base(root, args.base)
    paths = changed_files(root, base)
    work_path = args.work_file or default_work_path(root)
    if not work_path.is_absolute():
        work_path = root / work_path
    prior = load_work(work_path)
    omissions = CATALOG.load_metadata("localization-allowed-omissions.json")
    counts = CATALOG.load_metadata("localization-plurals.json")

    imported = apply_completed(root, prior, omissions)
    messages, attention = changed_swift_messages(root, base, paths)
    prepared = prepare_macos(root, messages, args.catalog, counts)
    attention.extend(prepared.attention)
    catalog_paths = set(paths)
    catalog_paths.update(str(path.relative_to(root)) for path, _ in prepared.changed_keys)
    catalog_changes = changed_catalog_keys(root, base, catalog_paths)
    attention.extend(catalog_changes.attention)
    changed_keys = sorted(set(prepared.changed_keys + catalog_changes.changed_keys), key=lambda item: (str(item[0]), item[1]))
    entries = extract_changed(root, changed_keys, omissions, counts, prior)

    web_locales = discover_web_locales(root)
    web_entries, web_attention, web_changed = web_work(root, base, paths, web_locales)
    attention.extend(web_attention)
    write_work(work_path, base, entries, web_entries, attention, web_locales)

    validator_code, validator_out, validator_err = run_validator(root)
    outstanding = len(entries) + len(web_entries) + len(set(attention))
    print(f"Localization diff base: {base}")
    print(f"macOS locales: {', '.join(macos_locales())}")
    print(f"web locales: {', '.join(web_locales)}")
    print(f"Prepared {prepared.prepared} new macOS key(s); marked {prepared.stale + catalog_changes.stale} changed key(s) for translation review; imported {imported} completed locale entry/entries.")
    print(f"Changed web English message keys: {web_changed}")
    print(f"Translation work packet: {work_path}")
    if validator_out:
        print(validator_out)
    if outstanding or validator_code:
        if entries:
            print(f"Outstanding macOS translation rows: {len(entries)}", file=sys.stderr)
        if web_entries:
            print(f"Outstanding web translation rows: {len(web_entries)}", file=sys.stderr)
        for item in sorted(dict.fromkeys(attention)):
            print(f"Human attention: {item}", file=sys.stderr)
        if validator_code:
            print("Strict catalog validator failed.", file=sys.stderr)
        if validator_err:
            print(validator_err, file=sys.stderr)
        print("Fill value/localization fields in the work packet (and any listed web catalogs), then run ./scripts/localize-changes again.", file=sys.stderr)
        return 1
    print("Localization ready: changed work is complete and the strict catalog validator passed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
