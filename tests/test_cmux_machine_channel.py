#!/usr/bin/env python3
"""The Cloud machine channel payload is the same whether it comes from the published manifest or
from this run's own Linux build.

point-machine-channel-early (cmux-tui-artifacts.yml) points the channel as soon as build-linux is
done, before publish writes cmux-tui/<sha>/manifest.json, so scripts/ci/cmux-machine-channel.py
takes each sha256 from the run's binaries (--binaries-dir) instead. Both ways it downloads every
binary from its URL and refuses one whose bytes differ, and both give the same payload key, so
the later point-machine-channel finds the channel current (web-ota-pointer.py newer) and keeps it.

The early upload and a publish of the same commit by another run never wait on each other: the
commit's write-once claim (scripts/ci/cmux-machine-linux-claim.sh) decides whose Linux bytes the
prefix gets. Without it, a publisher that claimed the prefix between the early job's check and its
upload left both runs waiting for a manifest neither could write (review of cmux#37970). Those
cases run the real publish steps against the fake R2 of test_cmux_tui_republish_same_commit.py.
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
    """Run 1 points the channel early; run 2 publishes the same commit (cx-a1q4d: two runs of one commit)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.box = republish.Sandbox(pathlib.Path(self.tmp.name))
        uploader = self.box.repo / "scripts/ci/upload-r2-object.py"
        uploader.write_text(uploader.read_text().replace(
            'p.add_argument("--conflict-exit-code", type=int)',
            'p.add_argument("--conflict-exit-code", type=int); p.add_argument("--content-type")'))
        shutil.copy(ROOT / "scripts/ci/cmux-machine-linux-claim.sh", self.box.repo / "scripts/ci/")
        self.keep = republish.step_script("publish", "Keep the Linux binaries the machine channel already uploaded")
        self.upload = republish.step_script("publish", "Upload to R2")
        self.early_dir = pathlib.Path(self.tmp.name) / "early-assets"
        self.early_dir.mkdir()
        (self.early_dir / LINUX).write_text("linux build of run 1\n")

    def early(self, **env):
        """point-machine-channel-early's claim and upload in run 1 (its point is not under test)."""
        script = f"""
            rc=0; scripts/ci/cmux-machine-linux-claim.sh early {self.early_dir} || rc=$?
            [[ $rc == 3 ]] && {{ echo skipped; exit 0; }}
            [[ $rc == 0 ]] || exit $rc
            python3 scripts/ci/upload-r2-object.py --write-once --conflict-exit-code 75 --file {self.early_dir}/{LINUX} \\
              --endpoint-url "$R2_ENDPOINT" --bucket cmux-binaries --key "cmux-tui/$GITHUB_SHA/{LINUX}" --cache-control x
            echo uploaded"""
        return self.box.run(script, **{"GITHUB_RUN_ID": "1", **env})

    def publish(self, **env):
        """Run 2's publish: keep, then the manifest and checksums of the bytes it holds, then the upload."""
        self.box.build("2", real_checksums=True)
        result = self.box.run(self.keep, GITHUB_RUN_ID="2", **env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.checksums_again()
        return self.box.run(self.upload, GITHUB_RUN_ID="2", **env)

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

    def test_the_publisher_claims_first_and_the_early_job_skips(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        early = self.early()
        self.assertEqual(early.returncode, 0, early.stdout + early.stderr)
        self.assertIn("skipped", early.stdout)
        self.assertIn("build 2", self.served())

    def test_the_early_job_claims_first_and_the_publisher_keeps_its_bytes(self):
        early = self.early()
        self.assertIn("uploaded", early.stdout, early.stderr)
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("immutable-r2-conflict", result.stdout + result.stderr)
        self.assertEqual(self.served(), "linux build of run 1\n")
        manifest = json.loads((self.box.r2 / f"cmux-tui/{self.box.sha}/manifest.json").read_text())
        self.assertEqual(manifest["binaries"][LINUX], hashlib.sha256(b"linux build of run 1\n").hexdigest())

    def test_the_publisher_waits_for_a_claimed_upload_still_in_flight(self):
        # Run 1 holds the claim; its binary lands while run 2 waits (the fake sleep copies it in).
        claim = self.box.r2 / f"cmux-tui-machine-claims/{self.box.sha}"
        claim.parent.mkdir(parents=True)
        claim.write_text("1 %d\n" % __import__("time").time())
        race = pathlib.Path(self.tmp.name) / "race"
        (race / f"cmux-tui/{self.box.sha}").mkdir(parents=True)
        (race / f"cmux-tui/{self.box.sha}/{LINUX}").write_text("linux build of run 1\n")
        result = self.publish(FAKE_RACE_DIR=str(race), FAKE_RACE_FINISHES="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.served(), "linux build of run 1\n")
        self.assertIn("15", (pathlib.Path(self.tmp.name) / "sleep.log").read_text())

    def test_a_claim_that_cannot_be_read_is_never_taken_for_this_runs_own(self):
        # Run 2's publish holds the claim; run 1's early job cannot read it back (review of cmux#37970).
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        early = self.early(FAKE_DOWNLOAD_FAIL=f"cmux-tui-machine-claims/{self.box.sha}=56")
        self.assertNotEqual(early.returncode, 0)
        self.assertNotIn("uploaded", early.stdout)
        self.assertIn("build 2", self.served())
        # Its publish fails the same way rather than adopting bytes no run uploaded.
        self.box.build("1", real_checksums=True)
        keep = self.box.run(self.keep, GITHUB_RUN_ID="1", FAKE_DOWNLOAD_FAIL=f"cmux-tui-machine-claims/{self.box.sha}=56")
        self.assertNotEqual(keep.returncode, 0)

    def test_a_rerun_of_all_jobs_keeps_its_own_earlier_upload(self):
        early = self.early(GITHUB_RUN_ID="2")
        self.assertIn("uploaded", early.stdout, early.stderr)
        result = self.publish()  # run 2 again: its rebuild has other bytes
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.served(), "linux build of run 1\n")


if __name__ == "__main__":
    unittest.main()
