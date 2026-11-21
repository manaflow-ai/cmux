#!/usr/bin/env python3
"""side-instance.sh refuses a root under ~/Documents, ~/Desktop or ~/Downloads.

macOS guards those folders with a privacy prompt. A copy made there read its config from the root at
launch, waited on a Documents-folder prompt (TCC kTCCServiceSystemPolicyDocumentsFolder) nobody saw,
and hung before its socket existed. The refusal comes before anything touches the root.
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/side-instance.sh"


class ProtectedRootTests(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="side-instance-root-"))
        self.addCleanup(shutil.rmtree, self.home, ignore_errors=True)

    def run_list(self, root: Path) -> subprocess.CompletedProcess:
        env = {**os.environ, "HOME": str(self.home), "CMUX_SIDE_ROOT": str(root)}
        return subprocess.run(["bash", str(SCRIPT), "list"], env=env, capture_output=True, text=True)

    def test_a_root_under_a_guarded_folder_is_refused_and_never_made(self):
        for folder in ("Documents", "Desktop", "Downloads"):
            root = self.home / folder / "task/cmux-side"
            run = self.run_list(root)
            self.assertNotEqual(run.returncode, 0, folder)
            self.assertIn(f"under ~/{folder}", run.stderr)
            self.assertIn("kTCCServiceSystemPolicyDocumentsFolder", run.stderr)
            self.assertFalse(root.exists(), f"{root} was created")

    def test_a_root_elsewhere_works(self):
        for root in (self.home / "Library/Caches/cmux-side", self.home / "DocumentsArchive/cmux-side"):
            run = self.run_list(root)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertTrue(root.is_dir())


if __name__ == "__main__":
    unittest.main()
