"""Quit, reopen and kill -9 actions and their oracle for the action fuzzer (ext_fuzz.py; QUIT P0, Lawrence 2026-11-01:
"after quitting and reopening, i lose all the workspaces and terminals ... need to fuzz and test for this").

driver.py loads this file (load_extensions) on the mini under the stock /usr/bin/python3 (standard library only); it
declares no steps or conditions of its own. ext_fuzz.py plays its actions (END_ACTIONS) and calls its oracle.

Actions (each ends its burst, so it can follow a create, a resize or typed text at once: "during" those):
  quit_keep            the File menu's Quit, Keep Sessions (no dialog), then the reopen
  quit_end_sessions    Quit, End Sessions, Keep Layout, then the reopen
  quit_end_everything  Quit, End Everything, then the reopen
  kill_app             SIGKILL of the app, then the reopen
  kill_daemon          SIGKILL of the app's daemon; the app stays and starts a new one
  kill_both            SIGKILL of the daemon, then of the app, then the reopen

Oracle `quit` (a STOP oracle: it is shrunk), from the ACKNOWLEDGED state: what the daemon listed at the end (read
just after the app's end while the daemon still runs, else just before a daemon kill) and the app's topology before:
  - keep, kill_app: the same daemon pid; every acknowledged workspace and terminal is back and live; every pane of
    the app's topology before is back; each sampled terminal's probe lines (fz<nonce>-N, read from the daemon's
    history before) are still in its history (scrollback intact)
  - kill_daemon, kill_both: a new daemon; every acknowledged workspace and terminal is back and live (the holder
    keeps the shells), the scrollback as above
  - end_sessions: a new daemon; every acknowledged workspace is back with its panes (each kept tab restarts a shell)
  - end_everything: a new daemon; no workspace of before is back
  - always: the app is connected; exactly one daemon of this bundle runs, at most one holder, and the old daemon is
    gone when it had to end (no orphan daemon or holder)
"""
import os
import re
import signal
import time

D = None
STEPS = {}
CONDITIONS = {}

# action -> (how the app ends: driver relaunch `how`, or "daemon" for a daemon-only kill; what the daemon must do)
END_ACTIONS = {
    "quit_keep": ("quit-keep", "kept"),
    "quit_end_sessions": ("quit-end-sessions", "ended_keep_layout"),
    "quit_end_everything": ("quit-end-everything", "ended_everything"),
    "kill_app": ("kill-app", "kept"),
    "kill_daemon": ("daemon", "restarted"),
    "kill_both": ("kill-both", "restarted"),
}
# Terminals whose scrollback is compared (the first ones by id: bounded time per action).
HISTORY_SAMPLE = 6
HISTORY_ROWS = 2000
RECONNECT_SECONDS = 45.0
PROCESS_SETTLE = 10.0
DEAD = ("exited", "dead", "closed", "ended")


def install(driver):
    global D
    D = driver


def _rows(answer, key):
    for _ in range(3):
        if isinstance(answer, list):
            return answer
        if isinstance(answer, dict):
            answer = next((answer[k] for k in (key, "value", "result", "data") if k in answer), None)
    return answer if isinstance(answer, list) else []


def daemon_lists(j):
    """({workspace id: name}, {terminal id: lifecycle}) from the app's daemon (`cmux workspace list`, `terminal list`)."""
    workspaces = {str(w.get("id")): w.get("name") for w in _rows(j.app.cmux("workspace", "list"), "workspaces")
                  if isinstance(w, dict) and w.get("id")}
    terminals = {str(t.get("id")): str(t.get("lifecycle") or t.get("state") or "live")
                 for t in _rows(j.app.cmux("terminal", "list"), "terminals") if isinstance(t, dict) and t.get("id")}
    return workspaces, terminals


def probe_lines(j, term, nonce):
    """The fuzzer's probe lines (fz<nonce>-N) in terminal TERM's scrollback and screen together, as a set (a reopen
    may move rows between the two: a different size reflows them)."""
    answer = j.app.cmux("terminal", term, "history", "read", "--limit", str(HISTORY_ROWS))
    for _ in range(3):
        if isinstance(answer, dict) and "rows" not in answer:
            answer = next((answer[k] for k in ("value", "result", "data") if isinstance(answer.get(k), dict)), answer)
    rows = answer.get("rows") if isinstance(answer, dict) else None
    text = "\n".join("".join(str(r.get("text", "")) for r in row.get("runs", []) if isinstance(r, dict))
                     for row in rows or [] if isinstance(row, dict))
    text += "\n" + str(j.app.screen(term).get("text", ""))
    return set(re.findall(r"fz" + re.escape(str(nonce)) + r"-\d+\b", text))


