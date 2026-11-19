#!/usr/bin/env python3
"""The live Screen Sharing leg of cmux-next-ios-sim.sh (`test ui=ScreenSharingLiveUITests...`).

The iPhone (a Debug simulator app, driven by UITests/ScreenSharingLiveUITests.swift) opens a real host's
screen through the device hub and taps and types on it; this file is the host side's glue and the readback:

  hub SOCKET ACTION [JSON]       one debug.device_hub call on a tagged DEBUG cmux NEXT Mac (its debug socket)
  wait-ready SOCKET SECONDS      waits until the Mac's hub client is signed in and connected; prints its device id
  approve SOCKET STOP LOG        answers every pending viewer request always_full until the file STOP exists
  readback --target T --events FILE --out JSON
                                 fails (exit 1) unless the host received the click, double-click, right-click,
                                 drag and the typed "hello" the test sends; writes the verdict as JSON

Targets (the host the phone controls) are a table, TARGETS: each names how its event log is parsed into
the common event list below. `mac` reads InputProbe's JSONL (cmux-next-ios/verify/screen-sharing/InputProbe.swift).
`linux` (cmux-rd linux-host on Xvfb, XTest injection) reads `xinput test-xi2 --root` on that display; its
parser is here so the checks are shared, and the shell leg that starts that host is the next step.

Common events: {"kind": "left-down"|"left-up"|"left-drag"|"right-down"|"key", "clicks": N, "drags": N, "chars": C}.
Nothing here reads or prints a credential.
"""
from __future__ import annotations

import argparse
import json
import re
import socket
import sys
import time
from pathlib import Path


# --- the Mac's debug socket ----------------------------------------------------------------------------------

