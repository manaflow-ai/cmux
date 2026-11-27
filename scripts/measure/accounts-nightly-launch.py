#!/usr/bin/env python3
"""Probe a signed NIGHTLY in a fresh state root, using cloud-chat-proof's launch contract."""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
FEED = "https://files-next.cmux.com/nightly-next/appcast-arm64.xml"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
MIN_BUILD = 4592220755201  # Source 956d6e600a16 supports CMUX_NEXT_STATE_ROOT.


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def run(argv, **kwargs):
    return subprocess.run(argv, check=True, timeout=kwargs.pop("timeout", 120), **kwargs)


def pick_feed(xml, requested_build="", requested_url=""):
    """Select only feed-listed bytes with signature metadata and supported isolation."""
    choices = []
    for item in ET.fromstring(xml).findall("./channel/item"):
        enclosure = item.find("enclosure")
        if enclosure is None:
            continue
        build = item.findtext(SPARKLE + "version") or enclosure.get(SPARKLE + "version", "")
        url = enclosure.get("url", "")
        if not build.isdigit() or int(build) < MIN_BUILD:
            continue
        if not url.startswith("https://files-next.cmux.com/nightly-next/") or not url.endswith(".dmg"):
            continue
        if (requested_build and build != requested_build) or (requested_url and url != requested_url):
            continue
        choices.append({"build": build, "url": url, "length": enclosure.get("length", ""),
                        "signature": enclosure.get(SPARKLE + "edSignature", "")})
    if not choices:
        raise RuntimeError("no matching state-root-capable NIGHTLY in the arm64 feed")
    return max(choices, key=lambda row: int(row["build"]))


