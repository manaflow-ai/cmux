#!/usr/bin/env python3
"""ON1: install cmux NEXT NIGHTLY in a fresh macOS VM and turn on Computer Use the way a person does.

vm.sh runs it per major (`--suite onboarding`) on the Tart host, with a DMG (the NIGHTLY feed's
newest, onboarding/nightly.py). The guest is a fresh clone of the pinned image: no cmux, no grants.

The person's part goes in over VNC only (real keyboard and pointer events) and is seen only through
VNC frames read with OCR (onboarding/vmeye.swift on the host). No terminal command, no AppleScript,
no TCC edit and no relaunch: the check plays the person, the one who answers cmux's cards and the
System Settings prompts it opens. SSH is used for the harness's own part only, never to enable
anything: it puts the DMG in ~/Downloads with the quarantine a browser download has, registers the
scripted agent's harness before cmux first starts, starts the agent's turn, and reads results.

Steps (each one ok/FAIL in result.json with its person actions, seconds and a still shot-<step>.png):
  install      open the DMG from Downloads in Finder, drag cmux NEXT to Applications, open it from
               Spotlight, answer Gatekeeper's Open: cmux shows its window
  first_run    the first-run page answers Escape (no setup is required to reach a chat)
  cu_open      the palette's "Computer Use Setup" opens the Computer Use window
  cu_ax        Allow on Accessibility, drag the helper into the list System Settings shows, the
               password: the row turns Done and the window comes back by itself
  cu_screen    the same for Screenshots (Screen & System Audio Recording), answering any prompt
               macOS raises on the way (its own Screen Recording ask, Quit & Reopen of the helper)
  cu_ready     the window says "Computer Use is ready." and Done closes it
  screen_sharing  the palette's "Screen Sharing" page turns on sharing this Mac (needs a signed-in
               cmux account: without one the step fails and says so)
  agent        a scripted agent (onboarding/agent.swift, no model) clicks Calculator to 6 x 7 = 42,
               types into TextEdit and drag-selects that line, both apps in the background: no
               focus steal
  no_relaunch  cmux's pid is the one that first opened (it never quit or relaunched)

The person's effort is counted: every click, drag, key chord and typed string is one action, a
password typed is one (a Touch ID touch on a real Mac). The reference flow (Claude Desktop and Codex
studied in cmuxterm-hq#7146) needs 7 to have Computer Use ready: 1 to start, 3 per grant (Allow,
drag, authenticate). A step over its reference count is recorded as a finding, not a FAIL; a step
that cannot finish at all is a FAIL.

Usage (vm.sh does this): onboarding.py --ssh admin@IP --vnc HOST:PORT:PW --dmg DMG --vmeye BIN --out DIR
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)
from eyes import Eyes, NotSeen  # noqa: E402
from rfb import RFB  # noqa: E402

PASSWORD = "admin"  # the pinned images' login (images.json)
BUNDLE_ID = "com.cmuxterm.app.nightly.cmux-next"
APP = "cmux NEXT"
ACPMUX_HOME = f"/Users/admin/.acpmux/builds/{BUNDLE_ID}"
GUEST_WORK = "/Users/admin/onboarding"
HARNESS = "onbagent"
# The reference count of person actions per step (cmuxterm-hq#7146, "the best flow").
REFERENCE = {"cu_open": 1, "cu_ax": 3, "cu_screen": 3, "cu_ready": 0}

p = argparse.ArgumentParser()
p.add_argument("--ssh", required=True)
p.add_argument("--ssh-opt", action="append", default=[])
p.add_argument("--vnc", required=True)
p.add_argument("--dmg", required=True)
p.add_argument("--vmeye", required=True)
p.add_argument("--agent", required=True, help="the agent binary (agent.swift, compiled on the host)")
p.add_argument("--nightly-build", default="")
p.add_argument("--out", required=True)
opts = p.parse_args()
SSH = ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
       *opts.ssh_opt, opts.ssh]
SCP = ["scp", "-q", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
       *opts.ssh_opt]


def guest(cmd: str, timeout: float = 60) -> subprocess.CompletedProcess:
    return subprocess.run([*SSH, cmd], capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)


def app_pid() -> int | None:
    """cmux's pid, by its executable's path (its CFBundleExecutable, not the bundle's name)."""
    exe = guest(f"/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' /Applications/{shlex.quote(APP)}.app/Contents/Info.plist").stdout.strip()
    if not exe:
        return None
    out = guest(f"pgrep -nf {shlex.quote('^/Applications/' + APP + '.app/Contents/MacOS/' + exe + '( |$)')} || true").stdout.strip()
    return int(out) if out.isdigit() else None


host, port, password = opts.vnc.split(":", 2)
vnc = RFB(host, int(port), password)
eyes = Eyes(vnc, opts.vmeye, opts.out)
steps: list[dict] = []
findings: list[dict] = []


def step(name: str):
    def wrap(fn):
        started, before = time.monotonic(), eyes.actions
        row = {"step": name}
        try:
            fn(row)
            row["ok"] = True
        except (NotSeen, RuntimeError, ValueError, subprocess.SubprocessError, OSError, ConnectionError, TimeoutError) as error:
            row["ok"], row["error"] = False, str(error)
        row["actions"] = eyes.actions - before
        row["seconds"] = round(time.monotonic() - started, 1)
        ref = REFERENCE.get(name)
        if ref is not None:
            row["reference_actions"] = ref
            if row["actions"] > ref:
                findings.append({"step": name, "kind": "more actions than the reference",
                                 "actions": row["actions"], "reference": ref, "extra": row.get("extra", [])})
        try:
            row["shot"] = os.path.basename(eyes.shot(name))
        except (OSError, ConnectionError, TimeoutError, subprocess.SubprocessError):
            pass
        steps.append(row)
        print("%-12s %s actions=%d%s %ss %s" % (name, "ok" if row["ok"] else "FAIL", row["actions"],
              "/%d" % ref if ref is not None else "", row["seconds"], row.get("error", "")), flush=True)
        return row["ok"]
    return wrap


def answer_macos_prompts(row: dict, seconds: float = 4) -> None:
    """Answer what macOS shows on the way to a grant, the way a person does, and note each one."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        lines = eyes.look()
        if eyes.find(r"enter your password|to allow this|modify .*settings|Use Password", lines) and \
                eyes.find(r"^Password$|Use Password", lines):
            if eyes.find(r"Use Password", lines):
                eyes.click(r"Use Password")
            eyes.type(PASSWORD + "\n")
            row.setdefault("extra", []).append("password")
            # One password per sheet: wait for the sheet to go before looking again.
            eyes.wait(r"enter your password|Use Password", 15, gone=True)
        elif eyes.find(r"would like to record this computer", lines):
            eyes.click(r"^Open System Settings$")
            row.setdefault("extra", []).append("macOS Screen Recording prompt")
        elif eyes.find(r"Quit (&|and) Reopen", lines):
            eyes.click(r"Quit (&|and) Reopen")
            row.setdefault("extra", []).append("Quit & Reopen (helper)")
        elif eyes.find(r"bypass the system private window picker|Allow For One Month", lines):
            eyes.click(r"^Allow( For One Month)?$")
            row.setdefault("extra", []).append("private window picker bypass")
        else:
            time.sleep(0.5)
            continue
        deadline = time.monotonic() + seconds


def drag_helper_into_list(row: dict) -> None:
    """The drag panel cmux docks under System Settings: drag its helper row up into the list."""
    eyes.wait(r"to the list above", 30)
    lines = eyes.lines
    hint = eyes.find(r"to the list above", lines)
    tile = min((l for l in lines if l["text"].strip() == "cmux Computer Use" and l["y"] > hint["y"]),
               key=lambda l: l["y"], default=None)
    if not tile:
        raise RuntimeError("the drag panel shows no cmux Computer Use row to drag")
    x0, y0 = eyes.center(tile)
    eyes.drag(x0, y0, x0, hint["y"] - 160)


def grant(row: dict, line_pattern: str, done_pattern: str) -> None:
    lines = eyes.wait(line_pattern, 20) and eyes.lines
    anchor = eyes.find(line_pattern, lines)
    allow = min((l for l in lines if l["text"].strip().startswith("Allow")),
                key=lambda l: abs(l["y"] - anchor["y"]), default=None)
    if not allow:
        raise RuntimeError(f"no Allow beside {line_pattern!r}")
    eyes.click_at(*eyes.center(allow))
    answer_macos_prompts(row, 3)
    drag_helper_into_list(row)
    answer_macos_prompts(row, 6)
    # The grant lands: the panel goes and the Computer Use window comes back with the row done.
    eyes.wait(r"to the list above", 30, gone=True)
    eyes.wait(done_pattern, 30)


def main() -> int:
    os.makedirs(opts.out, exist_ok=True)
    # Harness part (SSH): the DMG as a browser download leaves it, and the agent's harness.
    subprocess.run([*SCP, opts.dmg, f"{opts.ssh}:/Users/admin/Downloads/cmux-NEXT.dmg"], check=True, timeout=600)
    guest(f"mkdir -p {GUEST_WORK} {shlex.quote(ACPMUX_HOME)}")
    subprocess.run([*SCP, opts.agent, f"{opts.ssh}:{GUEST_WORK}/onbagent"], check=True, timeout=60)
    config = {"harnesses": {HARNESS: {"argv": [f"{GUEST_WORK}/onbagent"],
                                      "env": {"ONB_OUT": GUEST_WORK}, "description": "onboarding check's scripted agent"}}}
    quarantine = "0081;%08x;Safari;" % int(time.time())
    guest(f"xattr -w com.apple.quarantine '{quarantine}' ~/Downloads/cmux-NEXT.dmg && "
          f"printf %s {shlex.quote(json.dumps(config))} > {shlex.quote(ACPMUX_HOME)}/config.json")
    first_pid = None

    @step("install")
    def _(row):
        eyes.press("cmd+space")
        eyes.type("Downloads\n")
        eyes.wait(r"cmux-NEXT\.dmg|cmux-NEXT", 30)
        line = eyes.find(r"cmux-NEXT")
        vnc.click(*eyes.center(line), count=2)
        eyes.actions += 1
        # The DMG's window: the app's label and an "Applications" label on the same row, right of it
        # (Finder's sidebar has an "Applications" too, never beside the app).
        deadline = time.monotonic() + 120
        while True:
            lines = eyes.look()
            app = eyes.find(rf"^{APP}(\.app)?$", lines)
            apps = app and min((l for l in lines if l["text"].strip() == "Applications" and l["x"] > app["x"] + app["w"]
                                and abs(l["y"] - app["y"]) < 40), key=lambda l: l["x"], default=None)
            if app and apps:
                break
            if time.monotonic() > deadline:
                raise RuntimeError("the DMG window never showed cmux NEXT beside Applications")
            time.sleep(1)
        # Drag the icon (above its label) onto the Applications alias's icon.
        eyes.drag(eyes.center(app)[0], app["y"] - 40, eyes.center(apps)[0], apps["y"] - 40)
        answer_macos_prompts(row, 3)
        # The harness waits for Finder's copy to finish (a person watches its progress bar).
        for _ in range(180):
            # Done when the copy has as many files as the DMG's bundle (block sizes differ between the
            # DMG's filesystem and APFS, file counts do not).
            if guest(f'src=$(ls -d /Volumes/*/{shlex.quote(APP)}.app | head -1); dst=/Applications/{shlex.quote(APP)}.app; '
                     f'[ -n "$src" ] && [ -f "$dst/Contents/Info.plist" ] && '
                     f'[ "$(find "$src" | wc -l)" = "$(find "$dst" | wc -l)" ]').returncode == 0:
                break
            time.sleep(1)
        else:
            raise RuntimeError("cmux NEXT never reached /Applications")
        eyes.press("cmd+space")
        eyes.type(APP + "\n")
        # Gatekeeper's first-open question, or (once answered) the app's own first window.
        eyes.wait(r"downloaded from the Internet|Are you sure you want to open|Bring your history", 120)
        if eyes.find(r"downloaded from the Internet|Are you sure you want to open"):
            eyes.click(r"^Open$")
        for _ in range(60):
            row["pid"] = app_pid()
            if row["pid"]:
                break
            time.sleep(1)
        else:
            raise RuntimeError("cmux NEXT never started")

    if not steps[-1]["ok"]:
        return finish()
    first_pid = steps[-1]["pid"]

    @step("first_run")
    def _(row):
        # The first-run page, if this build shows one; Escape leaves it (nothing there is required).
        try:
            eyes.wait(r"Bring your history", 60)
            eyes.press("esc")
        except NotSeen:
            row["note"] = "no first-run page"

    @step("cu_open")
    def _(row):
        eyes.press("cmd+shift+p")
        eyes.type("Computer Use Setup")
        eyes.wait(r"Computer Use Setup", 10)
        eyes.press("return")
        eyes.wait(r"Turn On Computer Use", 20)

    @step("cu_ax")
    def _(row):
        grant(row, r"Lets agents click and type", r"^Done")

    @step("cu_screen")
    def _(row):
        grant(row, r"Lets agents see the window", r"Computer Use is ready")
        answer_macos_prompts(row, 5)

    @step("cu_ready")
    def _(row):
        eyes.wait(r"Computer Use is ready", 60)
        eyes.click(r"^Done$")

    @step("screen_sharing")
    def _(row):
        # Turn on sharing this Mac to a phone from cmux's own Screen Sharing page, as a person does.
        eyes.press("cmd+shift+p")
        eyes.type("Screen Sharing")
        eyes.wait(r"^Screen Sharing$", 10)
        eyes.press("return")
        eyes.wait(r"Allow Mac Screen|Sign in to cmux|Sign In", 30)
        if eyes.find(r"Sign in to cmux|^Sign In$"):
            raise RuntimeError("Screen Sharing needs a signed-in cmux account first; the VM has none yet")
        eyes.click(r"Allow Mac Screen on this Mac")
        answer_macos_prompts(row, 6)
        eyes.wait(r"Allow Mac Screen", 30)

    @step("agent")
    def _(row):
        acpmux = f"/Applications/{APP}.app/Contents/Resources/bin/acpmux"
        res = guest(f"cd {GUEST_WORK} && ACPMUX_HOME={shlex.quote(ACPMUX_HOME)} {shlex.quote(acpmux)} exec -m {HARNESS} "
                    f"--cwd {GUEST_WORK} --policy approve-all --timeout 240 'use Calculator and TextEdit in the background'",
                    timeout=300)
        row["exec_exit"] = res.returncode
        out = guest(f"cat {GUEST_WORK}/agent-result.json").stdout
        try:
            result = json.loads(out)
        except ValueError:
            result = {}
        with open(os.path.join(opts.out, "agent-result.json"), "w") as f:
            json.dump(result or {"exec_stdout": res.stdout[-3000:], "exec_stderr": res.stderr[-3000:]}, f, indent=1)
        row["checks"], row["focus_steals"] = result.get("checks"), result.get("focus_steals")
        if not result.get("ok"):
            raise RuntimeError("agent: %s" % json.dumps({k: result.get(k) for k in ("checks", "focus_steals", "errors", "error")})[:600])

    @step("no_relaunch")
    def _(row):
        row["pid"] = app_pid()
        if row["pid"] != first_pid:
            raise RuntimeError(f"cmux's pid went from {first_pid} to {row['pid']}: it quit or relaunched")

    return finish()


def write(result: dict) -> None:
    tmp = os.path.join(opts.out, "result.json.tmp")
    with open(tmp, "w") as f:
        json.dump(result, f, indent=1)
    os.replace(tmp, os.path.join(opts.out, "result.json"))


def finish() -> int:
    eyes.close()
    person = sum(s["actions"] for s in steps if s["step"] in REFERENCE)
    ok = {s["step"]: s["ok"] for s in steps}
    cu = ("install", "first_run", "cu_open", "cu_ax", "cu_screen", "cu_ready", "agent", "no_relaunch")
    result = {
        "suite": "onboarding", "nightly_build": opts.nightly_build or None,
        "ok": all(s["ok"] for s in steps) and len(steps) == 9,
        # ON1 needs both; each part has its own verdict, so a Screen Sharing FAIL (no account yet)
        # does not hide whether Computer Use got there.
        "parts": {"computer_use": all(ok.get(n) for n in cu), "screen_sharing": bool(ok.get("screen_sharing"))},
        "steps": steps, "failed_steps": [s["step"] for s in steps if not s["ok"]],
        "person_actions_to_ready": person, "reference_actions_to_ready": sum(REFERENCE.values()),
        "findings": findings, "video": None,
    }
    write(result)  # before the slow parts below: a timeout there keeps every step's verdict
    try:
        result["os"] = guest("sw_vers -productVersion").stdout.strip()
    except subprocess.SubprocessError:
        result["os"] = None
    try:
        if eyes.video(os.path.join(opts.out, "onboarding.mp4")):
            result["video"] = "onboarding.mp4"
    except subprocess.SubprocessError:
        pass
    write(result)
    print("ONBOARDING %s actions=%d/%d failed=%s" % ("PASS" if result["ok"] else "FAIL", person,
          result["reference_actions_to_ready"], ",".join(result["failed_steps"]) or "-"), flush=True)
    vnc.close()
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
