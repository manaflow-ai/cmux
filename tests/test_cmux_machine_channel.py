#!/usr/bin/env python3
"""The Cloud machine channel payload is the same whether it comes from the published manifest or
from this run's own Linux build.

point-machine-channel-early (cmux-tui-artifacts.yml) points the channel as soon as build is
done, before publish writes cmux-tui/<sha>/manifest.json, so scripts/ci/cmux-machine-channel.py
takes each sha256 from the run's binaries (--binaries-dir) instead. Both ways it downloads every
binary from its URL and refuses one whose bytes differ, and both give the same payload key, so
the later point-machine-channel finds the channel current (web-ota-pointer.py newer) and keeps it.

The early job uploads build's Linux binaries (the shipped fat bytes, built once: MUSL_BUILT_ONCE) to
cmux-tui/<sha>/machine/ and names it with --machine-path; publish uploads the same build to
cmux-tui/<sha>/. They never share an object, so whichever runs first, the shipped Linux binaries are
publish's own (fat, #41963) and the channel's copy stays under machine/. Each side is still
write-once against its own other runs and attempts (scripts/ci/cmux-machine-linux-bytes.sh): early
attempts with other bytes skip on the claim, and publish adopts another publisher's served bytes.
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
release = channel.helper_release  # scripts/ci/screen_sharing_helper_release.py, as the payload imports it

COMMIT = "a" * 40


class Payload(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.built = self.tmp / "built"   # this run's build artifacts
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

    def test_the_machine_path_names_the_commits_machine_copy(self):
        # The early job's thin copy: same checksums and key, URLs under cmux-tui/<sha>/machine/, the
        # second of the two URLs the updater accepts (updater/channel.rs).
        early = self.run_payload(["--binaries-dir", str(self.built), "--machine-path"])
        hook = early["targets"]["aarch64-unknown-linux-musl"]["cmux-tui-hook"]
        self.assertEqual(hook["url"], f"{channel.FILES}/{COMMIT}/machine/cmux-tui-hook-aarch64-unknown-linux-musl")
        self.assertEqual(hook["sha256"], self.sha["cmux-tui-hook-aarch64-unknown-linux-musl"])
        for binaries in early["targets"].values():
            for binary in binaries.values():
                self.assertTrue(binary["url"].startswith(f"{channel.FILES}/{COMMIT}/machine/"), binary["url"])

    def test_the_machine_path_is_only_for_this_runs_cloud_machine_build(self):
        manifest = self.tmp / "manifest.json"
        manifest.write_text(json.dumps({"commit": COMMIT, "binaries": self.sha}))
        for source in (["--manifest", str(manifest)],
                       ["--binaries-dir", str(self.built), "--purpose", "linux-release", "--channel", "feat-cmux-next"]):
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()) as err:
                self.run_payload([*source, "--machine-path"])
            self.assertIn("--machine-path is for the cloud-machine payload", err.getvalue())

    def test_one_source_only(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            channel.main(["x", "payload", "--manifest", "m", "--binaries-dir", "b", "--commit", COMMIT,
                          "--committed-at", "1", "--download-dir", "d", "--out", "o"])

    def test_the_x86_64_point_signs_x86_64_alone_and_the_full_point_completes_it(self):
        # LINUX_X86_64_FIRST: point-machine-channel-early signs the x86_64 leg's file before the aarch64
        # leg is done; only x86_64 artifacts are downloaded.
        (self.built / "cmux-tui-aarch64-unknown-linux-musl").unlink()
        (self.built / "cmux-tui-hook-aarch64-unknown-linux-musl").unlink()
        early = self.run_payload(["--binaries-dir", str(self.built), "--machine-path",
                                  "--target", "x86_64-unknown-linux-musl"])
        self.assertEqual(list(early["targets"]), ["x86_64-unknown-linux-musl"])
        for name in ("cmux-tui-aarch64-unknown-linux-musl", "cmux-tui-hook-aarch64-unknown-linux-musl"):
            data = f"{name} bytes".encode()
            (self.built / name).write_bytes(data)
        full = self.run_payload(["--binaries-dir", str(self.built), "--machine-path"])
        late = self.run_payload(["--binaries-dir", str(self.built)])  # point-machine-channel: the fat path
        for current in (early,):
            current = {**current, "purpose": channel.PURPOSE}
            for new in (full, late):
                self.assertTrue(pointer.completes({**new, "purpose": channel.PURPOSE}, current))
        purpose = {"purpose": channel.PURPOSE}
        # Never backwards (fewer targets), never the same set, never another commit or other bytes.
        self.assertFalse(pointer.completes({**early, **purpose}, {**full, **purpose}))
        self.assertFalse(pointer.completes({**full, **purpose}, {**full, **purpose}))
        self.assertFalse(pointer.completes({**full, **purpose, "commit": "b" * 40}, {**early, **purpose}))
        other = json.loads(json.dumps(full))
        other["targets"]["x86_64-unknown-linux-musl"]["cmux-tui"]["sha256"] = "0" * 64
        self.assertFalse(pointer.completes({**other, **purpose}, {**early, **purpose}))
        # Only the Cloud machine channel's files.
        self.assertFalse(pointer.completes({**full, "purpose": "cmux-linux-release"}, {**early, **purpose}))

    def test_the_target_flag_is_cloud_machine_only(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()) as err:
            self.run_payload(["--binaries-dir", str(self.built), "--purpose", "linux-release", "--channel",
                              "feat-cmux-next", "--target", "x86_64-unknown-linux-musl"])
        self.assertIn("--target is for the cloud-machine payload", err.getvalue())


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
        self.keep = republish.step_script("publish", "Keep the Linux binaries another publisher already uploaded")
        self.upload = republish.step_script("publish", "Upload to R2")
        self.early_dir = pathlib.Path(self.tmp.name) / "early-assets"
        self.early_dir.mkdir()
        (self.early_dir / LINUX).write_text("linux build of run 1\n")

    def early(self, assets=None, **env):
        """point-machine-channel-early's upload (its point is not under test)."""
        script = f"""
            rc=0; scripts/ci/cmux-machine-linux-bytes.sh early {assets or self.early_dir} || rc=$?
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

    def machine(self):
        return (self.box.r2 / f"cmux-tui/{self.box.sha}/machine/{LINUX}").read_text()

    def assert_published_with(self, result, text):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("immutable-r2-conflict", result.stdout + result.stderr)
        self.assertEqual(self.served(), text)
        manifest = json.loads((self.box.r2 / f"cmux-tui/{self.box.sha}/manifest.json").read_text())
        self.assertEqual(manifest["binaries"][LINUX], hashlib.sha256(text.encode()).hexdigest())

    def test_the_publisher_uploads_first_and_the_early_job_still_uploads_its_machine_copy(self):
        self.assert_published_with(self.publish(), f"{LINUX} build 2\n")
        early = self.early()
        self.assertEqual(early.returncode, 0, early.stdout + early.stderr)
        self.assertIn("uploaded", early.stdout)
        self.assertEqual(self.machine(), "linux build of run 1\n")
        self.assertEqual(self.served(), f"{LINUX} build 2\n")

    def test_the_early_job_uploads_first_and_publish_ships_its_own_bytes(self):
        # The regression: the channel's thin bytes never become the shipped ones.
        self.assertIn("uploaded", self.early().stdout)
        self.assert_published_with(self.publish(), f"{LINUX} build 2\n")
        self.assertEqual(self.machine(), "linux build of run 1\n")

    def test_the_early_job_after_the_keep_step_uploads_and_publish_completes(self):
        self.assertEqual(self.keep_step().returncode, 0)
        self.assertIn("uploaded", self.early().stdout)
        self.checksums_again()
        self.assert_published_with(self.box.run(self.upload, GITHUB_RUN_ID="2"), f"{LINUX} build 2\n")

    def test_the_early_job_uploads_all_four_binaries_at_once(self):
        names = [f"{n}-{t}" for t in ("x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl")
                 for n in ("cmux-tui", "cmux-tui-hook")]
        for name in names:
            (self.early_dir / name).write_text(f"{name} of run 1\n")
        self.assertIn("uploaded", self.early().stdout)
        prefix = self.box.r2 / f"cmux-tui/{self.box.sha}/machine"
        self.assertEqual(sorted(p.name for p in prefix.iterdir()), sorted(names + ["early-claim.json"]))
        # Nothing at the shipped names: publish writes those.
        self.assertEqual([p.name for p in prefix.parent.iterdir()], ["machine"])
        for name in names:
            self.assertEqual((prefix / name).read_text(), f"{name} of run 1\n")

    NAMES = [f"{n}-{t}" for t in ("x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl")
             for n in ("cmux-tui", "cmux-tui-hook")]

    def attempt(self, label, differ=()):
        """An attempt's four binaries: the same bytes as attempt "a", except the names in differ."""
        d = pathlib.Path(self.tmp.name) / label
        d.mkdir()
        for name in self.NAMES:
            (d / name).write_text(f"{name} of attempt {label if name in differ else 'a'}\n")
        return d

    def prefix(self):
        return self.box.r2 / f"cmux-tui/{self.box.sha}/machine"

    def test_the_loser_of_the_claim_uploads_nothing_else(self):
        # Two rebuilds of one commit race with the same hook bytes and another cmux-tui. Attempt a
        # wrote the claim and its binary uploads are still in flight; attempt b must upload none, or
        # publish would name binaries of two builds.
        first = self.attempt("a")
        self.assertIn("uploaded", self.early(assets=first).stdout)
        for name in self.NAMES:
            (self.prefix() / name).unlink()  # attempt a's binaries, not landed yet
        second = self.attempt("b", differ=("cmux-tui-x86_64-unknown-linux-musl",))
        result = self.early(assets=second, GITHUB_RUN_ID="2")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("skipped", result.stdout)
        self.assertEqual(sorted(p.name for p in self.prefix().iterdir()), ["early-claim.json"])

    def test_the_claim_names_every_binary_and_nothing_else(self):
        self.assertIn("uploaded", self.early(assets=self.attempt("a")).stdout)
        claim = json.loads((self.prefix() / "early-claim.json").read_text())
        self.assertEqual(sorted(claim), sorted(self.NAMES))
        self.assertEqual(claim["cmux-tui-hook-x86_64-unknown-linux-musl"],
                         hashlib.sha256(b"cmux-tui-hook-x86_64-unknown-linux-musl of attempt a\n").hexdigest())

    def test_a_rerun_with_the_same_bytes_holds_the_claim_and_fills_the_rest(self):
        # An attempt that died after the claim and one binary; a later attempt reusing the same build
        # artifacts holds the claim (same bytes) and uploads the keys the first never got to.
        first = self.attempt("a")
        self.assertIn("uploaded", self.early(assets=first).stdout)
        for name in self.NAMES[1:]:
            (self.prefix() / name).unlink()
        self.assertIn("uploaded", self.early(assets=first, GITHUB_RUN_ID="2").stdout)
        self.assertEqual(sorted(p.name for p in self.prefix().iterdir()), sorted(self.NAMES + ["early-claim.json"]))

    def test_a_rerun_of_all_jobs_ships_the_publishers_bytes(self):
        self.assertIn("uploaded", self.early(GITHUB_RUN_ID="2").stdout)
        self.assert_published_with(self.publish(), f"{LINUX} build 2\n")

    def test_publish_adopts_another_publishers_bytes(self):
        other = self.box.r2 / f"cmux-tui/{self.box.sha}/{LINUX}"
        other.parent.mkdir(parents=True, exist_ok=True)
        other.write_text("another publisher's build\n")
        self.assert_published_with(self.publish(), "another publisher's build\n")

    def test_a_read_that_fails_stops_publish_before_anything_names_the_bytes(self):
        other = self.box.r2 / f"cmux-tui/{self.box.sha}/{LINUX}"
        other.parent.mkdir(parents=True, exist_ok=True)
        other.write_text("another publisher's build\n")
        keep = self.keep_step(FAKE_DOWNLOAD_FAIL=f"cmux-tui/{self.box.sha}/{LINUX}=56")
        self.assertNotEqual(keep.returncode, 0)
        self.assertIn("could not be read", keep.stdout + keep.stderr)
        # Only the other publisher's binary: no checksums or manifest name anything yet.
        self.assertEqual(sorted(p.name for p in other.parent.iterdir()), [LINUX])
        # A re-run with healthy reads then publishes the served bytes.
        self.assert_published_with(self.publish(), "another publisher's build\n")


