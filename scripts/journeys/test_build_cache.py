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
# As the real client does: a progress line on stderr, the digest on stdout (Python: a closed pipe fails its exit).
python3 -c 'import sys; print("cmux-ci: progress", file=sys.stderr); print("digest")'
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


class FillBase(unittest.TestCase):
    """build_cache.py alone, against a local web server that serves a small app zip."""
    def setUp(self):
        t = OneDownload("test_a_filled_cache_makes_no_download")
        t.setUp()
        self.t, self.env = t, dict(t.env, JOURNEYS_CACHE_ROOT=str(t.home / ".cache" / "cmux-journeys"))
        import hashlib, zipfile
        site = t.tmp / "site"
        site.mkdir()
        with zipfile.ZipFile(site / "app.zip", "w") as z:
            z.writestr("cmux DEV s.app/Contents/Info.plist", "<plist/>")
        self.sha = hashlib.sha256((site / "app.zip").read_bytes()).hexdigest()
        self.server = subprocess.Popen([sys.executable, "-u", "-m", "http.server", "0", "--bind", "127.0.0.1"], cwd=site,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        line = self.server.stdout.readline()  # "Serving HTTP on 127.0.0.1 port N ..."
        self.url = f"http://127.0.0.1:{line.split(' port ')[1].split()[0]}/app.zip"

    def tearDown(self):
        self.server.terminate()
        self.server.wait(timeout=10)
        self.server.stdout.close()

    def fill(self, sha, url, job="JOB2"):
        return subprocess.run([sys.executable, "-I", str(HERE / "build_cache.py"), job, sha, "3", "b" * 40],
                              env=self.env, input=url + "\n", capture_output=True, text=True, timeout=120)

    def downloads(self):
        return self.t.log.read_text().splitlines() if self.t.log.exists() else []



class Fill(FillBase):
    """The store URL (curl, sha256 checked), its fallback, and an older copy's download."""

    def test_the_store_url_is_read_and_checked(self):
        done = self.fill(self.sha, self.url)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertTrue(done.stdout.strip().endswith("cmux DEV s.app"), done.stdout)
        self.assertEqual(self.downloads(), [])  # no cmux-ci read
        self.assertEqual((Path(done.stdout.strip()).parent / "capture-commit").read_text(), "b" * 40 + "\n")

    def test_a_wrong_hash_falls_back_to_cmux_ci(self):
        done = self.fill("1" * 64, self.url)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("sha256 does not match", done.stderr)
        self.assertEqual(done.stderr.count("store read"), 1)  # no second read of an object that does not match
        self.assertEqual(len(self.downloads()), 1)

    def test_a_crawling_older_download_does_not_hold_the_fill(self):
        builds = self.t.home / ".cache" / "cmux-journeys" / "builds"
        builds.mkdir(parents=True, exist_ok=True)
        other = subprocess.Popen(["sleep", "60"])  # an older harness copy's shell: alive, its folder does not grow
        try:
            (builds / f"JOB2.tmp.{other.pid}").mkdir()
            done = subprocess.run([sys.executable, "-I", str(HERE / "build_cache.py"), "JOB2", self.sha, "3"],
                                  env=dict(self.env, JOURNEYS_TAKEOVER_PROBE_SECONDS="1"), input=self.url + "\n",
                                  capture_output=True, text=True, timeout=60)
        finally:
            other.kill()
            other.wait()
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("crawls", done.stderr)

    def test_the_newest_three_builds_stay(self):
        for job in ("J1", "J2", "J3", "J4"):
            self.assertEqual(self.fill(self.sha, self.url, job).returncode, 0)
            time.sleep(1.1)
        builds = self.t.home / ".cache" / "cmux-journeys" / "builds"
        self.assertEqual(sorted(p.name for p in builds.iterdir()), ["J2", "J3", "J4"])


class FollowUps(FillBase):
    """The review of #33108 (findings 1, 6 and 7): an older copy at the install, a closed stderr, dead temporaries."""

    def test_a_killed_fills_folder_is_removed_and_a_live_ones_kept(self):
        builds = self.t.home / ".cache" / "cmux-journeys" / "builds"
        builds.mkdir(parents=True, exist_ok=True)
        dead = subprocess.Popen(["true"])
        dead.wait()
        live = subprocess.Popen(["sleep", "60"])
        try:
            (builds / f"JOBX.tmp.{dead.pid}").mkdir()
            (builds / f"JOBY.tmp.{live.pid}").mkdir()
            self.assertEqual(self.fill(self.sha, self.url).returncode, 0)
            self.assertFalse((builds / f"JOBX.tmp.{dead.pid}").exists())  # its fill was killed: nobody writes there
            self.assertTrue((builds / f"JOBY.tmp.{live.pid}").exists())  # a live download keeps its folder
        finally:
            live.kill()
            live.wait()

    def test_a_closed_stderr_does_not_stop_the_fill(self):
        # run.py's ssh timed out: the fill keeps going for the next round, and its first message must not end it.
        p = subprocess.Popen([sys.executable, "-I", str(HERE / "build_cache.py"), "JOB3", "1" * 64, "3"],
                             env=self.env, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        p.stderr.close()  # nobody reads it any more
        p.stdin.write((self.url + "\n").encode())  # a wrong hash: it says so, then reads it with cmux-ci
        p.stdin.close()
        p.wait(timeout=60)
        self.assertTrue((self.t.home / ".cache" / "cmux-journeys" / "builds" / "JOB3" / "ok").exists())

    def test_an_older_copy_moved_in_at_the_install_is_kept(self):
        import importlib.util
        from unittest import mock
        spec = importlib.util.spec_from_file_location("build_cache_under_test", HERE / "build_cache.py")
        bc = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(bc)
        cache = self.t.home / ".cache" / "cmux-journeys" / "builds" / "JOB4"
        real = os.rename

        def rename(src, dst):
            if str(dst) == str(cache) and not cache.exists():
                # An older harness copy (no lock) moves its own copy in first: `mv "$t" "$c"; touch "$c/ok"`.
                (cache / "build" / "cmux DEV old.app").mkdir(parents=True)
                (cache / "ok").write_text("")
            return real(src, dst)

        with mock.patch.dict(os.environ, self.env), mock.patch.object(bc.os, "rename", rename):
            app = bc.fill("JOB4", "-", 3, "")
        self.assertTrue(app.endswith("cmux DEV old.app"), app)
        self.assertEqual(sorted(p.name for p in cache.parent.iterdir()), ["JOB4"])  # no temporary left

    def test_a_plain_file_at_the_cache_path_is_replaced(self):
        # An older copy's `touch "$c"` after its folder was removed leaves a plain file where the cache goes.
        cache = self.t.home / ".cache" / "cmux-journeys" / "builds" / "JOB5"
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_text("")
        done = self.fill(self.sha, self.url, "JOB5")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertTrue((cache / "ok").exists())


if __name__ == "__main__":
    unittest.main()
