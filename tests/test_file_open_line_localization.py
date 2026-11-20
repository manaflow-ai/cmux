"""The file-open error has the same complete language coverage on both surfaces."""
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1] / "Packages/macOS/CmuxNext/Sources"


class FileOpenLineLocalizationTests(unittest.TestCase):
    def test_line_error_covers_all_app_languages_on_both_surfaces(self):
        control = json.loads((ROOT / "CmuxNextControl/Localizable.xcstrings").read_text())
        app = json.loads((ROOT / "CmuxNextApp/Resources/FileOpenLine.xcstrings").read_text())
        locales = {locale for entry in control["strings"].values() for locale in entry.get("localizations", {})}
        self.assertEqual(len(locales), 21)
        for catalog, key in ((app, "file.open.invalidLine"), (control, "control.error.invalidLine")):
            translated = catalog["strings"][key]["localizations"]
            self.assertEqual(set(translated), locales)
            for locale, value in translated.items():
                self.assertEqual(value["stringUnit"]["state"], "translated")
                self.assertTrue(value["stringUnit"]["value"].strip())
                if locale != "en":
                    self.assertNotEqual(value["stringUnit"]["value"], translated["en"]["stringUnit"]["value"])
        self.assertEqual(app["strings"]["file.open.invalidLine"]["localizations"],
                         control["strings"]["control.error.invalidLine"]["localizations"])


if __name__ == "__main__":
    unittest.main()
