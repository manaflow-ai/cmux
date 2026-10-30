#!/usr/bin/env python3
"""cmux-next backdrop art generation (cx-t2x.7): the string catalog keeps the backdrop keys that
are not art and gives every art string every locale the catalog carries, and the measured
brightness range covers the image's real extremes, which the legibility floor relies on."""

import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / "scripts/cmux-next/art"


def load(name):
    spec = importlib.util.spec_from_file_location(name, ART / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


GENERATOR = load("generate_backdrop_art")
CATALOG_LOCALES = [
    "ar", "bs", "da", "de", "en", "es", "fr", "it", "ja", "km", "ko", "nb", "pl", "pt-BR", "ru", "th", "tr",
    "uk", "vi", "zh-Hans", "zh-Hant",
]


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def entry(value):
    return {"extractionState": "manual", "localizations": {locale: unit(f"{value} ({locale})") for locale in CATALOG_LOCALES}}


class BackdropArtGeneratorTests(unittest.TestCase):
    def regenerate(self):
        catalog = {"sourceLanguage": "en", "version": "1.0", "strings": {
            "backdrop.desktop.title": entry("Desktop Wallpaper"),
            "backdrop.desktop.attribution": entry("Your current macOS desktop picture"),
            "backdrop.system.attribution": entry("macOS system wallpaper · %@"),
            "backdrop.retired-work.title": entry("A retired work"),
        }}
        works = [{"id": "van-gogh-starry-night", "title": "The Starry Night",
                  "titles": {locale: f"Starry ({locale})" for locale in CATALOG_LOCALES if locale != "en"}}]
        return GENERATOR.update_catalog(works, catalog)["strings"]

    def test_the_desktop_and_system_tiles_keep_their_translations(self):
        strings = self.regenerate()
        for key in ["backdrop.desktop.title", "backdrop.desktop.attribution", "backdrop.system.attribution"]:
            self.assertIn(key, strings)
            self.assertEqual(sorted(strings[key]["localizations"]), sorted(CATALOG_LOCALES), key)
        self.assertNotIn("backdrop.retired-work.title", strings)

    def test_every_art_string_carries_every_catalog_locale(self):
        strings = self.regenerate()
        for key in ["backdrop.van-gogh-starry-night.title", "backdrop.label", "backdrop.publicDomain",
                    "backdrop.collection.darkArt", "backdrop.collection.museumIcons",
                    "backdrop.collection.calm", "backdrop.collection.dore"]:
            self.assertEqual(sorted(strings[key]["localizations"]), sorted(CATALOG_LOCALES), key)

    def test_the_brightness_range_covers_a_small_bright_moon(self):
        try:
            from PIL import Image, ImageDraw
        except ImportError:
            self.skipTest("Pillow renders the art; install it to run this test")
        render = load("render_backdrop_art")
        night = Image.new("RGB", (1600, 1000), (12, 14, 20))
        ImageDraw.Draw(night).ellipse((1200, 120, 1212, 132), fill=(250, 248, 235))
        lightest = render.luminance(render.measure(night, "left")["lightest"])
        self.assertGreater(lightest, 0.9)


if __name__ == "__main__":
    unittest.main()
