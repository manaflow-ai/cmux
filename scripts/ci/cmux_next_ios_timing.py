#!/usr/bin/env python3
"""cmux-next-ios-sim.sh timing: open to first terminal frame on the iPhone, against the paired Mac.

  cmux_next_ios_timing.py --mac-app APP --ios-app APP --sims SET --udid UDID --bundle-id ID \
      --work DIR --out DIR --summary FILE [--runs 5] [--background-seconds 30]

The tagged DEBUG cmux NEXT Mac app of pair-e2e (same rig: its own settings, keychain and tag, no pairing
seed) starts on this worker, the simulator iPhone pairs with it by its code (as pair-e2e does), and then each
scenario runs `--runs` times, every run on its own `log stream` of the app's timing category:

  cold      terminate, launch into a terminal (CMUX_MOBILE_TIMING_SCENARIO=terminal): the app's
            `timing launch terminal_ready (<ms>)` mark, ms since the process started.
  warm      the app on a terminal, sent to the background (Settings in front) for `--background-seconds`
            (at least 30), then brought forward: `timing foreground terminal_frame +<ms>ms`, the first
            terminal frame presented after the foreground.
  browser   terminate, launch into a browser tab, switch to the terminal after a few seconds
            (CMUX_MOBILE_TIMING_SCENARIO=browser_then_terminal): `timing event
            scenario_switch_to_terminal` to `terminal_ready`, and whether the terminal ever said
            offline (`timing launch terminal_offline_shown`).

A run is cold in the sense of a fresh app process on a booted simulator (the simulator is not rebooted
between runs). The ConnectTimeline stage lines of each run (`timing <attempt> <stage> +<ms>ms (<total>ms)`)
are kept per run and summarized as medians. Writes timing.json and timing.md into --out and appends a line
per scenario to --summary. Needs the worker's dev account (CMUX_UITEST_STACK_EMAIL and _PASSWORD, or
~/.secrets/cmuxterm-dev.env, as pair-e2e) for the Mac; the phone uses the step's sign-in session
(CMUX_CI_SIGNIN_FILE, `cmux-ci run --sign-in agent`) when there is one. Nothing here prints a credential
or a pairing code.
"""
import argparse
import json
import os
import plistlib
import re
import shutil
import socket
import statistics
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

MIN_BACKGROUND_SECONDS = 30
READY_TIMEOUT = 120

LAUNCH_MARK = re.compile(r"timing launch (\w+) \((\d+)ms\)")
STAGE = re.compile(r"timing (\w+) (\w+) \+(\d+)ms \((\d+)ms\)")
EVENT = re.compile(r"timing event (\w+) \((\d+)ms\)")
FOREGROUND_FRAME = re.compile(r"timing foreground terminal_frame \+(\d+)ms")


def parse_run(lines):
    """One run's timing lines as {marks, stages, events, foreground_terminal_frame_ms}.

    marks: LaunchMarks, name -> ms since the process started. stages: ConnectTimeline, "attempt.stage"
    -> ms since the attempt began. events: name -> ms since the process started."""
    marks, stages, events, frame = {}, {}, {}, None
    for line in lines:
        if (m := FOREGROUND_FRAME.search(line)) and frame is None:
            frame = int(m.group(1))
        elif m := LAUNCH_MARK.search(line):
            marks.setdefault(m.group(1), int(m.group(2)))
        elif m := EVENT.search(line):
            events.setdefault(m.group(1), int(m.group(2)))
        elif m := STAGE.search(line):
            stages.setdefault(f"{m.group(1)}.{m.group(2)}", int(m.group(3)))
    return {"marks": marks, "stages": stages, "events": events, "foreground_terminal_frame_ms": frame}


def metric(scenario, run):
    """The scenario's open-to-first-terminal-frame in ms for one parsed run, or None when it never came."""
    if scenario == "cold":
        return run["marks"].get("terminal_ready")
    if scenario == "warm":
        return run["foreground_terminal_frame_ms"]
    ready, switched = run["marks"].get("terminal_ready"), run["events"].get("scenario_switch_to_terminal")
    if ready is None or switched is None or ready < switched:
        return None  # the terminal was ready before the switch: it was not measured from it
    return ready - switched


def offline_shown(run):
    """Whether the terminal said offline at any time in the run."""
    return any(key.endswith(".terminal_offline_shown") for key in run["stages"])


def median(values):
    values = [v for v in values if v is not None]
    return round(statistics.median(values), 1) if values else None


