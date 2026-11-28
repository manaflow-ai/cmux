#!/usr/bin/env python3
"""scripts/cmux-vmd/host-artifacts.sh builds what a new microVM host installs at boot, and the workflow publishes it.

A host provisions itself from this bundle with nobody's ssh (cmuxterm-hq build-fleet/microvm-host/provision.sh), so
the bundle's layout is a contract: bin/cmux-vmd, bin/firecracker, images/autocloud/{vmlinux, rootfs.ext4.zst},
autocloud-template.sh, manifest.json, and cmux-vmd/latest.json written last. The rootfs must carry the guest agent
cmux-vmd-guest, enabled, since cmux-vmd waits on its vsock ping after every boot.
"""

from __future__ import annotations

import io
import os
import re
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-vmd/host-artifacts.sh"
WORKFLOW = ROOT / ".github/workflows/cmux-vmd-host-artifacts.yml"
CARGO = ROOT / "cmux-tui/crates/cmux-vmd/Cargo.toml"
PROTO = ROOT / "cmux-tui/crates/cmux-vmd/src/proto.rs"


def shell_var(name: str) -> str:
    match = re.search(rf'^{name}="([^"]*)"', SCRIPT.read_text(), re.M)
    assert match, f"{name} not set in {SCRIPT.name}"
    return match.group(1)


class HostArtifactsTest(unittest.TestCase):
    def test_syntax(self) -> None:
        subprocess.run(["bash", "-n", str(SCRIPT)], check=True)

    def test_pins_are_exact(self) -> None:
        self.assertRegex(shell_var("FIRECRACKER_VERSION"), r"^v\d+\.\d+\.\d+$")
        self.assertRegex(shell_var("FIRECRACKER_TGZ_SHA256"), r"^[0-9a-f]{64}$")
        self.assertRegex(shell_var("VMLINUX_URL"), r"^https://[^ ]+/x86_64/vmlinux-\d+\.\d+\.\d+$")
        self.assertRegex(shell_var("VMLINUX_SHA256"), r"^[0-9a-f]{64}$")

    def test_bins_exist_in_the_crate(self) -> None:
        self.assertIn('name = "cmux-vmd"', CARGO.read_text())
        for name in ("cmux-vmd", "cmux-vmd-guest"):
            self.assertTrue((CARGO.parent / "src/bin" / f"{name}.rs").is_file(), name)
        self.assertIn("52", PROTO.read_text(), "the unit's description names vsock port 52")

    def test_workflow_builds_bundles_and_publishes(self) -> None:
        wf = WORKFLOW.read_text()
        self.assertIn("cargo build --release --locked -p cmux-vmd --bin cmux-vmd --bin cmux-vmd-guest", wf)
        self.assertIn("host-artifacts.sh bundle", wf)
        self.assertIn("host-artifacts.sh publish", wf)
        self.assertIn("python3 tests/test_cmux_vmd_host_artifacts.py", wf)
        self.assertIn("R2_BUCKET: cmux-fleet-artifacts", wf)
        self.assertNotIn("pull_request", wf, "a PR trigger goes through pr_router.json; this one only publishes")
        jobs = wf[wf.index("\njobs:\n"):]
        names = re.findall(r"^  ([a-z_]+):$", jobs, re.M)
        self.assertEqual(names, ["build", "publish"])
        self.assertEqual(jobs.count("    timeout-minutes:"), len(names))

    def test_latest_is_written_after_every_object(self) -> None:
        text = SCRIPT.read_text()
        publish = text[text.index("publish() {"):text.index("case \"${1:-}\" in")]
        self.assertLess(publish.index("done < <(jq -r '.files[]"), publish.index('"$PREFIX/latest.json" PUT'))
        self.assertLess(publish.index("probe PUT"), publish.index("done < <(jq -r '.files[]"))

    @unittest.skipUnless(all(shutil.which(t) for t in ("fakeroot", "mkfs.ext4", "zstd", "debugfs")),
                         "needs fakeroot, e2fsprogs and zstd")
    def test_rootfs_carries_the_guest_agent_and_the_fstab_label(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            raw = io.BytesIO()
            with tarfile.open(fileobj=raw, mode="w") as tar:
                def add(name: str, data: bytes = b"", mode: int = 0o644, kind: bytes = tarfile.REGTYPE,
                        link: str = "") -> None:
                    info = tarfile.TarInfo(name)
                    info.type, info.mode, info.size, info.linkname = kind, mode, len(data), link
                    tar.addfile(info, io.BytesIO(data))
                add("sbin", kind=tarfile.DIRTYPE, mode=0o755)
                add("sbin/init", b"#!/bin/sh\n", 0o755)
                add("etc", kind=tarfile.DIRTYPE, mode=0o755)
                add("etc/fstab", b"LABEL=cloudimg-rootfs\t/\text4\tdiscard,errors=remount-ro\t0 1\n")
            tarball = t / "rootfs.tar"
            tarball.write_bytes(raw.getvalue())
            subprocess.run(["zstd", "-q", str(tarball)], check=True)
            guest = t / "cmux-vmd-guest"
            guest.write_text("#!/bin/sh\n")
            guest.chmod(0o755)
            out = t / "rootfs.ext4.zst"
            env = dict(os.environ, ROOTFS_FREE_MIB="16", TMPDIR=tmp)
            run = subprocess.run(["bash", str(SCRIPT), "rootfs", f"{tarball}.zst", str(guest), str(out)],
                                 check=True, capture_output=True, text=True, env=env)
            self.assertIn("ROOTFS label=cloudimg-rootfs", run.stdout)
            subprocess.run(["zstd", "-q", "-d", str(out), "-o", str(t / "rootfs.ext4")], check=True)

            def debugfs(cmd: str) -> str:
                return subprocess.run(["debugfs", "-R", cmd, str(t / "rootfs.ext4")], check=True,
                                      capture_output=True, text=True).stdout

            self.assertIn("cmux-vmd-guest", debugfs("ls -l /usr/local/bin"))
            self.assertIn("ExecStart=/usr/local/bin/cmux-vmd-guest", debugfs("cat /etc/systemd/system/cmux-vmd-guest.service"))
            self.assertIn("cmux-vmd-guest.service", debugfs("ls -l /etc/systemd/system/multi-user.target.wants"))
            self.assertIn("../cmux-vmd-guest.service",
                          debugfs("stat /etc/systemd/system/multi-user.target.wants/cmux-vmd-guest.service"))
            stat = debugfs("stat /usr/local/bin/cmux-vmd-guest")
            self.assertRegex(stat, r"User:\s+0\s+Group:\s+0")
            label = subprocess.run(["dumpe2fs", "-h", str(t / "rootfs.ext4")], capture_output=True, text=True).stdout
            self.assertIn("cloudimg-rootfs", label)

    def test_manifest_shape(self) -> None:
        text = SCRIPT.read_text()
        for key in ("schema: 1", "source_sha", "firecracker", "kernel", "rootfs_tar", "files"):
            self.assertIn(key, text)


if __name__ == "__main__":
    unittest.main()
