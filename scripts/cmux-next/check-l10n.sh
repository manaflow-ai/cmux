#!/usr/bin/env bash
# Fails when a cmux-next string table (CmuxNext, the app's InfoPlist and CLI
# tables, and the Home transcript's CmuxMessagesLab tables) misses a supported language, has an
# empty value, or a translation's printf placeholders or line breaks differ
# from English. Tables: every CmuxNext package .xcstrings, the app's
# Resources/InfoPlist.xcstrings and the CLI table Resources/Localizable.xcstrings
# (the only one with plural variations). States `translated` and `needs_review`
# (machine translation awaiting human review) both count as present; the
# review backlog is printed per language.
# L10N_STYLE_WARN_MAX=N (CI sets it) is the warning tier for style errors (a
# missing language, an empty value, line breaks that differ): up to N of them
# are ratchet debt `::warning title=ratchet debt::` annotations and pass; more
# fail. Missing or unreadable tables, wrong shapes or states and placeholder
# mismatches always fail.
# Count agreement (always fails): a CmuxNext key whose English writes a word
# right after an integer count ("%lld items") needs plural variations, a label
# before the count, or a unit written by Foundation (CmuxNextCompat
# LocalizedArgument); a fixed word cannot agree with every count in Arabic or
# the Slavic languages, nor in English ("1 items"). The exceptions (a
# preposition, an invariant unit symbol, a constant limit) are listed with a
# reason in scripts/cmux-next/l10n-count-noun-allowlist.json, which only
# shrinks. And a key with plural variations must get its count in the lookup
# (an interpolated String(localized:) literal or
# Bundle.localizedString(forKey:value:table:arguments:...)), not in a
# String(format:) after it.
# Usage: scripts/cmux-next/check-l10n.sh [repo-root]
set -euo pipefail
root="${1:-$(git rev-parse --show-toplevel)}"
exec python3 - "$root" <<'PY'
import collections, json, os, pathlib, re, subprocess, sys

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
# The Home transcript's tables (MessagesLab's vendored ones and cmux's own) ship in the app too.
tables += sorted((root / "Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Resources").glob("*.xcstrings"))
tables += sorted((root / "Packages/Shared/CmuxMessagesLab/Sources/MessagesLabSidebar/Resources").glob("*.xcstrings"))
def forms(localization):
    """{"": unit} for a plain value, {category: unit} for plural variations, else None."""
    if "stringUnit" in localization:
        return {"": localization["stringUnit"]}
    plural = localization.get("variations", {}).get("plural")
    if isinstance(plural, dict) and plural:
        return {category: form.get("stringUnit") for category, form in plural.items()}
    return None

errors, style, review, keys = [], [], collections.Counter(), 0
parsed = {}  # path -> its strings, for the count agreement rule below
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
    parsed[path] = strings
    for key, entry in strings.items():
        keys += 1
        locs = entry.get("localizations", {})
        english_forms = forms(locs.get("en", {}))
        # A plural key (only in the CLI table) keeps English's plural
        # categories in every language; each form is checked like a value.
        for lang in LANGS:
            if lang not in locs:
                style.append(f"{rel}:{key}: missing {lang}")
                continue
            lang_forms = forms(locs[lang])
            if lang_forms is None or (english_forms and set(english_forms) - set(lang_forms)):
                errors.append(f"{rel}:{key}:{lang}: expected a plain stringUnit or English's plural forms")
                continue
            for form, unit in lang_forms.items():
                label = f"{rel}:{key}:{lang}" + (f":{form}" if form else "")
                if unit is None or not str(unit.get("value", "")).strip():
                    style.append(f"{label}: empty value")
                    continue
                if unit.get("state") not in STATES:
                    errors.append(f"{label}: state {unit.get('state')!r}")
                    continue
                if unit["state"] == "needs_review" and form in ("", "other"):
                    review[lang] += 1
                english = (english_forms or {}).get(form, {}) or {}
                english = english.get("value") if isinstance(english, dict) else None
                if english is None or lang == "en":
                    continue
                value = unit["value"]
                if signature(value) != signature(english):
                    errors.append(f"{label}: placeholders {FORMAT.findall(value)} != {FORMAT.findall(english)}")
                if value.count("\n") != english.count("\n"):
                    style.append(f"{label}: line breaks differ from English")

