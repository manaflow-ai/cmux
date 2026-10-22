"""perf100 app scenarios S0-S4 against a tagged cmux NEXT bundle (GUI host only).

Every scenario launches the bundle on a new scratch profile, builds its state over the control
socket, measures, then quits with `quitEndSessions` and sweeps (appdriver.App.stop / sweep).
Latency probes run after the resource windows, so their socket reads do not count in them.
"""
from __future__ import annotations

import json
import os
import random
import subprocess
import sys
import threading
import time

import appdriver
import procstat
import runlib

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures")
sys.path.insert(0, FIXTURES)
import pages  # noqa: E402


def _python() -> str:
    return "/usr/bin/python3" if os.path.exists("/usr/bin/python3") else sys.executable


def _fifo_wait(paths: list[str], timeout: float) -> list[float | None]:
    t0 = time.monotonic()
    done: list[float | None] = [None] * len(paths)

    def reader(i, path):
        with open(path, "rb") as handle:  # blocks until the shell in the terminal writes it
            handle.read()
        done[i] = time.monotonic() - t0

    threads = [threading.Thread(target=reader, args=(i, p), daemon=True) for i, p in enumerate(paths)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=max(0.0, timeout - (time.monotonic() - t0)))
    return done


def _fifo_release(paths: list[str], timeout: float):
    """Writes one line to each go FIFO; each open blocks until its shell reads it (no race)."""

    def writer(path):
        with open(path, "w") as handle:
            handle.write("go\n")

    threads = [threading.Thread(target=writer, args=(p,), daemon=True) for p in paths]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=timeout)


def _key_latency(app: appdriver.App, run: runlib.Run, samples: int, rng: random.Random, name: str):
    if app.focus_terminal() is None:
        run.note(f"{name}: no terminal tab in the focused workspace")
    values = []
    for _ in range(samples):
        marker = "".join(rng.choice("qwzx") for _ in range(4))
        ms = app.key_echo_ms(marker, timeout=10)
        if ms is not None:
            values.append(ms)
    run.latency(name, values)
    if len(values) < samples:
        run.note(f"{name}: {samples - len(values)} of {samples} keys never showed on the terminal")


def _end(app: appdriver.App, run: runlib.Run, prefix: str = "stop"):
    try:
        run.metric(f"{prefix}.quit_ms", round(app.stop() or 0, 1) or None)
    finally:
        app.sweep()
    run.data.setdefault("on_disk", {})[prefix] = procstat.du(app.home)
    run.metric(f"disk.{prefix}.home_mb", run.data["on_disk"][prefix]["allocated_mb"])
    for sub in ("Library/Application Support", ".local/state", ".cmux", ".acpmux"):
        path = os.path.join(app.home, sub)
        if os.path.isdir(path):
            for name in sorted(os.listdir(path)):
                usage = procstat.du(os.path.join(path, name))
                if usage["allocated_mb"] >= 0.1:
                    run.data["on_disk"].setdefault(f"{prefix}.tree", {})[f"{sub}/{name}"] = usage


def run_app(args, build: dict, out_dir: str) -> list[str]:
    paths = []
    for scenario in args.scenarios.split(","):
        rng = random.Random(f"{args.seed}-{scenario}")
        run = runlib.Run(scenario, "app", args.seed, vars(args), build, args.host_class)
        run.apps = []
        try:
            fn = {"S0": s0, "S1": s1, "S2": s2, "S3": s3, "S4": s4}[scenario]
            fn(args, run, rng)
        except (Exception, SystemExit) as error:  # noqa: BLE001 - recorded; the next scenario runs
            run.data["error"] = repr(error)
        finally:
            for app in run.apps:
                try:
                    if app.pid is not None:
                        _end(app, run)
                    else:
                        app.sweep()  # a quit kept its sessions, or the launch failed: stop what is left
                except Exception as error:  # noqa: BLE001
                    run.data.setdefault("teardown_error", repr(error))
                if not args.keep_scratch:
                    app.cleanup()
            paths.append(run.write(out_dir))
            print(f"perf100: {scenario} done ({run.data.get('error') or 'ok'})", flush=True)
    return paths


