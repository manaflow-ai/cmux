"""cmux NEXT resource budget: what one window with hidden terminals and browser tabs costs at idle.

xbench.py runs this as the browser `cmux-budget` (`--browsers cmux-budget`), so it shares xbench's
isolated launch (scratch HOME, TMPDIR and config, mock keychain, no activation), its local pages and
its counters (procs.py: proc_pid_rusage over the app, its helpers, WebKit XPC processes it is
responsible for, cmux-tui, acpmux and the terminal hosts). One session, after a template launch:

  1. Home: launch, settle, measure the idle window and the footprint (the app at idle).
  2. One workspace, then `terminals` more terminals, then per engine (Chromium, WebKit) one tab of
     the local idle page and `chromium_tabs` / `webkit_tabs` more (each waits for its first paint).
     After each step the workspace's first terminal is selected again, so every tab opened is
     hidden, and the footprint is read after `phase_settle_s` (past the 30 s hidden-page freeze).
     Rows: the footprint the first hidden tab of an engine added (the engine's own processes come
     with it) and the footprint per further hidden tab.
  3. With every tab hidden: settle, then one idle window with the window in view and one with the
     app hidden. The final sample keeps every process's pid, kind, command, CPU %, wakeups/s,
     footprint and RSS, so a PR can quote before and after numbers per process.

  4. Spinners (spinners.py): with the window in view again, one window with no spinner, then with
     `scenario.spinners` loading spinners visible (default 1 and 20): tree CPU, wakeups/s and the
     app's main thread CPU.

budgets.json holds the scenario's sizes and one budget per row: `limit` in the row's unit,
`enforce` true fails the step (xbench.py report exits 1), false only reports (advisory). A
budget starts advisory while the base breaks it; tighten it (and enforce it) once the base holds it.
"""
from __future__ import annotations

import json
import os
import shutil
import time

import spinners

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_BUDGETS = os.path.join(HERE, "budgets.json")
NAME = "cmux-budget"
LABEL = "cmux NEXT (resource budget)"

ROWS = [
    ("budget-idle-cpu", "CPU, idle, every tab hidden, window in view", "%"),
    ("budget-idle-wakeups", "Wakeups, idle, every tab hidden, window in view", "/s"),
    ("budget-idle-cpu-app-hidden", "CPU, idle, app hidden", "%"),
    ("budget-idle-wakeups-app-hidden", "Wakeups, idle, app hidden", "/s"),
    ("budget-memory-total", "Memory, whole app, every tab hidden", "MB"),
    ("budget-idle-cpu-home", "CPU, idle on Home after launch", "%"),
    ("budget-idle-wakeups-home", "Wakeups, idle on Home after launch", "/s"),
    ("budget-memory-home", "Memory, whole app, idle on Home", "MB"),
    ("budget-memory-per-terminal", "Memory per hidden terminal", "MB"),
    ("budget-memory-first-chromium-tab", "Memory, first hidden Chromium tab (with the engine)", "MB"),
    ("budget-memory-per-chromium-tab", "Memory per further hidden Chromium tab", "MB"),
    ("budget-memory-first-webkit-tab", "Memory, first hidden WebKit tab (with the engine)", "MB"),
    ("budget-memory-per-webkit-tab", "Memory per further hidden WebKit tab", "MB"),
    # Overhead rows (plans/cmux-next/speed-of-sound-DESIGN.md): the floor for each is 0 at idle.
    ("budget-memory-per-workspace", "Memory per further workspace (one terminal, not shown)", "MB"),
    ("budget-idle-disk-writes-home", "Disk writes, idle on Home after launch", "KB/s"),
    ("budget-idle-disk-writes", "Disk writes, idle, every tab hidden, window in view", "KB/s"),
    ("budget-idle-disk-writes-app-hidden", "Disk writes, idle, app hidden", "KB/s"),
    ("budget-idle-mach-msgs", "Mach messages (IPC), idle, every tab hidden", "/s"),
    ("budget-idle-syscalls", "Syscalls, idle, every tab hidden", "/s"),
    ("budget-idle-csw-app-hidden", "Context switches, idle, app hidden", "/s"),
    ("budget-processes", "Processes, every tab hidden", "n"),
    ("budget-threads", "Threads, every tab hidden", "n"),
]
ROWS += spinners.ROWS
ROW_INFO = {row: (label, unit, False) for row, label, unit in ROWS}


