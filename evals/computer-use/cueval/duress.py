# SPDX-License-Identifier: MIT
"""The Computer Use behaviour suite under duress, live (a real screen).

Leo, 2026-11-22: "WHAT THE FUCK IS OUR SUITE TO CHECK THE FUCKING CORRECTNESS
AND BEHAVIOUR OF THIS. WHERE IS THE FUCKING CURSOR. WHAT FUCKING VERSION OF
OUR COMPUTER USE DID YOU GUYS EVEN FUCKING USE!?" and "you keep interrupting
my inputs as you use shit. and you're foregrounding shit."

The harness drives cmux Computer Use's MCP server (`cmux computer-use mcp`,
or CUEVAL_CMUX_CU_COMMAND) against the scratch form fixture while:
  - every core is busy (CPU load processes this suite starts and stops), and
  - the person fixture, focused and frontmost, types its own text in-process
    (no synthetic events: nothing is ever typed into an app this suite did
    not start).

Five checks, each PASS, FAIL or KNOWN-RED (a failure we expect today, with
its reason; it still fails the run's verdict line, it is never skipped):
  1 frontmost   the frontmost app (sampled every 100 ms) stays the person's
  2 no-leak     the person app got no key event, never lost focus, its text
                is exactly its own, and the pointer did not move
  3 cursor      status names a cursor overlay that is not `none`, and a new
                on-screen window owned by neither fixture nor the system
                appears while the agent acts (macOS: CGWindowList)
  4 driver      every tool result carries driver {name, version, build},
                build not `unstamped`
  5 classic     classic cmux (com.cmuxterm.app) is never started nor
                frontmost, and a launch_app of it is refused

Output: duress.json (every sample and verdict) and DURESS lines on stdout.
Exit 0 only when every check passes.
"""

from __future__ import annotations

import ctypes
import json
import os
import re
import subprocess
import sys
import threading
import time

from . import arms as armsmod
from . import platform_env as penv
from .mcp import McpClient, ToolResult
from .tasks import TaskEnv

CLASSIC = "com.cmuxterm.app"

TASK = {
    "id": "duress",
    "split": "tool",
    "platforms": ["linux", "macos", "windows"],
    "instruction": "",
    "setup": [
        {"fixture": "form", "name": "form", "title": "CU Eval Form", "geometry": "420x520+40+40"},
        {"fixture": "person", "name": "person", "geometry": "420x260+520+40"},
    ],
    "checks": [],
    "person_present": True,
}

# Failures expected today, with the reason. A known red still fails; this only
# names why, so a fix shows up as an unexpected pass.
KNOWN_RED = {
    "cursor": {
        "macos": "the macOS Computer Use worker (Screen Sharing helper, cmux-rd-host "
                 "__computer-use-worker) draws no agent cursor: platform::cursor_overlay() is "
                 "NoCursor there (cmux-rd-host/src/computer_use_worker.rs)",
    },
}


# ---------------------------------------------------------------- macOS reads

