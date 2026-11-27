#!/usr/bin/env python3
"""cx-f58x: the notary test receipt never fails a run over a file's name.

Run 42176643049 (notary_test_import_part=full) got Apple's "Accepted" and then
failed at "Write notary test receipt" with "non-text receipt file": the step's
own `codesign -d --entitlements :-` output is entitlements.plist, and the guard
allowed only *.txt and *.log names. The guard exists because the repository is
public: no app, DMG or other binary of a diagnostic build may be uploaded. So
it must look at what a file holds, not at its name: text of any name is kept,
and a binary file is removed (with a warning) before the upload, never uploaded.

This runs scripts/ci/nightly-steps/notary-test-receipt.sh itself with stub
codesign, xcrun, spctl, syspolicy_check, security and plutil on PATH.
"""
from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/nightly-steps/notary-test-receipt.sh"

ENTITLEMENTS = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.cs.allow-jit</key><true/></dict></plist>
"""

STUBS = {
    # The real step's codesign -d --entitlements :- prints the plist the receipt keeps.
    "codesign": f"""#!/bin/sh
case "$*" in *--entitlements*) cat <<'EOF'
{ENTITLEMENTS}EOF
;; *) echo "Authority=Developer ID Application: stub" ;; esac
""",
    "xcrun": "#!/bin/sh\necho 'The validate action worked!'\n",
    "spctl": "#!/bin/sh\necho 'accepted'\necho 'source=Notarized Developer ID'\n",
    "syspolicy_check": "#!/bin/sh\necho 'App passed all pre-distribution checks.'\n",
    "security": "#!/bin/sh\nexit 1\n",
    "plutil": "#!/bin/sh\nexit 1\n",
}


def run_receipt(notarization_log: bytes | None) -> tuple[subprocess.CompletedProcess[str], Path]:
    work = Path(tempfile.mkdtemp(prefix="notary-receipt-test-"))
    bin_dir = work / "bin"
    bin_dir.mkdir()
    for name, body in STUBS.items():
        path = bin_dir / name
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)
    app = work / "cmux NIGHTLY.app"
    (app / "Contents").mkdir(parents=True)
    (app / "Contents/Info.plist").write_text("<plist><dict/></plist>\n", encoding="utf-8")
    dmg = work / "cmux-nightly-next-macos-arm64.dmg"
    dmg.write_bytes(b"\x00stub dmg\x00")
    if notarization_log is not None:
        Path(f"{dmg}.notarization.log").write_bytes(notarization_log)
    env = {
        "PATH": f"{bin_dir}:/usr/bin:/bin",
        "GITHUB_RUN_ID": "42176643049",
        "GITHUB_STEP_SUMMARY": str(work / "summary.md"),
        "BUILD_SHA": "6444fc3f9a4462fad8d792a47ddab8d7ead4f34a",
        "CHANNEL_BUNDLE_ID": "com.cmuxterm.app.nightly",
        "NOTARY_PROBE": "false",
        "IMPORT_VARIANT": "full",
        "SWIFT_IMPORT_FLAGS": "",
        "EMPTY_BROWSER_SOURCES": "false",
        "NOTARIZE_OUTCOME": "success",
        "NIGHTLY_DMG_RELEASE": str(dmg),
        "CHANNEL_APP_PATH": str(app),
    }
    proc = subprocess.run(["bash", str(SCRIPT)], cwd=work, env=env, capture_output=True, text=True)
    return proc, work / "notary-receipt"


class NotaryTestReceipt(unittest.TestCase):
    def test_the_entitlements_plist_the_step_writes_does_not_fail_the_job(self):
        proc, out = run_receipt(b"notarytool log: Accepted\n")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertNotIn("non-text receipt file", proc.stderr)
        self.assertEqual((out / "entitlements.plist").read_text(encoding="utf-8"), ENTITLEMENTS)
        self.assertIn("import variant: full", (out / "receipt.txt").read_text(encoding="utf-8"))
        self.assertTrue((out / "notarization.log").is_file())

    def test_a_binary_file_is_removed_before_the_upload_and_the_job_goes_on(self):
        proc, out = run_receipt(b"\x00\x01\x02not text\x00")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertFalse((out / "notarization.log").exists(), "a binary file must never be uploaded")
        self.assertIn("notarization.log", proc.stdout + proc.stderr)
        for path in out.iterdir():
            self.assertNotIn(b"\x00", path.read_bytes(), path.name)


if __name__ == "__main__":
    unittest.main()
