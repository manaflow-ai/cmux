#!/usr/bin/env python3
"""The Windows MSI built and signed on Linux (scripts/ci/windows-msi.py, map piece D4): it holds the five
cross-built exes under their installed names, a user PATH entry with its actions scheduled, an upgrade that
replaces an equal version; a test-signed MSI and its exes verify, --require-signed refuses without a
certificate, and with Wine an install, reinstall, refused downgrade and uninstall leave nothing behind.

Needs wixl, msitools and osslsigncode (apt: wixl msitools osslsigncode); the Wine case also needs wine64.
Each case says why it skips. Run: python3 tests/test_windows_msi.py
"""
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest


def load(path):
    with open(path) as f:
        return json.load(f)

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SCRIPT = os.path.join(ROOT, "scripts", "ci", "windows-msi.py")
sys.path.insert(0, os.path.dirname(SCRIPT))
import importlib.util  # noqa: E402

spec = importlib.util.spec_from_file_location("windows_msi", SCRIPT)
windows_msi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(windows_msi)

TOOLS = ("wixl", "msibuild", "msiinfo", "osslsigncode", "openssl")


def have(*tools):
    return all(shutil.which(t) for t in tools)


def tiny_pe(tag):
    """A minimal valid PE32+ image (one empty section) that osslsigncode can sign; `tag` makes each distinct."""
    dos = bytearray(64)
    dos[0:2] = b"MZ"
    struct.pack_into("<I", dos, 0x3C, 64)
    coff = struct.pack("<HHIIIHH", 0x8664, 1, 0, 0, 0, 240, 0x0022)
    opt = bytearray(240)
    struct.pack_into("<H", opt, 0, 0x20B)
    struct.pack_into("<I", opt, 16, 0x1000)  # entry point
    struct.pack_into("<Q", opt, 24, 0x140000000)  # image base
    struct.pack_into("<II", opt, 32, 0x1000, 0x200)  # section, file alignment
    struct.pack_into("<HH", opt, 48, 6, 0)  # subsystem version
    struct.pack_into("<I", opt, 56, 0x2000)  # size of image
    struct.pack_into("<I", opt, 60, 0x200)  # size of headers
    struct.pack_into("<H", opt, 68, 3)  # console subsystem
    struct.pack_into("<QQQQ", opt, 72, 0x100000, 0x1000, 0x100000, 0x1000)
    struct.pack_into("<I", opt, 108, 16)  # data directories
    sect = struct.pack("<8sIIIIIIHHI", b".text", 0x200, 0x1000, 0x200, 0x200, 0, 0, 0, 0, 0x60000020)
    head = bytes(dos) + b"PE\0\0" + coff + bytes(opt) + sect
    body = (b"\xc3" + tag.encode()).ljust(0x200, b"\0")
    return head.ljust(0x200, b"\0") + body


