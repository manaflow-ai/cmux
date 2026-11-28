#!/usr/bin/env python3
"""The iPhone app attached to a published cmux NEXT NIGHTLY Mac terminal, recorded on both screens.

  cmux_next_nightly_attach.py --udid UDID --sims SET --bundle-id dev.cmux.mobile.dev --ios-app APP \
      --out DIR [--build latest|VERSION]

cmux-next-ios-sim.sh `handoff tag=TAG nightly=BUILD` calls it on a fleet Mac with a console session, once the
untagged cmux Dev simulator app (dev.cmux.mobile.dev, the default build space a NIGHTLY Mac registers in) is built:
  1 the NIGHTLY DMG (the newest in the NEXT feed, or build VERSION) copied into a side instance (its own bundle id,
    data, daemon and settings; the Mac's own apps are untouched), mobile.allowIPhoneConnections on in its own
    settings, the step's agent session (cmux-ci run --sign-in agent) in its own token store file
  2 the copy launched in front with CMUX_NEXT_ACCESSIBILITY=1 while CuaDriver records the display; one terminal
    workspace made on it (action.run newTab) and its hostd's device id read (<support>/cmux-mobile-host/device-id)
  3 the phone, signed in with the same session, launched focused on that Mac into the DEBUG demo `live-terminal`
    while simctl records the simulator; the Mac's quiet pair request (Settings > Mobile, Connection Requests) is
    answered with Allow through the accessibility tree, as a person does
  4 PASS when the phone logs `demo step: live-terminal shown` (the Mac terminal is on the phone's screen)
The token is in no argv, artifact or log. Exit 0 pass, 1 product failure, 3 rig failure (no NIGHTLY, recorder,
session or Mac). Leo, 2026-11-28 (ask-ef11d55db3): "can't connect to cosmic-gray (NIGHTLY) on my connected iphone".
"""
from __future__ import annotations

import argparse
import glob
import importlib.util
import json
import os
import plistlib
import pwd
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
import cmux_next_pair_e2e as e2e  # noqa: E402  (the token store, the workspace, the log stream)

_spec = importlib.util.spec_from_file_location("lkr", ROOT / "scripts" / "measure" / "look-keys-readback.py")
lkr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lkr)
_spec = importlib.util.spec_from_file_location("cmr", ROOT / "scripts" / "measure" / "cloud-mvp-nightly-readback.py")
cmr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cmr)

FEED = "https://files-next.cmux.com/nightly-next/appcast-arm64.xml"
SIDE = ROOT / "scripts" / "cmux-next" / "side-instance.sh"
NAME = "iosattach"
SHOWN = re.compile(r"demo step: live-terminal (shown|no \w+)")
ALLOW = ("Allow",)


class Rig(Exception):
    pass


def say(text: str) -> None:
    print(f"NIA {text}", flush=True)


def run(argv: list, **kw) -> subprocess.CompletedProcess:
    return subprocess.run(argv, capture_output=True, text=True, stdin=subprocess.DEVNULL, **kw)


def dmg_url(build: str) -> str:
    if build != "latest":
        return f"https://files-next.cmux.com/nightly-next/cmux-nightly-next-macos-arm64-{build}.dmg"
    feed = run(["curl", "-fsSL", "--retry", "3", "--retry-all-errors", FEED], timeout=120).stdout
    m = re.search(r'url="(https://[^"]+-macos-arm64-[0-9]+\.dmg)"', feed)
    if not m:
        raise Rig("no NIGHTLY DMG in the NEXT feed")
    return m.group(1)


def copy_nightly(url: str, work: Path) -> Path:
    dmg, mnt, dest = work / "nightly.dmg", work / "mnt", work / "app"
    mnt.mkdir()
    dest.mkdir()
    if run(["curl", "-fsSL", "--proto", "=https", "--retry", "3", "--retry-all-errors", "-o", str(dmg), url],
           timeout=900).returncode:
        raise Rig(f"download failed: {url}")
    if run(["hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", str(mnt), str(dmg)], timeout=300).returncode:
        raise Rig("hdiutil attach failed")
    try:
        apps = sorted(mnt.glob("*.app"))
        if not apps:
            raise Rig("no app in the DMG")
        run(["ditto", str(apps[0]), str(dest / "cmux NIGHTLY.app")], check=True, timeout=600)
    finally:
        run(["hdiutil", "detach", str(mnt)], timeout=120)
    return dest / "cmux NIGHTLY.app"


