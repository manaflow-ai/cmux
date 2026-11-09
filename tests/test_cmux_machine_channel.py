#!/usr/bin/env python3
"""The Cloud machine channel payload is the same whether it comes from the published manifest or
from this run's own Linux build.

point-machine-channel-early (cmux-tui-artifacts.yml) points the channel as soon as build-linux is
done, before publish writes cmux-tui/<sha>/manifest.json, so scripts/ci/cmux-machine-channel.py
takes each sha256 from the run's binaries (--binaries-dir) instead. Both ways it downloads every
binary from its URL and refuses one whose bytes differ, and both give the same payload key, so
the later point-machine-channel finds the channel current (web-ota-pointer.py newer) and keeps it.

The early upload and a publish of the same commit by another run or attempt never wait on each
other: both upload the four Linux objects write-once before anything names them
(scripts/ci/cmux-machine-linux-bytes.sh), the first upload of each wins, the early job skips when it
lost and publish adopts the served bytes. A separate claim object left windows (a check before an
upload, an expired claim, a failed read) in which a publisher's checksums named bytes another upload
then replaced, and both runs waited for a manifest neither could write (reviews of cmux#37970).
Those cases run the real publish steps against the fake R2 of test_cmux_tui_republish_same_commit.py.
Runs without network.
"""

import contextlib
import hashlib
import sys
import importlib.util
import io
import json
import pathlib
import shutil
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("cmux_machine_channel", ROOT / "scripts/ci/cmux-machine-channel.py")
channel = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(channel)

COMMIT = "a" * 40


