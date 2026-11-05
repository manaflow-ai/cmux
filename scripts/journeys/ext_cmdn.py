"""CMD-N FIRST FRAME and CMD-N LATENCY steps for the journeys (journeys/perf/cmdn-*.json): the app's own timing
of a person's Cmd-N (debug.new_tab bench_create), light and STRESS-lite, with per-press probes and an Instruments
Time Profiler recording. Not a CI job, step or gate.

driver.py loads this file (load_extensions) on the mini, under the stock /usr/bin/python3 (3.9, standard library
only). It must not import driver.py: install() gets the driver module instead.

Steps (`do`):
  base_terminal                       a shown, focused terminal to press Cmd-N from (Ctrl-`, else a script's newTab)
  latency_runs  {bench, command, runs, label, gap, runs_option?, hangs?, cpu?, counters?}
                                      timed presses measured by the app (key_ms, visible_ms, confirmed_ms, spans)
  sample_presses {runs, seconds, min_count, label}
                                      per press, /usr/bin/sample of the app (1 ms), the main thread's call graph
  xctrace_presses {runs, gap, window_ms, top, label}
                                      presses under one `xctrace record --template "Time Profiler" --all-processes`;
                                      each press's main-thread samples on the bench's clock, by phase and 5 ms bin
  grow_workspaces {count, busy}       STRESS-lite set-up: script workspaces and busy terminals, then the base
                                      terminal shown and focused again
"""
import json
import re
import shutil
import signal
import subprocess
import threading
import time

BUSY_COMMAND = 'while :; do echo "$RANDOM $RANDOM $RANDOM stress output line $(date +%s)"; sleep 0.02; done\r'


def install(driver):
    global D, StepError, now
    D = driver
    StepError, now = driver.StepError, driver.now

_THREAD_FMT = re.compile(r"^(.*?)\s+0x[0-9a-fA-F]+\s+\((.*?),\s*pid:\s*(\d+)\)")
_OURS = re.compile(r"CmuxNext|Cmux[A-Z]|cmux|WorkspaceSpawn|ShellWindow|LayoutRootView|ScreenContentView|PaneHostView|AgentPane|FocusEffect")
_HANDLER = re.compile(r"WorkspaceSpawner\.start|startWorkspace|AppActions\.newWorkspace|newWorkspace\(")


def _xctrace_main_samples(path, pid):
    """[(t_ns, weight_ns, frames leaf first)] of the main thread of process `pid` in an exported time-profile table
    (streamed; `ref` cells resolved). Frames are names; the leaf is first."""
    import xml.etree.ElementTree as ET
    ids, vals, columns, out = {}, {}, [], []
    for event, elem in ET.iterparse(str(path), events=("start", "end")):
        if event == "start":
            if elem.tag == "node":
                ids.clear()
            continue
        tag = elem.tag
        if tag == "schema":
            columns = [(col.findtext("mnemonic") or "").strip() for col in elem.findall("col")]
            continue
        if tag == "row":
            cells = {}
            for index, child in enumerate(list(elem)):
                key = columns[index] if index < len(columns) and columns[index] else child.tag
                cells[key] = vals.get(id(child))
                cells.setdefault(child.tag, vals.get(id(child)))
            thread = cells.get("thread")
            if isinstance(thread, dict) and thread.get("pid") == pid and str(thread.get("name", "")).startswith("Main Thread"):
                t = cells.get("time") if cells.get("time") is not None else cells.get("sample-time")
                weight = cells.get("weight")
                stack = cells.get("stack") or cells.get("backtrace") or cells.get("tagged-backtrace") or cells.get("kperf-bt") or ()
                if isinstance(t, int):
                    out.append((t, weight if isinstance(weight, int) else 1_000_000, stack if isinstance(stack, tuple) else ()))
            vals.clear()
            elem.clear()
            continue
        ref = elem.get("ref")
        if ref is not None:
            value = ids.get(ref)
        else:
            if tag == "frame":
                value = elem.get("name") or elem.get("addr") or "?"
            elif tag == "backtrace":
                value = tuple(vals.get(id(c)) or "?" for c in elem if c.tag == "frame")
            elif tag in ("tagged-backtrace", "kperf-bt"):
                value = next((vals.get(id(c)) for c in elem if c.tag == "backtrace"), ())
            elif tag in ("tid", "pid"):
                try:
                    value = int(elem.text)
                except (TypeError, ValueError):
                    value = None
            elif tag == "process":
                value = {"pid": next((vals.get(id(c)) for c in elem if c.tag == "pid"), None)}
            elif tag == "thread":
                process = next((vals.get(id(c)) for c in elem if c.tag == "process"), None) or {}
                m = _THREAD_FMT.match(elem.get("fmt") or "")
                name = m.group(1).strip() if m else (elem.get("fmt") or "")
                tpid = process.get("pid") if process.get("pid") is not None else (int(m.group(3)) if m else None)
                value = {"name": name, "pid": tpid}
            else:
                try:
                    value = int(elem.text) if elem.text is not None else None
                except ValueError:
                    value = elem.text
            if elem.get("id") is not None:
                ids[elem.get("id")] = value
        vals[id(elem)] = value
    out.sort(key=lambda x: x[0])
    return out


