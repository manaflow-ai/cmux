"""A fixed synthetic load on the capture mini, and the time from an action to its new terminal's first prompt.

driver.py loads this file (load_extensions) on the mini, under the stock /usr/bin/python3 (standard library only).
It must not import driver.py (that runs as __main__ there): install() gets the driver module.

Why (cmux-ad, 2026-10-29): Lawrence's Mac is always loaded. A new terminal that shows no prompt, or takes over 6 s,
under load is a felt bug even when it passes on an idle host. The v2.2.7-opt P0 set had three new-terminal failures,
all on loaded hosts; on an idle host they did not come back. This makes the load fixed and the same for each build.

Steps (`do`):
  start_load {cpus: 8, io: true}   starts `cpus` busy loops (/usr/bin/yes > /dev/null) and, with io, one disk loop
                                   (dd 256 MiB write then read, again and again) in a scratch folder under the slot's
                                   HOME. Every pid is recorded (journey.load_pids) and returned. A second start_load
                                   stops the first load before it starts.
  stop_load {}                     stops every recorded load pid (TERM, then KILL after 2 s) and removes the scratch
                                   folder; for the journey's `finally` list, so the load ends whatever happened.
  first_prompts {action, count, timeout_s: 20, as}
                                   `count` times: does `action`, then times from the action to the first text on the
                                   new terminal's daemon screen (polled every 50 ms: each time is up to 50 ms late).
                                   action: `key_new_terminal` (Ctrl-`, the person's New Terminal Tab key),
                                   `script_new_tab` (action.run newTab with focus, the type journey's path),
                                   `new_window` (Cmd-Shift-N, then Ctrl-` in the new window, timed from the Cmd-Shift-N).
                                   A try with no prompt within timeout_s is a timeout. The result has every time, p50,
                                   p95, max (ms) and the timeouts; `as` keeps it for `load_report`.
  load_report {}                   writes every kept first_prompts result to <journey>/diag-load.json (run.py fetches diag-*.json).

Condition:
  first_prompt_p95 {action, max_ms}   holds when the kept result of `action` has p95 <= max_ms and no timeout.
"""
import json
import math
import os
import shutil
import signal
import subprocess
import time

D = None
KEY_NEW_TERMINAL = {"key": "`", "modifiers": ["control"]}
KEY_NEW_WINDOW = {"key": "n", "modifiers": ["cmd", "shift"]}
POLL_S = 0.05


def install(driver):
    global D
    D = driver


# ---- load ---------------------------------------------------------------------------------------

def _scratch(j):
    return os.path.join(j.app.home, "jr-load-scratch")


def step_start_load(j, step):
    if getattr(j, "load_pids", None):
        step_stop_load(j, {})
    cpus = int(step.get("cpus", 8))
    pids = []
    devnull = open(os.devnull, "wb")
    for _ in range(cpus):
        pids.append(subprocess.Popen(["/usr/bin/yes"], stdout=devnull, stderr=devnull, start_new_session=True).pid)
    if step.get("io", True):
        folder = _scratch(j)
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, "io.bin")
        loop = (f"while :; do /bin/dd if=/dev/zero of={path} bs=1m count=256 2>/dev/null; "
                f"/bin/dd if={path} of=/dev/null bs=1m 2>/dev/null; done")
        pids.append(subprocess.Popen(["/bin/sh", "-c", loop], stdout=devnull, stderr=devnull, start_new_session=True).pid)
    j.load_pids = pids
    time.sleep(float(step.get("settle_s", 3)))
    load = subprocess.run(["/usr/sbin/sysctl", "-n", "vm.loadavg"], capture_output=True, text=True).stdout.strip()
    return {"pids": pids, "cpus": cpus, "io": bool(step.get("io", True)), "loadavg_after_settle": load}


def step_stop_load(j, step):
    pids = list(getattr(j, "load_pids", None) or [])
    stopped = []
    for pid in pids:
        try:
            os.killpg(pid, signal.SIGTERM)  # its own session: the dd loop's children go too
            stopped.append(pid)
        except OSError:
            try:
                os.kill(pid, signal.SIGTERM)
                stopped.append(pid)
            except OSError:
                pass
    end = time.time() + 2
    alive = pids
    while alive and time.time() < end:
        alive = [p for p in alive if _alive(p)]
        time.sleep(0.1)
    for pid in alive:
        try:
            os.killpg(pid, signal.SIGKILL)
        except OSError:
            pass
    j.load_pids = []
    shutil.rmtree(_scratch(j), ignore_errors=True)
    return {"stopped": stopped, "killed": alive}


def _alive(pid):
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


# ---- first prompts ------------------------------------------------------------------------------

def _known_terminals(j):
    return {p.get("terminal_id") for p in j.app.panes() if p.get("terminal_id")}


