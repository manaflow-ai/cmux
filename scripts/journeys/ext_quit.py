"""Quit and reopen with a REAL Cmd-Q (QUIT P0, Lawrence 2026-11-01: "after quitting and reopening, i lose all the
workspaces and terminals ... cmd q needs to prompt for what type of quit").

driver.py loads this file (load_extensions) on the mini under the stock /usr/bin/python3 (3.9, standard library
only). It must not import driver.py: install() gets the driver module instead.

The driver's own `relaunch` presses Cmd-Q with `debug.key`, which enters the app's key router directly, in a capture
slot whose window is never key. A person's Cmd-Q comes from the window server to the key window, and AppKit's menu
key equivalent runs Quit. This group sends that real key (CuaDriver, ext_realkey.py; a whole-host lease, run.py
--whole-host) and records what the person sees and what survives.

Steps (`do`):
  quit_state     {name}                  records, under NAME, the app's daemon pid (`debug.daemon`), the holder and
                                         terminal host processes of the bundle, the daemon's workspaces and terminals
                                         (`cmux workspace list`, `cmux terminal list`) and the app's own topology
                                         (`snapshot.get`): what must come back
  require_whole_host {}                  `not run` at once in a capture slot (its window is never key, so a real key
                                         cannot reach it): run it with run.py --whole-host
  quit_speed     {count?, how?}          COUNT quit-and-reopen cycles (default quit-keep), each timed from the new
                                         process's main(): last frame, window frame, interactive, quit-to-gone;
                                         every cmux-tui daemon's identify (pid, build_commit, build_id) before and
                                         after each cycle; a cycle with a daemon not of the bundle's build is
                                         `not_run`; speed.json
  quit_why       {}                      evidence after the checks: the app's quit and daemon log lines since the real
                                         key (log show --info), the daemon_version_handoff mark, the daemon pid now
  real_quit      {ask_wait?, mark?, env?}      a REAL Cmd-Q (CuaDriver hotkey to the key window), then: when the app shows
                                         its quit dialog (`debug.quit` asking) within ASK_WAIT s (default 5), its
                                         title, lines, buttons and default are recorded and its default button is
                                         pressed (as Return does); a later dialog is recorded too; then the driver's
                                         `relaunch` path: wait for the process to end, reopen the same bundle through
                                         LaunchServices with its launch variables, wait for the restored topology.

Conditions (inside `expect.all`):
  quit_asked     {default?, buttons?}    app: the real Cmd-Q showed the quit dialog; its default button is DEFAULT and
                                         it has every id in BUTTONS
  daemon_kept    {before}                process: the daemon the reopened app is connected to is the one recorded in
                                         BEFORE (same pid), and every holder and terminal host recorded then still runs
  workspaces_back {before}               app: every workspace and every live terminal (by id) the daemon listed in
                                         BEFORE is listed again, each terminal still live (not ended), and the app's
                                         topology shows every workspace and every terminal BEFORE's showed
  helpers_kept   {before}                process: every holder and terminal host of BEFORE still runs (the daemon may be
                                         new: a handoff)
  daemon_is_prior {}                     process: the app's daemon runs ${prior_tui} (run.py --prior-build)
  daemon_handed_off {before}             process: the daemon is a new one running this build's bundled cmux-tui (a
                                         reopen that kept the prior daemon for a set-up reason is `not run`)
Set-up steps: require_prior {} (`not run` without --prior-build), require_daemon_prior {timeout?} (`not run` unless the
daemon runs ${prior_tui})
  scrollback_whole {prefix, last}        daemon: the current terminal's rows above the screen (history, oldest first)
                                         and its screen together hold PREFIX1 .. PREFIXLAST, each once, in order
"""
import json
import re
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


def step_require_prior(j, step):
    if j.sub("${prior_tui}") == "${prior_tui}":
        raise D.NotRun("this journey needs a second build: run.py --prior-build JOB (an older build of the same tag)")
    return {"prior_tui": j.sub("${prior_tui}")}