RELEASE_COMMIT = "c" * 40
# 2026-11-09 07:00:12 UTC.
COMMITTED_AT = 1794207612
# 2026-11-22 11:05:00 UTC.
PUBLISHED_AT = 1795345500
RELEASE = ("--purpose", "linux-release", "--channel", "feat-cmux-next")


def served_linux_build(directory, generation="1"):
    """What files.cmux.com/cmux-tui/<sha>/ serves for every Linux target, and its manifest binaries."""
    directory.mkdir(parents=True, exist_ok=True)
    sha = {}
    for target in channel.LINUX_RELEASE_TARGETS:
        for name in channel.LINUX_RELEASE_NAMES:
            if name in channel.LINUX_RELEASE_MUSL_ONLY and not target.endswith("-musl"):
                continue  # the detector is required on musl only; its glibc-named copy is optional
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
        # This run's own build artifacts (gh run download): the same bytes, plus files the release
        # file does not carry.
        self.built = self.tmp / "built"
        shutil.copytree(self.served, self.built)
        (self.built / "cmux-tui-cloud-server-x86_64-unknown-linux-gnu").write_bytes(b"cloud server")
        self.downloads = []

    def download(self, argv, check=False, **kwargs):
        url, out = argv[-1], argv[argv.index("-o") + 1]
        self.downloads.append(url.split("?")[0])
        shutil.copyfile(self.served / url.split("/")[-1].split("?")[0], out)

    def run_payload(self, *extra, source=None):
        out = self.tmp / "payload.json"
        argv = ["cmux-machine-channel.py", "payload", *(source or ("--binaries-dir", str(self.built))),
                "--commit", RELEASE_COMMIT, "--committed-at", str(COMMITTED_AT),
                "--download-dir", str(self.tmp / "dl"), "--out", str(out), *extra]
        with mock.patch.object(channel.subprocess, "run", side_effect=self.download):
            channel.main(argv)
        raw = out.read_bytes()
        value = json.loads(raw)
        self.assertEqual(raw, json.dumps(value, sort_keys=True, separators=(",", ":")).encode(), "not compact sorted JSON")
        return value

    def test_the_payload_names_every_linux_binary_and_a_publish_order_version(self):
        with mock.patch.object(channel.time, "time", return_value=PUBLISHED_AT):
            value = self.run_payload(*RELEASE, "--cargo-version", "1.0.0")
        self.assertEqual(sorted(value), ["channel", "commit", "committed_at", "expires_at", "published_at", "purpose",
                                         "schema", "sequence", "targets", "version"])
        self.assertEqual((value["schema"], value["purpose"], value["channel"]), (1, "cmux-linux-release", "feat-cmux-next"))
        # sequence is the publish time, the version carries it (installers and dpkg/rpm order by it).
        self.assertEqual(value["sequence"], 20261122110500)
        self.assertEqual(value["version"], "1.0.0+20261122110500.cccccccccccc")
        self.assertEqual((value["commit"], value["committed_at"]), (RELEASE_COMMIT, COMMITTED_AT))
        self.assertEqual(value["expires_at"] - value["published_at"], 30 * 24 * 3600)
        self.assertEqual(sorted(value["targets"]), sorted(channel.LINUX_RELEASE_TARGETS))
        for target, files in value["targets"].items():
            names = ["cmux-tui", "cmux-tui-acpmux", "cmux-tui-app-host", "cmux-tui-hook"]
            if target.endswith("-musl"):
                names.append("cmux-tui-agent-screen-detection")
            self.assertEqual(sorted(files), sorted(names))
            for name, entry in files.items():
                self.assertEqual(entry["url"], f"https://files.cmux.com/cmux-tui/{RELEASE_COMMIT}/{name}-{target}")
                self.assertEqual(entry["sha256"], self.sha[f"{name}-{target}"])
                self.assertEqual(entry["size"], len(f"{name}-{target} build 1"))
        # Every URL was downloaded and checked; nothing is left on disk.
        self.assertEqual(sorted(self.downloads), sorted(e["url"] for f in value["targets"].values() for e in f.values()))
        self.assertEqual(list((self.tmp / "dl").iterdir()), [])

    def test_a_bucket_writer_cannot_get_its_bytes_signed(self):
        # Reviews of #39452: a bucket writer controls every byte in the bucket. Before publish it plants a
        # musl binary that publish adopts (and attests) and copies to the GNU name; or after publish it
        # replaces a GNU binary and the manifest's checksum. Either way the served bytes are not this
        # run's build: refused, nothing written.
        evil = b"attacker build"
        for name in ("cmux-tui-x86_64-unknown-linux-musl", "cmux-tui-x86_64-unknown-linux-gnu"):
            (self.served / name).write_bytes(evil)
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()) as err:
            self.run_payload(*RELEASE)
        self.assertIn("cmux-tui-x86_64-unknown-linux-", err.getvalue())
        self.assertIn("does not have the expected sha256", err.getvalue())
        self.assertFalse((self.tmp / "payload.json").exists())

    def test_the_version_defaults_to_the_cmux_tui_cargo_version(self):
        with mock.patch.object(channel.time, "time", return_value=PUBLISHED_AT):
            value = self.run_payload(*RELEASE)
        base = channel.nightly_version.next_base(str(ROOT))
        self.assertEqual(value["version"], f"{base}+20261122110500.cccccccccccc")

    def test_the_sequence_rises_above_the_channel_and_never_below_the_commit(self):
        # A clock that would not exceed the channel's current sequence: one more than it.
        with mock.patch.object(channel.time, "time", return_value=PUBLISHED_AT):
            value = self.run_payload(*RELEASE, "--cargo-version", "1.0.0", "--min-sequence", "20261122120000")
        self.assertEqual((value["sequence"], value["version"]), (20261122120000, "1.0.0+20261122120000.cccccccccccc"))
        # A clock behind the commit: the commit time's stamp, which a phase-1 file of this commit carried.
        with mock.patch.object(channel.time, "time", return_value=COMMITTED_AT - 60):
            value = self.run_payload(*RELEASE, "--cargo-version", "1.0.0")
        self.assertEqual(value["sequence"], 20261109070012)

    def test_the_glibc_detector_goes_in_when_built_and_the_musl_one_is_required(self):
        (self.built / "cmux-tui-agent-screen-detection-x86_64-unknown-linux-gnu").write_bytes(b"detector gnu")
        (self.served / "cmux-tui-agent-screen-detection-x86_64-unknown-linux-gnu").write_bytes(b"detector gnu")
        value = self.run_payload(*RELEASE)
        self.assertIn("cmux-tui-agent-screen-detection", value["targets"]["x86_64-unknown-linux-gnu"])
        self.assertNotIn("cmux-tui-agent-screen-detection", value["targets"]["aarch64-unknown-linux-gnu"])
        (self.built / "cmux-tui-agent-screen-detection-aarch64-unknown-linux-musl").unlink()
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()) as err:
            self.run_payload(*RELEASE)
        self.assertIn("no sha256 for cmux-tui-agent-screen-detection-aarch64-unknown-linux-musl", err.getvalue())

    def test_the_cloud_machine_payload_is_unchanged(self):
        manifest = self.tmp / "musl.json"
        manifest.write_text(json.dumps({"commit": RELEASE_COMMIT, "binaries": self.sha}))
        value = self.run_payload(source=("--manifest", str(manifest)))
        self.assertEqual(sorted(value), ["channel", "commit", "committed_at", "expires_at", "key", "published_at",
                                         "purpose", "schema", "targets"])
        self.assertEqual(sorted(value["targets"]), sorted(channel.TARGETS))

    def test_refusals(self):
        cases = [
            (("--purpose", "linux-release"), "needs --channel"),
            (("--purpose", "linux-release", "--channel", "every-merge"), "needs --channel"),
            (("--channel", "feat-cmux-next"), "are for --purpose linux-release"),
            (("--min-sequence", "20261122110500"), "are for --purpose linux-release"),
            (("--purpose", "linux-release", "--channel", "nightly", "--cargo-version", "1.0"),
             "not MAJOR.MINOR.PATCH"),
        ]
        for extra, message in cases:
            with self.subTest(extra=extra), self.assertRaises(SystemExit), \
                    contextlib.redirect_stderr(io.StringIO()) as err:
                self.run_payload(*extra)
            self.assertIn(message, err.getvalue())
        # The manifest is in the bucket: a release file never takes its checksums from it.
        manifest = self.tmp / "manifest.json"
        manifest.write_text(json.dumps({"commit": RELEASE_COMMIT, "binaries": self.sha}))
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()) as err:
            self.run_payload(*RELEASE, source=("--manifest", str(manifest)))
        self.assertIn("needs --binaries-dir", err.getvalue())
        (self.built / "cmux-tui-hook-aarch64-unknown-linux-gnu").unlink()
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()) as err:
            self.run_payload(*RELEASE)
        self.assertIn("no sha256 for cmux-tui-hook-aarch64-unknown-linux-gnu", err.getvalue())

    def test_the_tree_key_names_the_trees_copies_of_this_runs_build(self):
        key = "e" * 40
        with mock.patch.object(channel.time, "time", return_value=PUBLISHED_AT):
            value = self.run_payload(*RELEASE, "--cargo-version", "1.0.0", "--tree-key", key)
        self.assertEqual(value["tree_key"], key)
        self.assertEqual((value["commit"], value["version"]), (RELEASE_COMMIT, "1.0.0+20261122110500.cccccccccccc"))
        for target, files in value["targets"].items():
            for name, entry in files.items():
                self.assertEqual(entry["url"], f"https://files.cmux.com/cmux-tui/tree/{key}/{name}-{target}")
                self.assertEqual(entry["sha256"], self.sha[f"{name}-{target}"])
        self.assertTrue(self.downloads)
        self.assertTrue(all(url.startswith(f"https://files.cmux.com/cmux-tui/tree/{key}/") for url in self.downloads))
        # The tree's copies are still checked against this run's build: other bytes are refused.
        (self.served / "cmux-tui-hook-x86_64-unknown-linux-gnu").write_bytes(b"another run's build")
        (self.tmp / "payload.json").unlink()
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()) as err:
            self.run_payload(*RELEASE, "--tree-key", key)
        self.assertIn("does not have the expected sha256", err.getvalue())
        self.assertFalse((self.tmp / "payload.json").exists())

    def test_tree_key_refusals(self):
        for extra, message in ((("--tree-key", "e" * 40), "--purpose linux-release"),
                               ((*RELEASE, "--tree-key", "E" * 40), "tree key"),
                               ((*RELEASE, "--tree-key", "e" * 39), "tree key")):
            with self.subTest(extra=extra), self.assertRaises(SystemExit), \
                    contextlib.redirect_stderr(io.StringIO()) as err:
                self.run_payload(*extra)
            self.assertIn(message, err.getvalue())


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
        shutil.copy(ROOT / "scripts/ci/timeout.sh", self.repo / "scripts/ci/")
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
                purpose="cmux-linux-release", sequence=None):
        stamp = str(sequence) if sequence else time.strftime("%Y%m%d%H%M%S", time.gmtime(committed_at))
        value = {"schema": 1, "purpose": purpose, "channel": "feat-cmux-next",
                 "version": f"1.0.0+{stamp}.{commit[:12]}", "commit": commit, "committed_at": committed_at,
                 "published_at": published_at, "expires_at": int(time.time()) + 86400,
                 "targets": {target: {n: {"url": f"https://files.cmux.com/cmux-tui/{commit}/{n}-{target}",
                                          "sha256": sha, "size": 5} for n in channel.NAMES}
                             for target in channel.LINUX_RELEASE_TARGETS}}
        if sequence:
            value["sequence"] = sequence
        if purpose == "cmux-cloud-machine-update":
            value.update(channel="cloud-machine", key="e" * 64)
            del value["version"]
        path = self.tmp / f"payload-{len(list(self.tmp.iterdir()))}.json"
        path.write_bytes(json.dumps(value, sort_keys=True, separators=(",", ":")).encode())
        return path

    def point(self, payload, *extra, run_id="1", release_key=None):
        scratch = pathlib.Path(tempfile.mkdtemp(dir=self.tmp))
        env = {"PATH": f"{self.bin}:{os.environ['PATH']}", "HOME": str(self.tmp), "FAKE_R2": str(self.r2),
               "FAKE_UPLOAD_LOG": str(self.tmp / "uploads.log"), "SIGNING_KEY": self.pem,
               "R2_ENDPOINT": "https://r2.invalid", "GITHUB_RUN_ID": run_id}
        if release_key is not None:
            env["LINUX_RELEASE_SIGNING_KEY"] = release_key
        return subprocess.run(["bash", "scripts/ci/cmux-machine-channel-point.sh", str(payload), str(scratch),
                               *extra], cwd=self.repo, env=env, text=True, capture_output=True)

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

    def release_key(self, listed):
        """A throwaway CMUX_LINUX_RELEASE_SIGNING_KEY; `listed` adds its public half to the key list."""
        pem = self.tmp / f"release-{listed}.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "ed25519", "-out", str(pem)], check=True,
                       capture_output=True)
        raw = subprocess.run(["openssl", "pkey", "-in", str(pem), "-pubout", "-outform", "DER"], check=True,
                             capture_output=True).stdout[-32:]
        key_id = hashlib.sha256(raw).hexdigest()[:16]
        if listed:
            keys = self.repo / KEYS_PATH
            value = json.loads(keys.read_text())
            value["keys"].append({"id": key_id, "ed25519": base64.b64encode(raw).decode()})
            keys.write_text(json.dumps(value))
        return pem.read_text(), key_id

    def signers(self, key):
        return [s["key_id"] for s in json.loads(self.served(key))["signatures"]]

    def only_linux_release(self):
        if type(self) is not LinuxReleasePoint:  # MacLivePoint inherits these; only Linux release files dual-sign
            self.skipTest("the release key signs Linux release files only")

    def test_a_listed_release_key_dual_signs_the_linux_release_files(self):
        self.only_linux_release()
        pem, key_id = self.release_key(listed=True)
        result = self.point(self.payload(), release_key=pem)
        self.assert_ok(result)
        for key in (self.RELEASE, self.POINTER):
            self.assertEqual(len(self.signers(key)), 2)
            self.assertIn(key_id, self.signers(key))
        self.assertNotIn("CMUX_LINUX_RELEASE_SIGNING_KEY is not set", result.stdout)

    def test_a_commit_only_release_file_is_dual_signed_too(self):
        self.only_linux_release()
        pem, key_id = self.release_key(listed=True)
        self.assert_ok(self.point(self.payload(), "--commit-only", release_key=pem))
        self.assertIn(key_id, self.signers(self.RELEASE))
        self.assertEqual(len(self.signers(self.RELEASE)), 2)
        self.assertIsNone(self.served(self.POINTER))

    def test_an_unlisted_release_key_is_skipped_with_a_warning(self):
        self.only_linux_release()
        pem, key_id = self.release_key(listed=False)
        result = self.point(self.payload(), release_key=pem)
        self.assert_ok(result)
        self.assertIn("extra signing key skipped", result.stdout + result.stderr)
        self.assertNotIn(key_id, self.signers(self.POINTER))
        self.assertEqual(len(self.signers(self.POINTER)), 1)

    def test_no_release_key_signs_with_the_web_update_key_and_warns(self):
        self.only_linux_release()
        result = self.point(self.payload(), release_key="")
        self.assert_ok(result)
        self.assertIn("CMUX_LINUX_RELEASE_SIGNING_KEY is not set", result.stdout)
        self.assertEqual(len(self.signers(self.POINTER)), 1)

    def test_a_retry_after_the_release_file_gives_the_channel_that_file(self):
        # The first run wrote the per-commit file and stopped before the channel; the retry signs another
        # sequence (and so another version). The channel must name the version the commit's file holds.
        if type(self) is not LinuxReleasePoint:
            self.skipTest("a Linux release file's sequence")
        self.assert_ok(self.point(self.payload(sequence=20261109080000)))
        first = self.served(self.RELEASE)
        (self.r2 / self.POINTER).unlink()
        result = self.point(self.payload(published_at=1794209999, sequence=20261109090000), run_id="2")
        self.assert_ok(result)
        self.assertEqual(self.served(self.RELEASE), first)
        self.assertEqual(self.served(self.POINTER), first)
        self.assertEqual(self.verified(self.POINTER)["sequence"], 20261109080000)

    NIGHTLY = "cmux-tui/channels/linux-nightly.json"

    def follow(self, commit, *, min_sequence=None, run_id="9"):
        """cmux-linux-nightly-channel.yml: repoint the commit's published release.json at linux-nightly."""
        release = self.r2 / f"cmux-tui/{commit}/release.json"
        if min_sequence is None:
            min_sequence = (self.verified(self.NIGHTLY)["sequence"] + 1) if self.served(self.NIGHTLY) else 0
        out = self.tmp / f"nightly-{len(list(self.tmp.iterdir()))}.json"
        made = subprocess.run([sys.executable, str(ROOT / "scripts/ci/cmux-machine-channel.py"), "repoint",
                               "--release", str(release), "--keys", str(self.repo / KEYS_PATH), "--channel",
                               "nightly", "--commit", commit, "--min-sequence", str(min_sequence), "--out", str(out)],
                              text=True, capture_output=True)
        if made.returncode != 0:
            return made
        return self.point(out, "--channel-only", run_id=run_id)

    def test_the_nightly_channel_follows_a_published_build_and_never_rewrites_its_files(self):
        self.only_linux_release()
        self.assert_ok(self.point(self.payload()))
        release, feat = self.served(self.RELEASE), self.served(self.POINTER)
        self.assert_ok(self.follow(RELEASE_COMMIT))
        self.assertEqual(self.served(self.RELEASE), release)
        self.assertEqual(self.served(self.POINTER), feat)
        nightly = self.verified(self.NIGHTLY, "nightly", "cmux-linux-release")
        build = self.verified(self.RELEASE, None, "cmux-linux-release", False)
        self.assertEqual(nightly["commit"], RELEASE_COMMIT)
        self.assertEqual(nightly["targets"], build["targets"])
        self.assertEqual(nightly["committed_at"], build["committed_at"])
        self.assertTrue(nightly["version"].endswith(f"{nightly['sequence']}.{RELEASE_COMMIT[:12]}"))
        # The same commit again: kept, so no installer updates to the same build.
        before = self.served(self.NIGHTLY)
        result = self.follow(RELEASE_COMMIT, run_id="10")
        self.assert_ok(result)
        self.assertIn("names cccccccccccc already", result.stderr)
        self.assertEqual(self.served(self.NIGHTLY), before)

    def test_the_nightly_channel_moves_back_with_a_nightly_rollback_and_its_sequence_still_rises(self):
        self.only_linux_release()
        newer = "e" * 40
        self.assert_ok(self.point(self.payload()))
        self.assert_ok(self.point(self.payload(commit=newer, committed_at=COMMITTED_AT + 60), run_id="2"))
        self.assert_ok(self.follow(newer))
        first = self.verified(self.NIGHTLY)["sequence"]
        self.assert_ok(self.follow(RELEASE_COMMIT, run_id="11"))
        value = self.verified(self.NIGHTLY, "nightly", "cmux-linux-release")
        self.assertEqual(value["commit"], RELEASE_COMMIT)
        self.assertGreater(value["sequence"], first)

    def test_the_nightly_channel_needs_a_published_signed_build(self):
        self.only_linux_release()
        missing = self.follow(RELEASE_COMMIT)
        self.assertNotEqual(missing.returncode, 0)
        self.assertIsNone(self.served(self.NIGHTLY))
        # An unsigned release.json (a bucket writer) never gets signed for the channel.
        path = self.r2 / self.RELEASE
        path.parent.mkdir(parents=True)
        path.write_bytes(self.payload().read_bytes())
        forged = self.follow(RELEASE_COMMIT)
        self.assertNotEqual(forged.returncode, 0)
        self.assertIn("does not verify", forged.stderr)
        self.assertIsNone(self.served(self.NIGHTLY))

    def run_follow(self, appcast_commit, run_id="20"):
        """scripts/ci/cmux-linux-nightly-follow.sh with the NIGHTLY appcast served from the fake R2."""
        for name in ("cmux-linux-nightly-follow.sh", "cmux-machine-channel.py", "screen_sharing_helper_release.py"):
            shutil.copy(ROOT / "scripts/ci" / name, self.repo / "scripts/ci/")
        for extra in ROOT.joinpath("scripts/ci").glob("nightly_version*.py"):
            shutil.copy(extra, self.repo / "scripts/ci/")
        # As Sparkle writes it: a self-closed <enclosure/> before the commit.
        item = (f'<item><title>NIGHTLY</title><enclosure url="https://files-next.cmux.com/x.dmg" length="1"/>'
                '<cmux:sourceCommit xmlns:cmux="https://cmux.com/xml-namespaces/cmux">'
                f"{appcast_commit}</cmux:sourceCommit></item>") if appcast_commit else "<item/>"
        (self.r2 / "nightly-appcast.xml").write_text(f"<rss><channel>{item}<item>"
                                                     f"<cmux:sourceCommit>{'0' * 40}</cmux:sourceCommit></item></channel></rss>")
        env = {"PATH": f"{self.bin}:{os.environ['PATH']}", "HOME": str(self.tmp), "FAKE_R2": str(self.r2),
               "FAKE_UPLOAD_LOG": str(self.tmp / "uploads.log"), "SIGNING_KEY": self.pem,
               "R2_ENDPOINT": "https://r2.invalid", "GITHUB_RUN_ID": run_id,
               "NIGHTLY_APPCAST": "https://files.cmux.com/nightly-appcast.xml"}
        return subprocess.run(["bash", "scripts/ci/cmux-linux-nightly-follow.sh", str(self.tmp / f"follow-{run_id}")],
                              cwd=self.repo, env=env, text=True, capture_output=True)

    def run_sign(self, *mode, run_id="30"):
        """scripts/ci/linux-release-sign.sh for RELEASE_COMMIT against the fake R2 (no gh: a run that finds
        the commit's file published never downloads its build)."""
        shutil.copy(ROOT / "scripts/ci/linux-release-sign.sh", self.repo / "scripts/ci/")
        env = {"PATH": f"{self.bin}:{os.environ['PATH']}", "HOME": str(self.tmp), "FAKE_R2": str(self.r2),
               "FAKE_UPLOAD_LOG": str(self.tmp / "uploads.log"), "SIGNING_KEY": self.pem,
               "R2_ENDPOINT": "https://r2.invalid", "GITHUB_RUN_ID": run_id, "GITHUB_SHA": RELEASE_COMMIT,
               "GITHUB_REPOSITORY": "manaflow-ai/cmux", "GH_TOKEN": "unused"}
        return subprocess.run(["bash", "scripts/ci/linux-release-sign.sh", str(self.tmp / f"sign-{run_id}"),
                               "feat-cmux-next", *mode], cwd=self.repo, env=env, text=True, capture_output=True)

    def test_a_published_release_file_is_kept_and_moves_the_channel(self):
        # sign-nightly-linux-release wrote the commit's file (--commit-only); point-machine-channel's run
        # of the same commit keeps it and moves linux-feat-cmux-next to its bytes, with no second build.
        self.only_linux_release()
        self.assert_ok(self.point(self.payload(), "--commit-only"))
        first = self.served(self.RELEASE)
        self.assertIsNone(self.served(self.POINTER))
        again = self.run_sign("--commit-only", run_id="31")
        self.assert_ok(again)
        self.assertIn("is published; keeping it", again.stdout)
        self.assertIsNone(self.served(self.POINTER))
        result = self.run_sign(run_id="32")
        self.assert_ok(result)
        self.assertEqual(self.served(self.RELEASE), first)
        self.assertEqual(self.served(self.POINTER), first)

    def test_the_follow_script_points_linux_nightly_at_the_nightlys_first_commit(self):
        self.only_linux_release()
        self.assert_ok(self.point(self.payload()))
        result = self.run_follow(RELEASE_COMMIT)
        self.assert_ok(result)
        self.assertEqual(self.verified(self.NIGHTLY, "nightly", "cmux-linux-release")["commit"], RELEASE_COMMIT)

    def test_the_follow_script_keeps_the_channel_without_a_signed_build_or_a_commit(self):
        self.only_linux_release()
        for commit, text in ((RELEASE_COMMIT, "has no signed Linux build"), (None, "names no source commit")):
            result = self.run_follow(commit)
            self.assert_ok(result)
            self.assertIn(text, result.stdout)
            self.assertIsNone(self.served(self.NIGHTLY))

    def test_channel_only_is_for_a_linux_release(self):
        self.only_linux_release()
        result = self.point(self.payload(purpose="cmux-cloud-machine-update"), "--channel-only")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--channel-only is for a Linux release channel", result.stdout)

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