def _new_app(args, run: runlib.Run, allow_agents: bool = False) -> appdriver.App:
    app = appdriver.App(args.app, allow_agents=allow_agents)
    run.apps.append(app)
    return app


def _launch(args, run: runlib.Run, allow_agents: bool = False) -> appdriver.App:
    app = _new_app(args, run, allow_agents)
    run.metric("launch.socket_ms", round(app.launch(), 1))
    launch = app.wait_first_terminal()
    for key in ("first_window_frame_committed", "first_terminal_surface_created"):
        if key in launch:
            run.metric(f"launch.{key}_ms", round(launch[key], 1))
    return app


def _idle_window(run, app, name, seconds, settle, per=None):
    time.sleep(settle)  # bench: let launch and setup work finish before the idle window
    window = procstat.Tracker(app.discover).start()
    time.sleep(seconds)  # bench: the measured idle window
    entry = run.phase(name, window.stop())
    if per:
        for unit, count, groups in per:
            units = runlib.per_unit(entry["groups"], count, unit, groups)
            entry.setdefault("per_unit", {}).update(units)
            for key, value in units[unit].items():
                run.metric(f"{name}.per_{unit}.{key}", value)
    return entry


def s0(args, run, rng):
    """App open, 10 terminals with idle shells, 3 idle agent TUIs, 5 browser tabs; 60 s idle."""
    urls, server = pages.serve(args.seed)
    app = _launch(args, run)
    # Top up to `terminals` terminal tabs (the launch tab need not be one), each shown once, as
    # Cmd-T does, so its terminal starts.
    while len(app.tabs("terminal")) < args.terminals:
        app.act("newSurface", focus=True)
    run.metric("setup.terminals", len(app.tabs("terminal")))
    for i in range(args.agent_tuis):
        app.act("newSurface", focus=True)
        error = app.send_text(f"exec {_python()} {os.path.join(FIXTURES, 'idle_tui.py')} {rng.randrange(1000)}\n")
        if error:
            run.note(f"S0: idle agent TUI {i}: {error}")
    for url in urls[: args.tabs]:
        # focus: a background browser tab does not load until it is shown (xbench, bench_memory).
        app.act("openBrowser.chromium", focus=True, url=url)
    app.focus_terminal()  # rest on the first terminal, as a user would
    _idle_window(run, app, "idle", args.idle, args.settle,
                 per=[("terminal", args.terminals + args.agent_tuis, ("tui",)), ("tab", args.tabs, ("browser",))])
    _key_latency(app, run, args.latency_samples, rng, "keystroke_to_glyph")
    server.shutdown()
    return app


def s1(args, run, rng):
    """`yes | head -c <flood_mb>M` in 1 terminal, then in `flood_terminals` terminals at once."""
    app = _launch(args, run)
    size = int(args.flood_mb * 1048576)
    fifo_dir = os.path.join(app.scratch, "fifo")
    os.makedirs(fifo_dir)
    for phase, count in (("flood1", 1), (f"flood{args.flood_terminals}", args.flood_terminals)):
        if phase != "flood1":
            app.new_workspace()
        fifos, gos = [], []
        for i in range(count):
            # A new terminal tab each (the launch tab need not be a terminal).
            app.act("newSurface", focus=True)
            fifo = os.path.join(fifo_dir, f"{phase}-{i}")
            go = os.path.join(fifo_dir, f"{phase}-{i}.go")
            os.mkfifo(fifo)
            os.mkfifo(go)
            fifos.append(fifo)
            gos.append(go)
            # The shell waits on its own go FIFO, so every flood starts together.
            command = f"read _ < '{go}'; LC_ALL=C yes | head -c {size}; printf done > '{fifo}'\n"
            error = app.send_text(command)
            if error:
                raise RuntimeError(f"{phase}: send to terminal {i}: {error}")
        window = procstat.Tracker(app.discover, interval=0.5).start()
        t0 = time.monotonic()
        _fifo_release(gos, timeout=60)
        done = _fifo_wait(fifos, timeout=args.flood_timeout)
        wall = time.monotonic() - t0
        entry = run.phase(phase, window.stop())
        finished = [d for d in done if d is not None]
        run.metric(f"{phase}.wall_s", round(wall, 2))
        run.metric(f"{phase}.finished", len(finished))
        if finished:
            run.metric(f"{phase}.throughput_mb_s", round(len(finished) * args.flood_mb / max(finished), 1))
        cmux = entry["groups"].get("cmux", {})
        run.metric(f"{phase}.cmux_cpu_s_per_100mb", round(cmux.get("cpu_s", 0) / (count * args.flood_mb / 100), 3))
        run.metric(f"{phase}.cmux_disk_written_per_output_mb", round(cmux.get("disk_written_mb", 0) / (count * args.flood_mb), 4))
        if len(finished) < count:
            run.note(f"{phase}: {count - len(finished)} of {count} floods did not report within {args.flood_timeout} s")
    run.note("S1: the terminals are tabs of one pane: one is visible, the others ingest output in the daemon only")
    _idle_window(run, app, "after", min(args.idle, 30), args.settle)
    return app