def _cf():
    cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    vp = ctypes.c_void_p
    cg.CGWindowListCopyWindowInfo.restype = vp
    cg.CGWindowListCopyWindowInfo.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    cf.CFArrayGetCount.restype = ctypes.c_long
    cf.CFArrayGetCount.argtypes = [vp]
    cf.CFArrayGetValueAtIndex.restype = vp
    cf.CFArrayGetValueAtIndex.argtypes = [vp, ctypes.c_long]
    cf.CFDictionaryGetValue.restype = vp
    cf.CFDictionaryGetValue.argtypes = [vp, vp]
    cf.CFStringCreateWithCString.restype = vp
    cf.CFStringCreateWithCString.argtypes = [vp, ctypes.c_char_p, ctypes.c_uint32]
    cf.CFStringGetCString.restype = ctypes.c_bool
    cf.CFStringGetCString.argtypes = [vp, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
    cf.CFNumberGetValue.restype = ctypes.c_bool
    cf.CFNumberGetValue.argtypes = [vp, ctypes.c_int, vp]
    cf.CFRelease.argtypes = [vp]
    return cf, cg


_CF = None


def mac_windows() -> list[dict]:
    """On-screen windows: id, owner pid, owner name, layer (no Screen Recording needed)."""
    global _CF
    if sys.platform != "darwin":
        return []
    try:
        if _CF is None:
            _CF = _cf()
        cf, cg = _CF
        key = lambda s: cf.CFStringCreateWithCString(None, s.encode(), 0x08000100)
        keys = {k: key(k) for k in ("kCGWindowNumber", "kCGWindowOwnerPID", "kCGWindowOwnerName", "kCGWindowLayer")}
        arr = cg.CGWindowListCopyWindowInfo(1 | 16, 0)  # on screen only, excluding desktop elements
        if not arr:  # no window server session: say so, never dereference NULL
            for v in keys.values():
                cf.CFRelease(v)
            return [{"error": "CGWindowListCopyWindowInfo returned NULL (no window server session)"}]
        out = []
        for i in range(cf.CFArrayGetCount(arr)):
            d = cf.CFArrayGetValueAtIndex(arr, i)

            def num(k):
                v = ctypes.c_int64()
                ref = cf.CFDictionaryGetValue(d, keys[k])
                return v.value if ref and cf.CFNumberGetValue(ref, 4, ctypes.byref(v)) else None

            name = ""
            ref = cf.CFDictionaryGetValue(d, keys["kCGWindowOwnerName"])
            if ref:
                buf = ctypes.create_string_buffer(512)
                if cf.CFStringGetCString(ref, buf, 512, 0x08000100):
                    name = buf.value.decode(errors="replace")
            out.append({"id": num("kCGWindowNumber"), "pid": num("kCGWindowOwnerPID"),
                        "owner": name, "layer": num("kCGWindowLayer")})
        cf.CFRelease(arr)
        for v in keys.values():
            cf.CFRelease(v)
        return out
    except Exception as e:  # an unreadable window list is reported, not hidden
        return [{"error": f"{type(e).__name__}: {e}"}]


def front_app() -> dict | None:
    """The frontmost app: pid and bundle id (macOS), pid (X11 with xdotool)."""
    try:
        if sys.platform == "darwin":
            asn = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True, timeout=5).stdout.strip()
            info = subprocess.run(["lsappinfo", "info", "-only", "pid", "-only", "bundleid", asn],
                                  capture_output=True, text=True, timeout=5).stdout
            pid = re.search(r'"pid"\s*=\s*(\d+)', info)
            bid = re.search(r'"CFBundleIdentifier"\s*=\s*"([^"]*)"', info)
            return {"pid": int(pid.group(1)) if pid else None, "bundle": bid.group(1) if bid else None}
        if sys.platform.startswith("linux"):
            r = subprocess.run(["xdotool", "getactivewindow", "getwindowpid"], capture_output=True, text=True, timeout=5)
            return {"pid": int(r.stdout.strip())} if r.returncode == 0 and r.stdout.strip().isdigit() else None
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return None
    return None


