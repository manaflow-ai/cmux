#!/usr/bin/env python3
"""The Windows installer of the cmux daemon, built and signed on Linux (cmuxterm-hq
docs/findings/2026-11-25-linux-everything-map.md, piece D4; RFD 0157 step 4: "MSI or MSIX, then winget").

The input is the cross-build-windows artifact (scripts/ci/windows-gnu-cross-build.sh): five
`<name>-x86_64-pc-windows-gnu.exe` files. The output is one per-user MSI (no administrator prompt) that installs
them under %LOCALAPPDATA%\\Programs\\cmux\\bin, with cmux-tui named cmux.exe as web/public/tui/install-static.ps1
installs it, appends that folder to the user's PATH and removes it again on uninstall. A newer MSI replaces an
older or equal one (one entry in Apps, never two side by side); an older one refuses to install over a newer one.

wixl (msitools) builds the database. wixl 0.103 has no <Environment> element and does not schedule its actions,
so the PATH row and WriteEnvironmentStrings/RemoveEnvironmentStrings go in afterwards with msibuild, and the
upgrade row is made inclusive of the same version.

Signing (Authenticode, osslsigncode): with CMUX_WINDOWS_SIGN_PFX_B64 (a base64 PKCS#12) and
CMUX_WINDOWS_SIGN_PFX_PASSWORD set, every exe is signed before it goes in the MSI and the MSI after, each with an
RFC 3161 timestamp from CMUX_WINDOWS_SIGN_TIMESTAMP_URL (default http://timestamp.digicert.com). Without them the
MSI is unsigned and the manifest says so; --require-signed turns that into a failure (for a release).
--test-sign signs with a throwaway self-signed certificate instead and verifies against it, so every run proves
the signing path works before a real certificate exists. Secrets are never printed.

  build --dist DIR --version V --out MSI [--require-signed | --test-sign]
      build, sign, verify and write MSI plus MSI.json: {version, msi_version, sha256, size, signed, signer, files}.
  verify --msi MSI [--ca PEM]
      read an MSI back: every expected file at its size, the PATH row and its actions, the upgrade rows;
      with --ca also the Authenticode signature of the MSI.
  msi-version V
      print the MSI ProductVersion of V (X.Y.Z; a prerelease or build suffix dropped).
  wine-roundtrip --msi MSI [--older MSI2]
      install MSI with Wine's msiexec into a fresh prefix ($WINEPREFIX, else a temporary one): every file in
      %LOCALAPPDATA%\\Programs\\cmux\\bin and that folder on the user PATH; install it again (one Apps entry,
      not two); with --older, that lower version must refuse to install over it; uninstall: the folder and the
      PATH entry are gone. What Wine cannot show (SmartScreen, a real user profile) stays a Windows check.
"""
import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
from xml.sax.saxutils import quoteattr

TARGET = "x86_64-pc-windows-gnu"
# (artifact base name, installed file name). cmux-tui installs as cmux.exe, as install-static.ps1 does.
FILES = [
    ("cmux-tui", "cmux.exe"),
    ("cmux-tui-hook", "cmux-tui-hook.exe"),
    ("cmux-tui-host", "cmux-tui-host.exe"),
    ("cmux-relay", "cmux-relay.exe"),
    ("chatmux-relay", "chatmux-relay.exe"),
]
# Fixed for the life of the product: Windows finds the installed cmux to upgrade by this code.
UPGRADE_CODE = "6f1d6a8e-3b0c-4c5e-9a57-0c3d2b1e9f41"
# Fixed: the PATH component must keep its GUID across versions so uninstall removes the entry it wrote.
PATH_COMPONENT_GUID = "6f1d6a8e-3b0c-4c5e-9a57-0c3d2b1e9f42"
NAMESPACE = uuid.UUID("6f1d6a8e-3b0c-4c5e-9a57-0c3d2b1e9f40")
DEFAULT_TIMESTAMP_URL = "http://timestamp.digicert.com"
MSI_VERSION_UPGRADE_INCLUSIVE = 512  # msidbUpgradeAttributesVersionMaxInclusive