def _wait_prompt(j, before, started, timeout_s, workspace=None):
    """Seconds from `started` to the first text on the daemon screen of a focused terminal not in `before`,
    or None at the timeout. The daemon id comes from the topology (debug.surfaces' terminal_id is the app's id)."""
    end = started + timeout_s
    term = pane = None
    while D.now() < end:
        if pane is None:
            for view in j.app.panes():
                if view.get("focused") and view.get("terminal_id") and view["terminal_id"] not in before:
                    pane, ws = view.get("pane"), view.get("workspace")
                    break
        if pane is not None:
            try:
                if term is None:
                    term = j.daemon_terminal(workspace or ws, pane)
                if j.app.screen(term)["text"].strip():
                    return D.now() - started, term
            except D.StepError as error:
                if "selector.not_found" in str(error):
                    term = None
            except Exception:  # noqa: BLE001 (a read during load can fail once; the next poll tries again)
                pass
        time.sleep(POLL_S)
    return None, term


def _try_once(j, action, timeout_s, index):
    before = _known_terminals(j)
    if action == "key_new_terminal":
        started = D.now()
        j.key(KEY_NEW_TERMINAL["key"], KEY_NEW_TERMINAL["modifiers"])
        return _wait_prompt(j, before, started, timeout_s)
    if action == "script_new_tab":
        name = f"jr-load-{j.nonce}-{index}"
        started = D.now()
        j.app.rpc("action.run", {"action": "newTab", "args": {"name": name, "focus": True}})
        return _wait_prompt(j, before, started, timeout_s, workspace=name)
    if action == "new_window":
        started = D.now()
        j.key(KEY_NEW_WINDOW["key"], KEY_NEW_WINDOW["modifiers"])
        # The new window opens on its New Tab page; Ctrl-` there makes its terminal (as mw-shortcuts-new-window).
        end = started + timeout_s
        windows = None
        while D.now() < end:
            report = j.app.rpc("debug.layers") or {}
            ids = [w.get("id") for w in report.get("windows") or []]
            if windows is None:
                windows = getattr(j, "load_windows_seen", set())
            new = [w for w in ids if w not in windows]
            if new:
                j.load_windows_seen = set(ids)
                j.app.rpc("debug.window.focus", {"window": new[0]})
                j.key(KEY_NEW_TERMINAL["key"], KEY_NEW_TERMINAL["modifiers"], window=new[0])
                return _wait_prompt(j, before, started, max(0.0, end - D.now()) + (D.now() - started))
            time.sleep(POLL_S)
        return None, None
    raise D.StepError(f"first_prompts: unknown action {action!r}")


def _pct(values, q):
    if not values:
        return None
    ordered = sorted(values)
    # Nearest rank: the smallest value with at least q of the tries at or under it (p95 of 10 tries is the largest).
    return ordered[max(0, min(len(ordered), math.ceil(q * len(ordered))) - 1)]


def step_first_prompts(j, step):
    action, count = step["action"], int(step.get("count", 10))
    timeout_s = float(step.get("timeout_s", 20))
    if action == "new_window" and not hasattr(j, "load_windows_seen"):
        j.load_windows_seen = {w.get("id") for w in ((j.app.rpc("debug.layers") or {}).get("windows") or [])}
    tries = []
    for index in range(count):
        seconds, term = _try_once(j, action, timeout_s, index)
        tries.append({"try": index + 1, "ms": None if seconds is None else round(seconds * 1000, 1), "terminal": term})
        time.sleep(float(step.get("gap_s", 1)))
    ms = [t["ms"] for t in tries if t["ms"] is not None]
    result = {"action": action, "count": count, "tries": tries, "timeouts": sum(1 for t in tries if t["ms"] is None),
              "p50_ms": _pct(ms, 0.5), "p95_ms": _pct(ms, 0.95), "max_ms": max(ms) if ms else None,
              "poll_error_ms": POLL_S * 1000}
    kept = getattr(j, "load_results", None)
    if kept is None:
        kept = j.load_results = {}
    kept[step.get("as", action)] = result
    return result


def step_load_report(j, step):
    path = os.path.join(str(j.out), "diag-load.json")
    with open(path, "w") as f:
        json.dump(getattr(j, "load_results", {}), f, indent=1)
    return {"path": path, "results": getattr(j, "load_results", {})}


def cond_first_prompt_p95(j, want, cache):
    result = (getattr(j, "load_results", None) or {}).get(want["action"])
    if not result:
        return False, {"error": f"no first_prompts result for {want['action']!r}"}
    ok = result["timeouts"] == 0 and result["p95_ms"] is not None and result["p95_ms"] <= float(want["max_ms"])
    return ok, {k: result[k] for k in ("p50_ms", "p95_ms", "max_ms", "timeouts", "count")}


STEPS = {"start_load": step_start_load, "stop_load": step_stop_load, "first_prompts": step_first_prompts,
         "load_report": step_load_report}
CONDITIONS = {"first_prompt_p95": ("daemon", cond_first_prompt_p95)}