def classic_running() -> list[int]:
    """Pids of running classic cmux (bundle id exactly com.cmuxterm.app)."""
    if sys.platform != "darwin":
        return []
    try:
        out = subprocess.run(["lsappinfo", "list"], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    pids = []
    for block in re.split(r"\n(?=\s*\d+\) )", out):
        if re.search(r'bundleID="' + re.escape(CLASSIC) + r'"', block):
            m = re.search(r"pid\s*=\s*(\d+)", block)
            if m:
                pids.append(int(m.group(1)))
    return pids


# ---------------------------------------------------------------- duress

class Sampler(threading.Thread):
    def __init__(self, interval: float = 0.1):
        super().__init__(daemon=True)
        self.interval = interval
        self.fronts: list[dict | None] = []
        self.classic: list[list[int]] = []
        self.windows: list[list[dict]] = []
        self.acting = threading.Event()
        self._halt = threading.Event()

    def run(self):
        n = 0
        while not self._halt.is_set():
            self.fronts.append(front_app())
            if self.acting.is_set():
                self.windows.append(mac_windows())
            if n % 10 == 0:
                self.classic.append(classic_running())
            n += 1
            self._halt.wait(self.interval)

    def stop(self):
        self._halt.set()
        self.join(timeout=10)


def start_cpu_load(n: int | None = None) -> list[subprocess.Popen]:
    n = n or os.cpu_count() or 2
    return [subprocess.Popen([sys.executable, "-I", "-c", "while True: pass"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) for _ in range(n)]


def stop_cpu_load(procs: list[subprocess.Popen]) -> None:
    for p in procs:  # only the processes this suite started
        p.terminate()
    for p in procs:
        try:
            p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            p.kill()


def _windows(r: ToolResult) -> list[dict]:
    d = r.data if isinstance(r.data, dict) else {}
    return d.get("windows") or []


def run(out_dir: str, rounds: int = 5) -> int:
    os.makedirs(out_dir, exist_ok=True)
    plat = penv.platform_name()
    arm = armsmod.load_arm("cmux-cu")
    command = armsmod.server_command(arm)
    report: dict = {"command": command, "platform": plat, "checks": {}, "calls": []}
    env = TaskEnv(TASK, os.path.join(out_dir, "work"), trial=0, seed=0)
    classic_before = classic_running()
    baseline_windows = mac_windows()
    env.reset(start_processes=True)
    fixture_pids = {env.read_state(n).get("pid") for n in ("form", "person")}
    person_pid = env.read_state("person").get("pid")
    time.sleep(0.5)
    front_before = front_app()
    report["front_before"] = front_before
    load = start_cpu_load()
    sampler = Sampler()
    sampler.start()
    client = McpClient(command, stderr_path=os.path.join(out_dir, "server.stderr"))
    results: list[tuple[str, ToolResult | None, str]] = []

    def call(name: str, args: dict) -> ToolResult | None:
        try:
            r = client.call(name, args, timeout=60)
            results.append((name, r, ""))
            report["calls"].append({"name": name, "args": args, "is_error": r.is_error,
                                    "data": r.data if isinstance(r.data, dict) else r.text()[:400]})
            return r
        except Exception as e:
            results.append((name, None, f"{type(e).__name__}: {e}"))
            report["calls"].append({"name": name, "args": args, "exception": f"{type(e).__name__}: {e}"})
            return None

    status = None
    try:
        try:
            client.initialize()
            client.list_tools()
            report["server"] = client.server_info
        except Exception as e:
            report["server_error"] = f"{type(e).__name__}: {e}"
        status = call("status", {})
        lw = call("list_windows", {})
        form = next((w for w in _windows(lw) if "CU Eval Form" in json.dumps(w)), None) if lw else None
        report["form_window"] = form
        wid = str(form.get("window_id") or form.get("id")) if form else None
        if wid:
            call("screenshot", {"window_id": wid})
            st = env.read_state("form")["widgets"]
            mid = lambda k: (st[k]["x"] + st[k]["w"] // 2, st[k]["y"] + st[k]["h"] // 2)
            sampler.acting.set()
            for i in range(rounds):
                call("click", {"window_id": wid, "x": mid("name")[0], "y": mid("name")[1]})
                call("type_text", {"window_id": wid, "text": f"agent {i} "})
                call("press_key", {"window_id": wid, "keys": "Return"})
                call("scroll", {"window_id": wid, "x": mid("list")[0], "y": mid("list")[1], "dy": 3})
                call("click", {"window_id": wid, "x": mid("increment")[0], "y": mid("increment")[1]})
            sampler.acting.clear()
        call("launch_app", {"app_id": CLASSIC})
        time.sleep(1.0)
    finally:
        client.close()
        sampler.stop()
        stop_cpu_load(load)
        pointer = env.sampler.stop() if env.sampler else {}
        person = env.read_state("person")
        form_state = env.read_state("form")
        env.teardown()

    checks = report["checks"]

    # 1 frontmost
    fronts = [f for f in sampler.fronts if f]
    changed = [f for f in fronts if f.get("pid") != person_pid]
    checks["frontmost"] = {
        "ok": bool(fronts) and not changed,
        "detail": f"{len(fronts)} samples, front was the person's app (pid {person_pid}) in "
                  f"{len(fronts) - len(changed)}; others: {changed[:5]}" if fronts else "front app unreadable",
    }

    # 2 no-leak
    script = "the quick brown fox jumps over the lazy dog. "
    typed = person.get("typed", "")
    own = (script * (len(typed) // len(script) + 1))[:len(typed)]
    drift = pointer.get("max_drift")
    checks["no-leak"] = {
        "ok": not person.get("keys_received") and person.get("focus_lost", 0) == (env.person_baseline or 0)
              and typed == own and person.get("has_focus", True) and drift in (None, 0),
        "detail": f"keys_received={person.get('keys_received')[:20]} focus_lost={person.get('focus_lost')} "
                  f"has_focus={person.get('has_focus')} typed_is_own={typed == own} ({len(typed)} chars) "
                  f"pointer={pointer}",
    }

    # 3 cursor
    overlay = (status.data or {}).get("cursor_overlay") if status and isinstance(status.data, dict) else None
    base_ids = {w.get("id") for w in baseline_windows}
    system = {"Window Server", "Dock", "SystemUIServer", "Control Center", "Spotlight", "Notification Center"}
    new = {}
    for snap in sampler.windows:
        for w in snap:
            if w.get("id") not in base_ids and w.get("pid") not in fixture_pids and w.get("owner") not in system \
                    and "error" not in w:
                new[w["id"]] = w
    checks["cursor"] = {
        "ok": overlay not in (None, "none") and (bool(new) or plat != "macos"),
        "detail": f"status cursor_overlay={overlay!r}; new non-fixture windows while acting: "
                  f"{list(new.values())[:5]}; {len(sampler.windows)} window-list samples",
    }

    # 4 driver
    missing = []
    stamps = set()
    for name, r, err in results:
        d = r.data if r and isinstance(r.data, dict) else {}
        drv = d.get("driver") or {}
        if not (drv.get("name") and drv.get("version") and drv.get("build")) or drv.get("build") == "unstamped":
            missing.append(f"{name}: {err or drv or 'no driver field'}")
        else:
            stamps.add(f"{drv['name']} {drv['version']} {drv['build']}")
    checks["driver"] = {
        "ok": bool(results) and not missing,
        "detail": f"stamps={sorted(stamps)}; {len(missing)}/{len(results)} without: {missing[:6]}",
    }

    # 5 classic
    started = sorted({p for snap in sampler.classic for p in snap} - set(classic_before))
    classic_front = [f for f in fronts if f.get("bundle") == CLASSIC]
    launch = next(((r, e) for n, r, e in results if n == "launch_app"), (None, "not called"))
    refused = bool(launch[0] and launch[0].is_error)
    checks["classic"] = {
        "ok": not started and not classic_front and refused,
        "detail": f"running before={classic_before} started during run={started} frontmost samples={len(classic_front)} "
                  f"launch_app refused={refused} ({(launch[0].text()[:160] if launch[0] else launch[1])})",
    }

    report["form_state"] = {k: form_state.get(k) for k in ("name", "counter", "saved", "first_visible")}
    report["person"] = {k: person.get(k) for k in ("keys_received", "focus_lost", "has_focus")}
    verdict = 0
    for name, c in checks.items():
        known = KNOWN_RED.get(name, {}).get(plat)
        c["known_red"] = known if (known and not c["ok"]) else None
        label = "PASS" if c["ok"] else ("KNOWN-RED" if known else "FAIL")
        if not c["ok"]:
            verdict = 1
        print(f"DURESS {label:9} {name:10} {c['detail'][:600]}")
        if c["known_red"]:
            print(f"DURESS           reason: {known}")
    with open(os.path.join(out_dir, "duress.json"), "w") as f:
        json.dump(report, f, indent=1, default=str)
    print(f"DURESS verdict {'PASS' if verdict == 0 else 'FAIL'}; report {os.path.join(out_dir, 'duress.json')}")
    return verdict