def side(*args: str, env: dict | None = None) -> str:
    done = run([str(SIDE), *args], timeout=600, env=env)
    if done.returncode:
        raise Rig(f"side-instance {args[0]}: {(done.stderr or done.stdout)[-300:]}")
    return done.stdout.strip()


def prepare(app: Path, config: Path, session: dict, out: Path) -> str:
    config.mkdir(parents=True, exist_ok=True)
    settings = config / "cmux-next.json"
    root = json.loads(settings.read_text()) if settings.is_file() and settings.read_text().strip() else {}
    root.setdefault("mobile", {})["allowIPhoneConnections"] = True
    settings.write_text(json.dumps(root, indent=2) + "\n")
    with open(app / "Contents" / "Info.plist", "rb") as handle:
        info = plistlib.load(handle)
    env = {k: v for k, v in os.environ.items() if k != "CMUX_CI_SIGNIN_FILE"}
    env.update({k: str(v) for k, v in (info.get("LSEnvironment") or {}).items()})
    store = e2e.mac_token_store(str(app), info["CFBundleIdentifier"],
                                str(app / "Contents" / "MacOS" / info["CFBundleExecutable"]), env, session["project"],
                                pwd.getpwuid(os.getuid()).pw_dir)
    e2e.write_mac_session(store, session["refresh_token"])
    say("Mac: mobile.allowIPhoneConnections on, the step's agent session in the copy's own token store")
    return info["CFBundleIdentifier"]


def device_id(bundle: str, since: float) -> str | None:
    """The copy's hostd id: <support>/<bundle>/cmux-mobile-host/device-id (config.rs persistent_device_id)."""
    support = Path.home() / "Library" / "Application Support"
    for path in sorted(glob.glob(str(support / bundle / "**" / "device-id*"), recursive=True)):
        try:
            text = Path(path).read_text().strip()
        except OSError:
            continue
        if re.fullmatch(r"[0-9a-fA-F-]{36}", text) and os.path.getmtime(path) >= since - 5:
            return text
    return None