def load(path: str | None = None) -> dict:
    with open(path or DEFAULT_BUDGETS) as handle:
        data = json.load(handle)
    if data.get("schema") != "xbench.budgets.v1":
        raise SystemExit(f"budget: {path or DEFAULT_BUDGETS} is not an xbench.budgets.v1 file")
    for entry in data.get("budgets", []):
        if entry.get("row") not in ROW_INFO or not isinstance(entry.get("limit"), (int, float)):
            raise SystemExit(f"budget: bad entry {entry} (row must be one of {sorted(ROW_INFO)}, limit a number)")
    return data


def animation_budgets(path: str | None = None) -> list[dict]:
    """The app animation budgets (`animations` in budgets.json, anim-perf-terminal.py's rows): each
    `{anim, metric, limit, enforce}`, `metric` a key of that bench's summary row. The xbench session
    does not measure them; scripts/cmux-next/perf-budgets.py's `anim` bench does, and gates on them.
    A file without the key has none; a malformed entry stops, as a bad `budgets` entry does."""
    data = load(path)
    entries = data.get("animations", [])
    for entry in entries:
        if not isinstance(entry.get("anim"), str) or not isinstance(entry.get("metric"), str) \
                or not isinstance(entry.get("limit"), (int, float)):
            raise SystemExit(f"budget: bad animation entry {entry} (anim and metric strings, limit a number)")
    return entries


def _sleep(seconds: float):
    time.sleep(seconds)  # bench: a deliberate settle window