class Fail(Exception):
    pass


def run(argv, secret=None):
    """Run a tool; on failure raise with its output, never echoing `secret`."""
    p = subprocess.run(argv, capture_output=True, text=True)
    if p.returncode != 0:
        shown = " ".join("***" if secret is not None and a == secret else a for a in argv)
        raise Fail(f"{shown}: exit {p.returncode}\n{p.stdout}{p.stderr}")
    return p.stdout


def msi_version(version):
    """MSI ProductVersion is major.minor.build with major, minor < 256 and build < 65536.

    The shared stable version is X.Y.Z; channel builds carry a prerelease or build suffix (0.0.0-r2.sha-...),
    which an MSI cannot hold, so it keeps X.Y.Z and an equal-version MSI still replaces the installed one.
    """
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$", version)
    if not m:
        raise Fail(f"version {version!r} is not X.Y.Z[-pre][+build]")
    a, b, c = (int(x) for x in m.groups())
    if a > 255 or b > 255 or c > 65535:
        raise Fail(f"version {version!r} is out of the MSI range (255.255.65535)")
    return f"{a}.{b}.{c}"


def wxs(version, staged):
    components = []
    refs = []
    for i, (_, name) in enumerate(FILES):
        cid = f"c{i}"
        # A stable GUID per installed file name, so an upgrade replaces the same component.
        guid = uuid.uuid5(NAMESPACE, name)
        components.append(
            f'              <Component Id="{cid}" Guid="{guid}" Win64="yes">\n'
            f'                <File Id="f{i}" Source={quoteattr(os.path.join(staged, name))} Name="{name}" KeyPath="yes"/>\n'
            f"              </Component>"
        )
        refs.append(f'<ComponentRef Id="{cid}"/>')
    components.append(
        f'              <Component Id="cpath" Guid="{PATH_COMPONENT_GUID}" Win64="yes">\n'
        '                <RegistryValue Root="HKCU" Key="Software\\Manaflow\\cmux" Name="PathEntry" Type="integer" Value="1" KeyPath="yes"/>\n'
        "              </Component>"
    )
    refs.append('<ComponentRef Id="cpath"/>')
    body = "\n".join(components)
    return f"""<?xml version="1.0" encoding="utf-8"?>
<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">
  <Product Id="*" Name="cmux" Language="1033" Version="{version}" Manufacturer="Manaflow" UpgradeCode="{UPGRADE_CODE}">
    <Package InstallerVersion="500" Compressed="yes" InstallScope="perUser"/>
    <MajorUpgrade DowngradeErrorMessage="A newer cmux is already installed."/>
    <Media Id="1" Cabinet="cmux.cab" EmbedCab="yes"/>
    <Property Id="ALLUSERS" Value="2"/>
    <Property Id="MSIINSTALLPERUSER" Value="1"/>
    <Property Id="ARPURLINFOABOUT" Value="https://cmux.com"/>
    <Directory Id="TARGETDIR" Name="SourceDir">
      <Directory Id="LocalAppDataFolder">
        <Directory Id="ProgramsDir" Name="Programs">
          <Directory Id="INSTALLDIR" Name="cmux">
            <Directory Id="BinDir" Name="bin">
{body}
            </Directory>
          </Directory>
        </Directory>
      </Directory>
    </Directory>
    <Feature Id="Main" Level="1">
      {"".join(refs)}
    </Feature>
  </Product>
</Wix>
"""


