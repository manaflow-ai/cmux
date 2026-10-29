#!/usr/bin/env python3
"""scripts/ci/release-signer/sign-app.sh gives each component of a cmux NEXT
bundle what scripts/sign-cmux-bundle.sh gives it, and keeps the key off every
command line.

A fake signer and a fake openssl record their argv, plus what the signer saw
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
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/release-signer/sign-app.sh"
APP_ENTITLEMENTS = ROOT / "cmux.next-dev.entitlements"
HELPER_TEXT = (ROOT / "cmux-helper.entitlements").read_text()

P12 = b"dummy-pkcs12-\x01\x02-identity"
P12_BASE64 = base64.b64encode(P12).decode()
PASSWORD = "dummy-p12-password-9f3a"
CN = "Developer ID Application: Example Corp (TEAM123456)"
SHA1 = "AB" * 20
BUNDLE_ID = "com.cmuxterm.app.debug.next"

FAKE_SIGNER = r'''
import json, os, stat, sys
argv = sys.argv[1:]
record = {"tool": "signer", "argv": argv}
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
        manifest = target + "/Contents/Resources/bin/cmux-tui-ssh/manifest.json"
        record["manifest"] = json.load(open(manifest)) if os.path.exists(manifest) else None
        import plistlib
        record["nonce"] = "CMUXNotarizationSubmission" in plistlib.load(open(target + "/Contents/Info.plist", "rb"))
    else:
        open(target, "ab").write(b"\nSIGNED")
# Only openssl may see the certificate secrets: the signer unsets them after the PEM exists.
record["secret_env"] = sorted(k for k in ("APPLE_CERTIFICATE_PASSWORD", "APPLE_CERTIFICATE_BASE64") if k in os.environ)
# The signer reads RCODESIGN_* variables as its own config: none may reach it.
record["config_env"] = sorted(k for k in os.environ if k.startswith("RCODESIGN_"))
record["notary_key_env"] = "ASC_API_KEY_P8_BASE64" in os.environ or os.environ.get("p8", "exported-by-the-caller") != "exported-by-the-caller"
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps(record) + "\n")
if argv[0] == os.environ.get("FAKE_FAIL") or argv[-1].endswith(os.environ.get("FAKE_FAIL_PATH") or "\0"):
    sys.exit("fake signer failure")
if argv[0] == "encode-app-store-connect-api-key":
    open(argv[argv.index("-o") + 1], "w").write("{}")
if argv[0] == "notary-submit":
    print("created submission ID: 0f0e0d0c-0b0a-4908-8706-050403020100")
    if os.environ.get("FAKE_NOTARY") == "timeout":
        sys.exit("Error: reached time limit waiting for notarization to complete")
    print("poll state after 30s: " + ("Invalid" if os.environ.get("FAKE_NOTARY") == "invalid" else "Accepted"))
    if os.environ.get("FAKE_NOTARY") == "invalid":
        sys.exit("notarization failed: Invalid")
    if os.environ.get("FAKE_NOTARY") in ("nolog", "latelog"):
        sys.exit("error interacting with Notary API: log not found")
if argv[0] == "notary-log":
    if os.environ.get("FAKE_NOTARY") == "nolog":
        sys.exit("log not ready")
    if os.environ.get("FAKE_NOTARY") == "latelog" and sum(1 for _ in open(os.environ["FAKE_LOG"])) and \
            [json.loads(l)["argv"][0] for l in open(os.environ["FAKE_LOG"])].count("notary-log") < 2:
        sys.exit("log not ready")
    print(json.dumps({"status": "Accepted", "ticketContents": [{"arch": "arm64", "cdhash": os.environ["FAKE_TICKET"]}]}))
if argv[0] == "staple":
    ticket = argv[-1] + "/Contents/CodeResources"
    open(ticket, "wb").write(b"ticket" + bytes.fromhex(os.environ.get("FAKE_STAPLED", os.environ["FAKE_TICKET"])))
    os.chmod(ticket, 0o600)
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
    log.write(json.dumps({"tool": name, "argv": sys.argv[1:], "notary_key_env": "ASC_API_KEY_P8_BASE64" in os.environ or os.environ.get("p8", "exported-by-the-caller") != "exported-by-the-caller"}) + "\n")
real = sys.executable if name == "python3" else shutil.which(name, path=os.environ["FAKE_REAL_PATH"])
os.execv(real, [real] + sys.argv[1:])
'''
SHIMMED = ["base64", "grep", "rm", "awk", "find", "chmod", "tail", "mktemp", "python3", "realpath", "sed", "dirname"]

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


NOTARY_KEY_ARGS = {"encode-app-store-connect-api-key": {"api-key.json", "AuthKey.p8"},
                   "notary-submit": {"api-key.json"}, "notary-log": {"api-key.json"}}


def options(argv: list[str], name: str) -> list[str]:
    return [argv[i + 1] for i, a in enumerate(argv[:-1]) if a == name]


class SignAppTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="sign-app-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.app = self.tmp / "unpacked/cmux NEXT DEV.app"
        build_app(self.app)
        self.log = self.tmp / "calls.jsonl"
        self.script_tmp = self.tmp / "script-tmp"
        self.script_tmp.mkdir()
        for directory, names, body in (("fakes", ["signer"], FAKE_SIGNER), ("fakes", ["openssl"], FAKE_OPENSSL),
                                       ("shims", SHIMMED, SHIM)):
            for name in names:
                write(self.tmp / directory / name, f"#!{sys.executable}\n{body}".encode())
        real_path = os.environ.get("PATH", "/usr/bin:/bin")
        self.env = {
            "PATH": f"{self.tmp}/shims:{self.tmp}/fakes:{real_path}", "HOME": str(self.tmp), "LANG": "C.UTF-8",
            "TMPDIR": str(self.script_tmp), "FAKE_LOG": str(self.log), "FAKE_REAL_PATH": real_path,
            "FAKE_P12": P12.decode("latin-1"), "FAKE_PASSWORD": PASSWORD, "FAKE_CN": CN, "FAKE_SHA1": SHA1,
            "APPLE_CERTIFICATE_BASE64": P12_BASE64, "APPLE_CERTIFICATE_PASSWORD": PASSWORD,
            "APPLE_SIGNING_IDENTITY": CN, "CMUX_SIGNER": f"{self.tmp}/fakes/signer",
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
        return [c for c in self.calls("signer", "sign") if c["argv"][-1] == str(target)]

    def test_no_config_variable_reaches_the_signer(self) -> None:
        """DEV publish 40454509260: a job's RCODESIGN_DMG_SHA256 failed the signer
        ("problem key: dmg ... UnknownField"). The script scrubs RCODESIGN_* first."""
        self.run_script(RCODESIGN_DMG_SHA256="0" * 64, RCODESIGN_FROM_IMAGE="1")
        calls = self.calls("signer")
        self.assertTrue(calls)
        self.assertEqual({tuple(c["config_env"]) for c in calls}, {()})

    def test_no_workflow_hands_the_signer_a_config_variable(self) -> None:
        """No RCODESIGN_* variable in any workflow; each workflow step that calls
        "$CMUX_SIGNER" scrubs RCODESIGN_* first, and each release signer script
        calls the signer only through run_signer."""
        import re
        scrub = re.compile(r"""compgen -e \| grep ['"]\^RCODESIGN_['"]""")
        for path in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
            text = path.read_text()
            self.assertIsNone(re.search(r"^\s+RCODESIGN_[A-Za-z0-9_]*\s*:", text, re.M), path.name)
            self.assertNotIn("RCODESIGN_", scrub.sub("", re.sub(r"#.*", "", text)), path.name)
            for step in re.split(r"\n\s+- (?=name:|uses:|run:)", text):
                if re.search(r'"\$\{?CMUX_SIGNER\}?"\s+\w', step):
                    self.assertRegex(step, scrub, f"{path.name}: a step calls the signer without the scrub")
        # Each release signer script calls the signer only through run_signer
        # (signer-env.sh), which keeps every RCODESIGN_* name from it.
        for script in sorted((ROOT / "scripts/ci/release-signer").glob("*.sh")):
            text = re.sub(r"#.*", "", script.read_text())
            calls = [line for line in text.splitlines() if re.search(r'"\$R" [a-z]', line)]
            if calls:
                self.assertIn("signer-env.sh", text, script.name)
                self.assertEqual([c for c in calls if "run_signer " not in c], [], script.name)

    def test_needs_the_signer_variable(self) -> None:
        self.env.pop("CMUX_SIGNER")
        self.assertIn("CMUX_SIGNER", self.run_script(ok=False).stderr)

    def test_components_get_the_sign_cmux_bundle_treatment(self) -> None:
        self.run_script()
        [sign] = self.signs(self.app)
        argv, ents = sign["argv"], sign["entitlements"]
        flags = options(argv, "--code-signature-flags")
        self.assertEqual(set(flags), {"runtime"} | {f"{rel}:runtime" for rel in MACHOS})
        self.assertIn("--for-notarization", argv)
        self.assertNotIn("--timestamp-url", argv)
        self.assertEqual(plistlib.loads(ents.pop("").encode()), plistlib.loads(APP_ENTITLEMENTS.read_bytes()))
        jit = {"com.apple.security.cs.allow-jit": True}
        self.assertEqual({rel: text for rel, text in ents.items() if rel in HELPER}, dict.fromkeys(HELPER, HELPER_TEXT))
        self.assertEqual({rel: plistlib.loads(ents[rel].encode()) for rel in JIT}, dict.fromkeys(JIT, jit))
        self.assertEqual({rel: plistlib.loads(ents[rel].encode()) for rel in CLEARED}, dict.fromkeys(CLEARED, {}))
        self.assertEqual(set(ents), HELPER | JIT | CLEARED)
        self.assertEqual(options(argv, "--binary-identifier"),
                         ["Contents/Resources/libexec/cmux-server-helper:cmux-server-helper"])
        self.assertEqual(sorted(options(argv, "--exclude")),
                         ["Contents/Resources/bin/cmux-tui-ssh/**", "Contents/Resources/cmux_Resources.bundle"])
        verified = {c["argv"][-1] for c in self.calls("signer", "verify")}
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
        signs = self.calls("signer", "sign")
        [pem] = {p for c in signs for p in options(c["argv"], "--pem-file")}
        self.assertTrue(all(c["pem"][0] & 0o077 == 0 and c["pem"][1] == 0o700 and c["pem"][2] for c in signs))
        key_dir = str(Path(pem).parent)
        self.assertLessEqual({"openssl", "python3", "base64", "rm"}, {c["tool"] for c in self.calls()})
        for call in self.calls():
            for i, arg in enumerate(call["argv"]):
                for secret in (P12_BASE64, PASSWORD, P12.decode("latin-1")):
                    self.assertNotIn(secret, arg, call)
                if pem in arg or (key_dir in arg and call["tool"] != "rm"):
                    # helper-first: the notary key, written and read only as files in the same directory.
                    argv = call["argv"]
                    if call["tool"] == "python3" and argv[0].endswith("run_with_timeout.py"):
                        argv = argv[argv.index("--") + 2:]  # the bounded notary-log call
                    if arg != pem and call["tool"] in ("signer", "python3") and argv and argv[0] in NOTARY_KEY_ARGS:
                        self.assertIn(Path(arg).name, NOTARY_KEY_ARGS[argv[0]], call)
                        continue
                    self.assertEqual((call["tool"], call["argv"][i - 1], arg), ("signer", "--pem-file", pem))
        self.assertFalse(Path(key_dir).exists())
        # The secrets are unset once the PEM exists: no signer call inherits them.
        self.assertEqual({tuple(c["secret_env"]) for c in self.calls("signer")}, {()})

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
                    self.assertEqual(self.calls("signer", "sign"), [])
                    self.assertNotIn(env.get("APPLE_SIGNING_IDENTITY", "\0"), result.stdout + result.stderr)
        self.run_script(APPLE_SIGNING_IDENTITY=SHA1.lower())

    def test_system_extension_is_refused(self) -> None:
        write(self.app / "Contents/Library/SystemExtensions/t.systemextension/Contents/MacOS/t", b"\xcf\xfa\xed\xfe")
        self.assertIn("no Cloud tunnel", self.run_script(ok=False).stderr)
        self.assertEqual(self.calls("signer", "sign"), [])