def step_require_daemon_prior(j, step):
    """Set-up check: the app's daemon is the prior build's, within TIMEOUT s; else `not run` (an older owner that
    refuses this build's state is a set-up limit, not the reopen under test)."""
    end = D.now() + float(step.get("timeout", 30))
    held, detail = False, {}
    while D.now() < end and not held:
        held, detail = cond_daemon_is_prior(j, {}, {})
        if not held:
            time.sleep(0.5)
    if not held:
        raise D.NotRun(f"set-up: the daemon did not start as the prior build's: {json.dumps(detail)[:300]}")
    return detail


def step_require_whole_host(j, step):
    if not D.ACTIVATE:
        # A slot's window is never key: a real key cannot reach it. Not a verdict on the app.
        raise D.NotRun("a real key needs a whole-host lease (run.py --whole-host): the app's window must be key")
    return {"activate": True}


def step_quit_state(j, step):
    name = step["name"]
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
    step_require_whole_host(j, step)
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
                answer = prompt.get("default") or "keep"
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
    if not seen.get("asked") and record.get("sheet"):
        # The dialog came after ASK_WAIT: the driver's own loop saw it and pressed its default.
        sheet = record["sheet"]
        seen.update(asked=True, late=True, default=sheet.get("default"), lines=sheet.get("lines"),
                    buttons=sheet.get("buttons"), answered=sheet.get("default"))
    record["quit_dialog"] = seen
    j.quit_wall = wall  # `quit_why` reads the logs since the key, after the checks
    return record


def step_quit_why(j, step):
    """Evidence (after the checks, so it never eats their time): see _why. Nothing when no real Cmd-Q was sent."""
    if not hasattr(j, "quit_wall"):
        return {"skipped": "no real Cmd-Q in this run"}
    return _why(j, j.quit_wall)


