#!/usr/bin/env python3
"""Exercise Computer Use host admission with the signed NIGHTLY apps.

The unit tests inject the code check.  This test keeps the real signed app in
the loop: it downloads the two NIGHTLY identities, starts each app with each
Computer Use driver enabled, and verifies that the app's authenticated host
connection remains open.  A host connection that is refused closes before it
can remain in the app's descriptor table.

The helper's own signed bundle is checked as a negative identity as well.  An
ad-hoc tagged app and an ordinary unsigned process are connected to each host
socket and must receive the stable ``host_unverified`` refusal.  The detailed
``not Apple-signed (ad hoc or unsigned)`` reason is emitted by the helper's
real code check (and is covered by the HostVerifier unit test); the wire reply
deliberately exposes only the stable refusal reason.

The NEXT appcast is the blocking contract.  The legacy identity is retained as
a best-effort diagnostic while that feed is still published; a retired or
temporarily unavailable classic feed must not turn this scheduled check red.
"""

from __future__ import annotations

import argparse
import os
import plistlib
import signal
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path


APPLE_NS = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
MAIN_IDS = {
    "com.cmuxterm.app.nightly",
    "com.cmuxterm.app.nightly.cmux-next",
}
HELPER_ID = "com.cmuxterm.cua"
HOST_REFUSAL = "host_unverified"


class Failure(RuntimeError):
    pass


def log(message: str) -> None:
    print(message, flush=True)


def run(args: list[str], *, timeout: float = 60, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
    if check and result.returncode != 0:
        raise Failure(f"{' '.join(args)} failed ({result.returncode}): {result.stderr.strip()}")
    return result


def feed_url(url: str) -> tuple[str, int, str]:
    request = urllib.request.Request(url, headers={"User-Agent": "cmux-cua-signed-host/1"})
    try:
        body = urllib.request.urlopen(request, timeout=30).read()
        root = ET.fromstring(body)
    except Exception as error:
        raise Failure(f"could not read appcast {url}: {error}") from error
    item = root.find("./channel/item")
    enclosure = item.find("enclosure") if item is not None else None
    if enclosure is None:
        raise Failure(f"appcast {url} has no enclosure")
    artifact = enclosure.attrib.get("url", "")
    length = enclosure.attrib.get("length", "")
    version = item.findtext("sparkle:version", default="", namespaces=APPLE_NS) if item is not None else ""
    if not artifact or not length.isdigit():
        raise Failure(f"appcast {url} has an invalid enclosure")
    return artifact, int(length), version


def download(url: str, length: int, destination: Path) -> None:
    log(f"download {url}")
    request = urllib.request.Request(url, headers={"User-Agent": "cmux-cua-signed-host/1"})
    try:
        with urllib.request.urlopen(request, timeout=180) as source, destination.open("wb") as target:
            shutil.copyfileobj(source, target, 1 << 20)
    except Exception as error:
        raise Failure(f"could not download {url}: {error}") from error
    actual = destination.stat().st_size
    if actual != length:
        raise Failure(f"{url}: expected {length} bytes, got {actual}")


def plist(bundle: Path) -> dict[str, object]:
    try:
        with (bundle / "Contents/Info.plist").open("rb") as source:
            return plistlib.load(source)
    except Exception as error:
        raise Failure(f"could not read {bundle}/Contents/Info.plist: {error}") from error


def bundle_id(bundle: Path) -> str:
    identifier = plist(bundle).get("CFBundleIdentifier")
    if not isinstance(identifier, str) or not identifier:
        raise Failure(f"{bundle} has no CFBundleIdentifier")
    return identifier


def executable(bundle: Path) -> Path:
    name = plist(bundle).get("CFBundleExecutable")
    if not isinstance(name, str):
        raise Failure(f"{bundle} has no CFBundleExecutable")
    path = bundle / "Contents/MacOS" / name
    if not path.is_file() or not os.access(path, os.X_OK):
        raise Failure(f"{bundle}: executable is missing ({path})")
    return path


def verify_signature(bundle: Path, expected: str) -> None:
    identifier = bundle_id(bundle)
    if identifier != expected:
        raise Failure(f"{bundle}: expected bundle id {expected}, got {identifier}")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(bundle)], timeout=120)
    details = run(["/usr/bin/codesign", "-d", "--verbose=4", str(bundle)], check=False)
    if "TeamIdentifier=7WLXT3NR37" not in details.stderr:
        raise Failure(f"{bundle}: signed by an unexpected team: {details.stderr}")