@unittest.skipUnless(have(*TOOLS), "needs " + ", ".join(TOOLS))
class Build(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="windows-msi-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.dist = os.path.join(self.tmp, "dist")
        os.mkdir(self.dist)
        for base, _ in windows_msi.FILES:
            with open(os.path.join(self.dist, f"{base}-{windows_msi.TARGET}.exe"), "wb") as f:
                f.write(tiny_pe(base))

    def build(self, version, name, *extra, env=None):
        out = os.path.join(self.tmp, name)
        e = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_WINDOWS_SIGN_")}
        e.update(env or {})
        p = subprocess.run([sys.executable, SCRIPT, "build", "--dist", self.dist, "--version", version,
                            "--out", out, *extra], capture_output=True, text=True, env=e)
        return p, out

    def test_unsigned_msi_holds_the_files_path_and_upgrade(self):
        p, out = self.build("0.1.2", "cmux.msi")
        self.assertEqual(p.returncode, 0, p.stderr)
        manifest = load(out + ".json")
        self.assertEqual(manifest["signer"], "unsigned")
        self.assertFalse(manifest["signed"])
        self.assertEqual(manifest["msi_version"], "0.1.2")
        self.assertEqual(sorted(manifest["files"]), sorted(n for _, n in windows_msi.FILES))
        self.assertIn("cmux.exe", windows_msi.verify(out))
        upgrade = {r["ActionProperty"]: r for r in windows_msi.table(out, "Upgrade")}
        self.assertEqual(int(upgrade["WIX_UPGRADE_DETECTED"]["Attributes"]) & 512, 512)

    def test_verify_refuses_an_msi_without_the_path_entry(self):
        # wixl's own output, before patch(): no Environment row, so verify must fail.
        staged = os.path.join(self.tmp, "staged")
        os.mkdir(staged)
        for base, name in windows_msi.FILES:
            shutil.copyfile(os.path.join(self.dist, f"{base}-{windows_msi.TARGET}.exe"), os.path.join(staged, name))
        wxs = os.path.join(self.tmp, "c.wxs")
        with open(wxs, "w") as f:
            f.write(windows_msi.wxs("0.1.2", staged))
        msi = os.path.join(self.tmp, "raw.msi")
        subprocess.run(["wixl", "-a", "x64", "-o", msi, wxs], check=True, capture_output=True)
        with self.assertRaises(windows_msi.Fail):
            windows_msi.verify(msi)

    def test_prerelease_version_keeps_its_numeric_part(self):
        self.assertEqual(windows_msi.msi_version("0.0.0-r2.sha-abc"), "0.0.0")
        self.assertEqual(windows_msi.msi_version("1.2.3+20261127"), "1.2.3")
        for bad in ("1.2", "256.0.0", "v1.2.3"):
            with self.assertRaises(windows_msi.Fail):
                windows_msi.msi_version(bad)

    def test_test_sign_signs_every_exe_and_the_msi(self):
        p, out = self.build("0.1.2", "signed.msi", "--test-sign")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(load(out + ".json")["signer"], "test")
        v = subprocess.run(["osslsigncode", "verify", "-in", out], capture_output=True, text=True)
        self.assertIn("cmux test signing", v.stdout)
        x = os.path.join(self.tmp, "x")
        subprocess.run(["msiextract", "-C", x, out], check=True, capture_output=True)
        exes = [os.path.join(d, f) for d, _, fs in os.walk(x) for f in fs if f.endswith(".exe")]
        self.assertEqual(len(exes), len(windows_msi.FILES))
        for exe in exes:
            v = subprocess.run(["osslsigncode", "verify", "-in", exe], capture_output=True, text=True)
            self.assertIn("cmux test signing", v.stdout, exe)

    def test_require_signed_without_a_certificate_fails(self):
        p, out = self.build("0.1.2", "r.msi", "--require-signed")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("CMUX_WINDOWS_SIGN_PFX_B64", p.stderr)
        self.assertFalse(os.path.exists(out))

    def test_release_password_is_never_printed(self):
        p, _ = self.build("0.1.2", "bad.msi", env={"CMUX_WINDOWS_SIGN_PFX_B64": "bm90IGEgcGZ4",
                                                    "CMUX_WINDOWS_SIGN_PFX_PASSWORD": "hunter2-secret"})
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn("hunter2-secret", p.stdout + p.stderr)

    def test_missing_exe_fails(self):
        os.remove(os.path.join(self.dist, f"cmux-relay-{windows_msi.TARGET}.exe"))
        p, _ = self.build("0.1.2", "m.msi")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("cmux-relay", p.stderr)

    @unittest.skipUnless(have("wine", "wineboot"), "needs wine64 (apt: wine64 wine)")
    def test_wine_install_reinstall_downgrade_uninstall(self):
        p, new = self.build("0.1.2", "new.msi", "--test-sign")
        self.assertEqual(p.returncode, 0, p.stderr)
        p, old = self.build("0.1.1", "old.msi")
        self.assertEqual(p.returncode, 0, p.stderr)
        env = dict(os.environ)
        env.pop("WINEPREFIX", None)
        r = subprocess.run([sys.executable, SCRIPT, "wine-roundtrip", "--msi", new, "--older", old],
                           capture_output=True, text=True, env=env, timeout=900)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("install, reinstall, downgrade-refused, uninstall", r.stdout)


if __name__ == "__main__":
    unittest.main()
