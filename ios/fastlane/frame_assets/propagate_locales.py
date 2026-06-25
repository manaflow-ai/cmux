#!/usr/bin/env python3
"""Fan the captured raws out to every App Store locale.

`fastlane snapshot` only captures the locales the app UI is actually localized in
(en-US + ja; see Snapfile). The App Store listing, though, takes localized
screenshots in ~39 locales. The app renders identical English UI for every
non-Japanese locale, so the raw capture for those locales is byte-identical to
en-US; only the framed *title* differs (that is localized in titles.json at frame
time). So we copy the en-US raws into every non-ja locale dir and the ja raws
into ja, then compose_shots.py frames each with its localized title.

Usage: propagate_locales.py <screenshots_dir>
"""
import os
import shutil
import sys

# App Store listing locales. ja is the only one with its own (Japanese) capture;
# every other locale reuses the en-US capture (the app UI is en/ja only, and the
# non-ja UI falls back to English).
LOCALES = [
    "ar-SA", "ca", "cs", "da", "de-DE", "el", "en-AU", "en-CA", "en-GB", "en-US",
    "es-ES", "es-MX", "fi", "fr-CA", "fr-FR", "he", "hi", "hr", "hu", "id", "it",
    "ja", "ko", "ms", "nl-NL", "no", "pl", "pt-BR", "pt-PT", "ro", "ru", "sk",
    "sv", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant",
]


def raws(d):
    return [f for f in os.listdir(d)
            if f.endswith(".png") and not f.endswith("_framed.png")] if os.path.isdir(d) else []


def main():
    ss = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else "screenshots"
    en = os.path.join(ss, "en-US")
    ja = os.path.join(ss, "ja")
    if not raws(en):
        raise SystemExit(f"no en-US raws in {en}; run capture first")
    ja_raws = raws(ja)
    n = 0
    for loc in LOCALES:
        if loc in ("en-US", "ja"):
            continue
        dst = os.path.join(ss, loc)
        os.makedirs(dst, exist_ok=True)
        # Clear stale raws/framed so a re-run is deterministic.
        for f in os.listdir(dst):
            if f.endswith(".png"):
                os.remove(os.path.join(dst, f))
        for f in raws(en):
            shutil.copy2(os.path.join(en, f), os.path.join(dst, f))
            n += 1
    print(f"propagated en-US raws to {len(LOCALES) - 2} locales ({n} files); "
          f"ja kept its own {len(ja_raws)} raws")


if __name__ == "__main__":
    main()
