#!/usr/bin/env bash
# Fails when a cmux-next string table misses a supported language, has an
# empty value, or a translation's printf placeholders or line breaks differ
# from English. Tables: every CmuxNext package .xcstrings plus the app's
# Resources/InfoPlist.xcstrings. States `translated` and `needs_review`
# (machine translation awaiting human review) both count as present; the
# review backlog is printed per language.
# Usage: scripts/cmux-next/check-l10n.sh [repo-root]
set -euo pipefail
root="${1:-$(git rev-parse --show-toplevel)}"
exec python3 - "$root" <<'PY'
import collections, json, pathlib, re, sys

# The languages the legacy app shipped (Apple codes; README.no.md is nb).
LANGS = ("en", "ar", "bs", "da", "de", "es", "fr", "it", "ja", "km", "ko", "nb",
         "pl", "pt-BR", "ru", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant")
STATES = {"translated", "needs_review"}
FORMAT = re.compile(
    r"%%|%(?:\d+\$)?[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hlLqjzt])?[diouxXfFeEgGaAcCsSp@]")

def signature(value):
    """(argument, specifier) pairs; implicit and positional forms compare equal."""
    out, nxt = [], 1
    for token in FORMAT.findall(value):
        if token == "%%":
            out.append((0, "%"))
            continue
        m = re.fullmatch(r"%(?:(\d+)\$)?(.*)", token)
        out.append((int(m[1]) if m[1] else nxt, m[2]))
        nxt += 1
    return sorted(out)

root = pathlib.Path(sys.argv[1])
tables = sorted((root / "Packages/macOS/CmuxNext/Sources").rglob("*.xcstrings"))
tables.append(root / "Resources/InfoPlist.xcstrings")
errors, review, keys = [], collections.Counter(), 0
for path in tables:
    rel = path.relative_to(root)
    if not path.exists():
        errors.append(f"{rel}: missing table")
        continue
    try:
        strings = json.loads(path.read_text(encoding="utf-8"))["strings"]
    except (ValueError, KeyError) as error:
        errors.append(f"{rel}: unreadable catalog ({error})")
        continue
    for key, entry in strings.items():
        keys += 1
        locs = entry.get("localizations", {})
        units = {}
        for lang in LANGS:
            unit = locs.get(lang, {}).get("stringUnit")
            if lang not in locs:
                errors.append(f"{rel}:{key}: missing {lang}")
            elif unit is None:
                errors.append(f"{rel}:{key}:{lang}: expected a plain stringUnit")
            elif not str(unit.get("value", "")).strip():
                errors.append(f"{rel}:{key}:{lang}: empty value")
            elif unit.get("state") not in STATES:
                errors.append(f"{rel}:{key}:{lang}: state {unit.get('state')!r}")
            else:
                units[lang] = unit
                if unit["state"] == "needs_review":
                    review[lang] += 1
        english = units.get("en", {}).get("value")
        if english is None:
            continue
        for lang, unit in units.items():
            value = unit["value"]
            if signature(value) != signature(english):
                errors.append(f"{rel}:{key}:{lang}: placeholders {FORMAT.findall(value)} != {FORMAT.findall(english)}")
            if value.count("\n") != english.count("\n"):
                errors.append(f"{rel}:{key}:{lang}: line breaks differ from English")

for line in errors[:200]:
    print(line)
if len(errors) > 200:
    print(f"... {len(errors) - 200} more")
backlog = " ".join(f"{lang}={review[lang]}" for lang in LANGS if review[lang])
print(f"{len(tables)} tables, {keys} keys, {len(LANGS)} languages: {len(errors)} errors")
if backlog:
    print(f"needs_review (machine translated): {backlog}")
sys.exit(1 if errors else 0)
PY
