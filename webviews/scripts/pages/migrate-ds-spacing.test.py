#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("migrate-ds-spacing.py")
spec = importlib.util.spec_from_file_location("migrate_ds_spacing", SCRIPT)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RewriteValueTests(unittest.TestCase):
    def rewrite(self, value: str) -> tuple[str, int]:
        return module.rewrite_value(value, module.mask(value))

    def test_schema_values_and_fractional_spellings_map(self):
        value, count = self.rewrite("4.0px 40px -8px")
        self.assertEqual(value, "var(--ds-space-fixed-1) var(--ds-space-fixed-40) calc(-1 * var(--ds-space-fixed-2))")
        self.assertEqual(count, 3)

    def test_off_scale_literal_skips_the_whole_declaration(self):
        value, count = self.rewrite("calc(4px + 2.5px)")
        self.assertEqual(value, "calc(4px + 2.5px)")
        self.assertEqual(count, 0)

    def test_off_scale_var_fallback_skips_the_whole_declaration(self):
        value, count = self.rewrite("var(--inset, 2.5px) 4px")
        self.assertEqual(value, "var(--inset, 2.5px) 4px")
        self.assertEqual(count, 0)


if __name__ == "__main__":
    unittest.main()
