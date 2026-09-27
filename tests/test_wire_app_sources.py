#!/usr/bin/env python3
"""scripts/wire-app-sources.py wires app sources through the real group tree."""

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/wire-app-sources.py"
spec = importlib.util.spec_from_file_location("wire_app_sources", SCRIPT)
wire_app_sources = importlib.util.module_from_spec(spec)
sys.modules["wire_app_sources"] = wire_app_sources  # dataclasses look it up
spec.loader.exec_module(wire_app_sources)

# A Sources group holding `Sidebar/Wired.swift` directly and a nested Cloud
# group with its own `path`, whose file (`AAA.swift`) sorts before every
# other ref, plus a repo-relative (SOURCE_ROOT) ref, and a cmuxTests target.
PROJECT = """// !$*UTF8*$!
{
	objects = {

/* Begin PBXBuildFile section */
		B0000000000000000000000A /* AAA.swift in Sources */ = {isa = PBXBuildFile; fileRef = F0000000000000000000000A /* AAA.swift */; };
		B0000000000000000000000B /* Wired.swift in Sources */ = {isa = PBXBuildFile; fileRef = F0000000000000000000000B /* Wired.swift */; };
		B0000000000000000000000C /* Rooted.swift in Sources */ = {isa = PBXBuildFile; fileRef = F0000000000000000000000C /* Rooted.swift */; };
		B0000000000000000000000T /* Wired.swift in Sources */ = {isa = PBXBuildFile; fileRef = F0000000000000000000000B /* Wired.swift */; };
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		F0000000000000000000000A /* AAA.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AAA.swift; sourceTree = "<group>"; };
		F0000000000000000000000B /* Wired.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Sidebar/Wired.swift; sourceTree = "<group>"; };
		F0000000000000000000000C /* Rooted.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "Sources/Rooted.swift"; sourceTree = SOURCE_ROOT; };
/* End PBXFileReference section */

/* Begin PBXGroup section */
		G0000000000000000000000C /* Cloud */ = {
			isa = PBXGroup;
			children = (
				F0000000000000000000000A /* AAA.swift */,
			);
			path = Cloud;
			sourceTree = "<group>";
		};
		G0000000000000000000000S /* Sources */ = {
			isa = PBXGroup;
			children = (
				G0000000000000000000000C /* Cloud */,
				F0000000000000000000000B /* Wired.swift */,
				F0000000000000000000000C /* Rooted.swift */,
			);
			path = Sources;
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		N0000000000000000000000A /* cmux */ = {
			isa = PBXNativeTarget;
			buildPhases = (
				S0000000000000000000000A /* Sources */,
			);
			name = cmux;
		};
		N0000000000000000000000T /* cmuxTests */ = {
			isa = PBXNativeTarget;
			buildPhases = (
				S0000000000000000000000T /* Sources */,
			);
			name = cmuxTests;
		};
/* End PBXNativeTarget section */

/* Begin PBXSourcesBuildPhase section */
		S0000000000000000000000A /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			files = (
				B0000000000000000000000A /* AAA.swift in Sources */,
				B0000000000000000000000B /* Wired.swift in Sources */,
				B0000000000000000000000C /* Rooted.swift in Sources */,
			);
		};
		S0000000000000000000000T /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			files = (
				B0000000000000000000000T /* Wired.swift in Sources */,
			);
		};
/* End PBXSourcesBuildPhase section */
	};
}
"""


def group_of(text, rel):
    project = wire_app_sources.parse(text)
    ref = next(ref for ref, path in project.ref_paths.items() if path == rel)
    return next(group.directory for group in project.groups.values() if ref in group.children)


class WireAppSourcesTests(unittest.TestCase):
    def test_resolves_paths_through_nested_groups_and_source_root(self):
        project = wire_app_sources.parse(PROJECT)
        self.assertEqual(
            project.wired_paths,
            {"Sources/Cloud/AAA.swift", "Sources/Sidebar/Wired.swift", "Sources/Rooted.swift"},
        )

    def test_a_top_level_file_goes_in_the_sources_group_not_a_nested_one(self):
        text = wire_app_sources.wire(PROJECT, "Sources/Top.swift")
        self.assertEqual(group_of(text, "Sources/Top.swift"), "Sources")
        self.assertIn("Sources/Top.swift", wire_app_sources.parse(text).wired_paths)

    def test_a_nested_group_file_gets_a_group_relative_path(self):
        text = wire_app_sources.wire(PROJECT, "Sources/Cloud/New+Thing.swift")
        self.assertEqual(group_of(text, "Sources/Cloud/New+Thing.swift"), "Sources/Cloud")
        # Group-relative, and quoted because of the `+`.
        self.assertIn('path = "New+Thing.swift";', text)

    def test_a_subdirectory_without_its_own_group_uses_a_prefixed_path(self):
        text = wire_app_sources.wire(PROJECT, "Sources/Sidebar/Glyph.swift")
        self.assertEqual(group_of(text, "Sources/Sidebar/Glyph.swift"), "Sources")
        self.assertIn("path = Sidebar/Glyph.swift;", text)

    def test_wires_the_app_target_only(self):
        text = wire_app_sources.wire(PROJECT, "Sources/Top.swift")
        tests_phase = text[text.index("S0000000000000000000000T /* Sources */ = {"):]
        self.assertNotIn("Top.swift", tests_phase)
        self.assertEqual(text.count("/* Top.swift in Sources */"), 2)  # build file + app phase

    def test_matching_is_by_path_not_basename(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            for rel in ["Sources/Sidebar/Wired.swift", "Sources/Other/Wired.swift", "Sources/Cloud/AAA.swift", "Sources/Rooted.swift"]:
                (root / rel).parent.mkdir(parents=True, exist_ok=True)
                (root / rel).write_text("")
            self.assertEqual(wire_app_sources.unwired_sources(root, PROJECT), ["Sources/Other/Wired.swift"])

    def test_a_lost_phase_line_reuses_the_surviving_reference_and_build_file(self):
        # Only the app-phase line is gone; the ref and the build file remain.
        stripped = PROJECT.replace("\t\t\t\tB0000000000000000000000C /* Rooted.swift in Sources */,\n", "")
        self.assertNotIn("Sources/Rooted.swift", wire_app_sources.parse(stripped).wired_paths)
        text = wire_app_sources.wire(stripped, "Sources/Rooted.swift")
        self.assertEqual(text.count("isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \"Sources/Rooted.swift\""), 1)
        self.assertEqual(text.count("= {isa = PBXBuildFile; fileRef = F0000000000000000000000C"), 1)
        self.assertIn("\t\t\t\tB0000000000000000000000C /* Rooted.swift in Sources */,\n", text)
        self.assertIn("Sources/Rooted.swift", wire_app_sources.parse(text).wired_paths)

    def test_a_derived_id_already_in_use_is_resalted(self):
        taken = wire_app_sources.object_id("fileref:Sources/Top.swift")
        busy = PROJECT.replace("F0000000000000000000000A", taken)
        text = wire_app_sources.wire(busy, "Sources/Top.swift")
        self.assertEqual(text.count(taken + " /* "), busy.count(taken + " /* "))

    def test_wiring_is_idempotent_and_ids_are_stable(self):
        once = wire_app_sources.wire(PROJECT, "Sources/Top.swift")
        self.assertEqual(wire_app_sources.wire(once, "Sources/Top.swift"), once)
        self.assertEqual(wire_app_sources.wire(PROJECT, "Sources/Top.swift"), once)


if __name__ == "__main__":
    unittest.main()
