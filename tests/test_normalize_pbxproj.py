#!/usr/bin/env python3
"""Exercise project normalization and object identity validation through its CLI."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


NORMALIZER = Path(__file__).resolve().parents[1] / "scripts/normalize-pbxproj.py"


def project(objects: str) -> str:
    return "// !$*UTF8*$!\n{\n\tobjectVersion = 60;\n\tobjects = {\n" + objects + "\n\t};\n}\n"


class NormalizeProjectTests(unittest.TestCase):
    def run_normalizer(self, path: Path, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(NORMALIZER), *args, str(path)],
            capture_output=True,
            text=True,
            check=False,
        )

    def assert_rejected(self, contents: str, identifier: str) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "project.pbxproj"
            for args in [(), ("--check",)]:
                with self.subTest(args=args):
                    path.write_text(contents)
                    result = self.run_normalizer(path, *args)
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn(f"duplicate object ID {identifier}", result.stdout + result.stderr)
                    self.assertIn("line", result.stdout + result.stderr)
                    # Normalizing must never change which duplicate definition wins.
                    self.assertEqual(path.read_text(), contents)

    def test_rejects_malformed_project_syntax_before_normalizing(self) -> None:
        cases = {
            "missing semicolon": "FILE1 = {isa = PBXFileReference; path = Example.swift };",
            "missing equals": "FILE1 {isa = PBXFileReference; };",
            "missing array comma": "GROUP1 = {children = (FILE1 FILE2); };",
            "unclosed dictionary": "FILE1 = {isa = PBXFileReference;",
            "unterminated string": 'FILE1 = {path = "Example.swift; };',
            "unterminated comment": "/* FILE1 = {isa = PBXFileReference; };",
            "trailing content": "FILE1 = {isa = PBXFileReference; };\n} ; extra = value;",
        }
        for name, objects in cases.items():
            contents = project(objects)
            for args in [(), ("--check",)]:
                with self.subTest(name=name, args=args), tempfile.TemporaryDirectory() as directory:
                    path = Path(directory) / "project.pbxproj"
                    path.write_text(contents)
                    result = self.run_normalizer(path, *args)
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn("syntax", result.stderr)
                    self.assertIn("line", result.stderr)
                    self.assertEqual(path.read_text(), contents)

    def test_accepts_nested_values_and_escaped_shell_script_punctuation(self) -> None:
        contents = project(r'''
        SCRIPT1 = {
            isa = PBXShellScriptBuildPhase;
            shellScript = "echo \"hello; ({})\"\n# $PATH";
            settings = {FLAGS = ("a,b", "quoted \"string\"", /usr/bin); };
        };
''')
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "project.pbxproj"
            path.write_text(contents)
            result = self.run_normalizer(path, "--check")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_rejects_colliding_build_files_despite_different_comments(self) -> None:
        identifier = "C1B1810000000000000005"
        self.assert_rejected(
            project(f"""
/* Begin PBXBuildFile section */
\t\t{identifier} /* Activation.swift in Sources */ = {{isa = PBXBuildFile; fileRef = A1; }};
\t\t{identifier} /* MappingTests.swift in Sources */ = {{isa = PBXBuildFile; fileRef = B1; }};
/* End PBXBuildFile section */
"""),
            identifier,
        )

    def test_rejects_collisions_across_object_types_without_comments(self) -> None:
        self.assert_rejected(
            project("""
/* Begin PBXFileReference section */
        ABC123 = {isa = PBXFileReference; path = Example.swift; };
/* End PBXFileReference section */
/* Begin PBXGroup section */
        ABC123 = {isa = PBXGroup; children = (); };
/* End PBXGroup section */
"""),
            "ABC123",
        )

    def test_rejects_identical_duplicate_definitions(self) -> None:
        self.assert_rejected(
            project("""
/* Begin PBXBuildFile section */
        ABC123 = {isa = PBXBuildFile; fileRef = FILE123; };
        ABC123 = {isa = PBXBuildFile; fileRef = FILE123; };
/* End PBXBuildFile section */
"""),
            "ABC123",
        )

    def test_accepts_repeated_references_and_nested_dictionary_keys(self) -> None:
        contents = project(r'''
/* Begin PBXBuildFile section */
        BUILD1 /* Example.swift in Sources */ = {isa = PBXBuildFile; fileRef = FILE1; };
/* End PBXBuildFile section */
/* Begin PBXFileReference section */
        FILE1 /* Example.swift */ = {isa = PBXFileReference; path = Example.swift; };
/* End PBXFileReference section */
/* Begin PBXProject section */
        PROJECT1 = {
            isa = PBXProject;
            attributes = {
                TargetAttributes = {
                    BUILD1 = {CreatedOnToolsVersion = 26.5; };
                    FILE1 = {CreatedOnToolsVersion = 26.5; };
                };
            };
        };
/* End PBXProject section */
/* Begin PBXShellScriptBuildPhase section */
        SCRIPT1 = {
            isa = PBXShellScriptBuildPhase;
            shellScript = "echo \"{ BUILD1 = { } }\"; // not a comment";
            /* BUILD1 = {isa = PBXBuildFile; }; */
            // FILE1 = {isa = PBXFileReference; };
        };
/* End PBXShellScriptBuildPhase section */
/* Begin PBXSourcesBuildPhase section */
        PHASE1 = {
            isa = PBXSourcesBuildPhase;
            files = (
                BUILD1 /* Example.swift in Sources */,
            );
        };
        PHASE2 = {
            isa = PBXSourcesBuildPhase;
            files = (
                BUILD1 /* Example.swift in Sources */,
            );
        };
/* End PBXSourcesBuildPhase section */
''')
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "project.pbxproj"
            path.write_text(contents)
            result = self.run_normalizer(path, "--check")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(path.read_text(), contents)

    def test_normalization_remains_idempotent(self) -> None:
        contents = project("""
/* Begin PBXFileReference section */
        FILE2 /* Zebra.swift */ = {isa = PBXFileReference; path = Zebra.swift; };
        FILE1 /* Alpha.swift */ = {isa = PBXFileReference; path = Alpha.swift; };
/* End PBXFileReference section */
""")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "project.pbxproj"
            path.write_text(contents)
            self.assertEqual(self.run_normalizer(path, "--check").returncode, 1)
            result = self.run_normalizer(path)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            normalized = path.read_text()
            self.assertLess(normalized.index("Alpha.swift"), normalized.index("Zebra.swift"))
            self.assertEqual(self.run_normalizer(path, "--check").returncode, 0)
            self.assertEqual(self.run_normalizer(path).returncode, 0)
            self.assertEqual(path.read_text(), normalized)


if __name__ == "__main__":
    unittest.main()
