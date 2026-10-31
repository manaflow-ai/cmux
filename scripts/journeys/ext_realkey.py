"""Real key events through CuaDriver, and the Ctrl-` read-out (Lawrence's v2.2.10 "Ctrl-` does not work").

driver.py loads this file (load_extensions) on the mini under the stock /usr/bin/python3 (3.9, standard library
only). It must not import driver.py: install() gets the driver module instead.

`debug.key` enters the app's key router directly. A person's key comes from the window server: macOS, the
responder chain and the menu's key equivalents see it first. This group sends that real event.

Steps (`do`):
  real_key    {key, modifiers?, mark?, delivery?: foreground|background}
              CuaDriver `hotkey` (a modifier and a key) or `press_key` (no modifier) to the app's process, aimed at
              its frontmost window; `foreground` (default) is a real HID key event. It needs CuaDriver's
              Accessibility grant on the mini and a whole-host lease (run.py --whole-host). The result keeps
              CuaDriver's answer, the window it aimed at and the app's action samples since the step began.
  key_outcome {action, entrypoint?, timeout?, as?}
              after a real_key: waits until the app's action log (`debug.action_budget` recent) has `action` with
              a sequence above the one before the key, from `entrypoint` (default key, the app's name for the keyboard). Records the outcome;
              fails when the action never ran. `as` keeps the sample under that name.

  daemon_pause {seconds, background?: false}
              SIGSTOP the app's daemon (`debug.daemon` pid), then SIGCONT after `seconds`; with `background` the
              step returns at once and the daemon resumes on its own (a key can then be sent while it is
              stopped). The person's case: a Mac in heavy swap, where the daemon does not answer for seconds
              (Lawrence's v2.2.10 capture: new-tab "no reply within 5.0 seconds", then "closed by client").

Conditions: none (the journeys read the terminal with the driver's own steps and conditions).
"""
import json
import os
import subprocess
import time

D = None

CUA = "/Applications/CuaDriver.app/Contents/MacOS/cua-driver"
MODIFIERS = {"control": "ctrl", "ctrl": "ctrl", "cmd": "cmd", "command": "cmd", "shift": "shift",
             "option": "option", "alt": "option", "fn": "fn"}


def install(driver):
    global D
    D = driver


def _cua(tool, args, timeout=30):
    if not os.path.exists(CUA):
        raise D.StepError(f"real_key: no CuaDriver at {CUA} on this mini")
    done = subprocess.run([CUA, "call", tool, json.dumps(args)], capture_output=True, text=True, timeout=timeout)
    text = (done.stdout or "") + (done.stderr or "")
    try:
        start = text.index("{")
        answer = json.loads(text[start:text.rindex("}") + 1])
    except ValueError:
        answer = {"raw": text.strip()[-600:]}
    return done.returncode, answer


def _app_windows(j):
    """The app's on-screen layer-0 windows (CuaDriver list_windows), frontmost first."""
    code, answer = _cua("list_windows", {})
    rows = answer.get("windows") or answer.get("structuredContent", {}).get("windows") or []
    if not rows and isinstance(answer.get("content"), list):
        for part in answer["content"]:
            try:
                rows = json.loads(part.get("text", "")).get("windows", [])
            except (ValueError, AttributeError):
                continue
    mine = [w for w in rows if int(w.get("pid") or w.get("owner_pid") or -1) == j.app.pid]
    mine = [w for w in mine if w.get("layer", 0) == 0 and w.get("is_on_screen", w.get("on_screen", True))]
    return mine, answer


def _recent_actions(j):
    try:
        reply = j.app.rpc("debug.action_budget", {"limit": 64}) or {}
    except D.StepError:
        return []
    return [r for r in reply.get("recent") or [] if isinstance(r, dict)]


def _last_sequence(j):
    rows = _recent_actions(j)
    return max([int(r.get("sequence") or 0) for r in rows] or [0])


