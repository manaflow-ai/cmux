#!/usr/bin/env python3
"""Exercise the real release producer, checksums, and native SSH hello protocol."""

import hashlib
import json
import platform
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
TARGETS = {("darwin", "arm64"), ("darwin", "amd64"),
           ("linux", "arm64"), ("linux", "amd64")}


class RemoteDaemonReleaseTests(unittest.TestCase):
    def test_stable_nightly_and_rc_release_artifacts(self):
        for channel, suffix in (("stable", ""), ("nightly", "12345601"), ("rc", "12345602")):
            with self.subTest(channel=channel), tempfile.TemporaryDirectory() as directory:
                output = Path(directory)
                version = "0.64.25" + (f"-{channel}.{suffix}" if suffix else "")
                tag = channel if suffix else "v0.64.25"
                args = [str(ROOT / "scripts/build_remote_daemon_release_assets.sh"),
                        "--version", version, "--release-tag", tag,
                        "--repo", "manaflow-ai/cmux", "--output-dir", directory]
                if suffix:
                    args += ["--asset-suffix", suffix]
                subprocess.run(args, check=True)
                ending = f"-{suffix}" if suffix else ""
                manifest = json.loads((output / f"cmuxd-remote-manifest{ending}.json").read_text())
                self.assertEqual(manifest["appVersion"], version)
                self.assertEqual(manifest["releaseTag"], tag)
                self.assertEqual(manifest["schemaVersion"], 1)
                self.assertEqual(len(manifest["entries"]), len(TARGETS))
                self.assertEqual({(e["goOS"], e["goArch"]) for e in manifest["entries"]}, TARGETS)
                base_url = f"https://github.com/manaflow-ai/cmux/releases/download/{tag}"
                self.assertEqual(manifest["releaseURL"], base_url)
                checksum_name = f"cmuxd-remote-checksums{ending}.txt"
                self.assertEqual(manifest["checksumsAssetName"], checksum_name)
                self.assertEqual(manifest["checksumsURL"], f"{base_url}/{checksum_name}")
                checksums = dict(line.split()[::-1] for line in (output / checksum_name).read_text().splitlines())
                self.assertEqual(len(checksums), len(TARGETS))
                for entry in manifest["entries"]:
                    name = f"cmuxd-remote-{entry['goOS']}-{entry['goArch']}{ending}"
                    self.assertEqual(entry["assetName"], name)
                    self.assertEqual(entry["downloadURL"], f"{base_url}/{name}")
                    binary = output / name
                    self.assertGreater(binary.stat().st_size, 0)
                    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
                    self.assertEqual(entry["sha256"], digest)
                    self.assertEqual(checksums[name], digest)

                # Run the artifact, rather than accepting an arbitrary file with a hash.
                go_os = {"Darwin": "darwin", "Linux": "linux"}[platform.system()]
                go_arch = {"arm64": "arm64", "aarch64": "arm64", "x86_64": "amd64"}[platform.machine()]
                binary = output / f"cmuxd-remote-{go_os}-{go_arch}{ending}"
                hello = subprocess.run([str(binary), "serve", "--stdio"],
                                       input='{"id":1,"method":"hello","params":{}}\n',
                                       capture_output=True, text=True, check=True, timeout=15)
                response = json.loads(hello.stdout.splitlines()[0])
                self.assertTrue(response["ok"], response)
                self.assertEqual(response["result"]["version"], version)
                required = {"proxy.stream.push", "pty.session", "pty.session.token",
                            "pty.session.persistent_daemon", "pty.write.notification",
                            "pty.resize.notification", "pty.attach.cancel"}
                self.assertTrue(required <= set(response["result"]["capabilities"]), response)


if __name__ == "__main__":
    unittest.main()
