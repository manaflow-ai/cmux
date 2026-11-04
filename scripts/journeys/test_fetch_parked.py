#!/usr/bin/env python3
"""fetch_parked.py: the parked movies are fetched only inside a whole-host lease of its own, on the parked host; the
parked folder is removed only after every item came whole; the lease is always released.

    python3 scripts/journeys/test_fetch_parked.py
"""
import io
import json
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "cmux-next"))  # build_names.py

PATH = "/Users/cmux/.cache/cmux-journeys/fetch/20261104T120000Z-ab12cd34"


def tar(members, keep=None):
    """A tar stream of MEMBERS; KEEP: only its first KEEP bytes (a stream cut on the way)."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as t:
        for name, data in members:
            info = tarfile.TarInfo(name)
            info.size = len(data)
            t.addfile(info, io.BytesIO(data))
    data = buf.getvalue()
    return data[:keep] if keep is not None else data


class FetchParked(unittest.TestCase):
    def setUp(self):
        import fetch_parked
        self.fp = fetch_parked
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def park(self, **over):
        rec = dict({"host": "cmux21", "path": PATH, "items": ["j/video"], "run_id": "20261104T120000Z-ab12cd34"}, **over)
        (self.out / "parked.json").write_text(json.dumps(rec))

    def go(self, slot_host="cmux21", tarred=None, tar_rc=0, acquire=None):
        """fetch() with capture-host and ssh faked; (exit code, remote scripts, capture-host calls)."""
        remote_calls, ch_calls = [], []

        def remote(host, script, **kw):
            remote_calls.append(script)
            if script.startswith("cd ") and " tar c " in script:
                return subprocess.CompletedProcess(script, tar_rc, tarred if tarred is not None
                                                   else tar([("j/video/a.mov", b"movie"), ("j/video/a.mov.frames.json", b"{}")]), b"")
            return subprocess.CompletedProcess(script, 0, b"", b"")

        def run(argv, **kw):
            ch_calls.append(argv[1:])
            return subprocess.CompletedProcess(argv, 0, f"host={slot_host} root=/lease".encode(), b"")

        def release(argv, **kw):
            ch_calls.append(argv[1:])
            return subprocess.CompletedProcess(argv, 0, b"", b"")
        acquire = acquire or (lambda *a, **k: ["whole-cmux21-1"])
        with mock.patch.object(self.fp.run, "acquire_lease", side_effect=acquire), \
                mock.patch.object(self.fp.run, "run", side_effect=run), \
                mock.patch.object(self.fp.run, "remote", side_effect=remote), \
                mock.patch.object(self.fp.run, "log"), \
                mock.patch.object(self.fp.subprocess, "run", side_effect=release):
            code = self.fp.fetch(self.out, ch="/fake/capture-host")
        return code, remote_calls, ch_calls

    def fetched(self):
        return json.loads((self.out / "fetched.json").read_text())

    def test_fetches_in_its_own_lease_then_removes_the_folder_and_releases(self):
        self.park()
        code, scripts, ch = self.go()
        self.assertEqual(code, 0)
        self.assertEqual(scripts[0], f"cd '{PATH}' && tar c j/video")
        self.assertEqual(scripts[1], f"rm -rf '{PATH}'")
        self.assertEqual(ch, [["slot-info", "whole-cmux21-1"], ["release", "whole-cmux21-1"]])
        self.assertEqual((self.out / "j" / "video" / "a.mov").read_bytes(), b"movie")
        rec = self.fetched()
        self.assertTrue(rec["ok"] and rec["released"])

    def test_a_lease_on_another_host_fetches_nothing_and_keeps_the_folder(self):
        self.park()
        code, scripts, ch = self.go(slot_host="cmux22")
        self.assertEqual(code, 1)
        self.assertEqual(scripts, [])
        self.assertEqual(ch[-1], ["release", "whole-cmux21-1"])
        self.assertIn("cmux22", self.fetched()["error"])

    def test_a_missing_item_or_a_cut_stream_keeps_the_folder(self):
        self.park(items=["j/video", "k/video"])
        code, scripts, _ = self.go()
        self.assertEqual(code, 1)
        self.assertFalse(any(s.startswith("rm ") for s in scripts))
        self.park()
        for keep in (2000, 512 + 4096 + 300):        # cut in the member's data, and in the end-of-archive blocks
            code, scripts, _ = self.go(tarred=tar([("j/video/a.mov", b"x" * 4096)], keep=keep))
            self.assertEqual(code, 1, keep)
            self.assertFalse(any(s.startswith("rm ") for s in scripts))
        self.assertEqual(code, 1)
        self.assertFalse(any(s.startswith("rm ") for s in scripts))
        self.assertFalse(self.fetched()["ok"])

    def test_a_failed_tar_keeps_the_folder(self):
        self.park()
        code, scripts, ch = self.go(tar_rc=2)
        self.assertEqual(code, 1)
        self.assertFalse(any(s.startswith("rm ") for s in scripts))
        self.assertEqual(ch[-1], ["release", "whole-cmux21-1"])

    def test_nothing_to_fetch_or_no_lease_takes_no_lease_or_touches_nothing(self):
        code, scripts, ch = self.go()                      # no parked.json
        self.assertEqual((code, scripts, ch), (75, [], []))
        for bad in ({"path": "/etc"}, {"path": PATH + "/../x"}, {"items": ["../x/video"]}, {"items": []},
                    {"host": "cmux21; rm"}, {"items": ["j/video; rm -rf ~"]}):
            self.park(**bad)
            code, scripts, ch = self.go()
            self.assertEqual((code, scripts, ch), (75, [], []), bad)
        self.park()

        def refused(*a, **k):
            raise RuntimeError("capture-host acquire exited 3: busy")
        code, scripts, ch = self.go(acquire=refused)
        self.assertEqual((code, scripts, ch), (75, [], []))  # no lease: no release, nothing on the mini
        self.assertIn("no lease", self.fetched()["error"])


if __name__ == "__main__":
    unittest.main()
