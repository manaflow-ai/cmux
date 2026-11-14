#!/usr/bin/env python3
"""scripts/ci/rcodesign-sign-bundle-dev.sh gives each component of a cmux NEXT
DEV bundle what feat-cmux-next's scripts/sign-cmux-bundle.sh gives it, and
keeps the key off every command line.

A fake rcodesign and a fake openssl record their argv, plus what rcodesign saw
when it signed (entitlements files, the bundle's files). Recording shims in
front of the common tools catch a secret or key path on any other argv.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/rcodesign-sign-bundle-dev.sh"
APP_ENTITLEMENTS = ROOT / "cmux.next-dev.entitlements"
HELPER_TEXT = (ROOT / "cmux-helper.entitlements").read_text()

P12 = b"dummy-pkcs12-\x01\x02-identity"
P12_BASE64 = base64.b64encode(P12).decode()
PASSWORD = "dummy-p12-password-9f3a"
CN = "Developer ID Application: Example Corp (TEAM123456)"
SHA1 = "AB" * 20
BUNDLE_ID = "com.cmuxterm.app.debug.next"

FAKE_RCODESIGN = r'''
import json, os, stat, sys
argv = sys.argv[1:]
record = {"tool": "rcodesign", "argv": argv}
if argv[0] == "sign":
    target, value = argv[-1], lambda name: [argv[i + 1] for i, a in enumerate(argv) if a == name]
    record["entitlements"] = {}
    for v in value("--entitlements-xml-file"):
        scope, _, path = v.partition(":") if ":" in v else ("", "", v)
        record["entitlements"][scope] = open(path).read()
    pem = value("--pem-file")[0]
    record["pem"] = [stat.S_IMODE(os.stat(pem).st_mode), stat.S_IMODE(os.stat(os.path.dirname(pem)).st_mode),
                     "PRIVATE KEY" in open(pem).read()]
    if os.path.isdir(target):
        record["files"] = sorted(os.path.relpath(os.path.join(d, f), target)
                                 for d, _, fs in os.walk(target) for f in fs)
        record["manifest"] = json.load(open(target + "/Contents/Resources/bin/cmux-tui-ssh/manifest.json"))
    else:
        open(target, "ab").write(b"\nSIGNED")
# Only openssl may see the certificate secrets: the signer unsets them after the PEM exists.
record["secret_env"] = sorted(k for k in ("APPLE_CERTIFICATE_PASSWORD", "APPLE_CERTIFICATE_BASE64") if k in os.environ)
# rcodesign reads RCODESIGN_* variables as its own config: none may reach it.
record["config_env"] = sorted(k for k in os.environ if k.startswith("RCODESIGN_"))
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps(record) + "\n")
if argv[0] == os.environ.get("FAKE_FAIL") or argv[-1].endswith(os.environ.get("FAKE_FAIL_PATH") or "\0"):
    sys.exit("fake rcodesign failure")
if argv[0] == "print-signature-info":
    print("- path: " + argv[-1] + "\n  entity:\n    mach_o:\n      signature:\n        code_directory:")
    if b"ENTITLED" in open(argv[-1], "rb").read():
        print("        entitlements_plist:\n        - <plist><dict/></plist>")
'''

FAKE_OPENSSL = r'''
import json, os, sys
argv = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps({"tool": "openssl", "argv": argv}) + "\n")
if argv[0] == "pkcs12":
    if sys.stdin.buffer.read() != os.environb[b"FAKE_P12"] or os.environ["APPLE_CERTIFICATE_PASSWORD"] != os.environ["FAKE_PASSWORD"]:
        sys.exit("bad PKCS#12 or password")
    print("-----BEGIN CERTIFICATE-----\nQ0VSVA==\n-----END CERTIFICATE-----\n-----BEGIN PRIVATE KEY-----\nS0VZ\n-----END PRIVATE KEY-----")
elif "-subject" in argv:
    print("subject=\n    userId                    = TEAM123456\n    commonName                = " + os.environ["FAKE_CN"])
elif "-fingerprint" in argv:
    print("SHA1 Fingerprint=" + ":".join(os.environ["FAKE_SHA1"][i:i + 2] for i in range(0, 40, 2)))
else:
    sys.exit("unexpected openssl command")
'''

SHIM = r'''
import json, os, shutil, sys
name = os.path.basename(sys.argv[0])
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps({"tool": name, "argv": sys.argv[1:]}) + "\n")
real = sys.executable if name == "python3" else shutil.which(name, path=os.environ["FAKE_REAL_PATH"])
os.execv(real, [real] + sys.argv[1:])
'''
SHIMMED = ["base64", "grep", "rm", "awk", "find", "chmod", "tail", "mktemp", "python3", "realpath", "sed"]

FW = "Contents/Frameworks/"
CEF = FW + "Chromium Embedded Framework.framework/Versions/A/"
RBH = "Contents/Helpers/cmux-remote-browser-host.app/Contents/"
PAYLOAD = "Contents/Resources/bin/cmux-tui-ssh/cmux-tui-aarch64-apple-darwin"
LINUX_PAYLOAD = "Contents/Resources/bin/cmux-tui-ssh/cmux-tui-x86_64-unknown-linux-musl"


def helper_exe(root: str, name: str) -> str:
    return f"{root}{name}.app/Contents/MacOS/{name}"


HELPER = {"Contents/Resources/bin/cmux", "Contents/Resources/bin/cmux-diff-sidecar",
          "Contents/Library/cmux Computer Use.app/Contents/MacOS/cmux-computer-use"}
JIT = {helper_exe(FW, "cmux NEXT DEV Helper (GPU)"), helper_exe(FW, "cmux NEXT DEV Helper (Renderer)"),
       helper_exe(RBH + "Frameworks/", "cmux-remote-browser-host Helper (GPU)"),
       helper_exe(RBH + "Frameworks/", "cmux-remote-browser-host Helper (Renderer)")}
# Signed without entitlements, and their build signature has some: cleared.
CLEARED = {"Contents/Resources/libexec/cmux-server-helper", FW + "Sparkle.framework/Versions/B/Autoupdate",
           helper_exe(FW, "cmux NEXT DEV Helper"), RBH + "MacOS/cmux-remote-browser-host",
           helper_exe(RBH + "Frameworks/", "cmux-remote-browser-host Helper"),
           "Contents/PlugIns/Share.appex/Contents/MacOS/Share", CEF + "Libraries/libEGL.dylib"}
# Signed without scoped entitlements: none to clear, or codesign leaves them alone.
UNSCOPED = {"Contents/MacOS/cmux", FW + "Sparkle.framework/Versions/B/Sparkle", CEF + "Chromium Embedded Framework",
            FW + "libcmux_cef_shim.dylib", helper_exe(FW, "cmux NEXT DEV Helper (Plugin)"),
            "Contents/MacOS/cmux-extra", "Contents/Library/cmux Computer Use.app/Contents/Frameworks/libcu.dylib"}
KEEPS_OWN = {"Contents/MacOS/cmux-extra", "Contents/Library/cmux Computer Use.app/Contents/Frameworks/libcu.dylib"}
MACHOS = HELPER | JIT | CLEARED | UNSCOPED


def write(path: Path, data: bytes, mode: int = 0o755) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    path.chmod(mode)


def build_app(app: Path, bundle_id: str = BUNDLE_ID) -> None:
    write(app / "Contents/Info.plist", plistlib.dumps({"CFBundleExecutable": "cmux", "CFBundleIdentifier": bundle_id}))
    for rel in MACHOS:
        magic = b"\xca\xfe\xba\xbe\x00\x00\x00\x02" if rel.endswith("shim.dylib") else b"\xcf\xfa\xed\xfe"
        write(app / rel, magic + rel.encode() + (b"ENTITLED" if rel in CLEARED | JIT | KEEPS_OWN else b""))
        bundle = app / rel.rsplit("Contents/MacOS/", 1)[0]
        if "/MacOS/" in rel and not (bundle / "Contents/Info.plist").exists():
            write(bundle / "Contents/Info.plist", plistlib.dumps(
                {"CFBundleExecutable": rel.rsplit("/", 1)[1], "CFBundleIdentifier": bundle_id}), 0o644)
    for alias in ("cmux-tui", "acpmux"):
        (app / "Contents/Resources/bin" / alias).symlink_to("cmux")
    write(app / "Contents/Resources/bin/cmux-wrapper.sh", b"#!/bin/sh\n")
    write(app / "Contents/Resources/Classes/Probe.class", b"\xca\xfe\xba\xbe\x00\x00\x00\x34java")
    write(app / "Contents/Resources/cmux_Resources.bundle/Contents/Resources/strings.json", b"{}")
    write(app / "Contents/Resources/._cmux", b"appledouble")
    sparkle = app / FW / "Sparkle.framework"
    write(sparkle / "Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader", b"\xcf\xfa\xed\xfexpc")
    (sparkle / "Versions/Current").symlink_to("B")
    (app / RBH / "Frameworks/Chromium Embedded Framework.framework").symlink_to(
        "../../../../Frameworks/Chromium Embedded Framework.framework")
    tui = {PAYLOAD: b"\xcf\xfa\xed\xfetui", LINUX_PAYLOAD: b"\x7fELF tui"}
    for rel, data in tui.items():
        write(app / rel, data)
    manifest = {"binaries": {rel.rsplit("/", 1)[1]: hashlib.sha256(d).hexdigest() for rel, d in tui.items()}}
    write(app / "Contents/Resources/bin/cmux-tui-ssh/manifest.json", json.dumps(manifest).encode(), 0o644)


def options(argv: list[str], name: str) -> list[str]:
    return [argv[i + 1] for i, a in enumerate(argv[:-1]) if a == name]


class RcodesignSignBundleDevTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="rcodesign-dev-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.app = self.tmp / "unpacked/cmux NEXT DEV.app"
        build_app(self.app)
        self.log = self.tmp / "calls.jsonl"
        self.script_tmp = self.tmp / "script-tmp"
        self.script_tmp.mkdir()
        for directory, names, body in (("fakes", ["rcodesign"], FAKE_RCODESIGN), ("fakes", ["openssl"], FAKE_OPENSSL),
                                       ("shims", SHIMMED, SHIM)):
            for name in names:
                write(self.tmp / directory / name, f"#!{sys.executable}\n{body}".encode())
        real_path = os.environ.get("PATH", "/usr/bin:/bin")
        self.env = {
            "PATH": f"{self.tmp}/shims:{self.tmp}/fakes:{real_path}", "HOME": str(self.tmp), "LANG": "C.UTF-8",
            "TMPDIR": str(self.script_tmp), "FAKE_LOG": str(self.log), "FAKE_REAL_PATH": real_path,
            "FAKE_P12": P12.decode("latin-1"), "FAKE_PASSWORD": PASSWORD, "FAKE_CN": CN, "FAKE_SHA1": SHA1,
            "APPLE_CERTIFICATE_BASE64": P12_BASE64, "APPLE_CERTIFICATE_PASSWORD": PASSWORD,
            "APPLE_SIGNING_IDENTITY": CN,
        }

    def run_script(self, ok: bool = True, **env: str) -> subprocess.CompletedProcess[str]:
        self.log.unlink(missing_ok=True)
        result = subprocess.run(["bash", str(SCRIPT), str(self.app), str(APP_ENTITLEMENTS)], cwd=ROOT,
                                env={**self.env, **env}, stdin=subprocess.DEVNULL, capture_output=True,
                                text=True, timeout=120)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        self.assertEqual(list(self.script_tmp.iterdir()), [], "the script left temporary files behind")
        return result

    def calls(self, tool: str | None = None, first: str | None = None) -> list[dict]:
        entries = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return [e for e in entries if (tool is None or e["tool"] == tool) and (first is None or e["argv"][0] == first)]

    def signs(self, target: Path) -> list[dict]:
        return [c for c in self.calls("rcodesign", "sign") if c["argv"][-1] == str(target)]

    def test_no_rcodesign_config_variable_reaches_rcodesign(self) -> None:
        """DEV publish 40454509260: a job's RCODESIGN_DMG_SHA256 failed rcodesign sign
        ("problem key: dmg ... UnknownField"). The signer scrubs RCODESIGN_* first."""
        self.run_script(RCODESIGN_DMG_SHA256="0" * 64, RCODESIGN_FROM_IMAGE="1")
        calls = self.calls("rcodesign")
        self.assertTrue(calls)
        self.assertEqual({tuple(c["config_env"]) for c in calls}, {()})

    def test_no_workflow_hands_rcodesign_a_config_variable(self) -> None:
        """No env key named RCODESIGN_* in any workflow; each signer script and each workflow step
        that calls "$RCODESIGN" itself scrubs RCODESIGN_* first."""
        import re
        scrub = re.compile(r"""compgen -e \| grep ['"]\^RCODESIGN_['"]""")
        for path in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
            text = path.read_text()
            self.assertIsNone(re.search(r"^\s+RCODESIGN_[A-Za-z0-9_]*\s*:", text, re.M), path.name)
            self.assertNotIn("RCODESIGN_", scrub.sub("", re.sub(r"#.*", "", text)), path.name)
            for step in re.split(r"\n\s+- (?=name:|uses:|run:)", text):
                if re.search(r'"\$RCODESIGN"\s+\w', step):
                    self.assertRegex(step, scrub, f"{path.name}: a step calls rcodesign without the scrub")
        for script in ("rcodesign-notarize-dmg-dev.sh", "rcodesign-sign-bundle-dev.sh"):
            text = (ROOT / "scripts/ci" / script).read_text()
            first_call = re.search(r'"\$R" [a-z]', text).start()  # not `command -v "$R"`
            self.assertLess(scrub.search(text).start(), first_call, script)

    def test_components_get_feat_cmux_next_treatment(self) -> None:
        self.run_script()
        [sign] = self.signs(self.app)
        argv, ents = sign["argv"], sign["entitlements"]
        flags = options(argv, "--code-signature-flags")
        self.assertEqual(set(flags), {"runtime"} | {f"{rel}:runtime" for rel in MACHOS})
        self.assertIn("--for-notarization", argv)
        self.assertNotIn("--timestamp-url", argv)
        self.assertEqual(plistlib.loads(ents.pop("").encode()), plistlib.loads(APP_ENTITLEMENTS.read_bytes()))
        jit = {"com.apple.security.cs.allow-jit": True}
        computer_use = "Contents/Library/cmux Computer Use.app/Contents/MacOS/cmux-computer-use"
        generic_helpers = HELPER - {computer_use}
        self.assertEqual({rel: text for rel, text in ents.items() if rel in generic_helpers},
                         dict.fromkeys(generic_helpers, HELPER_TEXT))
        computer_use_entitlements = plistlib.loads(ents[computer_use].encode())
        self.assertIs(computer_use_entitlements.get("com.apple.security.automation.apple-events"), True)
        self.assertNotIn("com.apple.security.automation.apple-events", plistlib.loads(HELPER_TEXT.encode()))
        self.assertEqual({rel: plistlib.loads(ents[rel].encode()) for rel in JIT}, dict.fromkeys(JIT, jit))
        self.assertEqual({rel: plistlib.loads(ents[rel].encode()) for rel in CLEARED}, dict.fromkeys(CLEARED, {}))
        self.assertEqual(set(ents), HELPER | JIT | CLEARED)
        self.assertEqual(options(argv, "--binary-identifier"),
                         ["Contents/Resources/libexec/cmux-server-helper:cmux-server-helper"])
        self.assertEqual(sorted(options(argv, "--exclude")),
                         ["Contents/Resources/bin/cmux-tui-ssh/**", "Contents/Resources/cmux_Resources.bundle"])
        verified = {c["argv"][-1] for c in self.calls("rcodesign", "verify")}
        self.assertEqual(verified, {str(self.app / rel) for rel in MACHOS | {PAYLOAD}})

    def test_bundle_is_prepared_before_it_is_signed(self) -> None:
        self.run_script()
        [sign] = self.signs(self.app)
        files = set(sign["files"])
        daemon, agent = (f"Contents/Library/{d}/{n}" for d, n in
                         (("LaunchDaemons", "com.cmux.server.helper.plist"), ("LaunchAgents", "com.cmux.server.plist")))
        self.assertLessEqual({daemon, agent}, files)
        self.assertFalse({f for f in files if "XPCServices" in f or "/._" in f})
        self.assertEqual(plistlib.loads((self.app / daemon).read_bytes()), {
            "Label": f"{BUNDLE_ID}.server-helper", "BundleProgram": "Contents/Resources/libexec/cmux-server-helper",
            "AssociatedBundleIdentifiers": [BUNDLE_ID], "ProgramArguments": ["cmux-server-helper", "--app", BUNDLE_ID],
            "MachServices": {f"{BUNDLE_ID}.server-helper": True}})
        self.assertEqual(plistlib.loads((self.app / agent).read_bytes()), {
            "Label": f"{BUNDLE_ID}.server", "BundleProgram": "Contents/Resources/bin/cmux",
            "AssociatedBundleIdentifiers": [BUNDLE_ID], "RunAtLoad": True, "ThrottleInterval": 10,
            "ProgramArguments": ["Contents/Resources/bin/cmux", "host", "run", "--mode", "user"],
            "KeepAlive": {"SuccessfulExit": False}, "ProcessType": "Standard"})
        # The SSH payload is signed alone, before the bundle, which seals its new pin.
        payload, linux = self.app / PAYLOAD, self.app / LINUX_PAYLOAD
        [alone] = self.signs(payload)
        self.assertLess(self.calls().index(alone), self.calls().index(sign))
        self.assertEqual(options(alone["argv"], "--code-signature-flags"), ["runtime"])
        self.assertEqual(list(alone["entitlements"].values()), [HELPER_TEXT])
        self.assertTrue(payload.read_bytes().endswith(b"SIGNED"))
        pins = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (payload, linux)}
        self.assertEqual(sign["manifest"]["binaries"], pins)

    def test_stable_bundle_id_drops_the_server_jobs(self) -> None:
        info = self.app / "Contents/Info.plist"
        info.write_bytes(plistlib.dumps({"CFBundleExecutable": "cmux", "CFBundleIdentifier": "com.cmuxterm.app"}))
        self.run_script()
        self.assertFalse((self.app / "Contents/Library/LaunchDaemons").exists())
        self.assertFalse((self.app / "Contents/Library/LaunchAgents").exists())
        self.assertFalse((self.app / "Contents/Resources/libexec/cmux-server-helper").exists())

    def test_key_material_stays_off_argv_and_is_removed(self) -> None:
        self.run_script()
        signs = self.calls("rcodesign", "sign")
        [pem] = {p for c in signs for p in options(c["argv"], "--pem-file")}
        self.assertTrue(all(c["pem"][0] & 0o077 == 0 and c["pem"][1] == 0o700 and c["pem"][2] for c in signs))
        key_dir = str(Path(pem).parent)
        self.assertLessEqual({"openssl", "python3", "base64", "rm"}, {c["tool"] for c in self.calls()})
        for call in self.calls():
            for i, arg in enumerate(call["argv"]):
                for secret in (P12_BASE64, PASSWORD, P12.decode("latin-1")):
                    self.assertNotIn(secret, arg, call)
                if pem in arg or (key_dir in arg and call["tool"] != "rm"):
                    self.assertEqual((call["tool"], call["argv"][i - 1], arg), ("rcodesign", "--pem-file", pem))
        self.assertFalse(Path(key_dir).exists())
        # The secrets are unset once the PEM exists: no rcodesign call inherits them.
        self.assertEqual({tuple(c["secret_env"]) for c in self.calls("rcodesign")}, {()})

    def test_failures_fail_the_script(self) -> None:
        cases = [{"FAKE_FAIL": "sign"}, {"FAKE_FAIL": "verify"},
                 {"FAKE_FAIL_PATH": "Sparkle.framework/Versions/B/Autoupdate"},  # print-signature-info probe
                 {"APPLE_CERTIFICATE_PASSWORD": "not-the-password"},
                 {"APPLE_SIGNING_IDENTITY": "Developer ID Application: Someone Else (OTHER12345)"},
                 {"APPLE_SIGNING_IDENTITY": "CD" * 20}]
        for env in cases:
            with self.subTest(**env):
                result = self.run_script(ok=False, **env)
                if "FAKE_FAIL_PATH" in env:
                    self.assertIn("print-signature-info failed for " + FW + env["FAKE_FAIL_PATH"], result.stderr)
                    self.assertEqual(self.signs(self.app), [])
                if "APPLE_SIGNING_IDENTITY" in env or "APPLE_CERTIFICATE_PASSWORD" in env:
                    self.assertEqual(self.calls("rcodesign", "sign"), [])
                    self.assertNotIn(env.get("APPLE_SIGNING_IDENTITY", "\0"), result.stdout + result.stderr)
        self.run_script(APPLE_SIGNING_IDENTITY=SHA1.lower())

    def test_system_extension_is_refused(self) -> None:
        write(self.app / "Contents/Library/SystemExtensions/t.systemextension/Contents/MacOS/t", b"\xcf\xfa\xed\xfe")
        self.assertIn("no Cloud tunnel", self.run_script(ok=False).stderr)
        self.assertEqual(self.calls("rcodesign", "sign"), [])


if __name__ == "__main__":
    unittest.main()