def xctrace_press_profiles(xml, pid, replies, window_ms=300.0, top=30):
    """Per press (``step_xctrace_presses``): the main thread's samples on the bench's clock and where they went."""
    samples = _xctrace_main_samples(xml, pid)
    # Each press's first handler sample (presses are over a second apart).
    starts = []
    for t, _w, stack in samples:
        if any(_HANDLER.search(f or "") for f in stack) and (not starts or t - starts[-1] > 500_000_000):
            starts.append(t)
    result = {"main_samples": len(samples), "presses_found": len(starts), "presses": len(replies), "rows": []}
    for index, reply in enumerate(replies):
        if index >= len(starts):
            break
        spans = reply.get("spans") or []
        anchor = next((sp.get("at") for sp in spans if sp.get("name") == "cmdN.start"), 0.5) or 0.5
        t0 = starts[index] - int(anchor * 1e6)  # the bench's 0 on the trace clock
        visible = reply.get("visible_ms") or window_ms
        phases = {}
        bins = {}
        for t, weight, stack in samples:
            at = (t - t0) / 1e6
            if at < -2 or at > window_ms:
                continue
            phase = "before_visible" if at < visible else "after_visible"
            ph = phases.setdefault(phase, {"ms": 0.0, "incl": {}, "self": {}})
            ms = weight / 1e6
            ph["ms"] += ms
            leaf = stack[0] if stack else "?"
            ph["self"][leaf] = ph["self"].get(leaf, 0.0) + ms
            for name in set(stack):
                ph["incl"][name] = ph["incl"].get(name, 0.0) + ms
            key = int(at // 5) * 5
            b = bins.setdefault(key, {"ms": 0.0, "ours": {}})
            b["ms"] += ms
            ours = next((f for f in stack if _OURS.search(f or "")), leaf)
            b["ours"][ours] = b["ours"].get(ours, 0.0) + ms
        row = {"run": index, "visible_ms": reply.get("visible_ms"), "frames_to_visible": reply.get("frames_to_visible"),
               "key_ms": reply.get("key_ms"), "confirmed_ms": reply.get("confirmed_ms"), "frames": reply.get("frames"),
               "spans": spans, "phases": {}, "bins": []}
        for phase, ph in phases.items():
            row["phases"][phase] = {
                "ms": round(ph["ms"], 1),
                "incl": [[round(v, 1), k[:180]] for k, v in sorted(ph["incl"].items(), key=lambda kv: -kv[1])[:top]],
                "self": [[round(v, 1), k[:180]] for k, v in sorted(ph["self"].items(), key=lambda kv: -kv[1])[:15]],
            }
        for key in sorted(bins):
            b = bins[key]
            row["bins"].append([key, round(b["ms"], 1)] + [[round(v, 1), k[:140]] for k, v in sorted(b["ours"].items(), key=lambda kv: -kv[1])[:3]])
        # The press's raw samples (leaf first, the run-loop roots cut), names through one string table.
        table, index_of, raw = [], {}, []
        for t, weight, stack in samples:
            at = (t - t0) / 1e6
            if at < -2 or at > window_ms:
                continue
            cut = list(stack)
            for i, name in enumerate(cut):
                if name in ("-[NSApplication run]", "__CFRunLoopRun", "CmuxNextApp.main()"):
                    cut = cut[:i]
                    break
            ids = []
            for name in cut[:60]:
                if name not in index_of:
                    index_of[name] = len(table)
                    table.append(name[:160])
                ids.append(index_of[name])
            raw.append([round(at, 2), round(weight / 1e6, 2), ids])
        row["raw"] = {"names": table, "samples": raw}
        result["rows"].append(row)
    return result


def base_terminal(j, step):
    """Set-up: a shown, focused terminal to press Cmd-N from. The person's Ctrl-` first; when no focused terminal
    shows within 8 s (an older build's first-run page), a script's newTab with focus, as
    instant-new-surfaces-bench.py's ensure_terminal."""
    tried = []
    for how in ("key", "script"):
        if how == "key":
            j.key("`", ["control"], None)
        else:
            j.app.rpc("action.run", {"action": "newTab", "args": {"focus": True, "name": f"cmdn-base-{j.nonce}"}, "wait": True})
        end = now() + (8 if how == "key" else 20)
        while now() < end:
            pane = focused_pane(j)
            if pane.get("kind") == "terminal":
                j.term, j.host_pid = pane.get("terminal_id") or j.term, pane.get("host_pid") or j.host_pid
                j.pane = pane.get("pane") or pane.get("id") or j.pane
                time.sleep(1.0)
                return {"via": how, "tried": tried, "terminal": j.term}
            time.sleep(0.2)
        tried.append(how)
    raise StepError(f"no focused terminal after {tried}")


def focused_pane(j):
    report = j.app.rpc("debug.surfaces", {}) or {}
    return next((p for w in report.get("windows", []) for p in w.get("panes", [])
                 if isinstance(p, dict) and p.get("focused")), None) or {}


def latency_runs(j, step):
    """`runs` timed presses measured by the app itself, the warm arm of instant-new-surfaces-bench.py:
    `bench: create` is `debug.new_tab {action: bench_create, command}` (the key through debug.key; key_ms,
    visible_ms: the first display frame that shows the result, confirmed_ms: the daemon's object in place),
    then 0.4 s, `closeWorkspace` (Cmd-N) or the tab's Cmd-W, a wait for a focused terminal, 1 s;
    `bench: prompt` is `debug.new_terminal_trace {action: run}` (newSurface as the person's, its marks up to
    prompt_contents, the first visible prompt; the app closes the tab). Each reply is kept whole."""
    bench, rows = step.get("bench", "create"), []
    # `runs_option`: a run.py --journey-option (e.g. presses=40) that overrides `runs`.
    runs = int((j.spec.get("options") or {}).get(step.get("runs_option", ""), step.get("runs", 20)))
    command = step.get("command", "new_workspace")
    for index in range(runs):
        t = now()
        if bench == "prompt":
            reply = j.app.rpc("debug.new_terminal_trace", {"action": "run", "timeout_ms": 10000}, timeout=25) or {}
            rows.append({"run": index, "wall_ms": round((now() - t) * 1000, 1), "reply": reply})
            time.sleep(float(step.get("gap", 1.0)))
            continue
        if step.get("hangs"):
            # debug.hangs: main-thread stalls over the watchdog threshold (50 ms in a launch without
            # CMUX_NEXT_HANG_THRESHOLD_MS), each with its sampled stack, and the heartbeat's longest gap.
            j.app.rpc("debug.hangs", {"clear": True})
            t = now()
        if step.get("counters"):
            j.app.rpc("debug.layout_counters", {"reset": True})
        if step.get("cpu"):
            j.app.rpc("debug.main_cpu", {"action": "start"})
        reply = j.app.rpc("debug.new_tab", {"action": "bench_create", "command": command}, timeout=25) or {}
        hangs = j.app.rpc("debug.hangs", {"limit": 8}) if step.get("hangs") else None
        if step.get("cpu"):
            reply["main_cpu"] = j.app.rpc("debug.main_cpu", {"action": "stop"})
        if step.get("counters"):
            time.sleep(0.25)
            reply["layout_counters"] = j.app.rpc("debug.layout_counters", {})
        kind = focused_pane(j).get("kind")
        rows.append({"run": index, "wall_ms": round((now() - t) * 1000, 1), "kind_after": kind, "reply": reply,
                     **({"hangs": hangs} if hangs is not None else {})})
        time.sleep(0.4)
        if command == "new_workspace":
            j.app.rpc("action.run", {"action": "closeWorkspace", "args": {"confirm": True}})
        else:
            j.app.rpc("debug.key", {"key": "w", "modifiers": ["command"]})
        end = now() + 10
        while now() < end and focused_pane(j).get("kind") != "terminal":
            time.sleep(0.1)
        time.sleep(float(step.get("gap", 1.0)))
    return {"bench": bench, "command": command, "label": step.get("label", ""), "rows": rows}


def sample_presses(j, step):
    """Profile: per Cmd-N press, `/usr/bin/sample` of the app (1 ms interval, `seconds` long) starts 0.3 s
    before the press; the press's main-thread call graph (lines with at least `min_count` samples) is kept
    with the press's own timing. The close waits until the sample ended, so it is not in the profile."""
    rows = []
    for index in range(int(step.get("runs", 10))):
        path = j.out / f"sample-{index:02d}.txt"
        proc = subprocess.Popen(["/usr/bin/sample", str(j.app.pid), str(step.get("seconds", 1)), "1", "-mayDie",
                                 "-file", str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        time.sleep(float(step.get("lead", 0.3)))
        reply = j.app.rpc("debug.new_tab", {"action": "bench_create", "command": "new_workspace"}, timeout=25) or {}
        try:
            err = proc.communicate(timeout=30)[1].decode(errors="replace")[-300:]
        except subprocess.TimeoutExpired:
            proc.kill()
            err = "sample timed out"
        main, keep = [], False
        try:
            # The call graph's first thread block is the main thread (sample lists it first); it ends at the
            # next thread's header line ("    <count> Thread_<id> ...").
            text = path.read_text(errors="replace")
            graph = text.split("Call graph:", 1)[1] if "Call graph:" in text else ""
            for line in graph.splitlines():
                if re.match(r"^\s{4}\d+ Thread_", line):
                    if keep:
                        break
                    keep = True
                if keep:
                    m = re.match(r"^[\s+!:|]*(\d+) ", line)
                    if m and int(m.group(1)) >= int(step.get("min_count", 2)):
                        main.append(line[:260])
            if not main:
                err += " no main thread block; head: " + text[:600]
            path.unlink()
        except Exception as error:  # noqa: BLE001 (a profile read never ends the journey)
            err += f" {error!r}"
        rows.append({"run": index, "reply": {k: reply.get(k) for k in ("key_ms", "visible_ms", "confirmed_ms", "frames_to_visible", "frames", "spans")},
                     "main": main[:int(step.get("max_lines", 400))], "sample_err": err})
        j.app.rpc("action.run", {"action": "closeWorkspace", "args": {"confirm": True}})
        end = now() + 10
        while now() < end and focused_pane(j).get("kind") != "terminal":
            time.sleep(0.1)
        time.sleep(0.8)
    return {"bench": "sample", "label": step.get("label", "sample"), "rows": rows}


def xctrace_presses(j, step):
    """Profile (CMD-N FIRST FRAME): `runs` Cmd-N presses under ONE Instruments Time Profiler recording of every
    process (`xctrace record --all-processes`, 1 ms kernel sampling; the close of each press is in it too, after
    its window). Each press's main-thread samples of the app go on the bench's own clock by the first sample
    inside the key's handler (`WorkspaceSpawner.start`, the `cmdN.start` span at about 0.5 ms), so each is in a
    phase (`before_visible`: the key to the first display tick that shows the workspace; `after_visible`, up
    to `window_ms`) and a 5 ms bin. Kept per press: its timing (spans, frames), the samples per phase, the
    heaviest frames (inclusive: ours and AppKit/QuartzCore/Chromium; self) per phase, and each bin's samples and
    deepest frame of ours."""
    xcrun = shutil.which("xcrun") or "/usr/bin/xcrun"
    trace = j.out / "presses.trace"
    shutil.rmtree(trace, ignore_errors=True)
    log = []
    rec = subprocess.Popen([xcrun, "xctrace", "record", "--template", "Time Profiler", "--all-processes",
                            "--time-limit", f"{int(step.get('cap_seconds', 120))}s", "--output", str(trace), "--no-prompt"],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    started = threading.Event()

    def read():
        for line in rec.stdout:
            log.append(line.rstrip()[:200])
            if "Starting recording" in line or "Ctrl-C to stop" in line:
                started.set()
        started.set()
    threading.Thread(target=read, daemon=True).start()
    started.wait(float(step.get("start_timeout", 120)))
    if rec.poll() is not None:
        return {"bench": "xctrace", "label": step.get("label", "xctrace"), "error": "xctrace record ended", "log": log[-20:]}
    time.sleep(1.0)
    replies = []
    for index in range(int(step.get("runs", 8))):
        reply = j.app.rpc("debug.new_tab", {"action": "bench_create", "command": "new_workspace"}, timeout=25) or {}
        replies.append(reply)
        time.sleep(0.4)
        j.app.rpc("action.run", {"action": "closeWorkspace", "args": {"confirm": True}})
        end = now() + 10
        while now() < end and focused_pane(j).get("kind") != "terminal":
            time.sleep(0.1)
        time.sleep(float(step.get("gap", 1.2)))
    rec.send_signal(signal.SIGINT)
    try:
        rec.wait(timeout=float(step.get("save_timeout", 240)))
    except subprocess.TimeoutExpired:
        rec.kill()
        log.append("xctrace save timed out")
    result = {"bench": "xctrace", "label": step.get("label", "xctrace"), "log": log[-12:], "rows": []}
    try:
        xml = j.out / "time-profile.xml"
        done = subprocess.run([xcrun, "xctrace", "export", "--input", str(trace), "--output", str(xml), "--xpath",
                               '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'],
                              capture_output=True, text=True, timeout=float(step.get("export_timeout", 300)))
        if done.returncode != 0:
            result["error"] = f"export exit {done.returncode}: {(done.stderr or done.stdout)[-400:]}"
        else:
            result.update(xctrace_press_profiles(xml, j.app.pid, replies, float(step.get("window_ms", 300)), int(step.get("top", 30))))
        xml.unlink(missing_ok=True)
    except Exception as error:  # noqa: BLE001 (a profile read never ends the journey)
        result["error"] = repr(error)[:400]
    shutil.rmtree(trace, ignore_errors=True)
    return result


def grow_workspaces(j, step):
    """STRESS-lite set-up: script workspaces (one terminal each; the app shows each new one) until the app holds
    `count`; then `busy` of them print a line every 20 ms (perf-stress-session.py's BUSY_COMMAND). At the end the
    journey's base terminal is shown and focused again (show_base_terminal)."""
    count, busy = int(step.get("count", 60)), int(step.get("busy", 10))
    def have():
        snap = j.app.rpc("snapshot.get") or {}
        topo = (snap.get("topology") or snap) if isinstance(snap, dict) else {}
        return [w.get("name") for w in topo.get("workspaces") or []]
    start, made = len(have()), []
    for index in range(start, count):
        name = f"stress-{j.nonce}-{index}"
        j.app.rpc("action.run", {"action": "newTab", "args": {"name": name}, "wait": True})
        made.append(name)
    keep = (j.term, j.pane, j.host_pid)
    busy_terms = []
    for name in made[:busy]:
        end = now() + 20
        while now() < end:
            try:
                term = daemon_terminal(j, name, None)
                if j.app.screen(term)["text"].strip():
                    break
            except StepError:
                term = None
            time.sleep(0.2)
        if term:
            j.app.cmux("terminal", term, "write", "--text", BUSY_COMMAND)
            busy_terms.append(term)
    j.term, j.pane, j.host_pid = keep
    names = have()
    if len(names) < count or len(busy_terms) < busy:
        raise StepError(f"STRESS-lite: {len(names)} workspaces (want {count}), {len(busy_terms)} busy (want {busy})")
    refocus = show_base_terminal(j) if made else None
    time.sleep(float(step.get("settle", 2.0)))
    return {"workspaces": len(names), "made": len(made), "busy": busy_terms, "refocus": refocus}


def show_base_terminal(j, timeout=20.0):
    """The app shows each workspace a script's newTab makes, so after the STRESS-lite set-up the last one has
    the keyboard (2026-11-04, DOGFOOD BENCH STATUS 11935: step 11 typed into stress-NONCE-59 on every round).
    Show the base terminal's workspace again, as the person's click on its row would, and wait until its pane
    has the focus; the STRESS-lite presses and the typing check then start from the same terminal as light."""
    # debug.surfaces (base_terminal) names the app's terminal id, the topology the daemon's: find the base
    # pane by its id, which both share (as focused_terminal does); the terminal id only as a second way.
    topo = j.topology()
    ws = next((w.get("id") for w, pane, tab, term in j.places(topo) if pane.get("id") == j.pane), None)
    if ws is None:
        place = j.place_of(j.term, topo)
        ws = place[0].get("id") if place else None
    if ws is None:
        raise StepError(f"STRESS-lite: the base pane {j.pane} (terminal {j.term}) is not in the topology")
    j.app.cmux("workspace", ws, "focus")
    end, last = now() + timeout, None
    while now() < end:
        last = focused_pane(j)
        if last.get("pane") == j.pane or (j.term and last.get("terminal_id") == j.term):
            return {"workspace": ws, "pane": j.pane}
        time.sleep(0.2)
    raise StepError(f"STRESS-lite: the base terminal's pane {j.pane} (workspace {ws}) has no focus "
                    f"{timeout:g} s after `cmux workspace {ws} focus`; focused: {last.get('pane') if last else None}")


def daemon_terminal(j, workspace_name, pane_key):
    """The daemon terminal id of the selected tab in `pane_key` of the workspace named `workspace_name`."""
    snap = j.app.rpc("snapshot.get") or {}
    topo = snap.get("topology") if isinstance(snap, dict) else None
    found = []
    for ws in (topo or {}).get("workspaces", []):
        if ws.get("name") != workspace_name:
            continue
        for screen in ws.get("screens", []):
            for pane in screen.get("panes", []):
                for tab in pane.get("tabs", []):
                    term = tab.get("terminal")
                    term = term.get("id") if isinstance(term, dict) else term
                    if term:
                        found.append((pane.get("id") == pane_key, bool(tab.get("selected")), str(term)))
    if not found:
        names = [w.get("name") for w in (topo or {}).get("workspaces", [])]
        sample = next((t for w in (topo or {}).get("workspaces", []) if w.get("name") == workspace_name
                       for s in w.get("screens", []) for p in s.get("panes", []) for t in p.get("tabs", [])), None)
        raise StepError(f"the topology has no terminal tab in a workspace named {workspace_name!r} "
                        f"(workspaces {names[:8]}, a tab {json.dumps(sample)[:300]})")
    return sorted(found, reverse=True)[0][2]


STEPS = {"base_terminal": base_terminal, "latency_runs": latency_runs, "sample_presses": sample_presses,
         "xctrace_presses": xctrace_presses, "grow_workspaces": grow_workspaces}
