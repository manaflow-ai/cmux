"""Exercise catalog field translation rules without a macOS CLI bundle."""
import unittest

from test_cli_workflow_catalog import check_localized_field


class CatalogTranslationTests(unittest.TestCase):
    def test_empty_and_executable_only_requirements_are_valid(self):
        for value in ([], ["codex"], ["claude"], ["codex", "claude"]):
            with self.subTest(value=value):
                check_localized_field(value, value, "requires")

    def test_mixed_requirements_translate_text_and_keep_executables(self):
        check_localized_field(["codex", "a repository"], ["codex", "ein Repository"], "requires")

    def test_invalid_translations_still_fail(self):
        for original, localized in (
            (["codex"], ["claude"]), (["claude"], ["Claude"]),
            (["codex"], []), ([], ["codex"]),
            (["a repository"], ["a repository"]),
            (["codex", "a repository"], ["codex", "a repository"]),
            ("title", "title"),
        ):
            with self.subTest(original=original, localized=localized), self.assertRaises(RuntimeError):
                check_localized_field(original, localized, "field")
        check_localized_field("title", "Titel", "title")


if __name__ == "__main__":
    unittest.main()
