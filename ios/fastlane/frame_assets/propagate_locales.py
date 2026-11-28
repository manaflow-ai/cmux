#!/usr/bin/env python3
"""Fan localized captures out to every App Store locale.

`fastlane snapshot` captures the app's nine localized UI languages. The App
Store listing has more locale slots than the binary has translations, so each
listing locale is mapped to the closest captured language and falls back to
English only where the app has no translation. `compose_shots.py` then applies
the listing-locale-specific marketing title.

Usage: propagate_locales.py <screenshots_dir>
"""
import os
import shutil
import sys
import tempfile

# App Store listing locale slots. Keep this in sync with the screenshot listing
# and titles.json, not with the smaller set of binary localizations.
LOCALES = [
    "ar-SA", "ca", "cs", "da", "de-DE", "el", "en-AU", "en-CA", "en-GB", "en-US",
    "es-ES", "es-MX", "fi", "fr-CA", "fr-FR", "he", "hi", "hr", "hu", "id", "it",
    "ja", "ko", "ms", "nl-NL", "no", "pl", "pt-BR", "pt-PT", "ro", "ru", "sk",
    "sv", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant",
]

# Each value is the fastlane output directory containing the app-localized raw
# capture to use for that listing locale. Regional variants share their base
# language. Listing locales without a binary translation intentionally use the
# English capture; their marketing headline remains localized by titles.json.
SOURCE_LOCALE = {
    "ar-SA": "ar-SA",
    "ca": "en-US",
    "cs": "en-US",
    "da": "en-US",
    "de-DE": "de-DE",
    "el": "en-US",
    "en-AU": "en-US",
    "en-CA": "en-US",
    "en-GB": "en-US",
    "en-US": "en-US",
    "es-ES": "es-ES",
    "es-MX": "es-ES",
    "fi": "en-US",
    "fr-CA": "fr-FR",
    "fr-FR": "fr-FR",
    "he": "en-US",
    "hi": "en-US",
    "hr": "en-US",
    "hu": "en-US",
    "id": "en-US",
    "it": "en-US",
    "ja": "ja",
    "ko": "ko",
    "ms": "en-US",
    "nl-NL": "en-US",
    "no": "en-US",
    "pl": "en-US",
    "pt-BR": "en-US",
    "pt-PT": "en-US",
    "ro": "en-US",
    "ru": "en-US",
    "sk": "en-US",
    "sv": "en-US",
    "th": "en-US",
    "tr": "en-US",
    "uk": "en-US",
    "vi": "en-US",
    "zh-Hans": "zh-Hans",
    "zh-Hant": "zh-Hant",
}

# Fastlane Snapshot names its output directory with the Apple language code
# supplied as the first element of `languages: [[language, locale]]` (for
# example `en`), while older/local runs may already use the App Store slot
# name (`en-US`). Accept both forms, preferring the language-code directory so
# a fresh capture wins over a stale propagated destination from an earlier run.
CAPTURE_DIRS = {
    "en-US": ("en", "en-US"),
    "de-DE": ("de", "de-DE"),
    "fr-FR": ("fr", "fr-FR"),
    "ar-SA": ("ar", "ar-SA"),
    "es-ES": ("es", "es-ES"),
    "zh-Hans": ("zh-Hans",),
    "zh-Hant": ("zh-Hant",),
    "ko": ("ko",),
    "ja": ("ja",),
}


def raws(d):
    return sorted(f for f in os.listdir(d)
                  if f.endswith(".png") and not f.endswith("_framed.png")) if os.path.isdir(d) else []


def clear_pngs(d):
    if not os.path.isdir(d):
        return
    for f in os.listdir(d):
        if f.endswith(".png"):
            os.remove(os.path.join(d, f))


def main():
    ss = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else "screenshots"
    missing_mapping = sorted(set(LOCALES) - set(SOURCE_LOCALE))
    if missing_mapping:
        raise SystemExit(f"missing source mapping for App Store locales: {missing_mapping}")
    # Snapshot can be intentionally partial for verification runs. Capture the
    # available source sets before clearing destination dirs, then fall back to
    # the canonical fresh set for any omitted language instead of mixing stale
    # and fresh files. Full release runs always include en-US, while a focused
    # locale run may provide only (for example) de-DE.
    source_dirs = sorted(set(SOURCE_LOCALE.values()))
    with tempfile.TemporaryDirectory(prefix="cmux-locale-raws-") as staged:
        available = {}
        for source in source_dirs:
            capture_dir = next(
                (candidate for candidate in CAPTURE_DIRS[source]
                 if raws(os.path.join(ss, candidate))),
                None,
            )
            if capture_dir is None:
                continue
            src = os.path.join(ss, capture_dir)
            files = raws(src)
            dst = os.path.join(staged, source)
            os.makedirs(dst)
            for f in files:
                shutil.copy2(os.path.join(src, f), os.path.join(dst, f))
            available[source] = files

        if not available:
            raise SystemExit(f"no localized raws in {ss}; run capture first")
        canonical = "en-US" if "en-US" in available else sorted(available)[0]
        if canonical != "en-US":
            print(f"no en-US raws; using {canonical} as the canonical focused capture")
        expected = set(available[canonical])
        incomplete = {
            source: sorted(set(files) ^ expected)
            for source, files in available.items()
            if set(files) != expected
        }
        if incomplete:
            raise SystemExit(f"localized capture sets differ from {canonical}: {incomplete}")

        counts = {}
        for loc in LOCALES:
            preferred = SOURCE_LOCALE[loc]
            source = preferred if preferred in available else canonical
            dst = os.path.join(ss, loc)
            os.makedirs(dst, exist_ok=True)
            clear_pngs(dst)
            for f in available[source]:
                shutil.copy2(os.path.join(staged, source, f), os.path.join(dst, f))
            counts[source] = counts.get(source, 0) + 1

    used = ", ".join(f"{source} -> {count} locales" for source, count in sorted(counts.items()))
    print(f"propagated localized raws across {len(LOCALES)} App Store locales ({used})")


if __name__ == "__main__":
    main()
