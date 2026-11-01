"""Quit and reopen with a REAL Cmd-Q (QUIT P0, Lawrence 2026-11-01: "after quitting and reopening, i lose all the
workspaces and terminals ... cmd q needs to prompt for what type of quit").

driver.py loads this file (load_extensions) on the mini under the stock /usr/bin/python3 (3.9, standard library
only). It must not import driver.py: install() gets the driver module instead.

The driver's own `relaunch` presses Cmd-Q with `debug.key`, which enters the app's key router directly, in a capture
slot whose window is never key. A person's Cmd-Q comes from the window server to the key window, and AppKit's menu
key equivalent runs Quit. This group sends that real key (CuaDriver, ext_realkey.py; a whole-host lease, run.py
--whole-host) and records what the person sees and what survives.

Steps (`do`):
  quit_state     {as}                    records, under NAME, the app's daemon pid (`debug.daemon`), the holder and
                                         terminal host processes of the bundle, the daemon's workspaces and terminals
                                         (`cmux workspace list`, `cmux terminal list`) and the app's own topology
                                         (`snapshot.get`): what must come back
  real_quit      {answer?, ask_wait?, mark?}
                                         a REAL Cmd-Q (CuaDriver hotkey to the key window), then: when the app shows
                                         its quit dialog (`debug.quit` asking) within ASK_WAIT s (default 5), its
                                         title, lines, buttons and default are recorded and ANSWER (default: the
                                         dialog's default button, as Return does) is pressed; then the driver's
                                         `relaunch` path: wait for the process to end, reopen the same bundle through
                                         LaunchServices with its launch variables, wait for the restored topology.

Conditions (inside `expect.all`):
  quit_asked     {default?, buttons?}    app: the real Cmd-Q showed the quit dialog; its default button is DEFAULT and
                                         it has every id in BUTTONS
  daemon_kept    {before}                process: the daemon the reopened app is connected to is the one recorded in
                                         BEFORE (same pid), and every holder and terminal host recorded then still runs
  workspaces_back {before}               app: every workspace (by id and name) and every terminal (by id) the daemon
                                         listed in BEFORE is listed again, each terminal still live (not ended), and
                                         the app's topology shows every workspace and every pane BEFORE's showed
"""
import json
import time

D = None


def install(driver):
    global D
    D = driver


def _daemon_pid(j):
    try:
        state = j.app.rpc("debug.daemon", timeout=5) or {}
    except (D.StepError, OSError, ValueError):
        return None
    pid = state.get("pid") or (state.get("daemon") or {}).get("pid")
    return int(pid) if pid else None


def _helpers(j):
    """The bundle's holder and terminal host processes (they keep the shells across an app quit)."""
    rows = j.app.bundle_processes(j.app.pid)
    return [{"pid": r["pid"], "role": "holder" if "__holder" in r["command"] or "cmux-holder" in r["command"] else "host",
             "command": r["command"][:160]}
            for r in rows if "__holder" in r["command"] or "cmux-holder" in r["command"] or "__terminal-host" in r["command"]]


def _rows(answer, *keys):
    for _ in range(3):
        if isinstance(answer, list):
            return answer
        if isinstance(answer, dict):
            answer = next((answer[k] for k in keys + ("value", "result", "data") if k in answer), None)
    return answer if isinstance(answer, list) else []


def _daemon_lists(j):
    workspaces = [{"id": w.get("id"), "name": w.get("name") or w.get("title")}
                  for w in _rows(j.app.cmux("workspace", "list"), "workspaces") if isinstance(w, dict)]
    terminals = [{"id": t.get("id"), "lifecycle": t.get("lifecycle") or t.get("state"), "workspace": t.get("workspace_id")}
                 for t in _rows(j.app.cmux("terminal", "list"), "terminals") if isinstance(t, dict)]
    return workspaces, terminals


def _app_places(j):
    topo = j.topology()
    workspaces = [{"id": ws.get("id"), "name": ws.get("name")} for ws in topo.get("workspaces", [])]
    terms = sorted({t for _, _, _, t in j.places(topo) if t})
    return workspaces, terms


def step_quit_state(j, step):
    name = step["as"]
    workspaces, terminals = _daemon_lists(j)
    app_workspaces, app_terms = _app_places(j)
    state = {"daemon_pid": _daemon_pid(j), "helpers": _helpers(j), "workspaces": workspaces, "terminals": terminals,
             "app_workspaces": app_workspaces, "app_terminals": app_terms, "app_pid": j.app.pid, "at": D.now()}
    if not hasattr(j, "quit_states"):
        j.quit_states = {}
    j.quit_states[name] = state
    return {k: (v if k not in ("terminals",) else len(v)) for k, v in state.items()}


def _quit_report(j):
    try:
        report = j.app.rpc("debug.quit", timeout=5) or {}
    except (D.StepError, OSError, ValueError):
        return None
    return report if isinstance(report, dict) else None


