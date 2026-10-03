#!/usr/bin/env python3
"""Regression cases for scripts/lint-text-input-substitutions.py.

The linter is the guard that every cmux text view goes through the shared
`cmuxDisableTypingSubstitutions()` setup
(https://github.com/manaflow-ai/cmux/issues/16738). Each case builds a small
fixture tree and checks that the linter accepts or rejects it.
"""

import importlib.util
from pathlib import Path
import tempfile
import textwrap
import unittest

REPO_ROOT = Path(__file__).resolve().parents[1]
LINTER = REPO_ROOT / "scripts" / "lint-text-input-substitutions.py"

LAUNCH = """
enum CmuxMain {
    static func main() {
        CmuxPlainTextInput.installAppDefaults(.standard)
        cmuxApp.main()
    }
}
"""


def load_linter():
    spec = importlib.util.spec_from_file_location("lint_text_input_substitutions", LINTER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TextInputSubstitutionsLintTests(unittest.TestCase):
    def setUp(self):
        self.linter = load_linter()

    def lint(self, files, launch=LAUNCH):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            sources = dict(files)
            if launch is not None:
                sources["Sources/CmuxMain.swift"] = launch
            for rel, text in sources.items():
                path = repo / rel
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(textwrap.dedent(text))
            return self.linter.lint(repo)

    def assertFlags(self, files, expected_fragment, **kwargs):
        errors = self.lint(files, **kwargs)
        self.assertTrue(
            any(expected_fragment in error for error in errors),
            f"expected an error containing {expected_fragment!r}, got {errors!r}",
        )

    def test_repository_passes(self):
        self.assertEqual(self.linter.lint(REPO_ROOT), [])

    def test_editor_without_shared_setup_fails(self):
        self.assertFlags({"Sources/Editor.swift": """
            func make() -> NSTextView {
                let textView = NSTextView()
                textView.isRichText = false
                return textView
            }
        """}, "Sources/Editor.swift:3: NSTextView `textView`")

    def test_editor_with_shared_setup_passes(self):
        self.assertEqual(self.lint({"Sources/Editor.swift": """
            func make() -> NSTextView {
                let textView = NSTextView()
                textView.cmuxDisableTypingSubstitutions()
                return textView
            }
        """}), [])

    def test_setup_on_another_view_does_not_count(self):
        self.assertFlags({"Sources/Editor.swift": """
            func make() {
                let first = NSTextView()
                let second = NSTextView()
                second.cmuxDisableTypingSubstitutions()
            }
        """}, "`first`")

    def test_setup_before_creation_does_not_count(self):
        self.assertFlags({"Sources/Editor.swift": """
            func make() {
                var textView = NSTextView()
                textView.cmuxDisableTypingSubstitutions()
                textView = NSTextView(frame: .zero)
            }
        """}, "Sources/Editor.swift:5:")

    def test_read_only_display_passes(self):
        self.assertEqual(self.lint({"Packages/macOS/Kit/Sources/Kit/Display.swift": """
            final class Display {
                let textView = NSTextView(frame: .zero)
                init() { textView.isEditable = false }
            }
        """}), [])

    def test_subclass_instances_need_setup(self):
        self.assertFlags({
            "Sources/Base.swift": "final class CodeTextView: NSTextView {}\n",
            "Sources/Use.swift": "let editor = CodeTextView(frame: .zero)\n",
        }, "Sources/Use.swift:1: CodeTextView `editor`")

    def test_subclass_of_subclass_is_found(self):
        self.assertFlags({
            "Sources/Base.swift": "class BaseTextView: NSTextView {}\nfinal class LeafTextView: BaseTextView {}\n",
            "Sources/Use.swift": "let editor = LeafTextView()\n",
        }, "LeafTextView `editor`")

    def test_subclass_that_configures_itself_covers_instances(self):
        self.assertEqual(self.lint({
            "Sources/Base.swift": """
                final class CodeTextView: NSTextView {
                    init() {
                        super.init(frame: .zero, textContainer: nil)
                        cmuxDisableTypingSubstitutions()
                    }
                }
            """,
            "Sources/Use.swift": "let editor = CodeTextView()\n",
        }), [])

    def test_unnamed_creation_fails(self):
        self.assertFlags({"Sources/Editor.swift": """
            func make() -> NSView {
                return NSTextView()
            }
        """}, "created without a name")

    def test_scrollable_factory_needs_setup(self):
        self.assertFlags({"Sources/Editor.swift": """
            func make() -> NSScrollView {
                let scrollView = NSTextView.scrollableTextView()
                return scrollView
            }
        """}, "the scroll view's text view")

    def test_exemption_needs_a_reason(self):
        exempt = """
            func cleanup() {
                // text-input-substitutions: exempt (never shown)
                let textView = NSTextView()
                textView.string = ""
            }
        """
        self.assertEqual(self.lint({"Sources/Editor.swift": exempt}), [])
        self.assertFlags(
            {"Sources/Editor.swift": exempt.replace("(never shown)", "()")},
            "Sources/Editor.swift:4:",
        )

    def test_comments_strings_and_tests_are_ignored(self):
        self.assertEqual(self.lint({
            "Sources/Notes.swift": """
                // A default `NSTextView()` is TextKit 2.
                let message = "NSTextView() here"
            """,
            "Packages/macOS/Kit/Tests/KitTests/EditorTests.swift": "let textView = NSTextView()\n",
        }), [])

    def test_missing_launch_defaults_fails(self):
        self.assertFlags(
            {},
            "must call `CmuxPlainTextInput.installAppDefaults(",
            launch="enum CmuxMain { static func main() { cmuxApp.main() } }\n",
        )


if __name__ == "__main__":
    unittest.main()
