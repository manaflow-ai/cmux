#!/usr/bin/env bash
# Fails when a cmux-next string table misses a supported language, has an
# empty value, or a translation's printf placeholders or line breaks differ
# from English. Tables: every CmuxNext package .xcstrings, the app's
# Resources/InfoPlist.xcstrings and the CLI table Resources/Localizable.xcstrings
# (the only one with plural variations). States `translated` and `needs_review`
# (machine translation awaiting human review) both count as present; the
# review backlog is printed per language.
# --mobile checks the cmux-next iOS tree instead: every .xcstrings under ios/
# (the app shell, its extensions and ios/CmuxiOS) and under the packages listed
# in scripts/cmux-next/mobile-scan-roots.txt, for the nine languages the iOS
# app ships (ios/LOCALIZATION.md).
# Usage: scripts/cmux-next/check-l10n.sh [--mobile] [repo-root]
set -euo pipefail
scope=macos
if [[ "${1:-}" == --mobile ]]; then
  scope=mobile
  shift
fi
root="${1:-$(git rev-parse --show-toplevel)}"
exec python3 - "$root" "$scope" <<'PY'
import collections, json, pathlib, re, sys

# The languages the legacy app shipped (Apple codes; README.no.md is nb).
LANGS = ("en", "ar", "bs", "da", "de", "es", "fr", "it", "ja", "km", "ko", "nb",
         "pl", "pt-BR", "ru", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant")
# The languages the iOS app ships (ios/LOCALIZATION.md); --mobile requires these.
MOBILE_LANGS = ("en", "ar", "de", "es", "fr", "ja", "ko", "zh-Hans", "zh-Hant")
if sys.argv[2] == "mobile":
    LANGS = MOBILE_LANGS
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
SKIP_DIRS = {".build", "DerivedData", "build", "node_modules"}
def catalogs(directory):
    return [path for path in directory.rglob("*.xcstrings")
            if not SKIP_DIRS.intersection(path.relative_to(directory).parts)]
if sys.argv[2] == "mobile":
    scan = [root / "ios"]
    for raw in (root / "scripts/cmux-next/mobile-scan-roots.txt").read_text(encoding="utf-8").splitlines():
        entry = raw.strip()
        if entry and not entry.startswith("#") and not entry.startswith("ios/"):
            scan.append(root / entry)
    tables = sorted({path for directory in scan for path in catalogs(directory)})
else:
    tables = sorted(catalogs(root / "Packages/macOS/CmuxNext/Sources"))
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
        english_forms = forms(locs.get("en", {}))
        # A plural key (only in the CLI table) keeps English's plural
        # categories in every language; each form is checked like a value.
        for lang in LANGS:
            if lang not in locs:
                errors.append(f"{rel}:{key}: missing {lang}")
                continue
            lang_forms = forms(locs[lang])
            if lang_forms is None or (english_forms and set(english_forms) - set(lang_forms)):
                errors.append(f"{rel}:{key}:{lang}: expected a plain stringUnit or English's plural forms")
                continue
            for form, unit in lang_forms.items():
                label = f"{rel}:{key}:{lang}" + (f":{form}" if form else "")
                if unit is None or not str(unit.get("value", "")).strip():
                    errors.append(f"{label}: empty value")
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
                    errors.append(f"{label}: line breaks differ from English")

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
