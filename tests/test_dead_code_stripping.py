#!/usr/bin/env python3
"""cmux's own Mach-O targets link with dead-code stripping.

DEAD_CODE_STRIPPING was unset, so ld kept every unreferenced function of the
app, the CLI and the statically linked libraries in the shipped binaries.
"""

from __future__ import annotations

import re
import unittest

from test_strings_output_encoding import PROJECT, build_settings, configuration_list


class DeadCodeStrippingTest(unittest.TestCase):
    def test_project_strips_dead_code(self):
        configurations = configuration_list('PBXProject "cmux"')
        self.assertEqual(len(configurations), 2)
        for configuration in configurations:
            self.assertRegex(
                build_settings(configuration),
                r"\n\t\t\t\tDEAD_CODE_STRIPPING = YES;\n",
                configuration,
            )

    def test_no_target_turns_it_off(self):
        overrides = re.findall(r"DEAD_CODE_STRIPPING = ([^;]+);", PROJECT)
        self.assertEqual(set(overrides), {"YES"})


if __name__ == "__main__":
    unittest.main()