def patch(msi):
    """What wixl 0.103 cannot express: the user PATH entry, its two actions, a same-version upgrade."""
    with tempfile.TemporaryDirectory() as d:
        idt = os.path.join(d, "Environment.idt")
        with open(idt, "w") as f:
            # Name "=-PATH": create or update, remove on uninstall. Value "[~];[BinDir]": append to the list.
            f.write("Environment\tName\tValue\tComponent_\ns72\tl255\tL255\ts72\nEnvironment\tEnvironment\n")
            f.write("epath\t=-PATH\t[~];[BinDir]\tcpath\n")
        run(["msibuild", msi, "-i", idt])
        # libmsi refuses UPDATE here, so the Upgrade table goes back in whole (an import replaces the table),
        # with the upgrade row's VersionMax made inclusive.
        lines = run(["msiinfo", "export", msi, "Upgrade"]).splitlines()
        cols = lines[0].split("\t")
        attr, prop = cols.index("Attributes"), cols.index("ActionProperty")
        for i in range(3, len(lines)):
            row = lines[i].split("\t")
            if row[prop] == "WIX_UPGRADE_DETECTED":
                row[attr] = str(int(row[attr]) | MSI_VERSION_UPGRADE_INCLUSIVE)
                lines[i] = "\t".join(row)
        idt = os.path.join(d, "Upgrade.idt")
        with open(idt, "w") as f:
            f.write("\n".join(lines) + "\n")
        run(["msibuild", msi, "-i", idt])
    run([
        "msibuild", msi,
        "-q", "INSERT INTO `InstallExecuteSequence` (`Action`, `Sequence`) VALUES ('RemoveEnvironmentStrings', 3300)",
        "-q", "INSERT INTO `InstallExecuteSequence` (`Action`, `Sequence`) VALUES ('WriteEnvironmentStrings', 5200)",
    ])


def table(msi, name):
    out = run(["msiinfo", "export", msi, name]).splitlines()
    cols = out[0].split("\t")
    return [dict(zip(cols, line.split("\t"))) for line in out[3:] if line]


def verify(msi, expected_sizes=None, ca=None):
    files = {r["FileName"].split("|")[-1]: int(r["FileSize"]) for r in table(msi, "File")}
    want = [name for _, name in FILES]
    if sorted(files) != sorted(want):
        raise Fail(f"{msi}: files {sorted(files)}, expected {sorted(want)}")
    for name, size in (expected_sizes or {}).items():
        if files[name] != size:
            raise Fail(f"{msi}: {name} is {files[name]} bytes in the MSI, {size} staged")
    env = table(msi, "Environment")
    if [(r["Name"], r["Value"], r["Component_"]) for r in env] != [("=-PATH", "[~];[BinDir]", "cpath")]:
        raise Fail(f"{msi}: Environment table is {env}")
    seq = {r["Action"]: int(r["Sequence"]) for r in table(msi, "InstallExecuteSequence")}
    if not (seq.get("RemoveEnvironmentStrings", 0) < seq.get("InstallFiles", 0) < seq.get("WriteEnvironmentStrings", 0)):
        raise Fail(f"{msi}: environment actions are not scheduled around InstallFiles: {seq}")
    up = {r["ActionProperty"]: r for r in table(msi, "Upgrade")}
    if int(up["WIX_UPGRADE_DETECTED"]["Attributes"]) & MSI_VERSION_UPGRADE_INCLUSIVE == 0:
        raise Fail(f"{msi}: an equal version would install beside the old one: {up}")
    props = {r["Property"]: r["Value"] for r in table(msi, "Property")}
    if props.get("MSIINSTALLPERUSER") != "1" or props.get("UpgradeCode", "").lower().strip("{}") != UPGRADE_CODE:
        raise Fail(f"{msi}: not the per-user cmux product: {props}")
    if ca:
        run(["osslsigncode", "verify", "-in", msi, "-CAfile", ca])
    return files