def step_real_key(j, step):
    key = step["key"]
    mods = [MODIFIERS.get(m, m) for m in step.get("modifiers", [])]
    j.realkey_before = _last_sequence(j)
    windows, listing = _app_windows(j)
    if not windows:
        raise D.StepError(f"real_key: CuaDriver lists no on-screen window of the app (pid {j.app.pid}): {json.dumps(listing)[:400]}")
    window = windows[0]
    wid = int(window.get("window_id") or window.get("id") or window.get("windowNumber"))
    delivery = step.get("delivery", "foreground")
    if step.get("mark"):
        j.marks[step["mark"]] = D.now()
    j.last_key_at = D.now()
    if mods:
        code, answer = _cua("hotkey", {"pid": j.app.pid, "window_id": wid, "keys": mods + [key], "delivery_mode": delivery})
    else:
        code, answer = _cua("press_key", {"pid": j.app.pid, "window_id": wid, "key": key, "delivery_mode": delivery})
    effect = answer.get("effect") or answer.get("structuredContent", {}).get("effect")
    if code != 0 or effect in ("refused", "failed", "error"):
        raise D.StepError(f"real_key {mods + [key]}: CuaDriver did not send it (exit {code}): {json.dumps(answer)[:500]}")
    return {"keys": mods + [key], "window_id": wid, "window_title": window.get("title") or window.get("name"),
            "delivery": delivery, "cua": {k: answer.get(k) for k in ("effect", "code", "message") if k in answer},
            "action_sequence_before": j.realkey_before}


def step_key_outcome(j, step):
    action, entry = step["action"], step.get("entrypoint", "key")
    before = int(getattr(j, "realkey_before", 0))
    end = D.now() + float(step.get("timeout", 5))
    seen = []
    while D.now() < end:
        seen = [r for r in _recent_actions(j) if int(r.get("sequence") or 0) > before]
        hit = next((r for r in seen if r.get("id") == action and (not entry or r.get("entrypoint") == entry)), None)
        if hit:
            if step.get("as"):
                j.vars[step["as"] + "_outcome"] = hit.get("outcome")
            return {"ran": hit, "actions_since_key": [(r.get("id"), r.get("entrypoint"), r.get("outcome")) for r in seen][:12]}
        time.sleep(0.1)
    raise D.StepError(f"key_outcome: action {action} ({entry}) never ran after the key; actions since: "
                      + json.dumps([(r.get("id"), r.get("entrypoint"), r.get("outcome")) for r in seen][:12]))


def _daemon_pid(j):
    state = j.app.rpc("debug.daemon", timeout=5) or {}
    pid = state.get("pid") or (state.get("daemon") or {}).get("pid")
    if not pid:
        raise D.StepError(f"daemon_pause: debug.daemon names no pid: {json.dumps(state)[:300]}")
    return int(pid)


def step_daemon_pause(j, step):
    import threading
    pid, seconds = _daemon_pid(j), float(step["seconds"])
    os.kill(pid, 19)  # SIGSTOP (macOS)

    def resume():
        time.sleep(seconds)
        try:
            os.kill(pid, 18)  # SIGCONT
        except OSError:
            pass
    if step.get("background"):
        threading.Thread(target=resume, daemon=True).start()
    else:
        resume()
    return {"daemon_pid": pid, "stopped_s": seconds, "background": bool(step.get("background"))}


def step_app_log(j, step):
    """The app process's unified log of the last `seconds` (default 15), lines that match `grep` (a regex) if
    given; kept in the result (at most 120 lines). Diagnostic only."""
    import re
    secs = int(step.get("seconds", 15))
    done = subprocess.run(["/usr/bin/log", "show", "--style", "compact", "--last", f"{secs}s", "--info", "--debug",
                           "--predicate", f"processID == {j.app.pid}"], capture_output=True, text=True, timeout=120)
    lines = done.stdout.splitlines()
    if step.get("grep"):
        rx = re.compile(step["grep"], re.I)
        lines = [l for l in lines if rx.search(l)]
    return {"lines": [l[:300] for l in lines[-120:]], "count": len(lines)}


STEPS = {"app_log": step_app_log, "real_key": step_real_key, "key_outcome": step_key_outcome, "daemon_pause": step_daemon_pause}
CONDITIONS = {}