def allow_pending(pid: int, sock: str) -> str | None:
    """Settings > Mobile's Connection Requests answered with Allow, as a person does; what was pressed, or None."""
    lkr.rpc(sock, "action.run", {"action": "openSettings", "args": {"section": "mobile"}, "focus": True}, timeout=30)
    time.sleep(1.5)
    seen = cmr.nodes(pid)
    button = cmr.find(seen, lambda t: t in ALLOW, "button")
    if not button:
        return None
    reply = cmr.press(pid, button)
    return f"{button.get('role')} '{cmr.text_of(button)}' ({'ok' if not reply.get('error') else reply.get('error')})"


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--udid", required=True)
    p.add_argument("--sims", required=True)
    p.add_argument("--bundle-id", required=True)
    p.add_argument("--ios-app", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--build", default="latest")
    a = p.parse_args()
    if not re.fullmatch(r"latest|[0-9]{1,16}", a.build):
        print("nightly= takes latest or a NIGHTLY build number", file=sys.stderr)
        return 2
    out = Path(a.out)
    shots = out / "nightly-attach"
    shots.mkdir(parents=True, exist_ok=True)
    simctl = ["xcrun", "simctl", "--set", a.sims]
    receipt: dict = {"schema": "cmux.ios-nightly-attach.v1", "phone_bundle": a.bundle_id, "steps": []}
    work = Path(tempfile.mkdtemp(prefix="nightly-attach."))
    (work / "side").mkdir()
    side_env = dict(os.environ, CMUX_SIDE_ROOT=str((work / "side").resolve()))
    mac_rec = phone_rec = phone_log = None
    status = 1
    try:
        session = e2e.signin_session()
        if session is None:
            raise Rig("no CMUX_CI_SIGNIN_FILE: send the step with cmux-ci run --sign-in agent")
        url = dmg_url(a.build)
        receipt["dmg"] = url
        say(f"NIGHTLY {url}")
        nightly = copy_nightly(url, work)
        side("make", NAME, "--from", str(nightly), "--label", "cmux nightly attach", "--neutral-shell", env=side_env)
        app = Path(side("path", NAME, env=side_env))
        with open(app / "Contents" / "Info.plist", "rb") as handle:
            info = plistlib.load(handle)
        receipt.update(app_version=info.get("CFBundleVersion"), app_commit=info.get("CMUXCommit"))
        say(f"Mac app: NIGHTLY {info.get('CFBundleShortVersionString')} ({info.get('CFBundleVersion')}), "
            f"commit {str(info.get('CMUXCommit'))[:12]}, side copy {info.get('CFBundleIdentifier')}")
        mac_bundle = prepare(app, work / "side" / NAME / "config", session, out)

        ready = run([sys.executable, str(ROOT / "scripts/measure/launch_reveal_record.py"), "preflight"], timeout=120)
        if ready.returncode == 0:
            mac_rec = subprocess.Popen([sys.executable, str(ROOT / "scripts/measure/launch_reveal_record.py"), "record",
                                        str(shots / "mac-video"), "900"], stdout=open(shots / "mac-rec.log", "w"),
                                       stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
            lkr.wait_for(lambda: "READY" in (shots / "mac-rec.log").read_text(), 70, step=0.2)
        else:
            say(f"Mac recorder: none ({(ready.stdout or ready.stderr).strip()[-200:]}); the phone video still runs")

        launched_at = time.time()
        launch_env = dict(side_env, CMUX_NEXT_ACCESSIBILITY="1")
        launch_env.pop("CMUX_CI_SIGNIN_FILE", None)
        side("launch", NAME, "--front", "--", "--skip-onboarding", env=launch_env)
        pid_file = work / "side" / NAME / "pid"
        pid = int(lkr.wait_for(lambda: pid_file.is_file() and pid_file.read_text().strip(), 60) or 0)
        sock = lkr.wait_for(lambda: lkr.control_socket(pid, side("socket", NAME, env=side_env)), 120, step=0.5) if pid else None
        if not sock:
            raise Rig("the NIGHTLY copy's control socket never answered")
        time.sleep(4)
        rpc = lambda method, params=None, timeout=30: lkr.rpc(sock, method, params, timeout)  # noqa: E731
        workspace = e2e.mac_workspace(str(app), sock, pwd.getpwuid(os.getuid()).pw_dir, None, rpc)
        say(f"Mac terminal workspace: {workspace}")
        mac_id = lkr.wait_for(lambda: device_id(mac_bundle, launched_at), 180, step=2)
        say(f"Mac hostd device id: {mac_id[:8] if mac_id else 'none in 180 s (the phone opens unfocused)'}")
        receipt["steps"].append({"step": "mac", "workspace": workspace, "device_id": bool(mac_id),
                                 "shots": lkr.shoot(pid, shots, "mac-ready")})

        # The phone: a new install, setup done, signed in from the step's session, focused on the copy.
        run(simctl + ["terminate", a.udid, a.bundle_id])
        run(simctl + ["uninstall", a.udid, a.bundle_id])
        run(simctl + ["install", a.udid, a.ios_app], check=True, timeout=300)
        data = run(simctl + ["get_app_container", a.udid, a.bundle_id, "data"], check=True).stdout.strip()
        prefs = Path(data) / "Library" / "Preferences" / f"{a.bundle_id}.plist"
        prefs.parent.mkdir(parents=True, exist_ok=True)
        with open(prefs, "wb") as handle:
            plistlib.dump({"cmuxMobile.setupComplete": True}, handle)
        phone_rec = subprocess.Popen(simctl + ["io", a.udid, "recordVideo", "--codec", "h264", "--force",
                                               str(out / "nightly-attach.mp4")],
                                     stdout=open(shots / "phone-rec.log", "w"), stderr=subprocess.STDOUT,
                                     stdin=subprocess.DEVNULL)
        lkr.wait_for(lambda: "Recording started" in (shots / "phone-rec.log").read_text(), 10, step=0.1)
        phone_log = e2e.Stream(simctl + ["spawn", a.udid, "log", "stream", "--level", "info", "--style", "compact",
                                         "--predicate", 'subsystem == "dev.cmux.mobile"'], str(shots / "phone.log"))
        phone_env = dict(os.environ, SIMCTL_CHILD_CMUX_MOBILE_STACK_REFRESH_TOKEN=session["refresh_token"])
        phone_env.pop("CMUX_CI_SIGNIN_FILE", None)
        if mac_id:
            phone_env["SIMCTL_CHILD_CMUX_MOBILE_FOCUS_MAC"] = mac_id

        outcome, allowed, t0 = None, [], time.monotonic()
        for attempt in range(1, 4):
            since = time.monotonic()
            run(simctl + ["terminate", a.udid, a.bundle_id])
            run(simctl + ["launch", a.udid, a.bundle_id, "-cmux-mobile-no-restore", "-cmux-mobile-demo",
                          "live-terminal"], env=phone_env, check=True, timeout=120)
            deadline = since + 150
            while time.monotonic() < deadline:
                hit = phone_log.wait_at(SHOWN, 5, since=since)
                if hit:
                    outcome = hit[1].group(1)
                    break
                pressed = allow_pending(pid, sock)
                if pressed:
                    allowed.append(pressed)
                    say(f"Mac Settings > Mobile: pressed {pressed} ({time.monotonic() - t0:.0f} s)")
            say(f"phone launch {attempt}: live-terminal {outcome or 'no demo line in 150 s'}")
            run(simctl + ["io", a.udid, "screenshot", str(shots / f"phone-{attempt}.png")])
            if outcome == "shown":
                break
            outcome = None  # "no mac"/"no terminal" before Allow: relaunch once the Mac answered
        time.sleep(8)  # the attached terminal on both screens, for the video
        run(simctl + ["io", a.udid, "screenshot", str(shots / "phone-attached.png")])
        receipt["steps"].append({"step": "phone", "outcome": outcome, "allowed": allowed,
                                 "seconds": round(time.monotonic() - t0, 1),
                                 "mac_shots": lkr.shoot(pid, shots, "mac-attached")})
        receipt["pass"] = outcome == "shown"
        say(("PASS" if receipt["pass"] else "FAIL") + f": the phone's live-terminal demo {outcome or 'never showed'} "
            f"on NIGHTLY {info.get('CFBundleVersion')} ({len(allowed)} Allow press(es))")
        status = 0 if receipt["pass"] else 1
    except Rig as why:
        receipt["rig"] = str(why)
        say(f"RIG: {why}")
        status = 3
    except SystemExit as stop:  # signin_session's refusals
        receipt["rig"] = str(stop.code)
        say(f"RIG: {stop.code}")
        status = 3
    finally:
        for proc in (phone_rec, mac_rec):
            if proc and proc.poll() is None:
                proc.send_signal(2 if proc is phone_rec else 15)
                try:
                    proc.wait(30)
                except subprocess.TimeoutExpired:
                    proc.terminate()
        if phone_log:
            phone_log.stop()
        run(simctl + ["terminate", a.udid, a.bundle_id])
        try:
            side("stop", NAME, env=side_env)
        except Rig:
            pass
        run([str(SIDE), "remove", NAME], env=side_env, timeout=300)
        shutil.rmtree(work, ignore_errors=True)
        video = sorted((shots / "mac-video").glob("*")) if (shots / "mac-video").is_dir() else []
        receipt["videos"] = {"phone": "nightly-attach.mp4" if (out / "nightly-attach.mp4").is_file() else None,
                             "mac": [str(v.relative_to(out)) for v in video]}
        (out / "nightly-attach.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print("NIGHTLY_ATTACH " + json.dumps(receipt), flush=True)
    return status


if __name__ == "__main__":
    sys.exit(main())