def main():
    out = ROOT / ".build/accounts-nightly-probe"
    out.mkdir(parents=True, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix="run-", dir=out))
    work = Path(tempfile.mkdtemp(prefix="accounts-"))
    status, launcher, owned_pid, mounted, selected = 1, None, None, False, {}
    cli_env, app = None, None
    try:
        required = ("CMUX_UITEST_STACK_EMAIL", "CMUX_UITEST_STACK_PASSWORD",
                    "CMUX_GITHUB_TEST_LOGIN", "CMUX_GITHUB_TEST_PASSWORD",
                    "CMUX_GITHUB_TEST_TOTP_SEED")
        if any(not os.environ.get(key) for key in required):
            raise RuntimeError("dedicated CMUX_ACCOUNTS_PROBE_* workflow secrets are required")
        requested = {}
        for arg in sys.argv[1:]:
            key, sep, value = arg.partition("=")
            if key not in ("build", "dmg") or not sep:
                raise RuntimeError("arguments are build=NUMBER or dmg=FEED_URL")
            requested[key] = value
        run(["curl", "-fsSL", "--max-time", "60", "-o", str(work / "feed.xml"), FEED])
        selected = pick_feed((work / "feed.xml").read_bytes(), requested.get("build", ""), requested.get("dmg", ""))
        run(["curl", "-fsSL", "--max-time", "600", "-o", str(work / "nightly.dmg"), selected["url"]], timeout=620)
        artifact = module("nightly_artifact", ROOT / "scripts/ci/nightly_next_artifact_check.py")
        selected["sha256"] = artifact.check_dmg(work / "nightly.dmg", selected["length"], selected["signature"])
        mount = work / "mount"
        mount.mkdir()
        run(["hdiutil", "attach", str(work / "nightly.dmg"), "-nobrowse", "-readonly", "-mountpoint", str(mount)], stdout=subprocess.DEVNULL)
        mounted = True
        apps = list(mount.glob("*.app"))
        if len(apps) != 1:
            raise RuntimeError("expected exactly one app in the NIGHTLY DMG")
        app = (work / "cmux NIGHTLY.app").resolve()
        run(["ditto", str(apps[0]), str(app)], timeout=300)
        run(["hdiutil", "detach", str(mount)], stdout=subprocess.DEVNULL)
        mounted = False
        (work / "nightly.dmg").unlink()
        with (app / "Contents/Info.plist").open("rb") as handle:
            meta = plistlib.load(handle)
        if meta.get("CFBundleIdentifier") != "com.cmuxterm.app.nightly" or str(meta.get("CFBundleVersion")) != selected["build"]:
            raise RuntimeError("app identity/build does not match the feed")
        selected["commit"] = meta.get("CMUXCommit")
        run(["codesign", "--verify", "--deep", "--strict", str(app)])
        run(["spctl", "-a", "--type", "execute", str(app)])
        credentials = work / "credentials.env"
        fd = os.open(credentials, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, "w") as handle:
            for key in required[:2]:
                value = os.environ[key]
                if "\n" in value or "\r" in value:
                    raise RuntimeError("credential file values cannot contain newlines")
                handle.write(f"{key}={value}\n")
        state = work / "state"
        state.mkdir()
        socket = str(work / "control.sock")
        if len(os.fsencode(socket)) > 103:
            raise RuntimeError("private control socket path exceeds the macOS limit")
        config = work / "cmux-next.json"
        config.write_text("{}\n")
        env = module("app_launch_env", ROOT / "scripts/cmux-next/app_launch_env.py").launch_env(os.environ)
        env = {k: v for k, v in env.items() if not k.startswith(("CMUX_UITEST_", "CMUX_DOGFOOD_", "CMUX_GITHUB_TEST_", "CMUX_AUTH_"))}
        values = {"CMUX_NEXT_SOCKET_PATH": socket, "CMUX_NEXT_STATE_ROOT": str(state),
                  "CMUX_NEXT_CONFIG_FILE": str(config), "CMUX_NEXT_ALLOW_SECOND_INSTANCE": "1",
                  "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_AUTH_CREDENTIALS_FILE": str(credentials),
                  "CMUX_DEV_AUTH_PROFILE": "agent"}
        command = ["/usr/bin/open", "-W", "-g", "-n"]
        for key, value in values.items():
            command += ["--env", f"{key}={value}"]
        command += [str(app), "--args", "--cloud-backend", "prod"]
        launcher = subprocess.Popen(command, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cli = str(app / "Contents/Resources/bin/cmux")
        cli_env = {**env, **values, "CMUX_SOCKET_PATH": socket}
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            if launcher.poll() is not None:
                raise RuntimeError("NIGHTLY exited before its private socket was ready")
            reply = subprocess.run([cli, "app", "identify", "--json"], env=cli_env,
                                   capture_output=True, text=True, timeout=10)
            try:
                identity = json.loads(reply.stdout)
            except ValueError:
                identity = {}
            if identity.get("app_bundle_path") == str(app) and isinstance(identity.get("pid"), int):
                owned_pid = identity["pid"]
                break
            time.sleep(1)
        if owned_pid is None:
            raise RuntimeError("NIGHTLY did not identify its exact private app path within 90 seconds")
        with (evidence / "run.log").open("w") as log:
            result = subprocess.run([sys.executable, str(ROOT / "scripts/measure/accounts-nightly-probe.py"),
                                     "--app", str(app), "--pid", str(owned_pid), "--socket", socket,
                                     "--out", str(evidence), "--api", "https://cloud-api.cmux.dev"],
                                    stdout=log, stderr=subprocess.STDOUT, timeout=900)
            status = result.returncode
    except Exception as error:
        # RuntimeErrors here contain only our static diagnostics, never command output or credentials.
        reason = str(error) if type(error) is RuntimeError else type(error).__name__
        (evidence / "launcher-error.json").write_text(json.dumps({"ok": False, "reason": reason}) + "\n")
        print(f"Accounts NIGHTLY probe failed: {reason}", flush=True)
    finally:
        cleanup_ok = True
        if owned_pid:
            owned_now = False
            try:
                if cli_env and app:
                    check = subprocess.run([str(app / "Contents/Resources/bin/cmux"), "app", "identify", "--json"],
                                           env=cli_env, capture_output=True, text=True, timeout=10)
                    identity = json.loads(check.stdout)
                    owned_now = identity.get("pid") == owned_pid and identity.get("app_bundle_path") == str(app)
            except (OSError, subprocess.TimeoutExpired, ValueError):
                owned_now = False
            if owned_now:
                try:
                    os.kill(owned_pid, signal.SIGTERM)
                except (ProcessLookupError, PermissionError):
                    cleanup_ok = False
            else:
                cleanup_ok = False
        stopped = launcher is None
        if launcher:
            try:
                launcher.wait(timeout=30)
                stopped = True
            except subprocess.TimeoutExpired:
                cleanup_ok = False
                launcher.terminate()  # Only our open -W helper; retain app files when app exit is unknown.
        if mounted:
            try:
                detached = subprocess.run(["hdiutil", "detach", str(work / "mount")], capture_output=True, timeout=30)
                mounted = detached.returncode != 0
                cleanup_ok &= not mounted
            except (OSError, subprocess.TimeoutExpired):
                cleanup_ok = False
        try:
            (work / "credentials.env").unlink(missing_ok=True)
        except OSError:
            cleanup_ok = False
        if cleanup_ok and stopped and not mounted:
            shutil.rmtree(work)  # This invocation alone created the private temp tree.
        if not cleanup_ok:
            status = status or 1
        (evidence / "artifact.json").write_text(json.dumps(selected, indent=2) + "\n")
        (evidence / "cleanup.json").write_text(json.dumps({"ok": cleanup_ok}) + "\n")
        with tarfile.open(evidence / "report.tgz", "w:gz") as archive:
            for path in evidence.iterdir():
                if path.name != "report.tgz":
                    archive.add(path, arcname=path.name)
        print(f"ACCOUNTS_PROBE exit={status} report={evidence / 'report.tgz'}", flush=True)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