class Payload(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.built = self.tmp / "built"   # this run's build-linux artifacts
        self.served = self.tmp / "served"  # what files.cmux.com/cmux-tui/<sha>/ serves
        self.built.mkdir()
        self.served.mkdir()
        self.sha = {}
        for target in channel.TARGETS:
            for name in channel.NAMES:
                published = f"{name}-{target}"
                data = f"{published} bytes".encode()
                (self.built / published).write_bytes(data)
                (self.served / published).write_bytes(data)
                self.sha[published] = hashlib.sha256(data).hexdigest()
        # An artifact the channel does not carry (acpmux rides the same artifact).
        (self.built / f"cmux-tui-acpmux-{channel.TARGETS[0]}").write_bytes(b"acpmux")

    def download(self, argv, check):
        url, out = argv[-1], argv[argv.index("-o") + 1]
        self.assertTrue(url.startswith(f"{channel.FILES}/{COMMIT}/"), url)
        shutil.copyfile(self.served / url.split("/")[-1].split("?")[0], out)

    def run_payload(self, source):
        out = self.tmp / f"payload-{len(list(self.tmp.iterdir()))}.json"
        argv = ["cmux-machine-channel.py", "payload", *source, "--commit", COMMIT, "--committed-at", "1700000000",
                "--download-dir", str(self.tmp / "dl"), "--out", str(out)]
        with mock.patch.object(channel.subprocess, "run", side_effect=self.download):
            channel.main(argv)
        return json.loads(out.read_text())

    def test_the_build_and_the_manifest_give_the_same_payload(self):
        manifest = self.tmp / "manifest.json"
        manifest.write_text(json.dumps({"commit": COMMIT, "binaries": self.sha}))
        early = self.run_payload(["--binaries-dir", str(self.built)])
        late = self.run_payload(["--manifest", str(manifest)])
        self.assertEqual(early["key"], late["key"])
        self.assertEqual(early["targets"], late["targets"])
        hook = early["targets"]["x86_64-unknown-linux-musl"]["cmux-tui-hook"]
        self.assertEqual(hook["url"], f"{channel.FILES}/{COMMIT}/cmux-tui-hook-x86_64-unknown-linux-musl")
        self.assertEqual(hook["sha256"], self.sha["cmux-tui-hook-x86_64-unknown-linux-musl"])

    def test_served_bytes_that_differ_from_the_build_are_refused(self):
        (self.served / "cmux-tui-aarch64-unknown-linux-musl").write_bytes(b"another build")
        with self.assertRaises(SystemExit) as raised, contextlib.redirect_stderr(io.StringIO()) as err:
            self.run_payload(["--binaries-dir", str(self.built)])
        self.assertEqual(raised.exception.code, 1)
        self.assertIn("does not have the expected sha256", err.getvalue())

    def test_a_missing_binary_is_refused(self):
        (self.built / "cmux-tui-hook-aarch64-unknown-linux-musl").unlink()
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()) as err:
            self.run_payload(["--binaries-dir", str(self.built)])
        self.assertIn("no sha256 for cmux-tui-hook-aarch64-unknown-linux-musl", err.getvalue())

    def test_one_source_only(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            channel.main(["x", "payload", "--manifest", "m", "--binaries-dir", "b", "--commit", COMMIT,
                          "--committed-at", "1", "--download-dir", "d", "--out", "o"])


sys.path.insert(0, str(ROOT / "tests"))
import test_cmux_tui_republish_same_commit as republish  # noqa: E402

LINUX = "cmux-tui-x86_64-unknown-linux-musl"


class EarlyUploadAndAnotherPublisher(unittest.TestCase):
    """Run 1 points the channel early; run 2 (or a later attempt) publishes the same commit."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.box = republish.Sandbox(pathlib.Path(self.tmp.name))
        shutil.copy(ROOT / "scripts/ci/cmux-machine-linux-bytes.sh", self.box.repo / "scripts/ci/")
        self.keep = republish.step_script("publish", "Keep the Linux binaries the machine channel already uploaded")
        self.upload = republish.step_script("publish", "Upload to R2")
        self.early_dir = pathlib.Path(self.tmp.name) / "early-assets"
        self.early_dir.mkdir()
        (self.early_dir / LINUX).write_text("linux build of run 1\n")

    def early(self, **env):
        """point-machine-channel-early's upload (its point is not under test)."""
        script = f"""
            rc=0; scripts/ci/cmux-machine-linux-bytes.sh early {self.early_dir} || rc=$?
            [[ $rc == 3 ]] && {{ echo skipped; exit 0; }}
            [[ $rc == 0 ]] || exit $rc
            echo uploaded"""
        return self.box.run(script, **{"GITHUB_RUN_ID": "1", **env})

    def keep_step(self, **env):
        self.box.build("2", real_checksums=True)
        return self.box.run(self.keep, **{"GITHUB_RUN_ID": "2", **env})

    def publish(self, **env):
        """Run 2's publish: keep, then the manifest and checksums of the bytes it holds, then the upload."""
        result = self.keep_step(**env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.checksums_again()
        return self.box.run(self.upload, **{"GITHUB_RUN_ID": "2", **env})

    def checksums_again(self):
        """"Build manifest and checksums" runs after the keep step: it names the bytes the step left."""
        d = self.box.repo / "assets/cmux-tui"
        names = sorted(p.name for p in d.iterdir() if p.name not in ("manifest.json", "cmux-tui-checksums.txt"))
        sha = {n: hashlib.sha256((d / n).read_bytes()).hexdigest() for n in names}
        (d / "cmux-tui-checksums.txt").write_text("".join(f"{sha[n]}  {n}\n" for n in names))
        manifest = json.loads((d / "manifest.json").read_text())
        manifest["binaries"] = sha
        (d / "manifest.json").write_text(json.dumps(manifest))

    def served(self):
        return (self.box.r2 / f"cmux-tui/{self.box.sha}/{LINUX}").read_text()

    def assert_published_with(self, result, text):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("immutable-r2-conflict", result.stdout + result.stderr)
        self.assertEqual(self.served(), text)
        manifest = json.loads((self.box.r2 / f"cmux-tui/{self.box.sha}/manifest.json").read_text())
        self.assertEqual(manifest["binaries"][LINUX], hashlib.sha256(text.encode()).hexdigest())

    def test_the_publisher_uploads_first_and_the_early_job_skips(self):
        self.assert_published_with(self.publish(), f"{LINUX} build 2\n")
        early = self.early()
        self.assertEqual(early.returncode, 0, early.stdout + early.stderr)
        self.assertIn("skipped", early.stdout)

    def test_the_early_job_uploads_first_and_the_publisher_keeps_its_bytes(self):
        self.assertIn("uploaded", self.early().stdout)
        self.assert_published_with(self.publish(), "linux build of run 1\n")

    def test_the_early_job_after_the_keep_step_skips_and_publish_completes(self):
        # Publish settled the bytes; a later early upload (another run, or a later attempt of a run
        # whose first attempt never uploaded) loses and skips before the checksums go up.
        self.assertEqual(self.keep_step().returncode, 0)
        self.assertIn("skipped", self.early().stdout)
        self.checksums_again()
        self.assert_published_with(self.box.run(self.upload, GITHUB_RUN_ID="2"), f"{LINUX} build 2\n")

    def test_a_rerun_of_all_jobs_keeps_its_own_earlier_upload(self):
        self.assertIn("uploaded", self.early(GITHUB_RUN_ID="2").stdout)
        self.assert_published_with(self.publish(), "linux build of run 1\n")  # the rebuild has other bytes

    def test_a_read_that_fails_stops_publish_before_anything_names_the_bytes(self):
        self.assertIn("uploaded", self.early().stdout)
        keep = self.keep_step(FAKE_DOWNLOAD_FAIL=f"cmux-tui/{self.box.sha}/{LINUX}=56")
        self.assertNotEqual(keep.returncode, 0)
        self.assertIn("could not be read", keep.stdout + keep.stderr)
        self.assertEqual(sorted(p.name for p in (self.box.r2 / f"cmux-tui/{self.box.sha}").iterdir()), [LINUX])
        # A re-run with healthy reads then publishes the early bytes.
        self.assert_published_with(self.publish(), "linux build of run 1\n")


if __name__ == "__main__":
    unittest.main()
