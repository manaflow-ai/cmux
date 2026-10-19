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


if __name__ == "__main__":
    unittest.main()