def session(run, browser, round_no: int, log, budgets_path: str | None = None):
    """One budget session on `browser` (an xbench CmuxBrowser); rows go through run.record."""
    scenario = load(budgets_path).get("scenario", {})  # report checks the file too; a bad one fails both
    terminals = int(scenario.get("terminals", 5))
    workspaces = int(scenario.get("workspaces", 0))
    kinds = (("chromium", "openBrowser.chromium", int(scenario.get("chromium_tabs", 5))),
             ("webkit", "openBrowser.webkit", int(scenario.get("webkit_tabs", 5))))
    home_settle = float(scenario.get("home_settle_s", 30))
    phase_settle = float(scenario.get("phase_settle_s", 40))
    idle = float(run.args.idle)
    name = browser.name
    load_avg = run.quiet()
    profile = run.profile(browser, f"session{round_no}")
    try:
        browser.launch(profile, None)
        browser.ready()
        log(f"{name} r{round_no}: budget session (load {load_avg}), {terminals} terminals, "
                + ", ".join(f"{count} {kind}" for kind, _action, count in kinds))
        _sleep(home_settle)
        files_before = _file_states(profile)
        got = browser.instance.window(idle)
        writers = _file_writes(files_before, _file_states(profile))
        home_mem = browser.instance.memory()
        run.record(name, round_no, "budget-idle-disk-writes-home", got["disk_kb_per_s"], files=writers)
        for path, grew in writers[:15]:
            log(f"  home idle wrote: {grew:>10,} B  {path}")
        run.record(name, round_no, "budget-idle-cpu-home", got["cpu_pct"], kinds=got["kinds"])
        run.record(name, round_no, "budget-idle-wakeups-home", got["wakeups_per_s"], kinds=got["kinds"])
        run.record(name, round_no, "budget-memory-home", home_mem["mb"], kinds=home_mem["kinds"],
                   processes=home_mem["processes"])

        browser.start_workspace()
        _sleep(phase_settle)
        before = browser.instance.memory()["mb"]
        for _ in range(terminals):
            browser.act("newSurface")
            _sleep(0.3)  # bench: a user's pace between new tabs
        browser.act("selectSurfaceByNumber", index=1)
        _sleep(phase_settle)
        after = browser.instance.memory()["mb"]
        if terminals:
            run.record(name, round_no, "budget-memory-per-terminal", (after - before) / terminals,
                       before_mb=before, after_mb=after, count=terminals)
        for kind, action, count in kinds:
            for row, tabs in ((f"budget-memory-first-{kind}-tab", 1), (f"budget-memory-per-{kind}-tab", count)):
                if not tabs:
                    continue
                before = after
                unpainted = 0
                for _ in range(tabs):
                    tab_id = run.tab_id("b")
                    t0 = time.time() * 1000
                    browser.act(action, url=run.server.url("idle", tab_id))
                    if not run.server.wait("fcp", tab_id, after=t0, timeout=30):
                        unpainted += 1
                browser.act("selectSurfaceByNumber", index=1)
                _sleep(phase_settle)
                after = browser.instance.memory()["mb"]
                # A tab that never painted is not a hidden tab's cost: the row stays unmeasured this
                # round (evaluate counts it incomplete) and keeps the delta for the log.
                per_tab = (after - before) / tabs
                run.record(name, round_no, row, None if unpainted else per_tab, before_mb=before, after_mb=after,
                           count=tabs, **({"note": f"{unpainted} of {tabs} tabs never painted",
                                           "unpainted_mb": round(per_tab, 3)} if unpainted else {}))

        if workspaces:
            # Further workspaces, each with its first terminal, then back to the measured one: what
            # a long session's sidebar of workspaces costs while only one is shown.
            before = browser.instance.memory()["mb"]
            for _ in range(workspaces):
                browser.act("workspace.newAtBottom")
                _sleep(0.2)  # bench: a user's pace between new workspaces
            browser.app.action("workspace.selectFirst", focus=True)
            _sleep(phase_settle)
            after = browser.instance.memory()["mb"]
            run.record(name, round_no, "budget-memory-per-workspace", (after - before) / workspaces,
                       before_mb=before, after_mb=after, count=workspaces)

        _sleep(phase_settle)
        files_before = _file_states(profile)
        got = browser.instance.window(idle, per_pid=True)
        writers = _file_writes(files_before, _file_states(profile))
        for path, grew in writers[:15]:
            log(f"  tabs-hidden idle wrote: {grew:>10,} B  {path}")
        mem = browser.instance.memory(per_pid=True)
        cpu = {row["pid"]: row for row in got.pop("pids")}
        table = []
        for row in mem.pop("pids"):
            window = cpu.get(row["pid"], {})
            table.append({**row, **{key: window.get(key) for key in (
                "cpu_pct", "wakeups_per_s", "mw", "threads", "disk_kb_per_s", "mach_msgs_per_s", "syscalls_per_s",
                "csw_per_s")}})
        run.record(name, round_no, "budget-idle-cpu", got["cpu_pct"], kinds=got["kinds"])
        run.record(name, round_no, "budget-idle-wakeups", got["wakeups_per_s"], kinds=got["kinds"])
        run.record(name, round_no, "budget-memory-total", mem["mb"], kinds=mem["kinds"],
                   processes=mem["processes"], pids=table)
        run.record(name, round_no, "budget-idle-disk-writes", got["disk_kb_per_s"], kinds=got["kinds"], files=writers)
        run.record(name, round_no, "budget-idle-mach-msgs", got["mach_msgs_per_s"])
        run.record(name, round_no, "budget-idle-syscalls", got["syscalls_per_s"])
        run.record(name, round_no, "budget-processes", got["processes"])
        run.record(name, round_no, "budget-threads", got["threads"])
        for row in table[:25]:
            log(f"  pid {row['pid']:>6} {row['kind'][:24]:<24} {row['footprint_mb']:>8.1f} MB "
                    f"{row['rss_mb'] or 0:>8.1f} MB rss {row['cpu_pct'] or 0:>6.2f}% "
                    f"{row['wakeups_per_s'] or 0:>7.1f} wk/s {row.get('threads') or 0:>4} thr "
                    f"{row.get('disk_kb_per_s') or 0:>7.1f} KB/s {row.get('mach_msgs_per_s') or 0:>7.1f} msg/s")
        # Who wakes the idle tree: call trees of the app's main thread and of the process with the
        # most wakeups, taken after the measured window so `sample` does not perturb it.
        busiest = max((row for row in table if row["pid"] != browser.instance.pid),
                      key=lambda row: row.get("wakeups_per_s") or 0, default=None)
        stacks = {"main": _sample_main(browser.instance.pid, 5)}
        if busiest and (busiest.get("wakeups_per_s") or 0) > 1:
            stacks[f"{busiest['kind']} {busiest['pid']}"] = _sample_main(busiest["pid"], 5, any_thread=True)
        # Who owns the threads: thread names of the process with the most threads (a thread per
        # terminal or per connection shows as one name repeated N times).
        most = max(table, key=lambda row: row.get("threads") or 0, default=None)
        thread_names = _thread_names(most["pid"]) if most else {}
        if most:
            log(f"  threads of {most['kind']} {most['pid']} ({most.get('threads')}): "
                + ", ".join(f"{count} x {label}" for label, count in list(thread_names.items())[:15]))
        run.record(name, round_no, "budget-idle-samples", None, note="call trees", stacks=stacks,
                   thread_names={"pid": most and most["pid"], "kind": most and most["kind"], "names": thread_names})
        for label, lines in stacks.items():
            for line in lines[:60]:
                log(f"  in-view {label}: {line}")
        if browser.hide():
            _sleep(10)
            stacks = _sample_main(browser.instance.pid, min(10.0, idle))
            got = browser.instance.window(idle)
            run.record(name, round_no, "budget-idle-cpu-app-hidden", got["cpu_pct"], kinds=got["kinds"])
            run.record(name, round_no, "budget-idle-wakeups-app-hidden", got["wakeups_per_s"], kinds=got["kinds"],
                       main_thread_sample=stacks)
            run.record(name, round_no, "budget-idle-disk-writes-app-hidden", got["disk_kb_per_s"])
            run.record(name, round_no, "budget-idle-csw-app-hidden", got["csw_per_s"])
            for line in stacks[:40]:
                log(f"  hidden main: {line}")
            browser.unhide()
        else:  # a visible app's idle is not the hidden app's: leave the rows unmeasured this round
            for row in ("budget-idle-cpu-app-hidden", "budget-idle-wakeups-app-hidden",
                        "budget-idle-disk-writes-app-hidden", "budget-idle-csw-app-hidden"):
                run.record(name, round_no, row, None, note="the app did not hide")
        # 4. Spinners (spinners.py): the same window in view, with 0, 1 and 20 loading spinners.
        spinner_counts = [int(c) for c in scenario.get("spinners", [1, 20])]
        if spinner_counts:
            _sleep(phase_settle)
            spinners.phase(run, browser, round_no, log, spinner_counts, float(scenario.get("spinner_settle_s", 10)),
                           _sleep)
    except Exception as error:  # noqa: BLE001 - a failed session is logged, the run goes on
        run.record(name, round_no, "session-error", None, note=f"{type(error).__name__}: {error}"[:400])
    finally:
        browser.quit()
        shutil.rmtree(profile, ignore_errors=True)