def nested_helper(app: Path) -> Path:
    for candidate in sorted(app.rglob("*.app")):
        if candidate == app:
            continue
        if bundle_id(candidate) == HELPER_ID:
            return candidate
    raise Failure(f"{app}: no signed {HELPER_ID} helper bundle")


def fnv_scope(identifier: str) -> str:
    value = 0xCBF29CE484222325
    for byte in identifier.encode():
        value = ((value ^ byte) * 0x00000100000001B3) & 0xFFFFFFFFFFFFFFFF
    return f"{value:016x}"


def user_temp() -> Path:
    return Path(run(["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"]).stdout.strip())


def host_socket(identifier: str, driver: str) -> Path:
    root = user_temp()
    scope = fnv_scope(identifier)
    if driver == "upstream":
        return root / "cmux-cua-v2" / scope / "c.sock"
    return root / "cmux-cua" / scope / "cua.sock"


def process_has_path(pid: int, path: Path) -> bool:
    result = run(["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-U"], timeout=15, check=False)
    return str(path) in result.stdout


def wait_for_host(process: subprocess.Popen[bytes], path: Path, timeout: float = 45) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise Failure(f"cmux exited with status {process.returncode} before attaching to {path}")
        if path.exists() and process_has_path(process.pid, path):
            return
        time.sleep(0.25)
    raise Failure(f"signed app pid {process.pid} never kept an accepted host connection to {path}")


def stop(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    process.send_signal(signal.SIGTERM)
    try:
        process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=15)


def connect_refusal(path: Path) -> str:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(10)
    try:
        client.connect(str(path))
        return client.makefile("rb").readline().decode("utf-8", "replace")
    finally:
        client.close()


def ad_hoc_peer(root: Path) -> Path:
    """Make a tagged DEV-shaped, ad-hoc app whose process can be a socket peer."""
    app = root / "cmux DEV signed-host-probe.app"
    binary = app / "Contents/MacOS/cmux"
    binary.parent.mkdir(parents=True)
    shutil.copyfile("/usr/bin/python3", binary)
    binary.chmod(0o755)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.cmuxterm.app.debug.signed-host-probe",
        "CFBundleExecutable": "cmux",
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1",
    }))
    run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], timeout=60)
    return binary


def ad_hoc_refusal(path: Path, binary: Path) -> None:
    script = (
        "import socket,sys; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); "
        "print(s.makefile('rb').readline().decode(), end=''); s.close()"
    )
    result = subprocess.run([str(binary), "-c", script, str(path)], capture_output=True, text=True, timeout=20)
    if HOST_REFUSAL not in result.stdout:
        raise Failure(f"ad hoc tagged DEV peer was not refused by {path}: {result.stdout!r}")


