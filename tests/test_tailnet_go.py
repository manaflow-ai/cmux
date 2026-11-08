#!/usr/bin/env python3
"""The shipping script can provision Go without changing the fleet host."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts/ci/tailnet-go.sh"


class TailnetGoTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="tailnet-go-")
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.capture = self.root / "capture.json"
        for name in ["rm", "mkdir", "mv"]:
            (self.bin / name).symlink_to(Path("/bin") / name)
        self.tool("uname", '#!/bin/sh\ncase "$1" in -s) echo Darwin;; -m) echo arm64;; esac\n')
        self.tool("curl", '''#!/usr/bin/python3
import pathlib, sys
pathlib.Path(sys.argv[sys.argv.index("-o") + 1]).touch()
''')
        self.tool("shasum", '''#!/usr/bin/python3
import os, pathlib, sys
pathlib.Path(os.environ["CHECKSUM"]).write_text(sys.stdin.read())
sys.exit(int(os.environ.get("CHECKSUM_RC", "0")))
''')
        self.tool("tar", '''#!/usr/bin/python3
import pathlib, sys
root = pathlib.Path(sys.argv[sys.argv.index("-C") + 1])
go = root / "go/bin/go"
go.parent.mkdir(parents=True)
go.write_text('#!/bin/sh\\necho "go version go1.27.1 darwin/arm64"\\n')
go.chmod(0o755)
''')

    def tearDown(self):
        self.tmp.cleanup()

    def tool(self, name, body):
        path = self.bin / name
        path.write_text(body)
        path.chmod(0o755)

    def run_helper(self, **overrides):
        env = {**os.environ, "PATH": str(self.bin), "CAPTURE": str(self.capture),
               "CHECKSUM": str(self.root / "checksum"), **overrides}
        command = '''source "$1"
ensure_tailnet_go "$2" || exit $?
/usr/bin/python3 - <<'CHECK'
import json, os, pathlib
pathlib.Path(os.environ["CAPTURE"]).write_text(json.dumps(dict(os.environ)))
CHECK
'''
        return subprocess.run(["/bin/bash", "-c", command, "tailnet-go", str(HELPER), str(self.root)],
                              env=env, capture_output=True, text=True)

    def test_missing_go_is_downloaded_and_checked_inside_job(self):
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        go = self.root / ".build/go-1.27.1/go/bin/go"
        self.assertTrue(go.is_file())
        self.assertTrue((self.root / "checksum").read_text().startswith(
            "ee215d57e0ec269c60cc9ceca68e6bda321ba9ee5afe24f4b0988703c2d87d12  "))
        env = json.loads(self.capture.read_text())
        self.assertTrue(env["PATH"].startswith(str(go.parent)))
        self.assertEqual(env["GOPATH"], str(self.root / ".build/go-path"))
        self.assertEqual(env["GOTOOLCHAIN"], "auto")

    def test_bad_checksum_never_extracts_archive(self):
        result = self.run_helper(CHECKSUM_RC="1")
        self.assertEqual(result.returncode, 3)
        self.assertFalse((self.root / ".build/go-1.27.1").exists())
        self.assertFalse(self.capture.exists())

    def test_existing_recent_go_uses_auto_without_downloading(self):
        self.tool("go", '#!/bin/sh\necho "go version go1.26.10 darwin/arm64"\n')
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "checksum").exists())
        env = json.loads(self.capture.read_text())
        self.assertEqual(env["PATH"], str(self.bin))
        self.assertEqual(env["GOTOOLCHAIN"], "auto")

    def test_old_go_without_toolchain_selection_uses_job_install(self):
        self.tool("go", '#!/bin/sh\necho "go version go1.20.1 darwin/arm64"\n')
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / ".build/go-1.27.1/go/bin/go").is_file())


if __name__ == "__main__":
    unittest.main()