def s2(args, run, rng):
    """`agents` agent sessions on the replay agent stream recorded Markdown replies at once."""
    app = _launch(args, run, allow_agents=True)
    agent_dir = os.path.join(app.scratch, "agent")
    os.makedirs(agent_dir)
    import shutil
    for name in ("replay_agent.py", "streams.py"):
        shutil.copy(os.path.join(FIXTURES, name), os.path.join(agent_dir, name))
    shutil.copytree(os.path.join(FIXTURES, "agent-streams"), os.path.join(agent_dir, "agent-streams"))
    script = os.path.join(agent_dir, "replay_agent.py")
    added = app.actions.run("agent.harness.add", id="perf100", name="perf100 replay", command=_python(),
                            args=script, protocol="acp", replace="true")
    if added.get("error") or added.get("code"):
        raise RuntimeError(f"agent.harness.add: {added}")
    env = dict(app._cli_env(), ACPMUX_SOCKET=app.acpmux_socket())

    def acp(*argv, timeout=120):
        return subprocess.run([app.cli, "acp", *argv], capture_output=True, text=True, timeout=timeout, env=env)

    sessions = []
    t0 = time.monotonic()
    for i in range(args.agents):
        made = acp("new", "--json", "-d", "-m", "perf100", f"perf100 session {i}")
        try:
            sid = _session_id(made.stdout)
        except (ValueError, KeyError, IndexError):
            raise RuntimeError(f"acp new: {(made.stdout + made.stderr)[-300:]}")
        opened = app.act("agent.openSessionWorkspace", session=sid)
        ws = next((c for c in opened.get("created", []) if str(c).startswith("ws_")), None)
        sessions.append({"sid": sid, "workspace": ws})
    run.metric("setup.agents", len(sessions))
    run.metric("setup.seconds", round(time.monotonic() - t0, 2))
    if sessions and sessions[-1]["workspace"]:
        app.act("goToWorkspace", focus=True, workspace=sessions[-1]["workspace"])
    _idle_window(run, app, "idle", min(args.idle, 30), args.settle,
                 per=[("session", len(sessions), ("cmux", "acpmux", "browser", "agents"))])
    fixtures = ["prose-8k", "mixed-24k", "code-48k"]
    done = []
    for i in range(len(sessions)):
        done.append(os.path.join(app.scratch, f"done-{i}"))
        os.mkfifo(done[-1])
    window = procstat.Tracker(app.discover).start()
    t0 = time.monotonic()
    for i, s in enumerate(sessions):
        fixture = fixtures[rng.randrange(len(fixtures))] if args.stream == "seeded" else args.stream
        acp("send", "--no-wait", s["sid"], f"perf100 stream={fixture} speed={args.speed} tag={i} done={done[i]}")
    ended = _fifo_wait(done, timeout=args.stream_timeout)
    run.metric("stream.sessions_ended", sum(1 for e in ended if e is not None))
    wall = time.monotonic() - t0
    entry = run.phase("stream", window.stop())
    run.metric("stream.wall_s", round(wall, 2))
    cmux = entry["groups"].get("cmux", {})
    run.metric("stream.cmux_cpu_s_per_session", round(cmux.get("cpu_s", 0) / max(len(sessions), 1), 4))
    run.metric("stream.cmux_disk_written_mb_per_session",
               round(cmux.get("disk_written_mb", 0) / max(len(sessions), 1), 4))
    # Token-to-page on the visible agent pane, apart from the resource window (its reads cost app
    # CPU): agent write to the marker in the pane's chat state (debug.agent_pane chat_state, read
    # every 5 ms). The pane's paint after that is not in it.
    if sessions:
        log = os.path.join(app.scratch, "marks.jsonl")
        probe_done = os.path.join(app.scratch, "done-probe")
        os.mkfifo(probe_done)
        acp("send", "--no-wait", sessions[-1]["sid"],
            f"perf100 stream=prose-8k speed={args.speed} marks={args.marks} tag=probe log={log} done={probe_done}")
        seen = _watch_page_for_marks(app, args.marks, timeout=60)
        emitted = {}
        try:
            with open(log) as handle:
                for line in handle:
                    e = json.loads(line)
                    emitted[e["mark"]] = e["t"]
        except (OSError, ValueError):
            pass
        run.latency("token_to_page", [(seen[m] - t) * 1000 for m, t in emitted.items() if m in seen])
        if not seen:
            # Evidence for the next fix: which pages exist and what the probe read.
            try:
                diag = appdriver.Rpc(app.socket)
                run.data["token_probe_debug"] = {
                    "pages": diag.result("debug.page", {"action": "list"}),
                    "chat_state": json.dumps(diag.result("debug.agent_pane", {"action": "chat_state"}))[-3000:],
                }
                diag.close()
            except Exception as error:  # noqa: BLE001
                run.data["token_probe_debug"] = repr(error)
        if len(seen) < len(emitted) or not emitted:
            run.note(f"token_to_page: {len(seen)} of {len(emitted)} markers seen in the agent pane")
        _fifo_wait([probe_done], timeout=120)
    run.unverified("token-to-screen pixels: S2 measures token-to-page (the agent pane's chat state); the paint "
                   "after it is not measured")
    return app