def _file_states(root: str) -> dict[str, tuple[float, int]]:
    """(mtime, size) of every file under the run's isolated HOME and TMPDIR."""
    states = {}
    for folder, _dirs, files in os.walk(root):
        for file in files:
            path = os.path.join(folder, file)
            try:
                info = os.lstat(path)
            except OSError:
                continue
            states[path] = (info.st_mtime, info.st_size)
    return states


def _file_writes(before: dict, after: dict) -> list[tuple[str, int]]:
    """Files written during an idle window, largest growth first (a rewrite of the same size counts
    its size): names who writes to disk when nothing changes."""
    root = os.path.commonpath(list(after) or ["/"])
    found = []
    for path, (mtime, size) in after.items():
        old = before.get(path)
        if old is None or old[0] != mtime:
            grew = size - old[1] if old and size > old[1] else size
            found.append((os.path.relpath(path, root), grew))
    return sorted(found, key=lambda item: -item[1])[:40]


def _thread_names(pid: int) -> dict[str, int]:
    """Thread name (or the top frame of an unnamed thread) -> count, from a 1 s `sample`."""
    import re
    import subprocess
    import tempfile
    with tempfile.NamedTemporaryFile(suffix=".txt") as out:
        try:
            subprocess.run(["/usr/bin/sample", str(pid), "1", "-mayDie", "-file", out.name],
                           capture_output=True, timeout=60)
            text = open(out.name, errors="replace").read()
        except (OSError, subprocess.SubprocessError):
            return {}
    counts: dict[str, int] = {}
    for line in text.splitlines():
        match = re.search(r"Thread_\d+(.*)$", line)
        if not match:
            continue
        rest = match.group(1).strip().lstrip(":").strip()
        queue = re.search(r"DispatchQueue_\d+:\s*(\S+)", rest)
        label = queue.group(1) if queue else re.sub(r"\s*\(serial\)|\s*\(concurrent\)", "", rest) or "unnamed"
        label = re.sub(r"[-_ ]?\d+$", " N", label)[:60]
        counts[label] = counts.get(label, 0) + 1
    return dict(sorted(counts.items(), key=lambda item: -item[1]))


