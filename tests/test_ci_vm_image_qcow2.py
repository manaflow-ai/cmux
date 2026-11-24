"""scripts/ci/vm-image-qcow2.sh: a tiny raw image and a tiny rootfs tarball become a qcow2 whose sha256 file
verifies and whose contents match (RFD 0100 step 6). Needs qemu-img; skipped on a runner without it."""

from __future__ import annotations
import hashlib
import os
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "vm-image-qcow2.sh"
HAS_QEMU = shutil.which("qemu-img") is not None
HAS_ROOTFS_TOOLS = HAS_QEMU and all(shutil.which(t) for t in ("mkfs.ext4", "fakeroot", "debugfs", "zstd"))


def run(*args: str, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(list(args), cwd=cwd, check=True, capture_output=True, text=True)


class Qcow2ExportTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def check_sha256(self, out: Path) -> str:
        line = (out.parent / f"{out.name}.sha256").read_text()
        digest, name = line.rstrip("\n").split("  ")
        self.assertEqual(name, out.name)
        self.assertEqual(digest, hashlib.sha256(out.read_bytes()).hexdigest())
        run("sha256sum", "-c", f"{out.name}.sha256", cwd=out.parent)
        return digest

    @unittest.skipUnless(HAS_QEMU, "qemu-img not installed")
    def test_raw_image_becomes_compressed_qcow2(self) -> None:
        raw = self.tmp / "disk.raw"
        with raw.open("wb") as f:
            f.truncate(4 * 1024 * 1024)
            f.seek(1024 * 1024)
            f.write(b"cmux-vm-image" * 4096)
        out = self.tmp / "out" / "cmux-vm-test.qcow2"
        out.parent.mkdir()
        result = run("bash", str(SCRIPT), "--raw", str(raw), "--out", str(out))
        digest = self.check_sha256(out)
        last = result.stdout.strip().splitlines()[-1].split()
        self.assertEqual(last, ["QCOW2", str(out), digest, str(out.stat().st_size)])
        info = run("qemu-img", "info", "--output=json", str(out)).stdout
        self.assertIn('"format": "qcow2"', info)
        self.assertIn('"virtual-size": 4194304', info)
        self.assertLess(out.stat().st_size, raw.stat().st_size)
        run("qemu-img", "compare", "-f", "raw", "-F", "qcow2", str(raw), str(out))

    @unittest.skipUnless(HAS_ROOTFS_TOOLS, "qemu-img, mkfs.ext4, fakeroot, debugfs or zstd not installed")
    def test_rootfs_tarball_keeps_owners_and_modes(self) -> None:
        tarball = self.tmp / "rootfs.tar"
        with tarfile.open(tarball, "w", format=tarfile.PAX_FORMAT) as tar:
            for name, mode, uid in (("etc", 0o755, 0), ("home", 0o755, 0), ("home/cmux", 0o750, 1000)):
                info = tarfile.TarInfo(name)
                info.type, info.mode, info.uid, info.gid = tarfile.DIRTYPE, mode, uid, uid
                tar.addfile(info)
            data = b"cmux-vm\n"
            info = tarfile.TarInfo("etc/hostname")
            info.size, info.mode = len(data), 0o644
            import io

            tar.addfile(info, io.BytesIO(data))
        zst = self.tmp / "rootfs.tar.zst"
        run("zstd", "-q", str(tarball), "-o", str(zst))
        out = self.tmp / "cmux-vm-rootfs.qcow2"
        run("bash", str(SCRIPT), "--rootfs-tar", str(zst), "--out", str(out), "--size-mib", "16")
        self.check_sha256(out)
        raw = self.tmp / "back.raw"
        run("qemu-img", "convert", "-f", "qcow2", "-O", "raw", str(out), str(raw))
        self.assertEqual(run("debugfs", "-R", "cat /etc/hostname", str(raw)).stdout, "cmux-vm\n")
        stat = run("debugfs", "-R", "stat /home/cmux", str(raw)).stdout
        self.assertRegex(stat, r"User:\s+1000\s+Group:\s+1000")
        self.assertRegex(stat, r"Mode:\s+0?750")
        self.assertRegex(run("debugfs", "-R", "stat /etc", str(raw)).stdout, r"User:\s+0\s+Group:\s+0")

    def test_refuses_bad_arguments(self) -> None:
        for args in ([], ["--raw", "x.raw"], ["--raw", "x", "--out", "x.img"], ["--raw", "a", "--rootfs-tar", "b", "--out", "x.qcow2"]):
            r = subprocess.run(["bash", str(SCRIPT), *args], capture_output=True, text=True, env={**os.environ, "PATH": os.environ.get("PATH", "")})
            self.assertEqual(r.returncode, 2, (args, r.stderr))


if __name__ == "__main__":
    unittest.main()