# Count agreement: a word right after an integer count, in a key without plural variations.
COUNT_NOUN = re.compile(r"%(?:\d+\$)?(?:ll|l|h|q|z|t|j)?[diu](?=\s?[^\W\d_])")
next_sources = root / "Packages/macOS/CmuxNext/Sources"
allow_rel = "scripts/cmux-next/l10n-count-noun-allowlist.json"
allow_path = root / allow_rel
try:
    allow = json.loads(allow_path.read_text(encoding="utf-8")) if allow_path.exists() else {}
except ValueError as error:
    errors.append(f"{allow_rel}: unreadable ({error})")
    allow = {}
allow_used, plural_keys = set(), set()
for path, strings in parsed.items():
    if next_sources not in path.parents:
        continue
    rel = path.relative_to(root)
    for key, entry in strings.items():
        english = entry.get("localizations", {}).get("en", {})
        if english.get("variations", {}).get("plural"):
            plural_keys.add(key)
            continue
        value = str(english.get("stringUnit", {}).get("value", ""))
        if not COUNT_NOUN.search(value):
            continue
        record = allow.get(key)
        if record is None:
            errors.append(f"{rel}:{key}: a word follows the count in {value!r}; give the key plural variations "
                          f"(and a scripts/localization-plurals.json entry), put a label before the count, or let "
                          f"Foundation write the unit (CmuxNextCompat LocalizedArgument); exceptions: {allow_rel}")
            continue
        allow_used.add(key)
        if not isinstance(record, dict) or record.get("source") != value or not str(record.get("reason", "")).strip():
            errors.append(f"{rel}:{key}: its {allow_rel} entry needs a reason and the current English {value!r}")
for key in sorted(set(allow) - allow_used):
    errors.append(f"{allow_rel}: {key} no longer writes a word after a count (or is gone); remove the entry")
# A plural key's count must reach the lookup.
if plural_keys and next_sources.exists():
    lookup = re.compile(r'"(' + "|".join(re.escape(key) for key in sorted(plural_keys)) + r')"')
    first_literal = re.compile(r'\s*,\s*(?:defaultValue:\s*)?"((?:\\.|[^"\\])*)"')
    # git grep (tracked files, as a push sees them) narrows 6,000 Swift files to the few that name a
    # plural key; a tree that is not a checkout (the script's fixture tests) reads them all.
    needles = [arg for key in sorted(plural_keys) for arg in ("-e", f'"{key}"')]
    found = subprocess.run(["git", "-C", str(root), "grep", "-l", "-F", *needles, "--",
                            "Packages/macOS/CmuxNext/Sources/*.swift"], capture_output=True, text=True)
    swift_files = ([root / line for line in found.stdout.splitlines()] if found.returncode in (0, 1)
                   else sorted(next_sources.rglob("*.swift")))
    for swift in swift_files:
        text = swift.read_text(encoding="utf-8", errors="replace")
        for match in lookup.finditer(text):
            if re.search(r"forKey:\s*$", text[max(0, match.start() - 40):match.start()]):
                continue
            literal = first_literal.match(text, match.end())
            if literal and "\\(" in literal[1]:
                continue
            line = text.count("\n", 0, match.start()) + 1
            errors.append(f"{swift.relative_to(root)}:{line}: plural key {match[1]} is looked up without its count; "
                          "interpolate the count into the String(localized:) literal or use "
                          "Bundle.localizedString(forKey:value:table:arguments:...)")

warn_max = int(os.environ.get("L10N_STYLE_WARN_MAX") or 0)
if style and len(style) <= warn_max:
    for line in style:
        print(f"::warning title=ratchet debt::{line}")
    print(f"{len(style)} style errors are ratchet debt (ceiling {warn_max})")
else:
    if style and warn_max:
        print(f"{len(style)} style errors are over the hard ceiling of {warn_max}")
    errors += style
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
