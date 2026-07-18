import subprocess
import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
GENERATOR = (
    REPO_ROOT
    / "Packages"
    / "macOS"
    / "CmuxTerminalCore"
    / "Scripts"
    / "generate_terminal_macos_key_map.py"
)


class TerminalMacOSKeyMapGenerationTests(unittest.TestCase):
    def test_generated_swift_matches_checked_in_ghostty_sources(self) -> None:
        result = subprocess.run(
            [sys.executable, str(GENERATOR), "--check"],
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(
            result.returncode,
            0,
            msg=f"{result.stdout}\n{result.stderr}",
        )


if __name__ == "__main__":
    unittest.main()
