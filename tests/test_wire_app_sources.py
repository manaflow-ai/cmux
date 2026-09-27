#!/usr/bin/env python3
"""scripts/wire-app-sources.py adds an unwired app source next to its sibling."""

import importlib.util
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/wire-app-sources.py"
spec = importlib.util.spec_from_file_location("wire_app_sources", SCRIPT)
wire_app_sources = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wire_app_sources)

PROJECT = """// !$*UTF8*$!
{
	objects = {

/* Begin PBXBuildFile section */
		AAAA00000000000000000001 /* Wired.swift in Sources */ = {isa = PBXBuildFile; fileRef = AAAA00000000000000000002 /* Wired.swift */; };
		TTTT00000000000000000001 /* Wired.swift in Sources */ = {isa = PBXBuildFile; fileRef = AAAA00000000000000000002 /* Wired.swift */; };
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		AAAA00000000000000000002 /* Wired.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Sidebar/Wired.swift; sourceTree = "<group>"; };
/* End PBXFileReference section */

/* Begin PBXGroup section */
		GGGG00000000000000000001 /* Sources */ = {
			isa = PBXGroup;
			children = (
				AAAA00000000000000000002 /* Wired.swift */,
			);
			path = Sources;
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		NNNN00000000000000000001 /* cmux */ = {
			isa = PBXNativeTarget;
			buildPhases = (
				SSSS00000000000000000001 /* Sources */,
			);
			name = cmux;
		};
		NNNN00000000000000000002 /* cmuxTests */ = {
			isa = PBXNativeTarget;
			buildPhases = (
				SSSS00000000000000000002 /* Sources */,
			);
			name = cmuxTests;
		};
/* End PBXNativeTarget section */

/* Begin PBXSourcesBuildPhase section */
		SSSS00000000000000000001 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			files = (
				AAAA00000000000000000001 /* Wired.swift in Sources */,
			);
		};
		SSSS00000000000000000002 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			files = (
				TTTT00000000000000000001 /* Wired.swift in Sources */,
			);
		};
/* End PBXSourcesBuildPhase section */
	};
}
"""


class WireAppSourcesTests(unittest.TestCase):
    def test_finds_and_wires_an_unwired_file_into_the_app_target_only(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            (root / "Sources/Sidebar").mkdir(parents=True)
            (root / "Sources/Sidebar/Wired.swift").write_text("")
            (root / "Sources/Sidebar/Glyph+Resolve.swift").write_text("")
            self.assertEqual(
                wire_app_sources.unwired_sources(root, PROJECT),
                ["Sources/Sidebar/Glyph+Resolve.swift"],
            )

            text = wire_app_sources.wire(PROJECT, "Sources/Sidebar/Glyph+Resolve.swift")

            self.assertIn("Glyph+Resolve.swift", wire_app_sources.wired_names(text))
            # `+` needs quoting in an OpenStep plist.
            self.assertIn('path = "Sidebar/Glyph+Resolve.swift";', text)
            self.assertEqual(text.count("/* Glyph+Resolve.swift in Sources */"), 2)  # build file + app phase
            self.assertEqual(text.count("/* Glyph+Resolve.swift */"), 3)  # file ref, build file's fileRef, group child
            tests_phase = text[text.index("SSSS00000000000000000002 /* Sources */ = {"):]
            self.assertNotIn("Glyph+Resolve", tests_phase)
            self.assertEqual(wire_app_sources.unwired_sources(root, text), [])

    def test_ids_are_stable_per_path(self):
        once = wire_app_sources.wire(PROJECT, "Sources/Sidebar/New.swift")
        twice = wire_app_sources.wire(PROJECT, "Sources/Sidebar/New.swift")
        self.assertEqual(once, twice)

    def test_a_directory_with_no_wired_sibling_is_an_error(self):
        with self.assertRaises(SystemExit):
            wire_app_sources.wire(PROJECT, "Sources/Elsewhere/New.swift")


if __name__ == "__main__":
    unittest.main()