MAC_COMMIT = "d" * 40


class MacLivePayload(unittest.TestCase):
    """--purpose mac-live: cmux-tui/<sha>/mac-live.json, the file `cmux app try SHA` takes live, and its channel."""

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.served = self.tmp / "served"
        self.served.mkdir()
        binaries = {}
        # Every darwin daemon binary but the browser host, plus two the app's bin/ does not take from here.
        for name in [n for n in channel.MAC_LIVE_NAMES if n != "cmux-tui-browser-host"] + ["cmux-tui-acpmux",
                                                                                          "cmux-tui-hook"]:
            published = f"{name}-aarch64-apple-darwin"
            data = f"{published} bytes".encode()
            (self.served / published).write_bytes(data)
            binaries[published] = hashlib.sha256(data).hexdigest()
        self.manifest = self.tmp / "manifest.json"
        self.manifest.write_text(json.dumps({"commit": MAC_COMMIT, "binaries": binaries}))
        self.live = self.tmp / "live-from.json"
        self.live.write_text(json.dumps({"sha": MAC_COMMIT, "live_from": [MAC_COMMIT, "e" * 40], "floor": "e" * 40}))

    def download(self, argv, check):
        url, out = argv[-1], argv[argv.index("-o") + 1]
        self.assertTrue(url.startswith(f"{channel.FILES}/{MAC_COMMIT}/"), url)
        shutil.copyfile(self.served / url.split("/")[-1].split("?")[0], out)

    def run_payload(self, *extra):
        out = self.tmp / "payload.json"
        argv = ["cmux-machine-channel.py", "payload", "--purpose", "mac-live", "--manifest", str(self.manifest),
                "--live-from", str(self.live), "--commit", MAC_COMMIT, "--committed-at", str(COMMITTED_AT),
                "--download-dir", str(self.tmp / "dl"), "--out", str(out), *extra]
        with mock.patch.object(channel.subprocess, "run", side_effect=self.download):
            channel.main(argv)
        return json.loads(out.read_text())

    def test_the_payload_names_the_bin_files_app_try_places_and_live_from(self):
        value = self.run_payload()
        self.assertEqual((value["purpose"], value["channel"], value["commit"]),
                         ("cmux-mac-live-update", "nightly-live", MAC_COMMIT))
        self.assertEqual(value["live_from"], [MAC_COMMIT, "e" * 40])
        files = value["targets"]["aarch64-apple-darwin"]
        # acpmux and the hook are not the app's bin/ files; a companion the build lacks is left out.
        self.assertEqual(sorted(files), sorted(n for n in channel.MAC_LIVE_NAMES if n != "cmux-tui-browser-host"))
        self.assertEqual(files["cmux-tui"]["url"], f"{channel.FILES}/{MAC_COMMIT}/cmux-tui-aarch64-apple-darwin")
        self.assertEqual(files["cmux-tui"]["size"], len(b"cmux-tui-aarch64-apple-darwin bytes"))

    def test_daemon_from_is_signed_beside_live_from(self):
        # The nightly-live channel follows daemon_from: app commits past the whole-app floor whose daemon ABI
        # still matches. A live-from file without it (an older hot-apply.py) signs live_from alone.
        self.assertNotIn("daemon_from", self.run_payload())
        self.live.write_text(json.dumps({"live_from": [MAC_COMMIT, "e" * 40],
                                         "daemon_from": [MAC_COMMIT, "e" * 40, "f" * 40]}))
        value = self.run_payload()
        self.assertEqual((value["live_from"], value["daemon_from"]),
                         ([MAC_COMMIT, "e" * 40], [MAC_COMMIT, "e" * 40, "f" * 40]))

    def test_daemon_from_refusals(self):
        for daemon in (["f" * 40], [MAC_COMMIT, "f" * 40], [MAC_COMMIT, "e" * 40, "short"],
                       [MAC_COMMIT, "e" * 40] + ["%040x" % i for i in range(399)], "nope"):
            self.live.write_text(json.dumps({"live_from": [MAC_COMMIT, "e" * 40], "daemon_from": daemon}))
            with self.subTest(daemon=str(daemon)[:60]), self.assertRaises(SystemExit):
                self.run_payload()

    def test_the_tree_key_is_named_for_the_team_signed_set(self):
        # A Team-signed NIGHTLY's daemon updater takes cmux-tui/tree/<key>/team-signed/, bound to these bytes by
        # each file's unsigned_sha256; the payload's urls stay the commit's ad-hoc files every older CLI reads.
        self.assertNotIn("tree_key", self.run_payload())
        value = self.run_payload("--tree-key", "c" * 40)
        self.assertEqual(value["tree_key"], "c" * 40)
        self.assertEqual(value["targets"]["aarch64-apple-darwin"]["cmux-tui"]["url"],
                         f"{channel.FILES}/{MAC_COMMIT}/cmux-tui-aarch64-apple-darwin")
        for bad in ("C" * 40, "c" * 39, "nope"):
            with self.subTest(bad=bad), self.assertRaises(SystemExit):
                self.run_payload("--tree-key", bad)

    def test_refusals(self):
        (self.served / "cmux-tui-host-aarch64-apple-darwin").write_bytes(b"other bytes")
        with self.assertRaises(SystemExit):
            self.run_payload()  # served bytes that differ from the manifest
        (self.served / "cmux-tui-host-aarch64-apple-darwin").write_bytes(b"cmux-tui-host-aarch64-apple-darwin bytes")
        for live in ({"live_from": ["e" * 40]}, {"live_from": [MAC_COMMIT, "short"]},
                     {"live_from": [MAC_COMMIT] * 2}, {"live_from": [MAC_COMMIT] + ["%040x" % i for i in range(400)]}):
            self.live.write_text(json.dumps(live))
            with self.subTest(live=str(live)[:60]), self.assertRaises(SystemExit):
                self.run_payload()
        self.live.write_text(json.dumps({"live_from": [MAC_COMMIT]}))
        with self.assertRaises(SystemExit):
            self.run_payload("--machine-path")

    def helper_record(self, **change):
        data = b"the signed helper's zip"
        (self.served / release.ZIP).write_bytes(data)
        value = {"schema": 1, "key": "c" * 16, "commit": "f" * 40, "zip": release.ZIP,
                 "sha256": hashlib.sha256(data).hexdigest(), "size": len(data), "bundle_id": release.BUNDLE_ID,
                 "team": release.TEAM, "designated_requirement": release.requirement(release.BUNDLE_ID, release.TEAM)}
        value.update(change)
        path = self.tmp / "helper.json"
        path.write_text(json.dumps(value))
        return path, value

    def test_without_a_helper_record_the_payload_has_no_helper_key(self):
        # The old CI's shape, which every CLI reads: no top-level helper key, `targets` unchanged.
        value = self.run_payload()
        self.assertNotIn(channel.MAC_LIVE_HELPER_KEY, value)
        self.assertEqual(list(value["targets"]), ["aarch64-apple-darwin"])

    def test_the_helper_goes_under_a_new_top_level_key_never_in_targets(self):
        path, record = self.helper_record()
        value = self.run_payload("--screen-sharing-helper", str(path))
        helper = value[channel.MAC_LIVE_HELPER_KEY]
        self.assertEqual(helper, {
            "url": f"{channel.FILES}/{MAC_COMMIT}/{release.ZIP}", "sha256": record["sha256"],
            "size": record["size"], "bundle_id": "com.cmuxterm.app.nightly.screen-sharing", "team": "7WLXT3NR37",
            # ss-host-helper's ask (a): the Developer ID intermediate and leaf clauses, byte for byte.
            "designated_requirement": 'identifier "com.cmuxterm.app.nightly.screen-sharing" and anchor apple '
                                      "generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and "
                                      "certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and "
                                      'certificate leaf[subject.OU] = "7WLXT3NR37"'})
        # `targets` holds only the bin/ names an installed CLI knows (live.rs FILES): nothing new there.
        self.assertEqual(set(value["targets"]["aarch64-apple-darwin"]) - set(channel.MAC_LIVE_NAMES), set())

    def test_a_helper_record_that_is_not_the_nightlys_identity_or_bytes_is_refused(self):
        short = 'identifier "com.cmuxterm.app.nightly.screen-sharing" and anchor apple generic and ' \
                'certificate leaf[subject.OU] = "7WLXT3NR37"'
        for change in ({"designated_requirement": short}, {"team": "ABCDEFGHIJ"},
                       {"bundle_id": "com.cmuxterm.cua"}, {"sha256": "0" * 64}, {"size": 3}):
            path, _ = self.helper_record(**change)
            with self.subTest(change=change), self.assertRaises(SystemExit):
                self.run_payload("--screen-sharing-helper", str(path))