def owned(j):
    """{daemons: [pid], holders: [pid]} of this bundle's session (its headless owner and its holder)."""
    rows = j.app.bundle_processes(j.app.pid)
    sessions = getattr(j.app, "sessions", [])
    daemons = [r["pid"] for r in rows if "--headless" in r["command"]
               and (not sessions or any(f"--session {s}" in r["command"] for s in sessions))]
    holders = [r["pid"] for r in rows if "__holder" in r["command"] or "cmux-holder" in r["command"]]
    return {"daemons": daemons, "holders": holders}


def acknowledged(j, topo_state, nonce):
    """What the oracle compares against: the daemon's lists, the app's panes, and sampled probe lines."""
    workspaces, terminals = daemon_lists(j)
    live = sorted(t for t, life in terminals.items() if life.lower() not in DEAD)
    # The probe lines go to the focused terminal: sample its pane's terminals first, then the first ones by id.
    focus = ((topo_state or {}).get("focus") or {}).get("pane")
    focused = [str(v.get("term")) for v in ((topo_state or {}).get("terminals") or {}).values()
               if isinstance(v, dict) and focus and v.get("pane") == focus]
    sample = [t for t in focused if t in live] + [t for t in live if t not in focused]
    history = {}
    for term in sample[:HISTORY_SAMPLE]:
        try:
            history[term] = sorted(probe_lines(j, term, nonce))
        except D.StepError:
            pass
    panes = {ws: list(p) for ws, p in (topo_state or {}).get("panes", {}).items()}
    return {"workspaces": workspaces, "terminals": live, "history": history, "panes": panes,
            "daemon_pid": j.app.daemon_pid()}


def state_now(j):
    """The app's topology just before an end (ext_fuzz.state): the panes a create or close earlier in the burst made."""
    import ext_fuzz  # same folder; only its pure topology reader is used
    return ext_fuzz.state(j)


def merged(before, after, closes):
    """The acknowledged state of a keep or a kill of the app: read just before the end (BEFORE) and again after the
    app ended while the daemon still runs (AFTER, which also holds a create in flight at the end). A daemon that dropped
    data at the quit is caught by BEFORE; a close in flight at the end is in BEFORE only, so a burst that CLOSES
    takes the workspaces and terminals from AFTER alone. Probe lines: both reads together."""
    out = dict(after)
    if not closes:
        out["workspaces"] = {**before.get("workspaces", {}), **after.get("workspaces", {})}
        out["terminals"] = sorted(set(before.get("terminals", [])) | set(after.get("terminals", [])))
    history = {t: set(lines) for t, lines in before.get("history", {}).items()}
    for term, lines in after.get("history", {}).items():
        history.setdefault(term, set()).update(lines)
    out["history"] = {t: sorted(lines) for t, lines in history.items()}
    out["panes"], out["daemon_pid"] = before.get("panes", {}), before.get("daemon_pid") or after.get("daemon_pid")
    return out


def play(fuzz, name, before_state):
    """Plays end action NAME; returns its record (with `ack`, the acknowledged state, and `after`). The acknowledged
    state is read just before the end (`state_now`), not at the burst's start: a create earlier in the burst counts."""
    j = fuzz.j
    how, expect = END_ACTIONS[name]
    rec = {"a": name, "expect": expect, "at": D.now()}
    try:
        before_state = state_now(j)
    except D.StepError:
        pass  # the burst's start state
    if how == "daemon":
        ack = acknowledged(j, before_state, j.nonce)
        rec["ack"] = ack
        if not ack["daemon_pid"]:
            raise D.StepError("kill_daemon: debug.daemon names no pid")
        os.kill(ack["daemon_pid"], signal.SIGKILL)
        end = D.now() + RECONNECT_SECONDS
        while D.now() < end:
            pid = j.app.daemon_pid()
            if pid and pid != ack["daemon_pid"]:
                try:
                    if j.topology().get("daemon_state") == "connected":
                        break
                except D.StepError:
                    pass
            time.sleep(0.25)
        j.app._daemon_sock = None
        rec["reconnected_after_s"] = round(D.now() - rec["at"], 2)
        return rec
    # The acknowledged state, read just before the end. For a kill of the app alone and for keep the daemon still runs
    # after the app ends: the hook reads it again then and merges both (`merged`).
    rec["ack"] = acknowledged(j, before_state, j.nonce)
    rec["closes"] = bool(getattr(fuzz, "burst_closes", True))
    rec["relaunch"] = j.step_relaunch({"how": how, "after_end": after_end_hook(fuzz, rec)})
    return rec


def after_end_hook(fuzz, rec):
    """Called by the driver's relaunch between the app's end and the reopen (keep, kill_app): the daemon's lists now."""
    def hook():
        if rec["expect"] != "kept":
            return None
        rec["ack"] = merged(rec["ack"], acknowledged(fuzz.j, None, fuzz.j.nonce), rec.get("closes", True))
        return {"workspaces": len(rec["ack"]["workspaces"]), "terminals": len(rec["ack"]["terminals"])}
    return hook