def step_real_quit(j, step):
    import ext_realkey  # the CuaDriver key path (same folder; it imports no driver)
    if not D.ACTIVATE:
        # A slot's window is never key: a real key cannot reach it. Not a verdict on the app.
        raise D.NotRun("real_quit needs a whole-host lease (run.py --whole-host): the app's window must be key")
    seen = {"asked": False}
    j.quit_seen = seen

    def real_cmd_q(key, modifiers):
        sent = ext_realkey.step_real_key(j, {"key": key, "modifiers": modifiers, "mark": step.get("mark_key")})
        seen["key"] = sent
        end = D.now() + float(step.get("ask_wait", 5))
        while D.now() < end and j.app.alive(j.app.pid):
            report = _quit_report(j)
            if report and report.get("asking"):
                prompt = report.get("prompt") or {}
                seen.update(asked=True, asked_after_s=round(D.now() - j.marks.get("real-cmd-q", D.now()), 3),
                            default=prompt.get("default"), lines=report.get("lines"),
                            buttons=[b.get("id") for b in report.get("buttons") or []],
                            titles=[b.get("title") for b in report.get("buttons") or []], remember=report.get("remember"))
                answer = step.get("answer") or prompt.get("default") or "keep"
                seen["answered"] = answer
                seen["pressed"] = (j.app.rpc("debug.quit", {"press": answer}, timeout=10) or {}).get("pressed")
                break
            time.sleep(0.1)
        return sent

    j.marks["real-cmd-q"] = D.now()
    wall = time.time()
    j.key = real_cmd_q  # the driver's relaunch presses Cmd-Q through self.key: here, the real key
    try:
        record = D.Journey.step_relaunch(j, dict(step, how="quit"))
    finally:
        del j.key
    record["quit_dialog"] = seen
    record["why"] = _why(j, wall)
    return record


def _why(j, since_wall):
    """Evidence of what ended or kept the daemon: the app's own quit and daemon log lines since the key (unified log,
    the app's subsystem: "quit origin=", "quit choice=", "handing off to", "daemon handoff"), the new launch's
    `daemon_version_handoff` mark, and the new daemon pid."""
    seconds = max(int(time.time() - since_wall) + 5, 10)
    predicate = ('subsystem == "com.cmuxterm.app.next" AND (category == "app.quit" OR category == "daemon")')
    try:
        out = D.subprocess.run(["/usr/bin/log", "show", "--style", "compact", "--last", f"{seconds}s", "--predicate", predicate],
                               capture_output=True, text=True, timeout=60).stdout
    except (OSError, D.subprocess.TimeoutExpired) as error:
        out = f"log show failed: {error}"
    keep = ("quit origin", "quit choice", "handing off", "handoff", "end sessions", "shutdown")
    lines = [line[-300:] for line in out.splitlines() if any(k in line for k in keep)]
    try:
        marks = (j.app.rpc("debug.timings", timeout=10) or {}).get("launch_ms_since_process_start") or {}
    except (D.StepError, OSError, ValueError):
        marks = {}
    return {"log": lines[-40:], "handoff_mark": marks.get("daemon_version_handoff"), "daemon_pid_now": _daemon_pid(j)}


def cond_quit_asked(j, want, cache):
    seen = getattr(j, "quit_seen", None)
    if seen is None:
        return False, {"error": "no real_quit step ran before this check"}
    detail = {k: seen.get(k) for k in ("asked", "default", "buttons", "titles", "lines", "answered", "pressed")}
    if not seen.get("asked"):
        return False, dict(detail, why="the real Cmd-Q quit with no dialog")
    if want.get("default") and seen.get("default") != want["default"]:
        return False, dict(detail, why=f"the default is {seen.get('default')!r}, not {want['default']!r}")
    missing = [b for b in want.get("buttons") or [] if b not in (seen.get("buttons") or [])]
    if missing:
        return False, dict(detail, why=f"no button {missing}")
    return True, detail


def _before(j, want):
    states = getattr(j, "quit_states", {})
    if want["before"] not in states:
        raise D.StepError(f"no quit_state step recorded {want['before']!r}")
    return states[want["before"]]


def cond_daemon_kept(j, want, cache):
    before = _before(j, want)
    pid = _daemon_pid(j)
    gone = [h for h in before["helpers"] if not j.app.alive(h["pid"])]
    detail = {"daemon_before": before["daemon_pid"], "daemon_now": pid, "helpers_before": len(before["helpers"]),
              "helpers_gone": gone[:6]}
    if not before["daemon_pid"]:
        return False, dict(detail, why="no daemon pid was recorded before the quit")
    if pid != before["daemon_pid"]:
        return False, dict(detail, why="the reopened app talks to another daemon: the old one ended")
    if gone:
        return False, dict(detail, why=f"{len(gone)} holder or host processes ended")
    return True, detail


def cond_workspaces_back(j, want, cache):
    before = _before(j, want)
    workspaces, terminals = _daemon_lists(j)
    app_workspaces, app_terms = _app_places(j)
    ids = {w["id"] for w in workspaces}
    lost_ws = [w for w in before["workspaces"] if w["id"] not in ids]
    by_id = {t["id"]: t for t in terminals}
    lost_terms = [t["id"] for t in before["terminals"] if t["id"] not in by_id]
    dead = [t["id"] for t in before["terminals"] if t["id"] in by_id
            and str(by_id[t["id"]].get("lifecycle") or "").lower() in ("dead", "ended", "exited", "closed")]
    app_ids = {w["id"] for w in app_workspaces}
    app_lost = [w for w in before["app_workspaces"] if w["id"] not in app_ids]
    app_lost_terms = [t for t in before["app_terminals"] if t not in set(app_terms)]
    detail = {"workspaces_before": len(before["workspaces"]), "workspaces_now": len(workspaces),
              "terminals_before": len(before["terminals"]), "terminals_now": len(terminals),
              "app_workspaces_before": len(before["app_workspaces"]), "app_workspaces_now": len(app_workspaces),
              "lost_workspaces": lost_ws[:8], "lost_terminals": lost_terms[:8], "ended_terminals": dead[:8],
              "app_lost_workspaces": app_lost[:8], "app_lost_terminals": app_lost_terms[:8]}
    ok = not (lost_ws or lost_terms or dead or app_lost or app_lost_terms) and len(before["workspaces"]) > 0
    return ok, detail


STEPS = {"quit_state": step_quit_state, "real_quit": step_real_quit}
CONDITIONS = {"quit_asked": ("app", cond_quit_asked), "daemon_kept": ("process", cond_daemon_kept),
              "workspaces_back": ("app", cond_workspaces_back)}