TREE_KEY = "e" * 40


class LinuxReleaseTree(unittest.TestCase):
    """A payload naming a tree_key: cmux-machine-channel-point.sh writes tree/<key>/release.json once, then the
    commit's file, then the channel; `alias` retells a verified tree file for another commit of the tree."""

    setUp, point, served, verified, assert_ok = (LinuxReleasePoint.setUp, LinuxReleasePoint.point,
                                                 LinuxReleasePoint.served, LinuxReleasePoint.verified,
                                                 LinuxReleasePoint.assert_ok)
    TREE = f"cmux-tui/tree/{TREE_KEY}/release.json"
    POINTER = LinuxReleasePoint.POINTER

    def tree_payload(self, commit=RELEASE_COMMIT, committed_at=COMMITTED_AT, sequence=20261122110500, sha="d" * 64):
        value = {"schema": 1, "purpose": "cmux-linux-release", "channel": "feat-cmux-next",
                 "version": f"1.0.0+{sequence}.{commit[:12]}", "sequence": sequence, "commit": commit,
                 "committed_at": committed_at, "tree_key": TREE_KEY, "published_at": int(time.time()),
                 "expires_at": int(time.time()) + 86400,
                 "targets": {target: {n: {"url": f"https://files.cmux.com/cmux-tui/tree/{TREE_KEY}/{n}-{target}",
                                          "sha256": sha, "size": 5} for n in channel.NAMES}
                             for target in channel.LINUX_RELEASE_TARGETS}}
        path = self.tmp / f"payload-{len(list(self.tmp.iterdir()))}.json"
        path.write_bytes(json.dumps(value, sort_keys=True, separators=(",", ":")).encode())
        return path

    def alias(self, commit, committed_at, tree_key=TREE_KEY, tree_release=None, min_sequence=0):
        out = self.tmp / f"alias-{len(list(self.tmp.iterdir()))}.json"
        channel.main(["cmux-machine-channel.py", "alias", "--tree-release", str(tree_release or self.r2 / self.TREE),
                      "--keys", str(self.repo / KEYS_PATH), "--tree-key", tree_key, "--channel", "feat-cmux-next",
                      "--commit", commit, "--committed-at", str(committed_at), "--out", str(out),
                      "--min-sequence", str(min_sequence)])
        return out

    def test_the_tree_run_writes_the_tree_file_the_commit_file_and_the_channel(self):
        result = self.point(self.tree_payload())
        self.assert_ok(result)
        signed = self.served(self.TREE)
        self.assertIsNotNone(signed)
        self.assertEqual(self.served(f"cmux-tui/{RELEASE_COMMIT}/release.json"), signed)
        self.assertEqual(self.served(self.POINTER), signed)
        value = self.verified(self.POINTER, "feat-cmux-next", "cmux-linux-release")
        self.assertEqual(value["tree_key"], TREE_KEY)  # the signed channel names the tree
        # The tree file is written before the commit's file and the channel.
        log = (self.tmp / "uploads.log").read_text().split()
        self.assertLess(log.index(self.TREE), log.index(f"cmux-tui/{RELEASE_COMMIT}/release.json"))
        self.assertLess(log.index(self.TREE), log.index(self.POINTER))

    def test_another_build_of_the_tree_keeps_the_tree_file_and_fails_loud(self):
        self.assert_ok(self.point(self.tree_payload()))
        first = self.served(self.TREE)
        result = self.point(self.tree_payload(commit="f" * 40, committed_at=COMMITTED_AT + 60,
                                              sequence=20261122110600, sha="f" * 64), run_id="2")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.served(self.TREE), first)
        self.assertIsNone(self.served(f"cmux-tui/{'f' * 40}/release.json"))

    def test_an_alias_keeps_the_tree_file_and_signs_the_commits_own(self):
        self.assert_ok(self.point(self.tree_payload()))
        tree = self.served(self.TREE)
        other = "f" * 40
        with mock.patch.object(channel.time, "time", return_value=PUBLISHED_AT + 120):
            payload = self.alias(other, COMMITTED_AT + 60, min_sequence=20261122110501)
        value = json.loads(payload.read_bytes())
        source = self.verified(self.TREE, "feat-cmux-next", "cmux-linux-release", False)
        self.assertEqual((value["commit"], value["committed_at"], value["tree_key"]), (other, COMMITTED_AT + 60, TREE_KEY))
        self.assertEqual(value["targets"], source["targets"])
        self.assertEqual(value["sequence"], 20261122110700)
        self.assertEqual(value["version"], "1.0.0+20261122110700.ffffffffffff")
        self.assertEqual(value["expires_at"] - value["published_at"], 30 * 24 * 3600)
        self.assert_ok(self.point(payload, run_id="2"))
        self.assertEqual(self.served(self.TREE), tree)  # the tree file is kept: same tree, same targets
        mine = self.served(f"cmux-tui/{other}/release.json")
        self.assertNotEqual(mine, tree)
        self.assertEqual(self.verified(f"cmux-tui/{other}/release.json", None, "cmux-linux-release", False)["commit"], other)
        self.assertEqual(self.served(self.POINTER), mine)  # a later commit of the tree moves the channel

    def test_alias_refusals(self):
        self.assert_ok(self.point(self.tree_payload()))
        tampered = self.tmp / "tampered.json"
        envelope = json.loads(self.served(self.TREE))
        body = json.loads(base64.b64decode(envelope["payload"]))
        body["targets"]["x86_64-unknown-linux-gnu"]["cmux-tui"]["sha256"] = "0" * 64
        envelope["payload"] = base64.b64encode(json.dumps(body, sort_keys=True, separators=(",", ":")).encode()).decode()
        tampered.write_text(json.dumps(envelope))
        cases = [({"tree_key": "a" * 40}, "release file of tree"),
                 ({"tree_release": tampered}, "does not verify"),
                 ({"tree_key": "E" * 40}, "bad tree key"),
                 ({"commit": "xyz"}, "bad commit")]
        for change, message in cases:
            kwargs = {"commit": "f" * 40, "committed_at": COMMITTED_AT + 60, **change}
            with self.subTest(change=change), self.assertRaises(SystemExit), \
                    contextlib.redirect_stderr(io.StringIO()) as err:
                self.alias(**kwargs)
            self.assertIn(message, err.getvalue())