CU = "Contents/Library/cmux Computer Use.app"
CU_EXE = CU + "/Contents/MacOS/cmux-computer-use"


def signed_macho(tag: bytes, cpu: int = 0x0100000C) -> tuple[bytes, str]:
    """A thin Mach-O with one SHA-256 CodeDirectory, and its CDHash."""
    cd = bytearray(struct.pack(">II", 0xFADE0C02, 44) + b"\0" * 36)
    cd[37] = 2
    cd = bytes(cd[:40]) + tag[:4].ljust(4, b"\0")
    sig = struct.pack(">III", 0xFADE0CC0, 20 + len(cd), 1) + struct.pack(">II", 0, 20) + cd
    head = struct.pack("<IIIIIIII", 0xFEEDFACF, cpu, 0, 2, 1, 16, 0, 0)
    body = head + struct.pack("<IIII", 0x1D, 16, 48, len(sig))
    return body + sig, hashlib.sha256(cd).hexdigest()[:40]


class HelperFirstTest(SignAppTest):
    """CMUX_SIGN_MODE=helper-first: the Computer Use helper is signed alone,
    notarized, checked and stapled before the rest of the bundle is signed
    around it, as notarize-computer-use-helper.sh and all-except-computer-use."""

    def setUp(self) -> None:
        super().setUp()
        macho, self.cdhash = signed_macho(b"cua1")
        write(self.app / CU_EXE, macho)
        self.env.update(CMUX_SIGN_MODE="helper-first", FAKE_TICKET=self.cdhash, ASC_API_KEY_ID="KEYID12345",
                        ASC_API_ISSUER_ID="issuer", ASC_API_KEY_P8_BASE64=base64.b64encode(b"p8-key-9c1e").decode())

    def test_components_get_the_sign_cmux_bundle_treatment(self) -> None:
        pass  # the bundle pass below leaves the helper out; the rest is SignAppTest's

    def test_helper_is_notarized_and_stapled_before_the_app_is_signed(self) -> None:
        self.run_script()
        order = [(c["argv"][0], c["argv"][-1]) for c in self.calls("signer") if c["argv"][0] != "print-signature-info"]
        helper, app = str(self.app / CU), str(self.app)
        steps = [o for o in order if o[1] in (helper, app) or o[0] in ("notary-log", "encode-app-store-connect-api-key")]
        self.assertEqual([s[0] for s in steps], ["encode-app-store-connect-api-key", "sign", "notary-submit",
                                                  "notary-log", "staple", "sign"])
        self.assertEqual([s[1] for s in steps if s[0] in ("sign", "notary-submit", "staple")],
                         [helper, helper, helper, app])
        [alone] = self.signs(self.app / CU)
        self.assertTrue(alone["nonce"], "the submission nonce goes in before the helper is signed")
        self.assertEqual(alone["entitlements"], {"": HELPER_TEXT})
        self.assertIn("--for-notarization", alone["argv"])
        self.assertEqual(sorted(options(alone["argv"], "--code-signature-flags")),
                         ["Contents/Frameworks/libcu.dylib:runtime", "Contents/MacOS/cmux-computer-use:runtime", "runtime"])
        # Checked after signing and after stapling, in place and as a standalone copy.
        verified = [c["argv"][-1] for c in self.calls("signer", "verify")]
        self.assertEqual(verified.count(str(self.app / CU_EXE)), 3)
        self.assertTrue(any(v.endswith("/standalone.app/Contents/MacOS/cmux-computer-use") for v in verified))
        ticket = self.app / CU / "Contents/CodeResources"
        self.assertEqual(ticket.read_bytes(), b"ticket" + bytes.fromhex(self.cdhash))
        self.assertEqual(ticket.stat().st_mode & 0o777, 0o644)
        # The bundle pass keeps the helper's signature and ticket: excluded, no scoped settings.
        [sign] = self.signs(self.app)
        self.assertEqual(sorted(options(sign["argv"], "--exclude"))[:2], [CU, CU + "/**"])
        self.assertFalse([v for v in options(sign["argv"], "--entitlements-xml-file")
                          + options(sign["argv"], "--code-signature-flags") if v.startswith(CU)])
        self.assertEqual(set(sign["entitlements"]), (HELPER - {CU_EXE}) | JIT | CLEARED | {""})
        # The API key reached the signer only as a file, never in its environment.
        for call in self.calls():
            self.assertNotIn(self.env["ASC_API_KEY_P8_BASE64"], " ".join(call["argv"]))
        self.assertEqual({c["notary_key_env"] for c in self.calls("signer")}, {False})

    def test_a_ticket_that_misses_a_slice_stops_before_anything_else(self) -> None:
        for env, stops_after in (({"FAKE_TICKET": "ab" * 20}, "notary-log"), ({"FAKE_STAPLED": "cd" * 20}, "staple"),
                                 ({"FAKE_NOTARY": "invalid"}, "notary-submit")):
            with self.subTest(**env):
                result = self.run_script(ok=False, **env)
                self.assertEqual(self.signs(self.app), [])
                self.assertEqual(self.calls("signer")[-1]["argv"][0], stops_after, result.stderr)
        for notary in ("timeout", "nolog"):
            with self.subTest(notary=notary):
                result = self.run_script(ok=False, FAKE_NOTARY=notary, CMUX_HELPER_LOG_RETRY_SECONDS="0")
                self.assertEqual(result.returncode, 75, result.stderr)
                self.assertEqual(self.signs(self.app), [])
        self.assertEqual(len(self.calls("signer", "notary-log")), 4)

    def test_an_accepted_helper_whose_log_is_late_goes_on(self) -> None:
        """notary-submit --wait fails when Apple has accepted but its log is not
        ready; the bounded log reads take over, and signing goes on."""
        self.run_script(FAKE_NOTARY="latelog", CMUX_HELPER_LOG_RETRY_SECONDS="0")
        self.assertEqual(len(self.calls("signer", "notary-log")), 2)
        self.assertEqual(len(self.signs(self.app)), 1)

    def test_an_unstamped_signature_is_not_submitted(self) -> None:
        self.assertIn("cannot be notarized", self.run_script(ok=False, CMUX_TIMESTAMP="none").stderr)
        self.assertEqual(self.calls("signer"), [])

    def test_needs_the_notary_key(self) -> None:
        for name in ("ASC_API_KEY_ID", "ASC_API_KEY_P8_BASE64"):
            with self.subTest(name=name):
                self.run_script(ok=False, **{name: ""})
                self.assertEqual(self.calls("signer", "sign"), [])

    def test_no_child_process_sees_the_notary_key(self) -> None:
        result = self.run_script(p8="exported-by-the-caller", SHELLOPTS="allexport:braceexpand:hashall:interactive-comments:xtrace")
        self.assertNotIn(self.env["ASC_API_KEY_P8_BASE64"], result.stdout + result.stderr)
        self.assertEqual({c["notary_key_env"] for c in self.calls("signer")}, {False})
        shims = [c for c in self.calls() if c["tool"] != "signer"]
        self.assertTrue(shims)
        self.assertEqual([c for c in shims if c.get("notary_key_env")], [])


class SliceCdhashesTest(unittest.TestCase):
    """slice-cdhashes.py prints what slice_cdhashes (lipo, codesign -d) prints."""

    def test_universal_helper(self) -> None:
        arm, arm_hash = signed_macho(b"arm1")
        x86, x86_hash = signed_macho(b"x861", cpu=0x01000007)
        fat = struct.pack(">II", 0xCAFEBABE, 2) + struct.pack(">iiIII", 0x01000007, 3, 4096, len(x86), 12)
        fat += struct.pack(">iiIII", 0x0100000C, 0, 8192, len(arm), 14)
        fat = fat.ljust(4096, b"\0") + x86.ljust(4096, b"\0") + arm
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "h.app"
            write(app / "Contents/Info.plist", plistlib.dumps({"CFBundleExecutable": "h"}))
            write(app / "Contents/MacOS/h", fat)
            out = subprocess.run([sys.executable, "-I", str(SCRIPT.parent / "slice-cdhashes.py"), str(app)],
                                 capture_output=True, text=True, check=True).stdout
        self.assertEqual(out, f"arm64={arm_hash}\nx86_64={x86_hash}\n")


if __name__ == "__main__":
    unittest.main()
