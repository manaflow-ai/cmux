#!/usr/bin/env python3
"""Two set-ups of one build on one mini make ONE download (ARTIFACT SPEED, 2026-11-03): no fleet, no ssh.

    python3 scripts/journeys/test_build_cache.py

2026-11-03 05:16Z: cmux20 ran three `cmux-ci artifact` downloads of build 1d8e759eb1ac at once. Each round's set-up
timed out (420 s) and left its download running, and the next round on that mini started one more. Here run.py plays
one lease with a stand-in capture-host and a stand-in ssh; the set-up script it sends to the mini is then run twice
at once, locally (zsh, HOME in a temporary folder), with a stand-in `cmux-ci` that logs each download and takes 2 s.
Both set-ups must print the same .app, and the stand-in must have been called once.
"""
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent

FAKE_CH = r"""#!/bin/sh
case "$1" in
  acquire) echo "slot-cmux99-abc" ;;
  slot-info) echo "host=cmux99 slot=1 root=$FAKE_ROOT" ;;
  launch) echo "pid=1 socket=/tmp/fake.sock bundle_id=x app=/tmp/fake.app" ;;
  release) echo released ;;
esac
"""

FAKE_CMUX_CI = r"""#!/bin/sh
# cmux-ci artifact JOB OUTPUT: one line per download, then a small app zip after 2 s.
echo "$*" >> "$FAKE_LOG"
sleep 2
python3 -c '
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("cmux DEV t.app/Contents/Info.plist", "<plist/>")
' "$3"
"""

FAKE_DITTO = r"""#!/bin/sh
# ditto -x -k ZIP INTO
python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$3" "$4"
"""

# Imports run.py, records the set-up script (and its input) that the lease sends to the mini, plays one lease.
CAPTURE = r"""
import json, os, sys
sys.path.insert(0, sys.argv[1]); sys.path.insert(0, os.path.join(sys.argv[1], "..", "cmux-next"))
import run
run.signed_url = lambda digest, timeout=20: ""  # no controller in this test: the mini's cmux-ci reads it
def remote(host, script, input=None, timeout=600, check=True):
    if "JOB1" in script and ("cmux-ci artifact" in script or "build_cache" in script):
        with open(os.environ["CAPTURED"], "w") as f:
            json.dump({"script": script, "input": (input or b"").decode()}, f)
    if "driver.py" in script:
        raise RuntimeError("stop after the set-up")
    class R: stdout = b"/tmp/x/build/cmux DEV t.app"; stderr = b""; returncode = 0
    return R()
run.remote = remote
run.run_lease([{"id": "action-fuzz", "budget_seconds": 60, "steps": []}],
              {"id": "JOB1", "commit": "a" * 40, "tag": "t", "artifact": "sha256:" + "0" * 64},
              run.Path(os.environ["OUT"]), 1.0)
"""


class OneDownload(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        for name, text in (("capture-host", FAKE_CH), ("cmux-ci", FAKE_CMUX_CI), ("ditto", FAKE_DITTO)):
            (bin_dir / name).write_text(text)
            (bin_dir / name).chmod(0o755)
        self.home = self.tmp / "home"
        (self.tmp / "root" / "journeys").mkdir(parents=True)
        self.log = self.tmp / "downloads.log"
        self.env = {**os.environ, "CAPTURE_HOST": str(bin_dir / "capture-host"), "FAKE_ROOT": str(self.tmp / "root"),
                    "OUT": str(self.tmp / "out"), "CAPTURED": str(self.tmp / "captured.json"),
                    "HOME": str(self.home), "FAKE_LOG": str(self.log), "PATH": f"{bin_dir}:{os.environ['PATH']}"}
        # The text reader is already built on this "mini" (the set-up compiles it only when it is missing).
        sys.path.insert(0, str(HERE))
        import hashlib
        source = HERE.parent / "ci" / "pr_media_ocr.swift"
        ocr = self.home / ".cache" / "cmux-journeys" / f"ocr-{hashlib.sha256(source.read_bytes()).hexdigest()[:16]}"
        ocr.parent.mkdir(parents=True)
        ocr.write_text("#!/bin/sh\n")
        ocr.chmod(0o755)

    def captured(self):
        (self.tmp / "capture.py").write_text(CAPTURE)
        done = subprocess.run([sys.executable, str(self.tmp / "capture.py"), str(HERE)], env=self.env,
                              capture_output=True, text=True, timeout=120)
        path = self.tmp / "captured.json"
        self.assertTrue(path.exists(), f"run.py sent no set-up script: {done.stderr[-2000:]}")
        return json.loads(path.read_text())

    def test_two_parallel_setups_make_one_download(self):
        setup = self.captured()
        starts = []
        for _ in range(2):
            starts.append(subprocess.Popen(["zsh", "-c", setup["script"]], env=self.env, cwd=self.tmp,
                                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                           text=True))
            time.sleep(0.3)  # the second set-up starts while the first downloads
        outs = []
        for p in starts:
            out, err = p.communicate(setup["input"], timeout=120)
            self.assertEqual(p.returncode, 0, err[-2000:])
            outs.append(out.strip().splitlines()[-1] if out.strip() else "")
        downloads = self.log.read_text().splitlines() if self.log.exists() else []
        self.assertEqual(len(downloads), 1, f"downloads of one build on one mini: {downloads}")
        self.assertTrue(outs[0].endswith(".app") and outs[0] == outs[1], outs)
        self.assertTrue((self.home / ".cache" / "cmux-journeys" / "builds" / "JOB1" / "ok").exists())

    def test_a_filled_cache_makes_no_download(self):
        setup = self.captured()
        for _ in range(2):
            done = subprocess.run(["zsh", "-c", setup["script"]], env=self.env, cwd=self.tmp, input=setup["input"],
                                  capture_output=True, text=True, timeout=120)
            self.assertEqual(done.returncode, 0, done.stderr[-2000:])
        self.assertEqual(len(self.log.read_text().splitlines()), 1)


if __name__ == "__main__":
    unittest.main()