class CloudMachineRollback(unittest.TestCase):
    """`rollback` (cloud-machine-channel-journey.yml machine-channel-settle): a regressed build's channel moves back to the
    last proven build, its commit and URLs, past the regressed build's commit time, so the forward-only channel
    and the machines' updaters take it; the regressed commit's later (fat) point then finds the channel newer."""

    setUp, point, served, verified, assert_ok = (LinuxReleasePoint.setUp, LinuxReleasePoint.point,
                                                 LinuxReleasePoint.served, LinuxReleasePoint.verified,
                                                 LinuxReleasePoint.assert_ok)
    CHANNEL = "cmux-tui/channels/cloud-machine.json"

    def build(self, commit, committed_at, key):
        path = LinuxReleasePoint.payload(self, commit=commit, committed_at=committed_at,
                                         purpose="cmux-cloud-machine-update")
        value = json.loads(path.read_bytes()) | {"key": key}
        path.write_bytes(json.dumps(value, sort_keys=True, separators=(",", ":")).encode())
        return path

    def rollback(self, proven, over):
        out = self.tmp / f"rollback-{len(list(self.tmp.iterdir()))}.json"
        channel.main(["cmux-machine-channel.py", "rollback", "--proven", str(proven), "--over", str(over),
                      "--keys", str(self.repo / KEYS_PATH), "--out", str(out)])
        return out

    def test_a_regressed_build_moves_back_to_the_proven_one(self):
        good, bad = "a" * 40, "b" * 40
        self.assert_ok(self.point(self.build(good, COMMITTED_AT, "1" * 64)))
        proven = self.tmp / "proven.json"
        proven.write_bytes(self.served(self.CHANNEL))
        self.assert_ok(self.point(self.build(bad, COMMITTED_AT + 60, "2" * 64), run_id="2"))
        over = self.tmp / "over.json"
        over.write_bytes(self.served(self.CHANNEL))
        self.assert_ok(self.point(self.rollback(proven, over), run_id="3"))
        value = self.verified(self.CHANNEL, "cloud-machine", "cmux-cloud-machine-update")
        self.assertEqual((value["commit"], value["key"], value["committed_at"]), (good, "1" * 64, COMMITTED_AT + 61))
        self.assertEqual(value["targets"], json.loads(base64.b64decode(json.loads(proven.read_bytes())["payload"]))["targets"])
        # The regressed commit's fat point, later in the same run, keeps the rolled-back channel.
        self.assert_ok(self.point(self.build(bad, COMMITTED_AT + 60, "3" * 64), run_id="4"))
        self.assertEqual(self.verified(self.CHANNEL, "cloud-machine", "cmux-cloud-machine-update")["commit"], good)
        # The next push moves it forward again.
        self.assert_ok(self.point(self.build("d" * 40, COMMITTED_AT + 120, "4" * 64), run_id="5"))
        self.assertEqual(self.verified(self.CHANNEL, "cloud-machine", "cmux-cloud-machine-update")["commit"], "d" * 40)

    def test_rollback_refuses_the_build_it_replaces_and_an_unsigned_file(self):
        self.assert_ok(self.point(self.build("b" * 40, COMMITTED_AT, "2" * 64)))
        over = self.tmp / "over.json"
        over.write_bytes(self.served(self.CHANNEL))
        unsigned = self.tmp / "unsigned.json"
        unsigned.write_bytes(self.build("a" * 40, COMMITTED_AT, "1" * 64).read_bytes())
        for proven, message in ((over, "the build it would replace"), (unsigned, "does not verify")):
            with self.subTest(message=message), self.assertRaises(SystemExit), \
                    contextlib.redirect_stderr(io.StringIO()) as err:
                self.rollback(proven, over)
            self.assertIn(message, err.getvalue())


