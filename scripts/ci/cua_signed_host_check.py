#!/usr/bin/env python3
"""Exercise Computer Use host admission with the signed NIGHTLY apps.

The unit tests inject the code check.  This test keeps the real signed app in
the loop: it downloads the two NIGHTLY identities, starts each app with each
Computer Use driver enabled, and verifies that the app's authenticated host
connection remains open.  A host connection that is refused closes before it
can remain in the app's descriptor table.

Each driver is checked as the build runs it: NIGHTLY carries no helper v2, so
"upstream" runs the legacy helper there.  An ad-hoc tagged app and an ordinary
unsigned process are connected to each host socket and must be refused.  The
helper v2 refuses them before reading, with the stable ``host_unverified``
refusal.  The legacy helper answers their ``machine_consent_host`` request
with the agent-token error, which it checks before the host token and the
code signature, so on legacy these probes prove token gating and that the
refusal never says attached.  The detailed
``not Apple-signed (ad hoc or unsigned)`` reason is emitted by the helper's
real code check (and is covered by the HostVerifier unit test); the wire reply
deliberately exposes only the stable refusal reason.

The NEXT appcast is the blocking contract.  The legacy identity is retained as
a best-effort diagnostic while that feed is still published; a retired or
temporarily unavailable classic feed must not turn this scheduled check red.
"""

from __future__ import annotations

import argparse
import json
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
# DEV builds embed the helper v2 here (ComputerUseHelperV2.embeddedHelperApp);
# without it "upstream" runs the legacy helper (ComputerUseHelperDaemon.effectiveDriver).
UPSTREAM_HELPER = "Contents/Library/cmux Computer Use (dev).app/Contents/MacOS/cmux-cua-helper"
# The legacy helper (cmux-cua serve) answers a request; this is the app's attach request.
LEGACY_ATTACH = b'{"request":{"args":{},"method":"machine_consent_host"}}\n'


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


def effective_driver(app: Path, driver: str) -> str:
    """The helper the app runs for `driver`: NIGHTLY has no helper v2, so upstream is legacy."""
    return "upstream" if driver == "upstream" and (app / UPSTREAM_HELPER).is_file() else "legacy"


def process_has_path(pid: int, path: Path) -> bool:
    result = run(["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-U"], timeout=15, check=False)
    return str(path) in result.stdout


def wait_for_host(process: subprocess.Popen[bytes], path: Path, timeout: float = 45, hold: float = 3) -> None:
    """The app's host connection must stay open for `hold` seconds: a refused one closes at once."""
    deadline = time.monotonic() + timeout
    since: float | None = None
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise Failure(f"cmux exited with status {process.returncode} before attaching to {path}")
        if path.exists() and process_has_path(process.pid, path):
            since = since if since is not None else time.monotonic()
            if time.monotonic() - since >= hold:
                return
        else:
            since = None
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


def connect_refusal(path: Path, driver: str) -> str:
    """Helper v2 refuses an unverified peer before reading; legacy answers the attach request."""
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(10)
    try:
        client.connect(str(path))
        if driver == "legacy":
            client.sendall(LEGACY_ATTACH)
        return client.makefile("rb").readline().decode("utf-8", "replace")
    finally:
        client.close()


def refused(reply: str, driver: str) -> bool:
    """Helper v2 names host_unverified. Legacy checks the agent token before the host
    token and the code signature, so a peer without them gets a refusal that never
    says attached."""
    if driver == "upstream":
        return HOST_REFUSAL in reply
    try:
        line = json.loads(reply)
    except ValueError:
        return False
    if not isinstance(line, dict):
        return False
    attached = isinstance(line.get("result"), dict) and line["result"].get("attached") is True
    return line.get("ok") is False and not attached


# A socket peer for the ad hoc app. /usr/bin/python3 is the xcrun shim, which
# picks its tool by its own name, so a copy named cmux would run the cmux CLI.
#   probe connect PATH REQUEST   connect, send REQUEST (if any), print one line
#   probe exec PATH REQUEST      connect, then exec itself to speak on the socket
PROBE_SOURCE = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static int speak(int fd, const char *request) {
    char line[4096];
    size_t used = 0;
    if (*request && write(fd, request, strlen(request)) < 0) return 1;
    while (used < sizeof line - 1) {
        ssize_t got = read(fd, line + used, 1);
        if (got <= 0 || line[used] == '\n') break;
        used += 1;
    }
    line[used] = 0;
    printf("%s\n", line);
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 4) return 2;
    if (strcmp(argv[1], "fd") == 0) return speak(atoi(argv[2]), argv[3]);
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strncpy(address.sun_path, argv[2], sizeof address.sun_path - 1);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0 || connect(fd, (struct sockaddr *)&address, sizeof address) != 0) return 1;
    if (strcmp(argv[1], "connect") == 0) return speak(fd, argv[3]);
    usleep(200000);
    char number[16];
    snprintf(number, sizeof number, "%d", fd);
    char *next[] = {argv[0], "fd", number, argv[3], NULL};
    execv(argv[0], next);
    return 1;
}
"""


def ad_hoc_peer(root: Path) -> Path:
    """Make a tagged DEV-shaped, ad-hoc app whose process can be a socket peer."""
    app = root / "cmux DEV signed-host-probe.app"
    binary = app / "Contents/MacOS/cmux"
    binary.parent.mkdir(parents=True)
    source = root / "probe.c"
    source.write_text(PROBE_SOURCE)
    run(["/usr/bin/xcrun", "clang", "-O1", "-o", str(binary), str(source)], timeout=120)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.cmuxterm.app.debug.signed-host-probe",
        "CFBundleExecutable": "cmux",
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1",
    }))
    run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], timeout=60)
    return binary


def probe(binary: Path, mode: str, path: Path, driver: str) -> str:
    request = LEGACY_ATTACH.decode() if driver == "legacy" else ""
    result = subprocess.run([str(binary), mode, str(path), request], capture_output=True, text=True, timeout=20)
    return result.stdout


def ad_hoc_refusal(path: Path, binary: Path, driver: str) -> None:
    reply = probe(binary, "connect", path, driver)
    if not refused(reply, driver):
        raise Failure(f"ad hoc tagged DEV peer was not refused by {path}: {reply!r}")


def exec_chain_refusal(path: Path, binary: Path, driver: str) -> None:
    """Connect, exec, then speak: the connection's audit token must not survive exec."""
    reply = probe(binary, "exec", path, driver)
    if not refused(reply, driver):
        raise Failure(f"exec-chain peer was not refused by {path}: {reply!r}")


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
                    runs = effective_driver(app, driver)
                    if runs != driver:
                        log(f"info: {name} has no helper v2; driver {driver} runs the {runs} helper")
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
                        path = host_socket(identifier, runs)
                        wait_for_host(process, path)
                        log(f"ok: {name} {driver} accepted the signed app host on {path}")
                        refusal = connect_refusal(path, runs)
                        if not refused(refusal, runs):
                            raise Failure(f"unsigned peer was not refused by {path}: {refusal!r}")
                        ad_hoc_refusal(path, adhoc, runs)
                        exec_chain_refusal(path, adhoc, runs)
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
