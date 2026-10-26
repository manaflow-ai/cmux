#!/usr/bin/env python3
"""scripts/ci/rcodesign-sign-bundle-dev.sh gives each component of a cmux NEXT
DEV bundle what scripts/sign-cmux-bundle.sh gives it, and keeps the key off
every command line.

A fake rcodesign and a fake openssl record their argv (and the entitlements
files rcodesign is handed, which the script deletes on exit). Recording shims
in front of the common tools the script runs record theirs, so the test can
check that no secret and no key path reaches any other command line.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/rcodesign-sign-bundle-dev.sh"
APP_ENTITLEMENTS = ROOT / "cmux.next-dev.entitlements"
HELPER_ENTITLEMENTS = ROOT / "cmux-helper.entitlements"

P12_BYTES = b"dummy-pkcs12-\x01\x02-identity"
P12_BASE64 = base64.b64encode(P12_BYTES).decode()
P12_PASSWORD = "dummy-p12-password-9f3a"
COMMON_NAME = "Developer ID Application: Example Corp (TEAM123456)"
SHA1 = "AB" * 20

THIN = b"\xcf\xfa\xed\xfe"
FAT = b"\xca\xfe\xba\xbe\x00\x00\x00\x02"
JAVA = b"\xca\xfe\xba\xbe\x00\x00\x00\x34"
ENTITLED = b"ENTITLED"

FAKE_RCODESIGN = r'''
import json, os, stat, sys
argv = sys.argv[1:]
record = {"tool": "rcodesign", "argv": argv}
fail = os.environ.get("FAKE_RCODESIGN_FAIL", "")
if argv and argv[0] == "sign":
    ents = {}
    pem = None
    for i, a in enumerate(argv):
        if a == "--entitlements-xml-file":
            value = argv[i + 1]
            scope, _, path = value.partition(":") if ":" in value else ("", "", value)
            ents[scope] = open(path, encoding="utf-8").read()
        if a == "--pem-file":
            pem = argv[i + 1]
    record["entitlements"] = ents
    if pem:
        st = os.stat(pem)
        record["pem_mode"] = stat.S_IMODE(st.st_mode)
        record["pem_dir_mode"] = stat.S_IMODE(os.stat(os.path.dirname(pem)).st_mode)
        record["pem_has_key"] = "PRIVATE KEY" in open(pem).read()
    target = argv[-1]
    if os.path.isfile(target):
        with open(target, "ab") as handle:
            handle.write(b"\nSIGNED")
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps(record) + "\n")
if argv and argv[0] == fail:
    print("fake rcodesign failure", file=sys.stderr)
    sys.exit(1)
if argv and argv[0] == "print-signature-info":
    data = open(argv[-1], "rb").read()
    print("- path: " + argv[-1])
    print("  entity:")
    print("    mach_o:")
    print("      signature:")
    print("        code_directory:")
    print("          flags: CodeSignatureFlags(ADHOC)")
    if b"ENTITLED" in data:
        print("        entitlements_plist:")
        print("        - <plist><dict><key>com.apple.security.cs.allow-jit</key><true/></dict></plist>")
'''

FAKE_OPENSSL = r'''
import json, os, sys
argv = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps({"tool": "openssl", "argv": argv}) + "\n")
if argv[0] == "pkcs12":
    data = sys.stdin.buffer.read()
    if data != os.environb[b"FAKE_P12"]:
        sys.exit("unexpected PKCS#12 on stdin")
    if "env:APPLE_CERTIFICATE_PASSWORD" not in argv or os.environ.get("APPLE_CERTIFICATE_PASSWORD") != os.environ["FAKE_PASSWORD"]:
        sys.exit("wrong password source")
    sys.stdout.write("-----BEGIN CERTIFICATE-----\nQ0VSVA==\n-----END CERTIFICATE-----\n"
                     "-----BEGIN PRIVATE KEY-----\nS0VZ\n-----END PRIVATE KEY-----\n")
elif argv[0] == "x509":
    sys.stdin.read()
    if "-subject" in argv:
        print("subject=")
        print("    userId                    = TEAM123456")
        print("    commonName                = " + os.environ["FAKE_CN"])
        print("    organizationName          = Example Corp")
    elif "-fingerprint" in argv:
        print("SHA1 Fingerprint=" + ":".join(os.environ["FAKE_SHA1"][i:i + 2] for i in range(0, 40, 2)))
else:
    sys.exit("unexpected openssl command")
'''

# Records argv, then runs the real tool from the original PATH.
SHIM = r'''
import json, os, shutil, sys
name = os.path.basename(sys.argv[0])
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps({"tool": name, "argv": sys.argv[1:]}) + "\n")
real = sys.executable if name == "python3" else shutil.which(name, path=os.environ["FAKE_REAL_PATH"])
os.execv(real, [real] + sys.argv[1:])
'''
SHIMMED = ["base64", "grep", "rm", "awk", "find", "chmod", "tail", "mktemp", "python3", "dirname", "basename"]

APP = "cmux NEXT DEV.app"
CEF_HELPER = "Contents/Frameworks/cmux NEXT DEV Helper{}.app/Contents/MacOS/cmux NEXT DEV Helper{}"
PAYLOAD = "Contents/Resources/bin/cmux-tui-ssh/cmux-tui-aarch64-apple-darwin"
LINUX_PAYLOAD = "Contents/Resources/bin/cmux-tui-ssh/cmux-tui-x86_64-unknown-linux-musl"

HELPER_SCOPED = {
    "Contents/Resources/bin/cmux",
    "Contents/Resources/bin/cmux-diff-sidecar",
    "Contents/Resources/libexec/cmux-server-helper",
    "Contents/Library/cmux Computer Use.app/Contents/MacOS/cmux-computer-use",
}
CLEARED = {
    "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate",
    CEF_HELPER.format(" (GPU)", " (GPU)"),
    CEF_HELPER.format(" (Renderer)", " (Renderer)"),
    "Contents/PlugIns/Share.appex/Contents/MacOS/Share",
}
# Signed by rcodesign but given no scoped entitlements.
UNSCOPED = {
    "Contents/MacOS/cmux",  # takes the unscoped app entitlements
    "Contents/MacOS/cmux-extra",  # left alone by codesign: keeps its own
    "Contents/Helpers/cmux-remote-browser-host.app/Contents/MacOS/cmux-remote-browser-host",
    "Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle",
    "Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A/Chromium Embedded Framework",
    "Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A/Libraries/libEGL.dylib",
    "Contents/Frameworks/libcmux_cef_shim.dylib",
    CEF_HELPER.format("", ""),
}
BUNDLE_MACHOS = HELPER_SCOPED | CLEARED | UNSCOPED


def write(path: Path, data: bytes, executable: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    if executable:
        path.chmod(0o755)


def info_plist(path: Path, executable: str, identifier: str) -> None:
    write(path, plistlib.dumps({"CFBundleExecutable": executable, "CFBundleIdentifier": identifier}))


def build_app(root: Path) -> Path:
    app = root / APP
    contents = app / "Contents"
    info_plist(contents / "Info.plist", "cmux", "com.cmuxterm.app.next.dev")
    for rel in BUNDLE_MACHOS - {"Contents/Frameworks/libcmux_cef_shim.dylib"}:
        write(app / rel, THIN + rel.encode() + (ENTITLED if rel in CLEARED or rel.endswith("cmux-extra") else b""), True)
    write(app / "Contents/Frameworks/libcmux_cef_shim.dylib", FAT + b"shim")
    write(contents / "Resources/bin/cmux-wrapper.sh", b"#!/bin/sh\nexec true\n", True)
    write(contents / "Resources/Classes/Probe.class", JAVA + b"java")
    write(contents / "Resources/cmux_Resources.bundle/Contents/Resources/strings.json", b"{}")
    write(contents / "Resources/._cmux", b"appledouble")
    for helper, exe, ident in [
        ("Library/cmux Computer Use.app", "cmux-computer-use", "com.cmuxterm.computer-use"),
        ("Helpers/cmux-remote-browser-host.app", "cmux-remote-browser-host", "com.cmuxterm.rbh"),
        ("PlugIns/Share.appex", "Share", "com.cmuxterm.share"),
    ] + [
        (f"Frameworks/cmux NEXT DEV Helper{s}.app", f"cmux NEXT DEV Helper{s}", "com.cmuxterm.helper")
        for s in ("", " (GPU)", " (Renderer)")
    ]:
        info_plist(contents / helper / "Contents/Info.plist", exe, ident)
    sparkle = contents / "Frameworks/Sparkle.framework"
    write(sparkle / "Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader", THIN + b"xpc", True)
    (sparkle / "Versions/Current").symlink_to("B")
    (sparkle / "Sparkle").symlink_to("Versions/Current/Sparkle")
    write(contents / "Library/SystemExtensions/tunnel.systemextension/Contents/MacOS/tunnel", THIN + b"ext", True)
    write(app / PAYLOAD, THIN + b"tui", True)
    linux = b"\x7fELF tui"
    write(app / LINUX_PAYLOAD, linux, True)
    manifest = {"binaries": {
        PAYLOAD.rsplit("/", 1)[1]: hashlib.sha256(THIN + b"tui").hexdigest(),
        LINUX_PAYLOAD.rsplit("/", 1)[1]: hashlib.sha256(linux).hexdigest(),
    }}
    write(app / "Contents/Resources/bin/cmux-tui-ssh/manifest.json", json.dumps(manifest).encode())
    return app


def options(argv: list[str], name: str) -> list[str]:
    return [argv[i + 1] for i, a in enumerate(argv[:-1]) if a == name]


class RcodesignSignBundleDevTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="rcodesign-dev-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.app = build_app(self.tmp / "unpacked")
        self.log = self.tmp / "calls.jsonl"
        self.script_tmp = self.tmp / "script-tmp"
        self.script_tmp.mkdir()
        fakes = self.tmp / "fakes"
        shims = self.tmp / "shims"
        fakes.mkdir()
        shims.mkdir()
        for name, body in (("rcodesign", FAKE_RCODESIGN), ("openssl", FAKE_OPENSSL)):
            write(fakes / name, f"#!{sys.executable}\n{body}".encode(), True)
        for name in SHIMMED:
            write(shims / name, f"#!{sys.executable}\n{SHIM}".encode(), True)
        real_path = os.environ.get("PATH", "/usr/bin:/bin")
        self.env = {
            "PATH": f"{shims}:{fakes}:{real_path}",
            "HOME": str(self.tmp),
            "LANG": "C.UTF-8",
            "TMPDIR": str(self.script_tmp),
            "FAKE_LOG": str(self.log),
            "FAKE_REAL_PATH": real_path,
            "FAKE_P12": P12_BYTES.decode("latin-1"),
            "FAKE_PASSWORD": P12_PASSWORD,
            "FAKE_CN": COMMON_NAME,
            "FAKE_SHA1": SHA1,
            "APPLE_CERTIFICATE_BASE64": P12_BASE64,
            "APPLE_CERTIFICATE_PASSWORD": P12_PASSWORD,
            "APPLE_SIGNING_IDENTITY": COMMON_NAME,
        }

    def run_script(self, **env: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(SCRIPT), str(self.app), str(APP_ENTITLEMENTS)],
            cwd=ROOT, env={**self.env, **env}, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120,
        )

    def calls(self, tool: str | None = None) -> list[dict]:
        if not self.log.exists():
            return []
        entries = [json.loads(line) for line in self.log.read_text().splitlines()]
        return [e for e in entries if tool is None or e["tool"] == tool]

    def bundle_sign(self) -> dict:
        signs = [c for c in self.calls("rcodesign") if c["argv"][0] == "sign" and c["argv"][-1] == str(self.app)]
        self.assertEqual(len(signs), 1, signs)
        return signs[0]

    def assert_no_leftovers(self) -> None:
        self.assertEqual(list(self.script_tmp.iterdir()), [], "the script left temporary files behind")

    def test_components_get_sign_cmux_bundle_treatment(self) -> None:
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        sign = self.bundle_sign()
        argv = sign["argv"]

        flags = options(argv, "--code-signature-flags")
        self.assertIn("runtime", flags)
        scoped_runtime = {f.rsplit(":", 1)[0] for f in flags if f != "runtime"}
        self.assertEqual(scoped_runtime, BUNDLE_MACHOS)
        self.assertTrue(all(f.endswith(":runtime") for f in flags if f != "runtime"))
        self.assertIn("--for-notarization", argv)
        self.assertNotIn("--timestamp-url", argv)

        ents = sign["entitlements"]
        helper_text = HELPER_ENTITLEMENTS.read_text()
        self.assertEqual(plistlib.loads(ents[""].encode()), plistlib.loads(APP_ENTITLEMENTS.read_bytes()))
        for rel in HELPER_SCOPED:
            self.assertEqual(ents.get(rel), helper_text, rel)
        for rel in CLEARED:
            self.assertEqual(plistlib.loads(ents[rel].encode()), {}, rel)
        self.assertEqual(set(ents) - {""}, HELPER_SCOPED | CLEARED)

        excludes = options(argv, "--exclude")
        self.assertEqual(
            sorted(excludes),
            ["Contents/Resources/bin/cmux-tui-ssh/**", "Contents/Resources/cmux_Resources.bundle"],
        )

        # Every Mach-O, and only Mach-O files, is verified after signing.
        verified = {c["argv"][-1] for c in self.calls("rcodesign") if c["argv"][0] == "verify"}
        self.assertEqual(verified, {str(self.app / rel) for rel in BUNDLE_MACHOS | {PAYLOAD}})

        contents = self.app / "Contents"
        self.assertFalse((contents / "Library/SystemExtensions").exists())
        self.assertFalse((contents / "Frameworks/Sparkle.framework/Versions/B/XPCServices").exists())
        self.assertFalse((contents / "Resources/._cmux").exists())
        self.assert_no_leftovers()

    def test_tui_ssh_payloads_are_signed_alone_and_repinned(self) -> None:
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        payload = self.app / PAYLOAD
        signs = [c for c in self.calls("rcodesign") if c["argv"][0] == "sign" and c["argv"][-1] == str(payload)]
        self.assertEqual(len(signs), 1)
        argv = signs[0]["argv"]
        self.assertEqual(options(argv, "--code-signature-flags"), ["runtime"])
        self.assertEqual(list(signs[0]["entitlements"].values()), [HELPER_ENTITLEMENTS.read_text()])
        self.assertIn("--for-notarization", argv)
        manifest = json.loads((self.app / "Contents/Resources/bin/cmux-tui-ssh/manifest.json").read_text())
        self.assertTrue(payload.read_bytes().endswith(b"SIGNED"))
        self.assertEqual(manifest["binaries"][payload.name], hashlib.sha256(payload.read_bytes()).hexdigest())
        linux = self.app / LINUX_PAYLOAD
        self.assertEqual(manifest["binaries"][linux.name], hashlib.sha256(linux.read_bytes()).hexdigest())

    def test_key_material_stays_off_argv_and_is_removed(self) -> None:
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        signs = [c for c in self.calls("rcodesign") if c["argv"][0] == "sign"]
        pems = {p for c in signs for p in options(c["argv"], "--pem-file")}
        self.assertEqual(len(pems), 1, pems)
        pem = pems.pop()
        for call in signs:
            self.assertTrue(call["pem_has_key"])
            self.assertEqual(call["pem_mode"] & 0o077, 0)
            self.assertEqual(call["pem_dir_mode"], 0o700)
        key_dir = str(Path(pem).parent)
        secrets = [P12_BASE64, P12_PASSWORD, P12_BYTES.decode("latin-1")]
        tools = {c["tool"] for c in self.calls()}
        self.assertTrue({"openssl", "python3", "base64", "rm"} <= tools, tools)
        for call in self.calls():
            for i, arg in enumerate(call["argv"]):
                for secret in secrets:
                    self.assertNotIn(secret, arg, call)
                if pem in arg or (key_dir in arg and call["tool"] != "rm"):
                    self.assertEqual(call["tool"], "rcodesign", call)
                    self.assertEqual(arg, pem)
                    self.assertEqual(call["argv"][i - 1], "--pem-file", call)
        self.assertFalse(Path(key_dir).exists())
        work_dir = Path(self.bundle_sign()["argv"][self.bundle_sign()["argv"].index("--entitlements-xml-file") + 1]).parent
        self.assertFalse(work_dir.exists())
        self.assert_no_leftovers()

    def test_failing_rcodesign_fails_the_script(self) -> None:
        for step in ("sign", "verify"):
            with self.subTest(step=step):
                self.log.unlink(missing_ok=True)
                result = self.run_script(FAKE_RCODESIGN_FAIL=step)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assert_no_leftovers()

    def test_identity_mismatch_signs_nothing(self) -> None:
        for identity in ("Developer ID Application: Someone Else (OTHER12345)", "CD" * 20):
            with self.subTest(identity=identity):
                self.log.unlink(missing_ok=True)
                result = self.run_script(APPLE_SIGNING_IDENTITY=identity)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(identity, result.stdout + result.stderr)
                self.assertEqual([c for c in self.calls("rcodesign") if c["argv"][0] == "sign"], [])
                self.assert_no_leftovers()
        result = self.run_script(APPLE_SIGNING_IDENTITY=SHA1.lower())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_wrong_password_fails(self) -> None:
        result = self.run_script(APPLE_CERTIFICATE_PASSWORD="not-the-password")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not open the PKCS#12", result.stderr)
        self.assertEqual(self.calls("rcodesign"), [])
        self.assert_no_leftovers()


if __name__ == "__main__":
    unittest.main()