class LinuxReleaseAliases(unittest.TestCase):
    """scripts/ci/cmux-linux-release-aliases.sh (mark-tree-commits) in a git repo against a fake R2: the
    window's commits that share a signed tree and have no release file get an alias; the rest are left."""

    point, served, verified, assert_ok = (LinuxReleasePoint.point, LinuxReleasePoint.served,
                                          LinuxReleasePoint.verified, LinuxReleasePoint.assert_ok)
    tree_payload = LinuxReleaseTree.tree_payload

    def setUp(self):
        LinuxReleasePoint.setUp(self)
        for name in ("cmux-linux-release-aliases.sh", "cmux-machine-channel.py", "nightly_version.py",
                     "screen_sharing_helper_release.py"):
            shutil.copy(ROOT / "scripts/ci" / name, self.repo / "scripts/ci/")
        republish.Sandbox._exe(self.repo / "scripts/ci/cmux_tui_tree_key.py", FAKE_TREE_KEY)
        (self.repo / "scripts/cmux-next/cmux-tui-tree-inputs.txt").write_text("cmux-tui/\n")
        git = lambda *a: subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *a], cwd=self.repo,
                                         check=True, capture_output=True, text=True).stdout.strip()
        git("init", "-q")
        self.commits = []
        for n in range(4):  # oldest first; each its own commit time
            (self.repo / "n.txt").write_text(str(n))
            git("add", "-A")
            subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", str(n)],
                           cwd=self.repo, check=True, capture_output=True,
                           env={**os.environ, "GIT_COMMITTER_DATE": f"{COMMITTED_AT + 60 * n} +0000",
                                "GIT_AUTHOR_DATE": f"{COMMITTED_AT + 60 * n} +0000"})
            self.commits.append(git("rev-parse", "HEAD"))

    def walk(self, trees):
        scratch = pathlib.Path(tempfile.mkdtemp(dir=self.tmp))
        env = {"PATH": f"{self.bin}:{os.environ['PATH']}", "HOME": str(self.tmp), "FAKE_R2": str(self.r2),
               "FAKE_UPLOAD_LOG": str(self.tmp / "uploads.log"), "SIGNING_KEY": self.pem,
               "R2_ENDPOINT": "https://r2.invalid", "GITHUB_RUN_ID": "9", "FAKE_TREE_KEYS": json.dumps(trees)}
        result = subprocess.run(["bash", "scripts/ci/cmux-linux-release-aliases.sh", str(scratch), "--window", "4"],
                                cwd=self.repo, env=env, text=True, capture_output=True)
        self.assert_ok(result)
        return result.stdout

    def test_commits_of_a_signed_tree_get_an_alias_and_the_rest_are_left(self):
        c0, c1, c2, head = self.commits
        # c0 built tree T and signed it; c1 and HEAD share T (they adopted it); c2 has tree U, unsigned.
        self.assert_ok(self.point(self.tree_payload(commit=c0, committed_at=COMMITTED_AT)))
        tree = self.served(LinuxReleaseTree.TREE)
        out = self.walk({c0: TREE_KEY, c1: TREE_KEY, c2: "9" * 40, head: TREE_KEY})
        self.assertIn("1 signed", out)
        value = self.verified(f"cmux-tui/{c1}/release.json", "feat-cmux-next", "cmux-linux-release", False)
        self.assertEqual((value["commit"], value["committed_at"], value["tree_key"]), (c1, COMMITTED_AT + 60, TREE_KEY))
        self.assertEqual(self.served(LinuxReleaseTree.TREE), tree)
        self.assertEqual(self.verified(LinuxReleaseTree.POINTER)["commit"], c1)  # later than c0: the channel moves
        self.assertIsNone(self.served(f"cmux-tui/{c2}/release.json"))  # its tree has no signed release file
        self.assertIsNone(self.served(f"cmux-tui/{head}/release.json"))  # HEAD is its own run's (or the next walk's)
        # A second walk signs nothing new: every commit with a signed tree has its file.
        before = (self.tmp / "uploads.log").read_text()
        self.assertIn("0 signed", self.walk({c0: TREE_KEY, c1: TREE_KEY, c2: "9" * 40, head: TREE_KEY}))
        self.assertEqual((self.tmp / "uploads.log").read_text(), before)