def _sample_main(pid: int, seconds: float, any_thread: bool = False) -> list[str]:
    """The main thread's call tree from `/usr/bin/sample` over `seconds` (the hidden app's idle):
    names who wakes an idle app in a Release build, where debug.wakeups does not exist."""
    import subprocess
    import tempfile
    with tempfile.NamedTemporaryFile(suffix=".txt") as out:
        try:
            subprocess.run(["/usr/bin/sample", str(pid), str(max(1, int(seconds))), "-mayDie", "-file", out.name],
                           capture_output=True, timeout=seconds + 60)
            text = open(out.name, errors="replace").read()
        except (OSError, subprocess.SubprocessError):
            return []
    lines = []
    in_main = False
    for line in text.splitlines():
        if "Thread_" in line and (any_thread or "main-thread" in line or "DispatchQueue_1:" in line):
            in_main = True
        elif in_main and not line.strip():
            break
        elif in_main and "Thread_" in line and not any_thread:
            break
        if in_main:
            stripped = line.rstrip()
            depth = len(stripped) - len(stripped.lstrip(" +!:|"))
            if depth <= 90 and stripped:
                lines.append(stripped[:200])
    return lines[:200]


def _fmt(value, unit: str) -> str:
    if value is None:
        return "–"
    if unit == "%":
        return f"{value:.2f}%"
    if unit == "/s":
        return f"{value:.1f}/s"
    if unit == "KB/s":
        return f"{value:,.1f} KB/s"
    if unit == "n":
        return f"{value:,.0f}"
    return f"{value:,.1f} MB"


def evaluate(rows: dict, requested: bool, budgets_path: str | None = None, rounds: int = 0,
             errors: int = 0) -> tuple[dict, list[str]]:
    """Budget verdicts for the cmux-budget medians in `rows` and the BENCH.md section.

    `requested`: the run had a cmux-budget session (its bundle was found). `rounds`: the rounds the
    run asked for; `errors`: the cmux-budget session-error rows. Prints one `PERF-BUDGET` line per
    budget and a summary line; `failed` counts enforced budgets that were broken or not fully
    measured (missing, fewer samples than rounds, or any session error), so a session that crashed
    or stopped measuring does not pass on the rows another round recorded."""
    data = load(budgets_path)
    measured = requested
    verdicts = []
    failed = 0
    lines = ["## Resource budget (cmux NEXT)", "",
             f"{LABEL}: scripts/perf-bench/budget.py, budgets in scripts/perf-bench/budgets.json. Scenario: "
             + json.dumps(data.get("scenario", {})) + ". Medians over rounds. Advisory budgets report only; "
             "enforced ones fail the step.", "",
             "| Row | Median | Budget | Verdict | Mode |", "|---|---|---|---|---|"]
    for entry in data.get("budgets", []) if measured else []:
        row = entry["row"]
        label, unit, _main = ROW_INFO[row]
        cell = rows.get(row, {}).get(NAME, {})
        value = cell.get("median")
        if value is None:
            verdict = "missing"
        elif value > entry["limit"]:
            verdict = "OVER"
        elif errors or (cell.get("n") or 0) < rounds:
            verdict = "incomplete"
        else:
            verdict = "ok"
        mode = "enforced" if entry.get("enforce") else "advisory"
        if entry.get("enforce") and verdict != "ok":
            failed += 1
        verdicts.append({"row": row, "value": value, "limit": entry["limit"], "unit": unit, "verdict": verdict,
                         "mode": mode, "n": cell.get("n")})
        lines.append(f"| {label} | {_fmt(value, unit)} | {_fmt(entry['limit'], unit)} | {verdict} | {mode} |")
        print(f"PERF-BUDGET {verdict} {mode} {row} value={value} limit={entry['limit']} {unit}", flush=True)
    if not measured:
        print("PERF-BUDGET SKIP no cmux-budget session in this run", flush=True)
    print(f"PERF-BUDGET {'FAIL' if failed else 'PASS'} enforced_broken={failed} session_errors={errors}", flush=True)
    lines.append("")
    return {"measured": measured, "failed": failed, "budgets": verdicts}, (lines if measured else [])