def exec_chain_refusal(path: Path, binary: Path) -> None:
    """Connect, exec, then speak: the connection's audit token must not survive exec."""
    script = (
        "import os,socket,sys,time; s=socket.socket(socket.AF_UNIX); "
        "s.set_inheritable(True); s.connect(sys.argv[1]); time.sleep(.2); "
        "os.execv(sys.executable,[sys.executable,'-c',"
        "\"import os,socket,sys; s=socket.socket(fileno=3); "
        "print(s.makefile('rb').readline().decode(), end='')\",sys.argv[1]])"
    )
    result = subprocess.run([str(binary), "-c", script, str(path)], capture_output=True, text=True, timeout=20)
    if HOST_REFUSAL not in result.stdout:
        raise Failure(f"exec-chain peer was not refused by {path}: {result.stdout!r}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--legacy-feed", default="https://files-next.cmux.com/nightly-next/appcast-arm64.xml")
    parser.add_argument("--next-feed", default="https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml")
    parser.add_argument("--out", type=Path, default=None)
    args = parser.parse_args()
    root = Path(tempfile.mkdtemp(prefix="cmux-cua-signed-host-"))
    if args.out:
        args.out.mkdir(parents=True, exist_ok=True)
    try:
        artifacts = [
            # NEXT is the supported nightly and the release-facing contract.
            ("next", "com.cmuxterm.app.nightly.cmux-next", args.next_feed, True),
            # Keep the old identity as a diagnostic while it is available; a
            # classic feed outage must not red the supported nightly check.
            ("classic", "com.cmuxterm.app.nightly", args.legacy_feed, False),
        ]
        apps: list[tuple[str, Path, str]] = []
        for name, expected, feed, required in artifacts:
            try:
                url, length, version = feed_url(feed)
                dmg = root / f"{name}.dmg"
                download(url, length, dmg)
                mount = root / f"mount-{name}"
                mount.mkdir()
                run(["/usr/bin/hdiutil", "attach", str(dmg), "-nobrowse", "-readonly", "-mountpoint", str(mount)], timeout=300)
                try:
                    candidates = sorted(mount.glob("*.app"))
                    if len(candidates) != 1:
                        raise Failure(f"{dmg}: expected one app, found {candidates}")
                    app = root / f"{name}.app"
                    run(["/usr/bin/ditto", str(candidates[0]), str(app)], timeout=300)
                finally:
                    run(["/usr/bin/hdiutil", "detach", str(mount)], timeout=120, check=False)
                verify_signature(app, expected)
                helper = nested_helper(app)
                verify_signature(helper, HELPER_ID)
                log(f"{name} {version}: signed app and helper identities are correct")
                apps.append((name, app, expected))
            except Failure as error:
                if required:
                    raise
                log(f"INFO: classic NIGHTLY diagnostic skipped: {error}")

        adhoc = ad_hoc_peer(root)
        for name, app, identifier in apps:
            try:
                for driver in ("upstream", "legacy"):
                    run_root = root / f"run-{name}-{driver}"
                    home = run_root / "home"
                    (home / "Library/Application Support").mkdir(parents=True)
                    run_root.mkdir(exist_ok=True)
                    config = run_root / "cmux-next.json"
                    config.write_text('{"computerUse":{"enabled":true,"driver":"' + driver + '"}}\n')
                    env = {
                        "HOME": str(home),
                        "CFFIXED_USER_HOME": str(home),
                        "TMPDIR": str(run_root / "tmp") + "/",
                        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                        "USER": os.environ.get("USER", ""),
                        "LOGNAME": os.environ.get("LOGNAME", os.environ.get("USER", "")),
                        "LANG": "en_US.UTF-8",
                        "CMUX_NEXT_CONFIG_FILE": str(config),
                        "CMUX_NEXT_NO_ACTIVATE": "1",
                        "CMUX_NEXT_SOCKET_MODE": "allowAll",
                    }
                    (run_root / "tmp").mkdir()
                    output = (run_root / "app.log").open("wb")
                    process = subprocess.Popen([str(executable(app)), "-ApplePersistenceIgnoreState", "YES"],
                                                env=env, cwd=str(home), stdin=subprocess.DEVNULL,
                                                stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
                    try:
                        path = host_socket(identifier, driver)
                        wait_for_host(process, path)
                        log(f"ok: {name} {driver} accepted the signed app host on {path}")
                        refusal = connect_refusal(path)
                        if HOST_REFUSAL not in refusal:
                            raise Failure(f"unsigned peer was not refused by {path}: {refusal!r}")
                        ad_hoc_refusal(path, adhoc)
                        exec_chain_refusal(path, adhoc)
                        log(f"ok: {name} {driver} refused unsigned, ad hoc, and exec-chain peers")
                    finally:
                        stop(process)
                        output.close()
            except Failure as error:
                if name == "next":
                    raise
                log(f"INFO: classic NIGHTLY diagnostic failed: {error}")
        if not any(name == "next" for name, _, _ in apps):
            raise Failure("NEXT NIGHTLY artifact was not checked")
        log("PASS: signed NEXT NIGHTLY host admission and refusal checks (classic is informational)")
        return 0
    except Failure as error:
        log(f"FAIL: {error}")
        return 1
    finally:
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