class MacLivePoint(LinuxReleasePoint):
    """cmux-machine-channel-point.sh with a Mac live update payload: the per-commit file is written once, the
    channel moves forward only, and a Linux release or Cloud machine file never stands in for it."""

    RELEASE = f"cmux-tui/{RELEASE_COMMIT}/mac-live.json"
    POINTER = "cmux-tui/channels/mac-live.json"

    def payload(self, commit=RELEASE_COMMIT, committed_at=COMMITTED_AT, published_at=1794208000, sha="d" * 64,
                purpose="cmux-mac-live-update"):
        if purpose != "cmux-mac-live-update":
            return super().payload(commit, committed_at, published_at, sha, purpose)
        value = {"schema": 1, "purpose": purpose, "channel": "nightly-live", "commit": commit,
                 "committed_at": committed_at, "published_at": published_at, "expires_at": int(time.time()) + 86400,
                 "live_from": [commit],
                 "targets": {"aarch64-apple-darwin": {"cmux-tui": {
                     "url": f"https://files.cmux.com/cmux-tui/{commit}/cmux-tui-aarch64-apple-darwin",
                     "sha256": sha, "size": 5}}}}
        path = self.tmp / f"payload-{len(list(self.tmp.iterdir()))}.json"
        path.write_bytes(json.dumps(value, sort_keys=True, separators=(",", ":")).encode())
        return path

    def test_a_build_writes_its_release_file_and_moves_the_pointer(self):
        self.assert_ok(self.point(self.payload()))
        self.assertEqual(self.served(self.RELEASE), self.served(self.POINTER))
        value = self.verified(self.POINTER, "nightly-live", "cmux-mac-live-update")
        self.assertEqual((value["commit"], value["live_from"]), (RELEASE_COMMIT, [RELEASE_COMMIT]))
        self.assertIsNone(self.served(f"cmux-tui/{RELEASE_COMMIT}/release.json"))

    def test_the_pointer_only_moves_forward(self):
        newer = "e" * 40
        self.assert_ok(self.point(self.payload(commit=newer, committed_at=COMMITTED_AT + 60)))
        self.assert_ok(self.point(self.payload(), run_id="2"))
        self.assertEqual(self.verified(self.RELEASE, None, "cmux-mac-live-update", False)["commit"], RELEASE_COMMIT)
        self.assertEqual(self.verified(self.POINTER)["commit"], newer)

    def test_a_tree_key_is_signed_in_but_writes_no_tree_release_file(self):
        path = self.payload()
        value = json.loads(path.read_text())
        value["tree_key"] = "c" * 40
        path.write_bytes(json.dumps(value, sort_keys=True, separators=(",", ":")).encode())
        self.assert_ok(self.point(path))
        self.assertEqual(self.verified(self.POINTER, "nightly-live", "cmux-mac-live-update")["tree_key"], "c" * 40)
        self.assertIsNone(self.served(f"cmux-tui/tree/{'c' * 40}/release.json"))
        value["tree_key"] = "C" * 40
        path.write_bytes(json.dumps(value, sort_keys=True, separators=(",", ":")).encode())
        self.assertNotEqual(self.point(path, run_id="2").returncode, 0)

    def test_a_pr_head_writes_its_own_file_and_leaves_the_channel(self):
        # `cmux app try PR` reads cmux-tui/<head>/mac-live.json; a PR head never moves nightly-live.
        self.assert_ok(self.point(self.payload()))
        channel_before = self.served(self.POINTER)
        head = "e" * 40
        self.assert_ok(self.point(self.payload(commit=head, committed_at=COMMITTED_AT + 60), "--commit-only",
                                  run_id="2"))
        self.assertEqual(self.verified(f"cmux-tui/{head}/mac-live.json", None, "cmux-mac-live-update",
                                       False)["commit"], head)
        self.assertEqual(self.served(self.POINTER), channel_before)
        # With no channel at all, none is created.
        (self.r2 / self.POINTER).unlink()
        self.assert_ok(self.point(self.payload(commit="f" * 40), "--commit-only", run_id="3"))
        self.assertIsNone(self.served(self.POINTER))

    def test_commit_only_is_refused_without_a_per_commit_file(self):
        result = self.point(super().payload(purpose="cmux-cloud-machine-update"), "--commit-only")
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(self.served("cmux-tui/channels/cloud-machine.json"))

    def test_a_cloud_machine_file_never_stands_in_for_the_pointer(self):
        self.assert_ok(self.point(super().payload(purpose="cmux-cloud-machine-update",
                                                  committed_at=COMMITTED_AT + 600)))
        (self.r2 / self.POINTER).write_bytes(self.served("cmux-tui/channels/cloud-machine.json"))
        self.assertIsNone(self.served(self.RELEASE))
        self.assert_ok(self.point(self.payload(), run_id="2"))
        self.assertEqual(self.verified(self.POINTER)["purpose"], "cmux-mac-live-update")


class MacAppPayload(unittest.TestCase):
    """--purpose mac-app: cmux-tui/<sha>/mac-app.json, the full app build `cmux app try` installs in place."""

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.zip = self.tmp / "app.zip"
        self.zip.write_bytes(b"app zip bytes")

    def run_payload(self, **change):
        args = {"commit": MAC_COMMIT, "zip": str(self.zip), "run_id": "12345",
                "url": f"{channel.FILES}/{MAC_COMMIT}/mac-app-release.zip", **change}
        out = self.tmp / "payload.json"
        argv = ["cmux-machine-channel.py", "payload", "--purpose", "mac-app", "--out", str(out)]
        for key, value in args.items():
            argv += [f"--{key.replace('_', '-')}", value]
        channel.main(argv)
        return out.read_bytes()

    def test_the_payload_is_the_contract_the_installer_reads(self):
        raw = self.run_payload()
        self.assertEqual(json.loads(raw), {
            "schema": 1, "purpose": "cmux-mac-app-build", "commit": MAC_COMMIT, "configuration": "release",
            "arch": "arm64", "run_id": "12345",
            "app": {"url": f"https://files.cmux.com/cmux-tui/{MAC_COMMIT}/mac-app-release.zip",
                    "sha256": hashlib.sha256(b"app zip bytes").hexdigest(), "size": len(b"app zip bytes")}})
        self.assertEqual(raw, self.run_payload())  # no time field: two signings of a build are the same bytes

    def test_refusals(self):
        cases = [({"commit": "abc"}, "bad commit"), ({"run_id": "x1"}, "bad run id"),
                 ({"url": "https://files.cmux.com/cmux-tui/other/mac-app-release.zip"}, "--url must be"),
                 ({"zip": str(self.tmp / "missing.zip")}, "is not a file")]
        for change, message in cases:
            with self.subTest(change=change), self.assertRaises(SystemExit), \
                    contextlib.redirect_stderr(io.StringIO()) as err:
                self.run_payload(**change)
            self.assertIn(message, err.getvalue())
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()) as err:
            channel.main(["cmux-machine-channel.py", "payload", "--purpose", "mac-app", "--commit", MAC_COMMIT,
                          "--out", str(self.tmp / "p.json")])
        self.assertIn("needs --zip", err.getvalue())

    def test_the_other_purposes_refuse_the_mac_app_flags(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()) as err:
            channel.main(["cmux-machine-channel.py", "payload", "--manifest", "m.json", "--commit", MAC_COMMIT,
                          "--committed-at", "1", "--download-dir", str(self.tmp), "--zip", "z", "--out", "o"])
        self.assertIn("for --purpose mac-app", err.getvalue())