def oracle(fuzz, rec, after_state):
    """[(oracle, detail)] for end action record REC, read now (after the reopen or the daemon's restart)."""
    j, ack, expect = fuzz.j, rec.get("ack") or {}, rec["expect"]
    problems = []
    try:
        workspaces, terminals = daemon_lists(j)
    except D.StepError as error:
        return [("quit", f"{rec['a']}: the daemon's lists cannot be read after it: {str(error)[-200:]}")]
    pid = j.app.daemon_pid()
    old = ack.get("daemon_pid")
    # A daemon or holder of before may still be ending: settle for up to PROCESS_SETTLE s before judging them.
    end = time.monotonic() + PROCESS_SETTLE
    while True:
        procs = owned(j)
        clean = len(procs["daemons"]) == 1 and len(procs["holders"]) <= 1 and not (expect != "kept" and old and j.app.alive(old))
        if clean or time.monotonic() >= end:
            break
        time.sleep(0.5)
    if (after_state or {}).get("daemon_state") != "connected":
        problems.append(("quit", f"{rec['a']}: the app is {(after_state or {}).get('daemon_state')}, not connected"))
    if len(procs["daemons"]) != 1:
        problems.append(("quit", f"{rec['a']}: {len(procs['daemons'])} daemons of this bundle run: {procs['daemons'][:4]}"))
    if len(procs["holders"]) > 1:
        problems.append(("quit", f"{rec['a']}: {len(procs['holders'])} holders run: {procs['holders'][:4]}"))
    if expect == "kept" and old and pid != old:
        problems.append(("quit", f"{rec['a']}: the daemon changed ({old} -> {pid}): it ended with the app"))
    if expect != "kept" and old and j.app.alive(old):
        problems.append(("quit", f"{rec['a']}: the old daemon {old} still runs (orphan)"))
    lost_ws = sorted(w for w in ack.get("workspaces", {}) if w not in workspaces)
    if expect in ("kept", "restarted", "ended_keep_layout") and lost_ws:
        problems.append(("quit", f"{rec['a']}: {len(lost_ws)} acknowledged workspaces are gone: {lost_ws[:4]}"))
    if expect == "ended_everything":
        kept = sorted(w for w in ack.get("workspaces", {}) if w in workspaces
                      and str(ack["workspaces"][w] or "").lower() != "home")
        if kept:
            problems.append(("quit", f"{rec['a']}: End Everything kept {len(kept)} workspaces: {kept[:4]}"))
    live_now = {t for t, life in terminals.items() if life.lower() not in DEAD}
    if expect in ("kept", "restarted"):
        lost = sorted(t for t in ack.get("terminals", []) if t not in live_now)
        if lost:
            problems.append(("quit", f"{rec['a']}: {len(lost)} acknowledged terminals are gone or ended: {lost[:4]}"))
        for term, lines in (ack.get("history") or {}).items():
            if term not in live_now or not lines:
                continue
            try:
                now_lines = probe_lines(j, term, j.nonce)
            except D.StepError as error:
                problems.append(("quit", f"{rec['a']}: terminal {term}'s history cannot be read: {str(error)[-120:]}"))
                continue
            missing = sorted(set(lines) - now_lines)
            if missing:
                problems.append(("quit", f"{rec['a']}: terminal {term} lost {len(missing)} scrollback lines: {missing[:3]}"))
    if expect == "ended_everything":
        # (End Sessions, Keep Layout restarts a shell in each kept tab, which may keep its terminal id: its oracle
        # is the kept panes below and the new daemon, not the ids.)
        still = sorted(t for t in ack.get("terminals", []) if t in live_now)
        if still:
            problems.append(("quit", f"{rec['a']}: {len(still)} terminals of before still run after an end: {still[:4]}"))
    if expect in ("kept", "ended_keep_layout"):
        panes_now = (after_state or {}).get("panes", {})
        for ws, panes in ack.get("panes", {}).items():
            if ws not in panes_now and ws not in workspaces:
                continue  # the workspace itself is judged above
            # Every acknowledged pane is back; a create still in flight at the end may add one.
            missing = sorted(set(panes) - set(panes_now.get(ws, [])))
            if expect == "kept" and missing:
                problems.append(("quit", f"{rec['a']}: workspace {ws} lost {len(missing)} of {len(panes)} panes: {missing[:4]}"))
            elif expect == "ended_keep_layout" and len(panes_now.get(ws, [])) < len(panes):
                problems.append(("quit", f"{rec['a']}: workspace {ws} kept {len(panes_now.get(ws, []))} of {len(panes)} panes"))
    return problems