def summarize(runs_by_scenario):
    """medians per scenario: the metric, each stage seen in at least one run, and for browser the offline count."""
    out = {}
    for scenario, runs in runs_by_scenario.items():
        values = [metric(scenario, run) for run in runs]
        stage_names = sorted({name for run in runs for name in run["stages"]})
        entry = {
            "runs": len(runs),
            "measured": sum(v is not None for v in values),
            "open_to_first_terminal_frame_ms": {
                "median": median(values),
                "min": min((v for v in values if v is not None), default=None),
                "max": max((v for v in values if v is not None), default=None),
                "all": values,
            },
            "stage_median_ms": {name: median([run["stages"].get(name) for run in runs]) for name in stage_names},
            "offline_shown_runs": sum(offline_shown(run) for run in runs),
        }
        out[scenario] = entry
    return out


def markdown(summary, meta):
    lines = ["# iPhone timing: open to first terminal frame", "",
             f"{meta['runs']} runs per scenario; simulator {meta['device']}; ref {meta['ref']}; Mac app of the same worker, paired.", "",
             "| scenario | measured | median ms | min | max | offline shown |", "| --- | --- | --- | --- | --- | --- |"]
    labels = {"cold": "cold launch into a terminal", "warm": f"warm: foreground after {meta['background_seconds']} s in the background",
              "browser": "cold launch into a browser tab, then the terminal"}
    for scenario, entry in summary.items():
        m = entry["open_to_first_terminal_frame_ms"]
        lines.append(f"| {labels[scenario]} | {entry['measured']}/{entry['runs']} | {m['median']} | {m['min']} | {m['max']} | "
                     f"{entry['offline_shown_runs']}/{entry['runs']} |")
    for scenario, entry in summary.items():
        if not entry["stage_median_ms"]:
            continue
        lines += ["", f"## {labels[scenario]}: connect stages (median ms since the attempt began)", ""]
        lines += [f"- {name}: {value}" for name, value in entry["stage_median_ms"].items()]
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    for flag in ("--mac-app", "--ios-app", "--sims", "--udid", "--bundle-id", "--work", "--out", "--summary"):
        ap.add_argument(flag, required=True)
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--background-seconds", type=int, default=MIN_BACKGROUND_SECONDS)
    ap.add_argument("--device", default="")
    ap.add_argument("--ref", default="")
    a = ap.parse_args()
    a.background_seconds = max(MIN_BACKGROUND_SECONDS, a.background_seconds)

    import cmux_next_pair_e2e as pe  # the rig's helpers; its main() is not run

    def note(line):
        print(line, flush=True)
        with open(a.summary, "a") as f:
            f.write(line + "\n")

    mac_bundle, tag, ls_env = pe.step_tag(a.mac_app)
    pe.no_data_protection_keychain(a.mac_app)
    sock = ls_env.get("CMUX_SOCKET_PATH") or f"/tmp/cmux-debug-{tag}.sock"
    rig = os.path.join(a.work, "pair-rig")
    config = os.path.join(rig, "cmux-next.json")
    creds = os.path.join(rig, "dev-auth.env")
    email, password = pe.dev_credential()
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX")}
    env.update(ls_env)
    env.update(CMUX_NEXT_CONFIG_FILE=config, CMUX_AUTH_CREDENTIALS_FILE=creds, CMUX_NEXT_IPHONE_PAIRING_SEED="",
               CMUX_NEXT_MOBILE_MACHINE_ID=pe.machine_id(mac_bundle), CMUX_NEXT_NO_ACTIVATE="1",
               CMUX_NEXT_MOBILE_DEVICE_NAME=pe.RIG_MAC_NAME, CMUX_NEXT_SOCKET_MODE="automation")

    def rpc(method, params=None, timeout=30):
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
                conn.settimeout(timeout)
                conn.connect(sock)
                conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
                buf = b""
                while not buf.endswith(b"\n"):
                    chunk = conn.recv(1 << 20)
                    if not chunk:
                        break
                    buf += chunk
            reply = json.loads(buf)
            if not reply.get("ok"):
                return {"error": reply.get("error")}
            return reply["result"] if isinstance(reply.get("result"), dict) else {"result": reply.get("result")}
        except (OSError, ValueError) as error:
            return {"error": str(error)}

    def pairing_status():
        r = rpc("debug.page", {"page": pe.PAGE, "action": "call", "op": "cmux.mobilePairing.status"})
        if "no live page" in str(r.get("error", "")):
            rpc("action.run", {"action": "palette.mobileConnect", "focus": True})
            return {}
        return r.get("value") if isinstance(r.get("value"), dict) else {}

    simctl = ["xcrun", "simctl", "--set", a.sims]
    phone_env = dict(os.environ)
    session_file = os.environ.get("CMUX_CI_SIGNIN_FILE")
    if session_file and os.path.isfile(session_file):
        # The step's own sign-in session (cmux-ci run --sign-in agent): its refresh token reaches only
        # the signing-in launches below, as scripts/lib/fleet-signin-session.sh does.
        phone_env["SIMCTL_CHILD_CMUX_MOBILE_STACK_REFRESH_TOKEN"] = json.load(open(session_file))["refresh_token"]
        signed_in_with = "the step's sign-in session (--sign-in agent)"
    else:
        phone_env.update(SIMCTL_CHILD_CMUX_MOBILE_STACK_EMAIL=email, SIMCTL_CHILD_CMUX_MOBILE_STACK_PASSWORD=password)
        signed_in_with = "the worker's dev account"
    plain_env = {k: v for k, v in os.environ.items() if not k.startswith("SIMCTL_CHILD_")}

    def terminate():
        subprocess.run(simctl + ["terminate", a.udid, a.bundle_id], capture_output=True, timeout=60)

    def launch(extra_env=None, args=(), with_session=False):
        child = dict(phone_env if with_session else plain_env)
        for key, value in (extra_env or {}).items():
            child[f"SIMCTL_CHILD_{key}"] = value
        done = subprocess.run(simctl + ["launch", a.udid, a.bundle_id, *args], env=child, capture_output=True, text=True, timeout=60)
        if done.returncode != 0:
            raise SystemExit(f"simctl launch failed ({done.returncode}): {pe.redact(done.stderr.strip())[-300:]}")

    def timing_stream(name):
        return pe.Stream(simctl + ["spawn", a.udid, "log", "stream", "--level", "info", "--style", "compact",
                                   "--predicate", 'subsystem=="dev.cmux.mobile" AND category=="timing"'],
                         os.path.join(a.out, f"timing-{name}.log"))

    ready = re.compile(r"timing launch terminal_ready ")
    frame = re.compile(r"timing foreground terminal_frame ")
    runs = {"cold": [], "warm": [], "browser": []}
    teardown = pe.TagTeardown(a.mac_app)
    teardown.install()
    app, streams = None, []
    keychain = pe.RigKeychain(a.mac_app)
    try:
        note(f"- timing: Keychain: {keychain.start()}")
        os.makedirs(rig, mode=0o700, exist_ok=True)
        with open(config, "w") as f:
            json.dump({"mobile": {"allowIPhoneConnections": True}}, f)
        with os.fdopen(os.open(creds, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
            f.write(f"CMUX_UITEST_STACK_EMAIL={email}\nCMUX_UITEST_STACK_PASSWORD={password}\n")
        if os.path.exists(sock):
            os.unlink(sock)
        plist = plistlib.load(open(os.path.join(a.mac_app, "Contents/Info.plist"), "rb"))
        exe = os.path.join(a.mac_app, "Contents/MacOS", plist["CFBundleExecutable"])
        app_out = pe.Stream([exe], os.path.join(a.out, "mac-app.log"), env=env)
        app = app_out.proc
        streams.append(app_out)
        if not pe.wait_for(lambda: app.poll() is None and "error" not in rpc("debug.focus", timeout=5), 180):
            raise SystemExit("the Mac app never answered on its control socket")
        teardown.remember()
        note(f"- timing: Mac app {mac_bundle}, pid {app.pid}")
        pairing_logs = f'processID == {app.pid} AND subsystem == "com.cmuxterm.app.next" AND category BEGINSWITH "app.iphone"'
        streams.append(mac_log := pe.Stream(["/usr/bin/log", "stream", "--level", "info", "--style", "compact",
                                             "--predicate", pairing_logs], os.path.join(a.out, "mac-pairing.log")))
        qr = pe.wait_for(lambda: pairing_status().get("qr"), 300, every=2) or {}
        url = qr.get("url")
        if not url:
            raise SystemExit("the Mac's pairing page shows no code in 300 s")

        # The phone: a new install, setup marked done, signed in, paired by the code; then closed.
        terminate()
        subprocess.run(simctl + ["uninstall", a.udid, a.bundle_id], capture_output=True)
        subprocess.run(simctl + ["install", a.udid, a.ios_app], check=True, capture_output=True)
        data = subprocess.run(simctl + ["get_app_container", a.udid, a.bundle_id, "data"],
                              check=True, capture_output=True, text=True).stdout.strip()
        prefs = os.path.join(data, "Library/Preferences", f"{a.bundle_id}.plist")
        os.makedirs(os.path.dirname(prefs), exist_ok=True)
        with open(prefs, "wb") as f:
            plistlib.dump({"cmuxMobile.setupComplete": True}, f)
        streams.append(phone_log := pe.Stream(
            simctl + ["spawn", a.udid, "log", "stream", "--level", "info", "--style", "compact",
                      "--predicate", 'subsystem == "dev.cmux.mobile"'], os.path.join(a.out, "phone-pairing.log")))
        launch(with_session=True, args=["-cmux-mobile-settings-page", "devices"])
        phone_log.wait(re.compile(r"live data on"), 90)
        terminate()
        if pe.takes_pair_url_env():
            launch({"CMUX_MOBILE_PAIR_URL": url}, ["-cmux-mobile-settings-page", "devices"], with_session=True)
        else:
            subprocess.run(simctl + ["openurl", a.udid, url], capture_output=True, text=True, timeout=60)
        if not mac_log.wait(pe.PAIRED, 180):
            raise SystemExit("the phone did not pair with the Mac in 180 s")
        pe.wait_for(lambda: pairing_status().get("connectedPhones", 0) >= 1, 60, every=2)
        phone_log.stop()
        terminate()
        note(f"- timing: phone signed in with {signed_in_with} and paired with the Mac")

        scenario_env = {"cold": {"CMUX_MOBILE_TIMING_SCENARIO": "terminal"},
                        "warm": {"CMUX_MOBILE_TIMING_SCENARIO": "terminal"},
                        "browser": {"CMUX_MOBILE_TIMING_SCENARIO": "browser_then_terminal"}}
        for scenario in ("cold", "warm", "browser"):
            for n in range(1, a.runs + 1):
                terminate()
                stream = timing_stream(f"{scenario}-{n}")
                try:
                    time.sleep(2)  # bounded: the log stream's first lines
                    launch(scenario_env[scenario])
                    got = stream.wait(ready, READY_TIMEOUT)
                    if scenario == "warm" and got:
                        subprocess.run(simctl + ["launch", a.udid, "com.apple.Preferences"], capture_output=True, timeout=60)
                        time.sleep(a.background_seconds)
                        subprocess.run(simctl + ["launch", a.udid, a.bundle_id], env=plain_env, capture_output=True, timeout=60)
                        stream.wait(frame, READY_TIMEOUT)
                    elif scenario == "browser" and got:
                        time.sleep(2)  # bounded: a late offline line after the terminal's first frame
                    elif not got:
                        note(f"- timing: {scenario} run {n}: no terminal frame in {READY_TIMEOUT} s")
                finally:
                    stream.stop()
                runs[scenario].append(parse_run(list(stream.lines)))
            note(f"- timing {scenario}: {summarize({scenario: runs[scenario]})[scenario]['open_to_first_terminal_frame_ms']['median']} ms median "
                 f"({sum(metric(scenario, r) is not None for r in runs[scenario])}/{a.runs} measured)")
        terminate()
    finally:
        summary = summarize(runs)
        meta = {"runs": a.runs, "background_seconds": a.background_seconds, "device": a.device, "ref": a.ref}
        with open(os.path.join(a.out, "timing.json"), "w") as f:
            json.dump({"meta": meta, "summary": summary, "runs": runs}, f, indent=2)
        with open(os.path.join(a.out, "timing.md"), "w") as f:
            f.write(markdown(summary, meta))
        if app and app.poll() is None:
            rpc("debug.cloud.end_session", timeout=30)
            rpc("action.run", {"action": "quitEndSessions"})
            try:
                app.wait(30)
            except subprocess.TimeoutExpired:
                app.terminate()  # the exact PID this script started
                try:
                    app.wait(15)
                except subprocess.TimeoutExpired:
                    app.kill()
        try:
            for s in streams:
                s.stop()
            teardown.end()
            shutil.rmtree(rig, ignore_errors=True)
        finally:
            pe.forget_tag(a.mac_app)
    complete = all(len(runs[s]) == a.runs and all(metric(s, r) is not None for r in runs[s]) for s in runs)
    return 0 if complete else 1


if __name__ == "__main__":
    sys.exit(main())