class MacAppPoint(unittest.TestCase):
    """cmux-machine-channel-point.sh with a Mac app build payload: its file is written once and no channel
    is ever created or moved, with or without --commit-only."""

    setUp, point, served, verified, assert_ok = (LinuxReleasePoint.setUp, LinuxReleasePoint.point,
                                                 LinuxReleasePoint.served, LinuxReleasePoint.verified,
                                                 LinuxReleasePoint.assert_ok)
    RELEASE = f"cmux-tui/{RELEASE_COMMIT}/mac-app.json"

    def payload(self, commit=RELEASE_COMMIT, sha="d" * 64, purpose="cmux-mac-app-build", run_id="1"):
        value = {"schema": 1, "purpose": purpose, "commit": commit, "configuration": "release", "arch": "arm64",
                 "app": {"url": f"https://files.cmux.com/cmux-tui/{commit}/mac-app-release.zip",
                         "sha256": sha, "size": 5}, "run_id": run_id}
        path = self.tmp / f"payload-{len(list(self.tmp.iterdir()))}.json"
        path.write_bytes(json.dumps(value, sort_keys=True, separators=(",", ":")).encode())
        return path

    def test_a_build_writes_its_file_once_and_no_channel(self):
        self.assert_ok(self.point(self.payload()))
        value = self.verified(self.RELEASE, None, "cmux-mac-app-build", False)
        self.assertEqual((value["commit"], value["arch"], value["configuration"]), (RELEASE_COMMIT, "arm64", "release"))
        for mode in ("--commit-only", None):
            with self.subTest(mode=mode):
                head = "e" * 40 if mode else "f" * 40
                self.assert_ok(self.point(self.payload(commit=head), *([mode] if mode else []), run_id="2"))
                self.assertEqual(self.verified(f"cmux-tui/{head}/mac-app.json", None, "cmux-mac-app-build",
                                               False)["commit"], head)
        self.assertEqual(sorted(p.name for p in (self.r2 / "cmux-tui").iterdir()),
                         sorted([RELEASE_COMMIT, "e" * 40, "f" * 40]))  # no channels/ directory

    def test_a_rerun_of_the_same_build_keeps_the_file_and_another_build_fails(self):
        self.assert_ok(self.point(self.payload()))
        before = self.served(self.RELEASE)
        self.assert_ok(self.point(self.payload(), run_id="2"))
        self.assertEqual(self.served(self.RELEASE), before)
        result = self.point(self.payload(sha="e" * 64), run_id="3")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.served(self.RELEASE), before)


# Stands in for scripts/ci/cmux_tui_tree_key.py: FAKE_TREE_KEYS maps a commit to its v2 tree key; a
# commit it lacks fails, as the real script does for a commit the checkout cannot read.
FAKE_TREE_KEY = r'''#!/usr/bin/env python3
import json, os, sys
assert sys.argv[1:2] == ["--version"] and sys.argv[2] == "v2", sys.argv
keys = json.loads(os.environ.get("FAKE_TREE_KEYS", "{}"))
if sys.argv[3] not in keys:
    sys.exit(1)
print(keys[sys.argv[3]])
'''

TREE_T, TREE_U = "1" * 40, "2" * 40
THIN, FAT, OTHER = "a1" * 32, "f1" * 32, "c1" * 32  # payload keys: a sha256 over the binaries


class CloudMachinePoint(unittest.TestCase):
    """point-machine-channel-early then point-machine-channel (cmux-tui-artifacts.yml) against a fake R2:
    the Cloud machine channel moves once per source tree. Commit B builds tree T: the early job points
    at its thin build, and the fat build of the same commit keeps it. Commit C adopts B's tree T (it
    built nothing): the channel stays on B, the same code, where before it moved to C's fat bytes and
    every machine updated to identical code. Commit D has tree U: the channel moves."""

    B, C, D = "b" * 40, "c" * 40, "d" * 40
    CHANNEL = "cmux-tui/channels/cloud-machine.json"

    def setUp(self):
        LinuxReleasePoint.setUp(self)
        republish.Sandbox._exe(self.repo / "scripts/ci/cmux_tui_tree_key.py", FAKE_TREE_KEY)
        self.trees = {self.B: TREE_T, self.C: TREE_T, self.D: TREE_U}

    served = LinuxReleasePoint.served
    verified = LinuxReleasePoint.verified
    assert_ok = LinuxReleasePoint.assert_ok

    def payload(self, commit, committed_at, key, expires_in=30 * 86400):
        value = {"schema": 1, "purpose": "cmux-cloud-machine-update", "channel": "cloud-machine", "key": key,
                 "commit": commit, "committed_at": committed_at, "published_at": committed_at + 60,
                 "expires_at": int(time.time()) + expires_in,
                 "targets": {t: {n: {"url": f"https://files.cmux.com/cmux-tui/{commit}/{n}-{t}", "sha256": key,
                                     "size": 5} for n in channel.NAMES} for t in channel.TARGETS}}
        path = self.tmp / f"payload-{len(list(self.tmp.iterdir()))}.json"
        path.write_bytes(json.dumps(value, sort_keys=True, separators=(",", ":")).encode())
        return path

    def point(self, payload, *extra, run_id="1"):
        scratch = pathlib.Path(tempfile.mkdtemp(dir=self.tmp))
        env = {"PATH": f"{self.bin}:{os.environ['PATH']}", "HOME": str(self.tmp), "FAKE_R2": str(self.r2),
               "FAKE_UPLOAD_LOG": str(self.tmp / "uploads.log"), "SIGNING_KEY": self.pem,
               "R2_ENDPOINT": "https://r2.invalid", "GITHUB_RUN_ID": run_id,
               "FAKE_TREE_KEYS": json.dumps(self.trees)}
        result = subprocess.run(["bash", "scripts/ci/cmux-machine-channel-point.sh", str(payload), str(scratch),
                                 *extra], cwd=self.repo, env=env, text=True, capture_output=True)
        self.assert_ok(result)
        return result

    def moves(self):
        log = self.tmp / "uploads.log"
        return log.read_text().split().count(self.CHANNEL) if log.exists() else 0

    def published(self):
        value = self.verified(self.CHANNEL, "cloud-machine", "cmux-cloud-machine-update")
        return value["commit"], value["key"]

    def early_then_fat(self):
        self.point(self.payload(self.B, COMMITTED_AT, THIN))  # point-machine-channel-early
        self.point(self.payload(self.B, COMMITTED_AT, FAT), "--same-tree", run_id="2")  # point-machine-channel

    def test_thin_then_fat_of_the_same_commit_moves_the_channel_once(self):
        self.early_then_fat()
        self.assertEqual((self.moves(), self.published()), (1, (self.B, THIN)))

    def test_the_fat_build_of_the_same_commit_is_kept_by_its_tree_not_its_commit_time(self):
        # A commit has one tree key: the fat move keeps the thin channel even if the commit times
        # were to differ (ordering by commit time alone kept it only because they are equal).
        self.point(self.payload(self.B, COMMITTED_AT, THIN))
        result = self.point(self.payload(self.B, COMMITTED_AT + 1, FAT), "--same-tree", run_id="2")
        self.assertIn("has the same tree", result.stderr)
        self.assertEqual((self.moves(), self.published()), (1, (self.B, THIN)))

    def test_an_adopted_tree_with_the_same_tree_key_keeps_the_channel(self):
        self.early_then_fat()
        result = self.point(self.payload(self.C, COMMITTED_AT + 60, FAT), "--same-tree", run_id="3")
        self.assertIn("has the same tree", result.stderr)
        self.assertEqual((self.moves(), self.published()), (1, (self.B, THIN)))

    def test_a_different_tree_key_moves_the_channel(self):
        self.early_then_fat()
        self.point(self.payload(self.C, COMMITTED_AT + 60, FAT), "--same-tree", run_id="3")
        self.point(self.payload(self.D, COMMITTED_AT + 120, OTHER), "--same-tree", run_id="4")
        self.assertEqual((self.moves(), self.published()), (2, (self.D, OTHER)))

    def test_a_same_tree_file_close_to_expiry_is_re_signed(self):
        self.point(self.payload(self.B, COMMITTED_AT, THIN, expires_in=86400))
        self.point(self.payload(self.C, COMMITTED_AT + 60, FAT), "--same-tree", run_id="2")
        self.assertEqual((self.moves(), self.published()), (2, (self.C, FAT)))

    def test_an_unknown_tree_key_moves_by_commit_time_as_before(self):
        self.point(self.payload(self.B, COMMITTED_AT, THIN))
        del self.trees[self.B]  # the published commit cannot be read (and git fetch has no origin here)
        result = self.point(self.payload(self.C, COMMITTED_AT + 60, FAT), "--same-tree", run_id="2")
        self.assertIn("no tree key for the published", result.stdout)
        self.assertEqual((self.moves(), self.published()), (2, (self.C, FAT)))

    def test_without_same_tree_an_adopted_tree_moves_as_before(self):
        self.point(self.payload(self.B, COMMITTED_AT, THIN))
        self.point(self.payload(self.C, COMMITTED_AT + 60, FAT), run_id="2")
        self.assertEqual((self.moves(), self.published()), (2, (self.C, FAT)))

    def test_same_tree_is_only_for_the_cloud_machine_channel(self):
        payload = LinuxReleasePoint.payload(self)
        scratch = pathlib.Path(tempfile.mkdtemp(dir=self.tmp))
        env = {"PATH": f"{self.bin}:{os.environ['PATH']}", "SIGNING_KEY": self.pem}
        result = subprocess.run(["bash", "scripts/ci/cmux-machine-channel-point.sh", str(payload), str(scratch),
                                 "--same-tree"], cwd=self.repo, env=env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--same-tree is for the Cloud machine channel", result.stdout)


if __name__ == "__main__":
    unittest.main()
