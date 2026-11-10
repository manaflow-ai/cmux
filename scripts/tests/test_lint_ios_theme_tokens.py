"""Offline tests for scripts/lint_ios_theme_tokens.py (docs/ios-theme-tokens.md)."""

import contextlib
import io
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import lint_ios_theme_tokens as lint  # noqa: E402

VIEW = "Packages/iOS/CmuxMobileFixtureUI/Sources/CmuxMobileFixtureUI/FixtureView.swift"


class ScanSourceTests(unittest.TestCase):
    def rules(self, source, path=VIEW):
        return [(f.rule, f.line) for f in lint.scan_source(path, source)]

    def test_literal_colors_are_flagged(self):
        source = "\n".join([
            "let a = Color(red: 0.1, green: 0.2, blue: 0.3)",
            "let b = Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 1)",
            "let c = UIColor(white: 0, alpha: 0.38)",
            "let d = UIColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1)",
            'let e = Color(hex: "#FF8800")',
            "let f = #colorLiteral(red: 1, green: 0, blue: 0, alpha: 1)",
        ])
        self.assertEqual(self.rules(source), [("literal-color", n) for n in range(1, 7)])

    def test_hex_helper_with_a_runtime_value_is_a_user_color_not_a_literal(self):
        self.assertEqual(self.rules("let c = Color(hexString: workspace.customColorHex)"), [])

    def test_named_hues_are_flagged_but_semantic_colors_are_not(self):
        source = "\n".join([
            ".foregroundStyle(.red)",
            ".tint(.orange.opacity(0.5))",
            "let dot = Color.green",
            "button.backgroundColor = UIColor.systemBlue",
            ".foregroundStyle(.secondary)",
            ".tint(Color.accentColor)",
            ".background(Color(uiColor: .systemBackground))",
            ".foregroundStyle(.white)",
        ])
        self.assertEqual(self.rules(source), [("hue-color", 1), ("hue-color", 2), ("hue-color", 3), ("hue-color", 4)])

    def test_literal_font_sizes_are_flagged_but_text_styles_are_not(self):
        source = "\n".join([
            ".font(.system(size: 32, weight: .semibold, design: .monospaced))",
            "label.font = UIFont.systemFont(ofSize: 14, weight: .medium)",
            "let m = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)",
            '.font(.custom("Menlo", size: 12))',
            ".font(.system(.title2, design: .monospaced))",
            ".font(.headline)",
            "label.font = UIFont.systemFont(ofSize: metrics.size)",
        ])
        self.assertEqual(self.rules(source), [("literal-font-size", n) for n in range(1, 5)])

    def test_comments_and_strings_are_masked(self):
        source = "\n".join([
            "// Color(red: 1, green: 0, blue: 0) in a comment",
            "/* .font(.system(size: 12)) */",
            'let doc = "use .foregroundStyle(.red) here"',
        ])
        self.assertEqual(self.rules(source), [])

    def test_lint_allow_on_the_line_or_two_above_skips_it(self):
        source = "\n".join([
            "// lint:allow brand mark matches the App Store icon",
            "",
            "let brand = Color(red: 0.1, green: 0.2, blue: 0.3)",
            "let other = Color(red: 0.1, green: 0.2, blue: 0.3)",
        ])
        self.assertEqual(self.rules(source), [("literal-color", 4)])

    def test_everything_after_a_preview_is_skipped(self):
        source = "\n".join([
            "let a = Color.blue",
            "#Preview {",
            "    Text(\"x\").foregroundStyle(.red).font(.system(size: 9))",
            "}",
        ])
        self.assertEqual(self.rules(source), [("hue-color", 1)])

    def test_radius_and_padding_only_where_the_theme_defines_tokens(self):
        source = ".padding(.vertical, 2)\n.clipShape(RoundedRectangle(cornerRadius: 10))"
        self.assertEqual(self.rules(source), [])
        themed = "Packages/iOS/CmuxMobileChanges/Sources/CmuxMobileChanges/UI/DiffRow.swift"
        self.assertEqual(self.rules(source, themed), [("literal-padding", 1), ("literal-radius", 2)])

    def test_each_finding_names_a_token(self):
        for finding in lint.scan_source(VIEW, "let a = Color.blue\n.font(.system(size: 3))"):
            self.assertTrue(finding.token)

    def test_tests_previews_and_token_definitions_are_skipped(self):
        for path in (
            "Packages/iOS/CmuxMobileShellUI/Tests/CmuxMobileShellUITests/RowTests.swift",
            "Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/Debug/LayoutPreviewView.swift",
            "Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/PlatformPalette.swift",
            "Packages/iOS/CmuxMobileChanges/Sources/CmuxMobileChanges/UI/ChangesTheme.swift",
            "Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/TerminalTheme+UIKit.swift",
            "ios/cmuxUITests/SignInTests.swift",
        ):
            self.assertTrue(lint.skipped_path(path), path)
        self.assertFalse(lint.skipped_path(VIEW))
        # "Preview" in a name is not a SwiftUI preview: link previews and the onboarding preview card ship.
        self.assertFalse(lint.skipped_path(
            "Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/OnboardingConnectionPreview.swift"))

    def test_a_debug_only_file_is_skipped(self):
        fixture = "#if canImport(UIKit) && DEBUG\nimport SwiftUI\nlet a = Color.blue\n#endif\n"
        self.assertEqual(self.rules("import SwiftUI\n\n" + fixture), [])
        shipped = "#if canImport(UIKit)\nlet a = Color.blue\n#endif\n"
        self.assertEqual(self.rules(shipped), [("hue-color", 2)])
        self.assertEqual(self.rules("#if !DEBUG\nlet a = Color.blue\n#endif\n"), [("hue-color", 2)])


class RatchetTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.view = self.root / VIEW
        self.view.parent.mkdir(parents=True)

    def tearDown(self):
        self.temporary.cleanup()

    def run_lint(self, *args):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = lint.main(["--root", str(self.root), *args])
        return code, output.getvalue()

    def test_baselined_findings_pass_and_a_new_one_fails_with_file_line_and_token(self):
        self.view.write_text("let a = Color.blue\n")
        self.assertEqual(self.run_lint("--update-baseline", "--accept-new")[0], 0)
        self.assertEqual(self.run_lint()[0], 0)

        self.view.write_text("let a = Color.blue\nlet b = Color.blue\n.font(.system(size: 9))\n")
        code, output = self.run_lint()
        self.assertEqual(code, 1)
        self.assertIn(f"{VIEW}:2", output)
        self.assertIn(f"{VIEW}:3", output)
        self.assertNotIn(f"{VIEW}:1 ", output)
        self.assertIn("use: Color.accentColor", output)
        self.assertIn("use: a text style", output)

    def test_moving_a_baselined_line_is_not_new(self):
        self.view.write_text("let a = Color.blue\n")
        self.run_lint("--update-baseline", "--accept-new")
        self.view.write_text("\n\n\nlet a = Color.blue\n")
        self.assertEqual(self.run_lint()[0], 0)

    def test_fixed_entries_warn_and_update_only_shrinks(self):
        self.view.write_text("let a = Color.blue\nlet b = Color.red\n")
        self.run_lint("--update-baseline", "--accept-new")
        self.view.write_text("let a = Color.blue\n")
        code, output = self.run_lint()
        self.assertEqual(code, 0)
        self.assertIn("baseline entry no longer found", output)

        self.view.write_text("let a = Color.blue\nlet c = Color.green\n")
        code, output = self.run_lint("--update-baseline")
        self.assertEqual(code, 1)
        self.assertIn("refusing to add", output)

        self.view.write_text("let a = Color.blue\n")
        self.assertEqual(self.run_lint("--update-baseline")[0], 0)
        baseline = (self.root / lint.DEFAULT_BASELINE).read_text()
        self.assertEqual([line for line in baseline.splitlines() if not line.startswith("#")],
                         [f"hue-color\t{VIEW}\tlet a = Color.blue"])


class ConventionsWiringTests(unittest.TestCase):
    def test_conventions_lint_fails_on_a_new_literal_color(self):
        with tempfile.TemporaryDirectory() as temporary:
            checkout = Path(temporary)
            (checkout / "scripts").mkdir()
            for name in ("lint-ios-package-conventions.sh", "swift_source_mask.py",
                         "lint_swift_namespaces.py", "lint_ios_theme_tokens.py"):
                shutil.copy2(SCRIPTS / name, checkout / "scripts" / name)
            package = checkout / "Packages/iOS/CmuxMobileFixture/Sources/Fixture"
            package.mkdir(parents=True)
            (package / "FixtureView.swift").write_text(
                "public struct FixtureView {\n    public let tint = Color(red: 1, green: 0, blue: 0)\n}\n")
            result = subprocess.run(["bash", str(checkout / "scripts/lint-ios-package-conventions.sh")],
                                    text=True, capture_output=True, timeout=60)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertRegex(result.stdout, r"ERROR\s+literal-color\s+Packages/iOS/CmuxMobileFixture/.*FixtureView\.swift:2")


if __name__ == "__main__":
    unittest.main()