def _watch_page_for_marks(app, marks: int, timeout: float) -> dict[str, float]:
    """debug.page state of the agent page until every marker shows; {mark: first time seen}."""
    seen: dict[str, float] = {}
    deadline = time.monotonic() + timeout
    rpc = appdriver.Rpc(app.socket)
    try:
        while time.monotonic() < deadline and len(seen) < marks:
            # The agent pane's own chat state (webviews automation.ts chatState): the last
            # assistant message as the page holds it to render, through debug.agent_pane.
            state = rpc.result("debug.agent_pane", {"action": "chat_state"})
            now = time.time()
            text = json.dumps(state)
            start = 0
            while True:
                i = text.find("[pm:probe:", start)
                if i < 0:
                    break
                j = text.find("]", i)
                if j < 0:
                    break
                seen.setdefault(text[i:j + 1], now)
                start = j + 1
            time.sleep(0.005)  # bench: next read of the page (bounded by the deadline)
    finally:
        rpc.close()
    return seen


def s3(args, run, rng):
    """`workspaces` workspaces with `per_workspace` terminals each (capped by free PTYs)."""
    app = _launch(args, run)
    _build_scale(app, run, args)
    _key_latency(app, run, args.latency_samples, rng, "keystroke_to_glyph")
    return app


def _build_scale(app, run, args) -> int:
    workspaces, per = args.workspaces, args.per_workspace
    cap = _pty_cap(args)
    if cap is not None and workspaces * per > cap:
        per = max(1, cap // workspaces)
        if workspaces * per > cap:
            workspaces = cap
        run.note(f"S3: {args.workspaces} x {args.per_workspace} terminals exceed the PTYs this job may take ({cap}); "
                 f"ran {workspaces} x {per}")
        run.unverified(f"S3 at {args.workspaces * args.per_workspace} terminals in the app: PTY cap {cap} on this host")
    window = procstat.Tracker(app.discover, interval=2.0).start()
    t0 = time.monotonic()
    for w in range(workspaces):
        if w:
            app.new_workspace()
        for _ in range(per - 1):
            app.act("newSurface", focus=True)
    create_s = time.monotonic() - t0
    run.phase("create", window.stop())
    total = workspaces * per
    run.metric("create.workspaces", workspaces)
    run.metric("create.terminals", total)
    run.metric("create.seconds", round(create_s, 2))
    _idle_window(run, app, "idle", args.idle, args.settle,
                 per=[("terminal", total, ("cmux", "tui", "app")), ("workspace", workspaces, ("cmux", "app"))])
    return total


def _pty_cap(args) -> int | None:
    try:
        ptmx = int(runlib.sh(["sysctl", "-n", "kern.tty.ptmx_max"]))
    except ValueError:
        return None
    in_use = sum(1 for name in os.listdir("/dev") if name.startswith("ttys") and name[4:].isdigit())
    # nx-remote refuses GUI jobs under 50 free PTYs: leave other jobs `pty_reserve`.
    return max(1, min(args.pty_budget, ptmx - in_use - args.pty_reserve))


def s4(args, run, rng):
    """Cold start to interactive, quit, then restart with an S3-sized session."""
    # Cold start: a new profile, no daemon.
    app = _new_app(args, run)
    t0 = time.monotonic()
    run.metric("cold.socket_ms", round(app.launch(), 1))
    # The first window frame, not the first terminal: a launch window may show no terminal at all.
    launch = app.wait_first_terminal(timeout=60, mark="first_window_frame_committed")
    for key in ("first_window_frame_committed", "first_terminal_surface_created"):
        if key in launch:
            run.metric(f"cold.{key}_ms", round(launch[key], 1))
    if app.focus_terminal() is None:
        # The launch window shows no terminal tab: open one, as a user's Cmd-T (counted in the time).
        app.act("newSurface", focus=True)
        run.note("S4 cold: the launch window had no terminal tab; launch-to-interactive includes a New Tab")
        app.focus_terminal()
    ms = app.key_echo_ms("".join(rng.choice("qwzx") for _ in range(4)), timeout=60)
    run.metric("cold.launch_to_interactive_ms", round((time.monotonic() - t0) * 1000, 1) if ms is not None else None)
    run.data.setdefault("latency", {})["launch_to_interactive"] = {"cold_ms": run.data["metrics"].get("cold.launch_to_interactive_ms")}
    if run.data["metrics"].get("cold.launch_to_interactive_ms") is not None:
        run.metric("latency.launch_to_interactive.cold_ms", run.data["metrics"]["cold.launch_to_interactive_ms"])
    run.metric("cold.quit_end_sessions_ms", round(app.stop() or 0, 1) or None)
    app.sweep()
    # Restart with the S3 session: build it, quit keeping sessions, launch on the same profile.
    app = _new_app(args, run)
    app.launch()
    app.wait_first_terminal()
    total = _build_scale(app, run, args)
    window = procstat.Tracker(app.discover, interval=0.5).start()
    quit_ms = app.stop(end_sessions=False)
    run.metric("restart.quit_keep_sessions_ms", round(quit_ms, 1) if quit_ms else None)
    t0 = time.monotonic()
    app.launch()
    app.wait_first_terminal()
    app.focus_terminal()
    ms = app.key_echo_ms("".join(rng.choice("qwzx") for _ in range(4)), timeout=120)
    interactive = (time.monotonic() - t0) * 1000 if ms is not None else None
    restored = None
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        if app.workspace_count() >= run.data["metrics"].get("create.workspaces", 1):
            restored = (time.monotonic() - t0) * 1000
            break
        time.sleep(0.05)  # bench: next topology read (bounded)
    run.phase("restart", window.stop())
    run.metric("restart.launch_to_interactive_ms", round(interactive, 1) if interactive else None)
    run.metric("restart.launch_to_all_workspaces_ms", round(restored, 1) if restored else None)
    run.metric("restart.terminals", total)
    if interactive:
        run.metric("latency.launch_to_interactive.restart_ms", round(interactive, 1))
    run.unverified("S4 restart-to-update: quit with sessions kept and launch of the same build; the Sparkle "
                   "install and UpdateWindowHandoff path are not exercised")
    return app


def _session_id(stdout: str) -> str:
    """The sessionId of `acp new --json` (one JSON object, possibly pretty-printed)."""
    text = stdout.strip()
    try:
        return json.loads(text)["sessionId"]
    except (ValueError, KeyError, TypeError):
        start = text.rfind("\n{")
        return json.loads(text[start + 1:] if start >= 0 else text)["sessionId"]
