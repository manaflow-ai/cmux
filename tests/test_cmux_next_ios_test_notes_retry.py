#!/usr/bin/env python3
"""cmux-next-ios/scripts/set-test-notes.sh: What to Test retries Apple 5xx, and never fails an uploaded build.

Run 39421191207 uploaded a VALID build, then went red because App Store Connect
answered the notes call with status 500 once. The helper retries a 5xx up to 3
times with backoff; a notes failure is a warning, since the build is already
uploaded and processed. A fake `asc` on PATH plays App Store Connect.
"""
from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "cmux-next-ios/scripts/set-test-notes.sh"

FAKE_ASC = """#!/bin/bash
# Answers from $FAKE_ANSWERS (one per call: ok, 500, 401); counts calls in $FAKE_CALLS.
n=$(( $(cat "$FAKE_CALLS" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FAKE_CALLS"
answer=$(sed -n "${n}p" "$FAKE_ANSWERS")
case "$answer" in
  ok) echo '{"data":{"type":"betaBuildLocalizations"}}'; exit 0 ;;
  500) echo 'Error: builds test-notes update: App Store Connect internal server error (status 500): An unexpected error occurred.' >&2; exit 1 ;;
  *) echo "Error: builds test-notes update: (status $answer): forbidden" >&2; exit 1 ;;
esac
"""


class SetTestNotes(unittest.TestCase):
    def run_with(self, *answers: str) -> tuple[subprocess.CompletedProcess[str], int]:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "bin").mkdir()
            asc = root / "bin/asc"
            asc.write_text(FAKE_ASC)
            asc.chmod(0o755)
            (root / "answers").write_text("\n".join(answers) + "\n")
            env = os.environ | {"PATH": f"{root / 'bin'}:{os.environ['PATH']}", "FAKE_ANSWERS": str(root / "answers"),
                                "FAKE_CALLS": str(root / "calls"), "CMUX_MOBILE_NOTES_BACKOFF_SECONDS": "0 0"}
            result = subprocess.run(["bash", str(HELPER), str(root / "notes.json"), "--", "asc", "builds", "test-notes",
                                     "update", "--build-number", "1"], env=env, capture_output=True, text=True)
            calls = int((root / "calls").read_text()) if (root / "calls").exists() else 0
            return result, calls

    def test_first_try_succeeds(self) -> None:
        result, calls = self.run_with("ok")
        self.assertEqual((result.returncode, calls), (0, 1), result.stderr)

    def test_a_5xx_is_retried_until_it_succeeds(self) -> None:
        result, calls = self.run_with("500", "500", "ok")
        self.assertEqual((result.returncode, calls), (0, 3), result.stderr)
        self.assertNotIn("::warning::", result.stdout + result.stderr)

    def test_three_5xx_warn_but_do_not_fail_the_uploaded_build(self) -> None:
        result, calls = self.run_with("500", "500", "500", "ok")
        self.assertEqual((result.returncode, calls), (0, 3), result.stderr)
        self.assertIn("::warning::", result.stdout + result.stderr)

    def test_a_4xx_is_not_retried_and_only_warns(self) -> None:
        result, calls = self.run_with("401", "ok")
        self.assertEqual((result.returncode, calls), (0, 1), result.stderr)
        self.assertIn("::warning::", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
