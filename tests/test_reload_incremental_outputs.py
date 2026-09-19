"""Regression contract for retaining prior products and rejecting failed builds."""
from pathlib import Path
import unittest

class ReloadOutputsTest(unittest.TestCase):
    def test_cleanup_only_on_failed_build(self):
        source=(Path(__file__).resolve().parents[1]/'scripts/reload.sh').read_text()
        preparation=source.split('XCODEBUILD_ARGS+=(build)',1)[1].split('XCODEBUILD_LOCK_DIR=',1)[0]
        self.assertNotIn('cleanup_incomplete_xcodebuild_outputs',preparation)
        failure=source.split('reload_finalize() {',1)[1].split('echo "==> reload succeeded',1)[0]
        self.assertIn('"$XCODEBUILD_STARTED" -eq 1 && "$XCODEBUILD_OUTPUT_VALID" -ne 1',failure)
        self.assertIn('cleanup_incomplete_xcodebuild_outputs',failure)
        self.assertIn('refusing to reuse DerivedData app artifacts',source)

if __name__=='__main__':unittest.main()