def rpc(sock_path: str, params: dict, timeout: float = 30.0) -> dict:
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(timeout)
    try:
        s.connect(sock_path)
        s.sendall((json.dumps({"id": 1, "method": "debug.device_hub", "params": params}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
    finally:
        s.close()
    reply = json.loads(buf or b"{}")
    if "error" in reply and "result" not in reply:
        raise RuntimeError(f"debug.device_hub {params.get('action')}: {reply['error']}")
    return reply.get("result") or {}


def this_device(state: dict) -> dict | None:
    return next((d for d in state.get("devices") or [] if d.get("this")), None)


def cmd_hub(a) -> int:
    params = json.loads(a.json) if a.json else {}
    params["action"] = a.action
    print(json.dumps(rpc(a.socket, params))[:4000])
    return 0


def cmd_wait_ready(a) -> int:
    deadline = time.monotonic() + a.seconds
    last = ""
    while time.monotonic() < deadline:
        try:
            state = rpc(a.socket, {"action": "state"}, timeout=10)
            me = this_device(state)
            summary = {k: v for k, v in state.items() if k not in ("devices", "permissions", "pending_requests")}
            last = json.dumps(summary)[:600]
            if me and me.get("id"):
                print(me["id"])
                print(f"wait-ready: {last}", file=sys.stderr)
                return 0
        except (OSError, ValueError, RuntimeError) as error:
            last = f"{type(error).__name__}: {error}"
        time.sleep(2)
    print(f"wait-ready: the Mac's hub client never listed this device in {a.seconds} s (last: {last})", file=sys.stderr)
    return 1


def cmd_approve(a) -> int:
    stop = Path(a.stop)
    log = open(a.log, "a", buffering=1)
    deadline = time.monotonic() + a.max_seconds
    decided: set[str] = set()
    while not stop.exists() and time.monotonic() < deadline:
        try:
            state = rpc(a.socket, {"action": "state"}, timeout=10)
            for request in state.get("pending_requests") or []:
                sid = request.get("id") or request.get("session")
                if not sid or sid in decided:
                    continue
                result = rpc(a.socket, {"action": "decide", "session": sid, "choice": "always_full"})
                decided.add(sid)
                log.write(json.dumps({"t": time.time(), "decided": sid, "result": result})[:2000] + "\n")
        except (OSError, ValueError, RuntimeError) as error:
            log.write(json.dumps({"t": time.time(), "error": f"{type(error).__name__}: {error}"[:500]}) + "\n")
        time.sleep(1)
    log.write(json.dumps({"t": time.time(), "stopped": True, "decided": sorted(decided)}) + "\n")
    return 0


# --- the Mac's session ---------------------------------------------------------------------------------------

# The Mac app's token file (CmuxAuthRuntime FileStackTokenStore, the store an ad-hoc Debug build falls back to)
# lives in Library/Application Support/cmux-next/<bundle>/<namespace>/credentials.json, the namespace being
# the hex of the backend's API origin and "-0" for a fresh tag (cmux-cloud-environment `auth_namespace`,
# cmux-cloud-config `credentials_subpath`). A tagged Debug build runs development or staging: both share the
# development Stack project and the development device hub, so the session goes under both.
MAC_API_ORIGINS = ("https://cmux-api-development.debussy.workers.dev", "https://cloud-api-staging.cmux.dev")


def cmd_seed_mac_session(a) -> int:
    signin = json.loads(Path(a.signin).read_text())
    token = str(signin.get("refresh_token") or "")
    if signin.get("profile") != "agent" or not token:
        print("seed-mac-session: the sign-in file holds no agent session", file=sys.stderr)
        return 1
    import os
    for origin in MAC_API_ORIGINS:
        namespace = origin.encode().hex() + "-0"
        folder = Path(a.home, "Library", "Application Support", "cmux-next", a.bundle, namespace)
        folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        path = folder / "credentials.json"
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump({"accessToken": None, "refreshToken": token}, f)
    print(f"seed-mac-session: {len(MAC_API_ORIGINS)} token files for {a.bundle}", file=sys.stderr)
    return 0


# --- targets: each host's event log as common events ---------------------------------------------------------

def parse_mac(text: str) -> list[dict]:
    """InputProbe's JSONL: one object per event, kinds as the common ones."""
    events = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except ValueError:
            continue
        events.append({"kind": e.get("kind", ""), "clicks": int(e.get("clicks") or 0),
                       "drags": int(e.get("drags") or 0), "chars": str(e.get("chars") or ""),
                       "mods": str(e.get("mods") or "")})
    return events


# xinput test-xi2 --root prints blocks:  "EVENT type 4 (ButtonPress)" then indented "detail: 1" ... lines.
_XI_EVENT = re.compile(r"^EVENT type \d+ \((\w+)\)")
_XI_FIELD = re.compile(r"^\s+(\w+): (.*)$")


def parse_linux(text: str, keymap: dict[int, str] | None = None) -> list[dict]:
    """`xinput test-xi2 --root` on the host's display. Buttons 1 and 3 are left and right; a second press
    of button 1 within 400 ms (and few pixels) counts as clicks=2, as X has no click count; a Motion while
    button 1 is down is a drag; a KeyPress's keycode becomes chars through `keymap` (xmodmap -pke: keycode
    to its first keysym), which the shell leg reads from the same display."""
    blocks: list[tuple[str, dict]] = []
    for line in text.splitlines():
        m = _XI_EVENT.match(line)
        if m:
            blocks.append((m.group(1), {}))
            continue
        f = _XI_FIELD.match(line)
        if f and blocks:
            blocks[-1][1][f.group(1)] = f.group(2).strip()
    events: list[dict] = []
    down = False
    drags = 0
    last_press: tuple[float, float, float] | None = None
    for kind, fields in blocks:
        detail = fields.get("detail", "")
        t = float(fields.get("time", "0") or 0) / 1000.0
        root = fields.get("root", "0/0").split("/")
        x, y = (float(root[0]), float(root[1])) if len(root) == 2 else (0.0, 0.0)
        if kind == "ButtonPress" and detail == "1":
            clicks = 1
            if last_press and t - last_press[0] < 0.4 and abs(x - last_press[1]) < 8 and abs(y - last_press[2]) < 8:
                clicks = 2
            last_press = (t, x, y)
            down, drags = True, 0
            events.append({"kind": "left-down", "clicks": clicks, "drags": 0, "chars": "", "mods": ""})
        elif kind == "ButtonRelease" and detail == "1":
            down = False
            events.append({"kind": "left-up", "clicks": 0, "drags": drags, "chars": "", "mods": ""})
        elif kind == "ButtonPress" and detail == "3":
            events.append({"kind": "right-down", "clicks": 1, "drags": 0, "chars": "", "mods": ""})
        elif kind == "Motion" and down:
            drags += 1
            if drags % 10 == 1:
                events.append({"kind": "left-drag", "clicks": 0, "drags": drags, "chars": "", "mods": ""})
        elif kind == "KeyPress":
            code = int(detail) if detail.isdigit() else -1
            events.append({"kind": "key", "clicks": 0, "drags": 0, "chars": (keymap or {}).get(code, ""), "mods": ""})
    return events


def read_xmodmap(path: str | None) -> dict[int, str]:
    out: dict[int, str] = {}
    if not path:
        return out
    for line in Path(path).read_text().splitlines():
        m = re.match(r"^keycode\s+(\d+)\s*=\s*(\S+)", line)
        if m:
            out[int(m.group(1))] = m.group(2) if len(m.group(2)) == 1 else ""
    return out


TARGETS = {"mac": "InputProbe JSONL", "linux": "xinput test-xi2 --root"}


# --- the checks, the same for every target -------------------------------------------------------------------

def check(events: list[dict], typed: str = "hello") -> dict:
    lefts = [e for e in events if e["kind"] == "left-down"]
    keys = "".join(e["chars"] for e in events if e["kind"] == "key")
    checks = {
        "click": any(e["clicks"] == 1 for e in lefts),
        "double_click": any(e["clicks"] >= 2 for e in lefts),
        "right_click": any(e["kind"] == "right-down" for e in events),
        "drag": any(e["kind"] == "left-drag" for e in events)
                and any(e["kind"] == "left-up" and e["drags"] > 0 for e in events),
        "typed_" + typed: typed in keys,
    }
    return {"checks": checks, "pass": all(checks.values()), "keys_received": keys[:200],
            "counts": {k: sum(1 for e in events if e["kind"] == k)
                       for k in ("left-down", "left-up", "left-drag", "right-down", "key")}}


def cmd_readback(a) -> int:
    path = Path(a.events)
    text = path.read_text(errors="replace") if path.is_file() else ""
    if a.target == "mac":
        events = parse_mac(text)
    else:
        events = parse_linux(text, read_xmodmap(a.keymap))
    verdict = {"target": a.target, "source": TARGETS[a.target], "events_file": path.name, "events": len(events),
               **check(events)}
    if not text:
        verdict["error"] = f"no events file at {path} (or it is empty)"
        verdict["pass"] = False
    Path(a.out).write_text(json.dumps(verdict, indent=2) + "\n")
    print(json.dumps(verdict))
    return 0 if verdict["pass"] else 1


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    h = sub.add_parser("hub")
    h.add_argument("socket"); h.add_argument("action"); h.add_argument("json", nargs="?")
    w = sub.add_parser("wait-ready")
    w.add_argument("socket"); w.add_argument("seconds", type=int)
    ap = sub.add_parser("approve")
    ap.add_argument("socket"); ap.add_argument("stop"); ap.add_argument("log")
    ap.add_argument("--max-seconds", type=int, default=3600)
    sm = sub.add_parser("seed-mac-session")
    sm.add_argument("--signin", required=True); sm.add_argument("--home", required=True)
    sm.add_argument("--bundle", required=True)
    r = sub.add_parser("readback")
    r.add_argument("--target", choices=sorted(TARGETS), required=True)
    r.add_argument("--events", required=True)
    r.add_argument("--keymap", help="linux: xmodmap -pke of the host's display")
    r.add_argument("--out", required=True)
    a = p.parse_args(argv)
    return {"hub": cmd_hub, "wait-ready": cmd_wait_ready, "approve": cmd_approve, "readback": cmd_readback,
            "seed-mac-session": cmd_seed_mac_session}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