def signer(args, work):
    """(pfx path, password, ca or None, label) or None for unsigned."""
    if args.test_sign:
        key, cert, pfx = (os.path.join(work, n) for n in ("test.key", "test.pem", "test.pfx"))
        run(["openssl", "req", "-x509", "-newkey", "rsa:3072", "-nodes", "-keyout", key, "-out", cert, "-days", "1",
             "-subj", "/CN=cmux test signing (not trusted)", "-addext", "extendedKeyUsage=codeSigning"])
        password = uuid.uuid4().hex
        run(["openssl", "pkcs12", "-export", "-inkey", key, "-in", cert, "-out", pfx, "-passout", f"pass:{password}"],
            secret=f"pass:{password}")
        return pfx, password, cert, "test"
    b64 = os.environ.get("CMUX_WINDOWS_SIGN_PFX_B64", "")
    password = os.environ.get("CMUX_WINDOWS_SIGN_PFX_PASSWORD", "")
    if not b64:
        if args.require_signed:
            raise Fail("--require-signed: CMUX_WINDOWS_SIGN_PFX_B64 is not set")
        return None
    pfx = os.path.join(work, "sign.pfx")
    fd = os.open(pfx, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(base64.b64decode(b64))
    return pfx, password, None, "release"


def sign(path, sig, timestamp):
    pfx, password, _, label = sig
    out = path + ".signed"
    argv = ["osslsigncode", "sign", "-pkcs12", pfx, "-pass", password, "-n", "cmux", "-i", "https://cmux.com",
            "-h", "sha256", "-in", path, "-out", out]
    if label == "release":
        argv[-4:-4] = ["-ts", timestamp]
    run(argv, secret=password)
    os.replace(out, path)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def build(args):
    for tool in ("wixl", "msibuild", "msiinfo", "osslsigncode"):
        if not shutil.which(tool):
            raise Fail(f"{tool} is missing (apt: wixl msitools osslsigncode)")
    version = msi_version(args.version)
    with tempfile.TemporaryDirectory(prefix="windows-msi-") as work:
        staged = os.path.join(work, "bin")
        os.mkdir(staged)
        sig = signer(args, work)
        sizes = {}
        for base, name in FILES:
            src = os.path.join(args.dist, f"{base}-{TARGET}.exe")
            if not os.path.isfile(src):
                raise Fail(f"{src} is missing")
            dst = os.path.join(staged, name)
            shutil.copyfile(src, dst)
            if sig:
                sign(dst, sig, args.timestamp_url)
                if sig[2]:
                    run(["osslsigncode", "verify", "-in", dst, "-CAfile", sig[2]])
            sizes[name] = os.path.getsize(dst)
        src = os.path.join(work, "cmux.wxs")
        with open(src, "w") as f:
            f.write(wxs(version, staged))
        tmp = args.out + ".part"
        run(["wixl", "-a", "x64", "-o", tmp, src])
        patch(tmp)
        if sig:
            sign(tmp, sig, args.timestamp_url)
        verify(tmp, sizes, sig[2] if sig else None)
        if sig and not sig[2]:
            # A release signature: check it is there and intact (trust needs the Windows root store).
            out = subprocess.run(["osslsigncode", "verify", "-in", tmp], capture_output=True, text=True)
            if "Signature verification: ok" not in out.stdout:
                raise Fail(f"{tmp}: signature does not verify\n{out.stdout}{out.stderr}")
        os.replace(tmp, args.out)
    manifest = {
        "version": args.version,
        "msi_version": version,
        "target": TARGET,
        "file": os.path.basename(args.out),
        "sha256": sha256(args.out),
        "size": os.path.getsize(args.out),
        "signed": bool(sig) and sig[3] == "release",
        "signer": sig[3] if sig else "unsigned",
        "upgrade_code": UPGRADE_CODE,
        "files": sizes,
    }
    with open(args.out + ".json", "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
        f.write("\n")
    print(json.dumps(manifest, sort_keys=True))


def wine_roundtrip(msi, older=None):
    for tool in ("wine", "wineboot"):
        if not shutil.which(tool):
            raise Fail(f"{tool} is missing (apt: wine64 wine)")
    own = None
    prefix = os.environ.get("WINEPREFIX")
    if not prefix:
        own = tempfile.mkdtemp(prefix="windows-msi-wine-")
        prefix = os.path.join(own, "prefix")
    env = dict(os.environ, WINEPREFIX=prefix, WINEDEBUG="-all", WINEDLLOVERRIDES="mscoree,mshtml=")

    def wine(*argv, timeout=180):
        p = subprocess.run(["wine", *argv], env=env, capture_output=True, text=True, timeout=timeout,
                           stdin=subprocess.DEVNULL)
        return p.returncode, (p.stdout + p.stderr).replace("\r", "")

    def path_value():
        code, out = wine("reg", "query", "HKCU\\Environment", "/v", "PATH", timeout=60)
        m = re.search(r"PATH\s+REG_\w+\s+(.*)", out)
        return m.group(1).strip() if code == 0 and m else ""

    def entries():
        n = 0
        for hive in ("HKLM", "HKCU"):
            _, out = wine("reg", "query", f"{hive}\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall",
                          "/s", timeout=60)
            n += len(re.findall(r"DisplayName\s+REG_SZ\s+cmux\s*$", out, re.M))
        return n

    try:
        if not os.path.isfile(os.path.join(prefix, "system.reg")):
            subprocess.run(["wineboot", "-i"], env=env, capture_output=True, timeout=300, stdin=subprocess.DEVNULL)
        user = os.environ.get("USER") or os.environ.get("LOGNAME") or "root"
        bindir = os.path.join(prefix, "drive_c", "users", user, "AppData", "Local", "Programs", "cmux", "bin")
        want = sorted(name for _, name in FILES)
        steps = []
        code, out = wine("msiexec", "/i", os.path.abspath(msi), "/qn")
        if code != 0:
            raise Fail(f"install: msiexec exit {code}\n{out}")
        got = sorted(os.listdir(bindir)) if os.path.isdir(bindir) else []
        if got != want:
            raise Fail(f"install: {bindir} holds {got}, expected {want}")
        if "programs\\cmux\\bin" not in path_value().lower():
            raise Fail(f"install: the user PATH is {path_value()!r}, without the cmux bin folder")
        steps.append("install")
        code, out = wine("msiexec", "/i", os.path.abspath(msi), "/qn")
        if code != 0 or entries() != 1:
            raise Fail(f"reinstall: msiexec exit {code}, {entries()} Apps entries (want 1)\n{out}")
        steps.append("reinstall")
        if older:
            code, _ = wine("msiexec", "/i", os.path.abspath(older), "/qn")
            if code == 0:
                raise Fail("an older MSI installed over a newer one")
            steps.append("downgrade-refused")
        code, out = wine("msiexec", "/x", os.path.abspath(msi), "/qn")
        if code != 0:
            raise Fail(f"uninstall: msiexec exit {code}\n{out}")
        if os.path.isdir(bindir) and os.listdir(bindir):
            raise Fail(f"uninstall left {sorted(os.listdir(bindir))} in {bindir}")
        if "programs\\cmux\\bin" in path_value().lower():
            raise Fail(f"uninstall left the cmux bin folder on the user PATH: {path_value()!r}")
        if entries() != 0:
            raise Fail("uninstall left an Apps entry")
        steps.append("uninstall")
        return steps
    finally:
        if own:
            shutil.rmtree(own, ignore_errors=True)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--dist", required=True)
    b.add_argument("--version", required=True)
    b.add_argument("--out", required=True)
    b.add_argument("--timestamp-url", default=os.environ.get("CMUX_WINDOWS_SIGN_TIMESTAMP_URL", DEFAULT_TIMESTAMP_URL))
    g = b.add_mutually_exclusive_group()
    g.add_argument("--require-signed", action="store_true")
    g.add_argument("--test-sign", action="store_true")
    v = sub.add_parser("verify")
    v.add_argument("--msi", required=True)
    v.add_argument("--ca")
    mv = sub.add_parser("msi-version")
    mv.add_argument("version")
    w = sub.add_parser("wine-roundtrip")
    w.add_argument("--msi", required=True)
    w.add_argument("--older")
    args = ap.parse_args(argv)
    try:
        if args.cmd == "build":
            build(args)
        elif args.cmd == "msi-version":
            print(msi_version(args.version))
        elif args.cmd == "wine-roundtrip":
            print("windows-msi: wine round trip passed: " + ", ".join(wine_roundtrip(args.msi, args.older)))
        else:
            print(json.dumps(verify(args.msi, ca=args.ca), sort_keys=True))
    except Fail as e:
        print(f"windows-msi: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
