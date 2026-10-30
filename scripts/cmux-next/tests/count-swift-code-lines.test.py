import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
COUNTER = ROOT / "scripts/cmux-next/count-swift-code-lines.py"


class CountSwiftCodeLinesTests(unittest.TestCase):
    def run_counter(self, root: Path, *extra: str) -> int:
        result = subprocess.run(
            ["python3", str(COUNTER), *extra, str(root)],
            check=True,
            capture_output=True,
            text=True,
        )
        return int(result.stdout)

    def test_ignores_comments_and_blank_lines_but_counts_string_contents(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Example.swift"
            source.parent.mkdir(parents=True)
            source.write_text(
                '// comment with "quotes"\n'
                'let url = "https://example.test/*not a comment*/" // trailing comment\n'
                '/* block comment\n'
                '   still a comment */\n'
                '\n'
                'let value = 1\n'
            )
            self.assertEqual(self.run_counter(root), 2)

    def test_git_ref_counts_the_base_tree(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Example.swift"
            source.parent.mkdir(parents=True)
            source.write_text("let value = 1\n")
            subprocess.run(["git", "-C", str(root), "init", "-q"], check=True)
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(root),
                    "-c",
                    "user.email=test@example.invalid",
                    "-c",
                    "user.name=Test",
                    "commit",
                    "-qm",
                    "base",
                ],
                check=True,
            )
            source.write_text("let value = 1\n// merge noise\n")
            self.assertEqual(self.run_counter(root, "--git-ref", "HEAD"), 1)
            self.assertEqual(self.run_counter(root), 1)


    def test_grown_lists_the_files_whose_source_grew_largest_first(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "Packages/macOS/CmuxNext/Sources/CmuxNextApp"
            app.mkdir(parents=True)
            (app / "Same.swift").write_text("let a = 1\n")
            (app / "Grows.swift").write_text("let b = 1\n")
            (app / "Shrinks.swift").write_text("let c = 1\nlet d = 2\n")
            (app / "Deleted.swift").write_text("let i = 1\n")
            git = ["git", "-C", str(root), "-c", "user.email=t@example.invalid", "-c", "user.name=T"]
            subprocess.run(["git", "-C", str(root), "init", "-q"], check=True)
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            subprocess.run([*git, "commit", "-qm", "base"], check=True)
            (app / "Same.swift").write_text("let a = 1\n// comment only\n")
            (app / "Grows.swift").write_text("let b = 1\nlet e = 2\n")
            (app / "Shrinks.swift").write_text("let c = 1\n")
            (app / "New.swift").write_text("let f = 1\nlet g = 2\nlet h = 3\n")
            (app / "Deleted.swift").unlink()
            result = subprocess.run(
                ["python3", str(COUNTER), "--grown", "HEAD", str(root)],
                check=True, capture_output=True, text=True,
            )
            self.assertEqual(result.stdout.splitlines(), [
                "+3 New.swift (0 -> 3)",
                "+1 Grows.swift (1 -> 2)",
                "-1 Deleted.swift (1 -> 0)",
                "-1 Shrinks.swift (2 -> 1)",
            ])


if __name__ == "__main__":
    unittest.main()