def _why(j, since_wall):
    """Evidence of what ended or kept the daemon: the app's own quit and daemon log lines since the key (unified log,
    the app's subsystem: "quit origin=", "quit choice=", "handing off to", "daemon handoff"), the new launch's
    `daemon_version_handoff` mark, and the new daemon pid."""
    seconds = max(int(time.time() - since_wall) + 5, 10)
    predicate = ('subsystem == "com.cmuxterm.app.next" AND (category == "app.quit" OR category == "daemon")')
    try:
        out = D.subprocess.run(["/usr/bin/log", "show", "--info", "--style", "compact", "--last", f"{seconds}s", "--predicate", predicate],
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
    if not before["helpers"]:
        return False, dict(detail, why="no holder or terminal host was found before the quit: nothing to compare")
    if pid != before["daemon_pid"]:
        return False, dict(detail, why="the reopened app talks to another daemon: the old one ended")
    if gone:
        return False, dict(detail, why=f"{len(gone)} holder or host processes ended")
    return True, detail


def cond_helpers_kept(j, want, cache):
    """Every holder and terminal host recorded in BEFORE still runs (a daemon handoff keeps them: the new daemon adopts
    the shells); the daemon itself may be new."""
    before = _before(j, want)
    gone = [h for h in before["helpers"] if not j.app.alive(h["pid"])]
    pid = _daemon_pid(j)
    detail = {"helpers_before": len(before["helpers"]), "helpers_gone": gone[:6], "daemon_before": before["daemon_pid"],
              "daemon_now": pid}
    if not before["helpers"]:
        return False, dict(detail, why="no holder or terminal host was found before the quit: nothing to compare")
    if gone:
        return False, dict(detail, why=f"{len(gone)} holder or host processes ended: their shells ended")
    return True, detail


def cond_daemon_is_prior(j, want, cache):
    """The app's daemon runs the prior build's cmux-tui (${prior_tui}): the set-up for a handoff at the reopen."""
    prior = j.sub("${prior_tui}")
    pid = _daemon_pid(j)
    if not pid or prior == "${prior_tui}":
        return False, {"why": "no daemon pid, or no prior build (run.py --prior-build)", "daemon": pid}
    command = D.subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return command.startswith(prior), {"daemon": pid, "command": command[:200], "prior": prior}


def cond_daemon_handed_off(j, want, cache):
    """The reopen handed the daemon off: the app's daemon is not BEFORE's (another pid) and runs this build's bundled
    cmux-tui. When the reopen kept the prior daemon for a set-up reason (the same build commit, or a build the app
    cannot read), the journey is `not run`: the handoff under test never ran."""
    before = _before(j, want)
    pid = _daemon_pid(j)
    bundled = j.app.bundle.rstrip("/") + "/Contents/Resources/bin/cmux-tui"
    command = D.subprocess.run(["ps", "-o", "command=", "-p", str(pid or 0)], capture_output=True, text=True).stdout.strip()
    detail = {"daemon_before": before["daemon_pid"], "daemon_now": pid, "command": command[:200], "bundled": bundled}
    if pid and pid != before["daemon_pid"] and command.startswith(bundled):
        return True, detail
    prior = j.sub("${prior_tui}")
    if pid == before["daemon_pid"]:
        versions, commits = {}, {}
        for name, path in (("prior", prior), ("bundled", bundled)):
            out = D.subprocess.run([path, "--version"], capture_output=True, text=True, timeout=10).stdout.strip()
            versions[name] = out[:120]
            # The app's own parse (DaemonLauncher.parseBuildCommit): the hex run after "(", 7 digits or more.
            found = re.search(r"\(([0-9a-fA-F]+)", out)
            commits[name] = found.group(1) if found and len(found.group(1)) >= 7 else None
        detail["versions"] = versions
        same = commits["prior"] is not None and commits["prior"] == commits["bundled"]
        unknown = None in commits.values()
        if same or unknown:
            raise D.NotRun(f"set-up: no handoff can run (prior and bundled builds: {json.dumps(versions)})")
        return False, dict(detail, why="the reopened app kept the prior build's daemon: no handoff ran")
    return False, dict(detail, why="the app's daemon is neither the prior one nor this build's bundled cmux-tui")


def cond_workspaces_back(j, want, cache):
    before = _before(j, want)
    workspaces, terminals = _daemon_lists(j)
    app_workspaces, app_terms = _app_places(j)
    ids = {w["id"] for w in workspaces}
    lost_ws = [w for w in before["workspaces"] if w["id"] not in ids]
    by_id = {t["id"]: t for t in terminals}
    ended = ("dead", "ended", "exited", "closed")
    live_before = [t for t in before["terminals"] if str(t.get("lifecycle") or "").lower() not in ended]
    lost_terms = [t["id"] for t in live_before if t["id"] not in by_id]
    dead = [t["id"] for t in live_before if t["id"] in by_id and str(by_id[t["id"]].get("lifecycle") or "").lower() in ended]
    app_ids = {w["id"] for w in app_workspaces}
    app_lost = [w for w in before["app_workspaces"] if w["id"] not in app_ids]
    app_lost_terms = [t for t in before["app_terminals"] if t not in set(app_terms)]
    detail = {"workspaces_before": len(before["workspaces"]), "workspaces_now": len(workspaces),
              "terminals_before": len(before["terminals"]), "terminals_now": len(terminals),
              "app_workspaces_before": len(before["app_workspaces"]), "app_workspaces_now": len(app_workspaces),
              "lost_workspaces": lost_ws[:8], "lost_terminals": lost_terms[:8], "ended_terminals": dead[:8],
              "app_lost_workspaces": app_lost[:8], "app_lost_terminals": app_lost_terms[:8]}
    ok = not (lost_ws or lost_terms or dead or app_lost or app_lost_terms) and len(before["workspaces"]) > 0 and len(live_before) > 0
    return ok, detail


def cond_scrollback_whole(j, want, cache):
    """The history alone is 1..k, each once, in order; the screen adds k+1..LAST (a screen row numbered k or lower,
    at its start, is the boundary overlap of the two reads and is skipped). A duplicated scrollback fails."""
    import re
    prefix, last = j.sub(want["prefix"]), int(want["last"])
    texts, _total = j.history("oldest", min(max(last + 200, 200), 10000), cache)
    screen = j.app.screen(j.need_term())["text"].splitlines()
    pattern = re.compile(r"^\s*" + re.escape(prefix) + r"(\d+)\s*$")
    numbered = lambda lines: [int(m.group(1)) for line in lines for m in [pattern.match(line)] if m]
    hist, scr = numbered(texts), numbered(screen)
    k = len(hist)
    detail = {"history_rows_read": len(texts), "screen_rows": len(screen), "history_numbered": k,
              "screen_numbered": len(scr), "history_head": hist[:3], "history_tail": hist[-3:], "screen_head": scr[:3]}
    if hist != list(range(1, k + 1)):
        return False, dict(detail, why="the history is not 1..k once each, in order (lost, repeated or out of order)")
    rest = scr
    while rest and rest[0] <= k:
        rest = rest[1:]
    if hist + rest != list(range(1, last + 1)):
        return False, dict(detail, why=f"history + screen is not exactly 1..{last}",
                           screen_rest_head=rest[:3], screen_rest_tail=rest[-3:])
    return True, detail


def _identify(sock):
    """The daemon's own `identify` on its socket: {pid, build_commit, build_id}, or {error}."""
    import socket as _socket
    try:
        with _socket.socket(_socket.AF_UNIX, _socket.SOCK_STREAM) as conn:
            conn.settimeout(5)
            conn.connect(sock)
            conn.sendall(b'{"id":1,"cmd":"identify"}\n')
            buf = b""
            while True:
                chunk = conn.recv(1 << 16)
                if not chunk:
                    break
                buf += chunk
                for line in buf.split(b"\n"):
                    try:
                        reply = json.loads(line)
                    except ValueError:
                        continue
                    if reply.get("id") == 1 and "ok" in reply:
                        data = reply.get("data") or {}
                        return {k: data.get(k) for k in ("pid", "build_commit", "build_id")}
    except OSError as error:
        return {"error": str(error)[-120:]}
    return {"error": "no identify reply"}


def daemon_builds(j):
    """Every cmux-tui daemon (`--headless`) the app's bundle runs, plus the one the app is connected to, each read
    by its own `identify` (measured, not assumed: cmux-ad 01:25Z), and the bundle's own cmux-tui build commit."""
    socks = {}
    for row in j.app.bundle_processes(j.app.pid):
        found = re.search(r"--socket[ =](\S+)", row["command"]) if "--headless" in row["command"] else None
        if found:
            socks[found.group(1)] = row["pid"]
    connected = j.app.daemon_socket()
    if connected:
        socks.setdefault(connected, None)
    out = [dict(_identify(sock), socket=sock[-40:], connected=sock == connected) for sock in socks]
    bundled = D.subprocess.run([j.app.bundle.rstrip("/") + "/Contents/Resources/bin/cmux-tui", "--version"],
                               capture_output=True, text=True, timeout=10).stdout
    found = re.search(r"\(([0-9a-fA-F]{7,})", bundled)
    commit = found.group(1) if found else None
    ok = bool(out) and commit is not None and all(d.get("build_commit") == commit for d in out)
    return {"daemons": out, "bundled_commit": commit, "of_build_under_test": ok}


def step_quit_speed(j, step):
    """QUIT P0 speed: COUNT quit-and-reopen cycles of kind HOW (default quit-keep: the File menu's Quit, Keep
    Sessions, no dialog), each through ext_restore's restore_relaunch (the visible panes sampled from the new
    process's first socket answer, about every 20 ms: the sampler's own reads add main-thread work to the launch it
    measures, the same on both arms of an A/B). Per cycle, all from the new process's main() (the launch marks and
    the samples share the kernel's process start and the wall clock):
      first_frame_ms   `terminal.launch_frame_shown`: the FIRST pane got its saved frame (the app records it once)
      all_frames_ms    the slowest visible terminal pane's first sample with content (its held last frame or its
                       replayed screen): every visible terminal shows its last frame
      window_frame_ms  `first_window_frame_committed`
      interactive_ms   the slowest visible terminal live (attached, connected, its screen replayed); a cycle where
                       one never went live within the sampler's 20 s is `censored` (never dropped: a p95 counts it
                       as slower than 20 s)
      quit_to_gone_ms  the quit request to the old process's end (the driver's 250 ms poll: a coarse number)
    Both arms are WARM (the app ran in this lease before): `warm-first` is cycle 1, `warm-again` the rest. A cycle
    whose window was occluded (a capture slot's other windows over it: AppKit stops drawing) is marked `occluded`
    and is not evidence; run it on a whole-host lease (run.py --whole-host). Writes speed.json and each cycle's
    restore-trace-N.json; fails when a cycle did not reopen."""
    import ext_restore
    rows = []
    for index in range(int(step.get("count", 3))):
        daemons_before = daemon_builds(j)
        record = ext_restore.step_restore_relaunch(j, {"how": step.get("how", "quit-keep")})
        r = getattr(j, "restore", None) or {}
        trace_file = j.out / "restore-trace.json"
        if trace_file.exists():
            trace_file.replace(j.out / f"restore-trace-{index + 1}.json")
        marks = {}
        try:
            marks = (j.app.rpc("debug.timings", timeout=10) or {}).get("launch_ms_since_process_start") or {}
        except (D.StepError, OSError, ValueError):
            pass
        main = r.get("main_start")
        sub = lambda mark: round(mark - main, 1) if isinstance(mark, (int, float)) and isinstance(main, (int, float)) else None
        first_content = {}
        trace = r.get("trace") or []
        for at, panes in trace:
            for row in panes:
                pane, held, replayed = row[0], row[1], row[2]
                has_text = bool(row[6]) if len(row) > 6 else True
                kind = row[7] if len(row) > 7 else "terminal"
                # The blank rule of restore_no_blank: its held last frame, or its replayed screen with text.
                if kind == "terminal" and (held or (replayed and has_text)) and pane not in first_content and at is not None:
                    first_content[pane] = at
        visible = int(r.get("visible_terminals") or 0)
        live = list((r.get("live_from_main_ms") or {}).values())
        censored = not live or len(live) < visible
        occluded = False
        try:
            occluded = any(p.get("window_occluded") for p in j.app.panes() if p.get("visible"))
        except (D.StepError, OSError, ValueError):
            pass
        rows.append({"cycle": index + 1, "arm": "warm-first" if index == 0 else "warm-again",
                     "quit_to_gone_ms": round(record["ended_after_s"] * 1000, 1) if record.get("ended_after_s") is not None else None,
                     "first_frame_ms": sub(marks.get("terminal.launch_frame_shown", r.get("launch_frame_shown"))),
                     "frame_missed": marks.get("terminal.launch_frame_missed"),
                     "all_frames_ms": sub(max(first_content.values())) if len(first_content) >= visible > 0 else None,
                     "frames_censored": not (len(first_content) >= visible > 0),
                     "window_frame_ms": sub(r.get("first_window_frame_committed")),
                     "interactive_ms": None if censored else max(live), "censored": censored,
                     "visible_terminals": visible, "samples": r.get("samples"), "blank_pane_samples": r.get("blank_pane_samples"),
                     "occluded": occluded, "socket_ms": r.get("socket_ms"), "main_start_ms": main,
                     # A cycle whose daemons are not all of the build under test is not run (cmux-ad 01:25Z).
                     "daemons_before": daemons_before, "daemons_after": daemon_builds(j)})
        rows[-1]["not_run"] = not (rows[-1]["daemons_before"]["of_build_under_test"]
                                   and rows[-1]["daemons_after"]["of_build_under_test"])
        (j.out / "speed.json").write_text(json.dumps({"how": step.get("how", "quit-keep"), "rows": rows}, indent=1) + "\n")
    return {"rows": rows, "summary": {"cycles": len(rows), "censored": sum(1 for x in rows if x["censored"]),
                                      "frames_censored": sum(1 for x in rows if x["frames_censored"]),
                                      "occluded": sum(1 for x in rows if x["occluded"]),
                                      "not_run_daemon_build": sum(1 for x in rows if x["not_run"])}}


STEPS = {"quit_state": step_quit_state, "quit_speed": step_quit_speed, "real_quit": step_real_quit, "require_whole_host": step_require_whole_host,
         "quit_why": step_quit_why, "require_prior": step_require_prior, "require_daemon_prior": step_require_daemon_prior}
CONDITIONS = {"quit_asked": ("app", cond_quit_asked), "daemon_kept": ("process", cond_daemon_kept),
              "workspaces_back": ("app", cond_workspaces_back), "scrollback_whole": ("daemon", cond_scrollback_whole),
              "helpers_kept": ("process", cond_helpers_kept), "daemon_is_prior": ("process", cond_daemon_is_prior),
              "daemon_handed_off": ("process", cond_daemon_handed_off)}
