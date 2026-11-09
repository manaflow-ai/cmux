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
The same script makes the Linux release payload (--purpose linux-release): every Linux binary the
build publishes and a version that sorts by commit time. LinuxReleasePoint runs
scripts/cmux-machine-channel-point.sh against a fake R2 with a throwaway key: the per-commit
release.json is written once (a re-sign of the same build keeps it, another build fails loud), the
channel pointer only moves forward, and a Cloud machine file never stands in for it.
Runs without network.
"""

import base64
import contextlib
import hashlib
import sys
import importlib.util
import io
import os
import json
import pathlib
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("cmux_machine_channel", ROOT / "scripts/ci/cmux-machine-channel.py")
channel = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(channel)
POINTER_SPEC = importlib.util.spec_from_file_location("web_ota_pointer", ROOT / "scripts/cmux-next/web-ota-pointer.py")
pointer = importlib.util.module_from_spec(POINTER_SPEC)
POINTER_SPEC.loader.exec_module(pointer)

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


RELEASE_COMMIT = "c" * 40
# 2026-11-09 07:00:12 UTC.
COMMITTED_AT = 1794207612


def served_linux_build(directory, generation="1"):
    """What files.cmux.com/cmux-tui/<sha>/ serves for every Linux target, and its manifest binaries."""
    directory.mkdir(parents=True, exist_ok=True)
    sha = {}
    for target in channel.LINUX_RELEASE_TARGETS:
        for name in channel.NAMES:
            data = f"{name}-{target} build {generation}".encode()
            (directory / f"{name}-{target}").write_bytes(data)
            sha[f"{name}-{target}"] = hashlib.sha256(data).hexdigest()
    return sha


class LinuxReleasePayload(unittest.TestCase):
    """--purpose linux-release: the payload of cmux-tui/<sha>/release.json and channels/linux-<channel>.json."""

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.served = self.tmp / "served"
        self.sha = served_linux_build(self.served)
        # The manifest also lists binaries the release file does not carry.
        self.manifest = self.tmp / "manifest.json"
        self.manifest.write_text(json.dumps({"commit": RELEASE_COMMIT, "binaries": {
            **self.sha, "cmux-tui-aarch64-apple-darwin": "0" * 64, "cmux-tui-acpmux-x86_64-unknown-linux-gnu": "1" * 64}}))
        self.downloads = []

    def download(self, argv, check):
        url, out = argv[-1], argv[argv.index("-o") + 1]
        self.downloads.append(url.split("?")[0])
        shutil.copyfile(self.served / url.split("/")[-1].split("?")[0], out)

    def run_payload(self, *extra, manifest=None):
        out = self.tmp / "payload.json"
        argv = ["cmux-machine-channel.py", "payload", "--manifest", str(manifest or self.manifest),
                "--commit", RELEASE_COMMIT, "--committed-at", str(COMMITTED_AT),
                "--download-dir", str(self.tmp / "dl"), "--out", str(out), *extra]
        with mock.patch.object(channel.subprocess, "run", side_effect=self.download):
            channel.main(argv)
        raw = out.read_bytes()
        value = json.loads(raw)
        self.assertEqual(raw, json.dumps(value, sort_keys=True, separators=(",", ":")).encode(), "not compact sorted JSON")
        return value

    def test_the_payload_names_every_linux_binary_and_a_commit_time_version(self):
        value = self.run_payload("--purpose", "linux-release", "--channel", "feat-cmux-next", "--cargo-version", "1.0.0")
        self.assertEqual(sorted(value), ["channel", "commit", "committed_at", "expires_at", "published_at", "purpose",
                                         "schema", "targets", "version"])
        self.assertEqual((value["schema"], value["purpose"], value["channel"]), (1, "cmux-linux-release", "feat-cmux-next"))
        self.assertEqual(value["version"], "1.0.0+20261109070012.cccccccccccc")
        self.assertEqual((value["commit"], value["committed_at"]), (RELEASE_COMMIT, COMMITTED_AT))
        self.assertEqual(value["expires_at"] - value["published_at"], 30 * 24 * 3600)
        self.assertEqual(sorted(value["targets"]), sorted(channel.LINUX_RELEASE_TARGETS))
        for target, files in value["targets"].items():
            self.assertEqual(sorted(files), ["cmux-tui", "cmux-tui-hook"])
            for name, entry in files.items():
                self.assertEqual(entry["url"], f"https://files.cmux.com/cmux-tui/{RELEASE_COMMIT}/{name}-{target}")
                self.assertEqual(entry["sha256"], self.sha[f"{name}-{target}"])
                self.assertEqual(entry["size"], len(f"{name}-{target} build 1"))
        # Every URL was downloaded and checked; nothing is left on disk.
        self.assertEqual(sorted(self.downloads), sorted(e["url"] for f in value["targets"].values() for e in f.values()))
        self.assertEqual(list((self.tmp / "dl").iterdir()), [])

    def test_the_version_defaults_to_the_cmux_tui_cargo_version(self):
        value = self.run_payload("--purpose", "linux-release", "--channel", "feat-cmux-next")
        base = channel.nightly_version.next_base(str(ROOT))
        self.assertEqual(value["version"], f"{base}+20261109070012.cccccccccccc")

    def test_the_cloud_machine_payload_is_unchanged(self):
        manifest = self.tmp / "musl.json"
        manifest.write_text(json.dumps({"commit": RELEASE_COMMIT, "binaries": self.sha}))
        value = self.run_payload(manifest=manifest)
        self.assertEqual(sorted(value), ["channel", "commit", "committed_at", "expires_at", "key", "published_at",
                                         "purpose", "schema", "targets"])
        self.assertEqual(sorted(value["targets"]), sorted(channel.TARGETS))

    def test_refusals(self):
        cases = [
            (("--purpose", "linux-release"), "needs --channel"),
            (("--purpose", "linux-release", "--channel", "every-merge"), "needs --channel"),
            (("--channel", "feat-cmux-next"), "are for --purpose linux-release"),
            (("--purpose", "linux-release", "--channel", "nightly", "--cargo-version", "1.0"), "not MAJOR.MINOR.PATCH"),
        ]
        for extra, message in cases:
            with self.subTest(extra=extra), self.assertRaises(SystemExit), \
                    contextlib.redirect_stderr(io.StringIO()) as err:
                self.run_payload(*extra)
            self.assertIn(message, err.getvalue())
        missing = dict(self.sha)
        del missing["cmux-tui-hook-aarch64-unknown-linux-gnu"]
        self.manifest.write_text(json.dumps({"commit": RELEASE_COMMIT, "binaries": missing}))
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()) as err:
            self.run_payload("--purpose", "linux-release", "--channel", "feat-cmux-next")
        self.assertIn("no sha256 for cmux-tui-hook-aarch64-unknown-linux-gnu", err.getvalue())


# The real uploader's write modes: --write-once takes identical bytes and refuses others,
# --replace-sha256 replaces only the bytes it read (compare-and-swap); a refusal exits
# --conflict-exit-code. FAKE_UPLOAD_LOG records each key written.
FAKE_CAS_UPLOADER = r'''#!/usr/bin/env python3
import argparse, hashlib, os, shutil, sys
p = argparse.ArgumentParser()
p.add_argument("--write-once", action="store_true")
p.add_argument("--replace-sha256")
for name in ("--file", "--endpoint-url", "--bucket", "--key", "--cache-control", "--content-type"):
    p.add_argument(name)
p.add_argument("--conflict-exit-code", type=int, default=1)
a = p.parse_args()
dest = os.path.join(os.environ["FAKE_R2"], a.key)
body = open(a.file, "rb").read()
if os.path.exists(dest):
    current = open(dest, "rb").read()
    if a.write_once and current != body:
        print(f"{a.key} exists with other bytes", file=sys.stderr)
        sys.exit(a.conflict_exit_code)
    if a.replace_sha256 and hashlib.sha256(current).hexdigest() != a.replace_sha256:
        sys.exit(a.conflict_exit_code)
elif a.replace_sha256:
    sys.exit(a.conflict_exit_code)
os.makedirs(os.path.dirname(dest), exist_ok=True)
shutil.copyfile(a.file, dest)
with open(os.environ["FAKE_UPLOAD_LOG"], "a") as log:
    log.write(a.key + "\n")
'''

KEYS_PATH = "Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Resources/web-update-keys.json"


class LinuxReleasePoint(unittest.TestCase):
    """scripts/ci/cmux-machine-channel-point.sh with a Linux release payload, against a fake R2."""

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.repo, self.r2, self.bin = self.tmp / "repo", self.tmp / "r2", self.tmp / "bin"
        for d in (self.repo / "scripts/ci", self.repo / "scripts/cmux-next", self.r2, self.bin):
            d.mkdir(parents=True)
        shutil.copy(ROOT / "scripts/ci/cmux-machine-channel-point.sh", self.repo / "scripts/ci/")
        shutil.copy(ROOT / "scripts/cmux-next/web-ota-pointer.py", self.repo / "scripts/cmux-next/")
        republish.Sandbox._exe(self.repo / "scripts/ci/upload-r2-object.py", FAKE_CAS_UPLOADER)
        republish.Sandbox._exe(self.bin / "curl", republish.FAKE_CURL)
        # A throwaway key stands in for CMUX_WEB_OTA_SIGNING_KEY and the committed key list.
        pem = self.tmp / "key.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "ed25519", "-out", str(pem)], check=True,
                       capture_output=True)
        self.pem = pem.read_text()
        raw = subprocess.run(["openssl", "pkey", "-in", str(pem), "-pubout", "-outform", "DER"], check=True,
                             capture_output=True).stdout[-32:]
        keys = self.repo / KEYS_PATH
        keys.parent.mkdir(parents=True)
        keys.write_text(json.dumps({"keys": [{"id": hashlib.sha256(raw).hexdigest()[:16],
                                              "ed25519": base64.b64encode(raw).decode()}]}))
        self.ptr = pointer

    def payload(self, commit=RELEASE_COMMIT, committed_at=COMMITTED_AT, published_at=1794208000, sha="d" * 64,
                purpose="cmux-linux-release"):
        stamp = time.strftime("%Y%m%d%H%M%S", time.gmtime(committed_at))
        target = "x86_64-unknown-linux-gnu"
        value = {"schema": 1, "purpose": purpose, "channel": "feat-cmux-next",
                 "version": f"1.0.0+{stamp}.{commit[:12]}", "commit": commit, "committed_at": committed_at,
                 "published_at": published_at, "expires_at": int(time.time()) + 86400,
                 "targets": {target: {n: {"url": f"https://files.cmux.com/cmux-tui/{commit}/{n}-{target}",
                                          "sha256": sha, "size": 5} for n in channel.NAMES}}}
        if purpose == "cmux-cloud-machine-update":
            value.update(channel="cloud-machine", key="e" * 64)
            del value["version"]
        path = self.tmp / f"payload-{len(list(self.tmp.iterdir()))}.json"
        path.write_bytes(json.dumps(value, sort_keys=True, separators=(",", ":")).encode())
        return path

    def point(self, payload, run_id="1"):
        scratch = pathlib.Path(tempfile.mkdtemp(dir=self.tmp))
        env = {"PATH": f"{self.bin}:{os.environ['PATH']}", "HOME": str(self.tmp), "FAKE_R2": str(self.r2),
               "FAKE_UPLOAD_LOG": str(self.tmp / "uploads.log"), "SIGNING_KEY": self.pem,
               "R2_ENDPOINT": "https://r2.invalid", "GITHUB_RUN_ID": run_id}
        return subprocess.run(["bash", "scripts/ci/cmux-machine-channel-point.sh", str(payload), str(scratch)],
                              cwd=self.repo, env=env, text=True, capture_output=True)

    def served(self, key):
        path = self.r2 / key
        return path.read_bytes() if path.exists() else None

    def verified(self, key, *args):
        path = self.r2 / key
        return self.ptr.verified_payload(str(path), self.ptr.load_keys(str(self.repo / KEYS_PATH)), *args)

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    RELEASE = f"cmux-tui/{RELEASE_COMMIT}/release.json"
    POINTER = "cmux-tui/channels/linux-feat-cmux-next.json"

    def test_a_build_writes_its_release_file_and_moves_the_pointer(self):
        self.assert_ok(self.point(self.payload()))
        self.assertEqual(self.served(self.RELEASE), self.served(self.POINTER))
        value = self.verified(self.POINTER, "feat-cmux-next", "cmux-linux-release")
        self.assertEqual(value["commit"], RELEASE_COMMIT)
        self.assertIsNone(self.served("cmux-tui/channels/cloud-machine.json"))

    def test_a_re_sign_of_the_same_build_keeps_the_release_file(self):
        self.assert_ok(self.point(self.payload()))
        first = self.served(self.RELEASE)
        result = self.point(self.payload(published_at=1794209999), run_id="2")
        self.assert_ok(result)
        self.assertEqual(self.served(self.RELEASE), first)
        self.assertEqual(self.served(self.POINTER), first)  # same commit time: the pointer is current

    def test_another_build_of_a_published_commit_fails_loud(self):
        self.assert_ok(self.point(self.payload()))
        first = self.served(self.RELEASE)
        result = self.point(self.payload(sha="f" * 64), run_id="2")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("immutable-r2-conflict", result.stdout)
        self.assertEqual(self.served(self.RELEASE), first)
        self.assertEqual(self.served(self.POINTER), first)

    def test_the_pointer_only_moves_forward(self):
        newer = "e" * 40
        self.assert_ok(self.point(self.payload(commit=newer, committed_at=COMMITTED_AT + 60)))
        self.assert_ok(self.point(self.payload(), run_id="2"))
        # The older build still gets its own release file; the pointer stays on the newer one.
        self.assertEqual(self.verified(self.RELEASE, None, "cmux-linux-release", False)["commit"], RELEASE_COMMIT)
        self.assertEqual(self.verified(self.POINTER)["commit"], newer)

    def test_a_cloud_machine_file_never_stands_in_for_the_pointer(self):
        # Someone copies the Cloud machine channel (the same key) to the Linux pointer's place.
        self.assert_ok(self.point(self.payload(purpose="cmux-cloud-machine-update", committed_at=COMMITTED_AT + 600)))
        (self.r2 / self.POINTER).write_bytes(self.served("cmux-tui/channels/cloud-machine.json"))
        self.assertIsNone(self.served(self.RELEASE))  # the machine channel writes no release file
        self.assert_ok(self.point(self.payload(), run_id="2"))
        self.assertEqual(self.verified(self.POINTER)["purpose"], "cmux-linux-release")


if __name__ == "__main__":
    unittest.main()
