#!/usr/bin/env python3
"""The perf cron's power part (split-spring-terminal.py --suite=power): the app's power in mW, idle and in light use,
as perf-cron rows.

Leo, 2026-11-19: "a lot of this is just applying things properly and having those measurements in so that we're aware
of things." Idle power came only from hand runs of scripts/measure/perf-idle-power.sh (bench_power.py), which nothing
stored, so a change that kept the app awake showed up nowhere.

This runs bench_power.py on the cron's app in three of its scenarios, then measures standalone Ghostty (the release
terminal-throughput-bench.py pins) at idle the same way, on the same host, in the same step:
- terminal: one terminal workspace, the window in view, idle (120 s settle, 60 s measured);
- tab1: one static Chromium page in view, idle (120 s settle, 60 s measured);
- scroll: a page that scrolls itself in view, the light-use scenario (10 s settle, 60 s measured).

Power is the CPU energy macOS accounts to each process (proc_pid_rusage ri_energy_nj; no root), over the app and
every process it owns (Chromium and WebKit helpers, cmux-tui daemons and terminal hosts, acpmux). GPU and display
energy are not in it. Rows (report.json `rows`, perf-cron.py's budgets kind):
- power.idle.terminal.total_mw  budget: Ghostty's idle mW from this run (one window, its shell at the prompt,
  Ghostty's own processes only, as the app's shell is not in its sum either). A run with no Ghostty falls back to
  GHOSTTY_FALLBACK_MW.
- power.idle.terminal.ghostty_mw, power.idle.terminal.vs_ghostty  shown, never judged (perf-cron.py REPORT_ONLY_ROW_RE).
- power.idle.tab1.total_mw  budget: the best other browser's "Power, idle, in view, 1 tab" in the checked-in xbench
  baseline (scripts/perf-bench/baseline/BENCH-apple-m4-pro-macos27.md: Ardia, 0.4 mW). Leo's goal there is a tenth of it.
- power.active.scroll.total_mw  budget: the best other browser's "Power, scrolling" there (Chrome, 7.7 mW).
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
# (bench_power scenario, row name, budget mW or None for Ghostty's). The budgets' sources are in the docstring.
SCENARIOS = (("terminal", "power.idle.terminal.total_mw", None),
             ("tab1", "power.idle.tab1.total_mw", 0.4),
             ("scroll", "power.active.scroll.total_mw", 7.7))
# Ghostty's idle mW when this run could not measure it. Set from the first measured run (PR body).
GHOSTTY_FALLBACK_MW = 1.0
FLOOR_MW = 2.0  # the xbench gate's noise floor for mW (scripts/perf-bench/README.md)
GHOSTTY_SETTLE_S = 30  # no Chromium in it: nothing does the two minutes of post-load work bench_power settles for
GHOSTTY_MEASURE_S = 60


def rows_from(report: dict, ghostty_mw: float | None) -> list[dict]:
    """perf-cron rows from bench_power.py's report and Ghostty's idle mW (pure)."""
    by_label = {r.get("label"): r for r in report.get("results") or [] if isinstance(r, dict)}
    rows = []
    for scenario, name, budget in SCENARIOS:
        mw = ((by_label.get(scenario) or {}).get("total") or {}).get("mw")
        if not isinstance(mw, (int, float)):
            continue
        if budget is None:
            budget = ghostty_mw if isinstance(ghostty_mw, (int, float)) else GHOSTTY_FALLBACK_MW
        rows.append({"name": name, "p50": round(mw, 3), "p95": round(mw, 3), "unit": "mW", "budget": budget,
                     "floor": FLOOR_MW})
        if scenario == "terminal" and isinstance(ghostty_mw, (int, float)):
            rows.append({"name": "power.idle.terminal.ghostty_mw", "p50": ghostty_mw, "p95": ghostty_mw, "unit": "mW",
                         "floor": FLOOR_MW})
            if ghostty_mw > 0:
                ratio = round(mw / ghostty_mw, 2)
                rows.append({"name": "power.idle.terminal.vs_ghostty", "p50": ratio, "p95": ratio, "unit": "x",
                             "floor": 0.5})
    return rows


def missing_scenarios(rows: list[dict]) -> list[str]:
    """The scenarios with no row, as the report's `incomplete` (pure)."""
    have = {r["name"] for r in rows}
    return [f"{scenario}: no power sample" for scenario, name, _ in SCENARIOS if name not in have]


def ghostty_idle(out_dir: str, ghostty_app: str | None) -> dict:
    """Standalone Ghostty idle: one window, its shell at the prompt, GHOSTTY_SETTLE_S, then the energy of Ghostty's own
    processes over GHOSTTY_MEASURE_S. {mw, cpu_pct, wakeups_per_s, version} or {error}."""
    import bench_memory as bm  # macOS only (libproc)
    import bench_power as bp
    spec = importlib.util.spec_from_file_location("terminal_throughput", os.path.join(HERE, "terminal-throughput-bench.py"))
    tt = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(tt)
    scratch = tempfile.mkdtemp(prefix="power-ghostty-")
    app, version = tt.ghostty_app(argparse.Namespace(ghostty_app=ghostty_app), scratch)
    if not app:
        return {"error": version}
    binary = os.path.join(app, "Contents", "MacOS", "ghostty")
    argv = [binary, "--config-default-files=false", "--quit-after-last-window-closed=true",
            "--confirm-close-surface=false", "--window-save-state=never", "--auto-update=off"]
    env = dict(os.environ, XDG_CONFIG_HOME=os.path.join(scratch, "xdg"))
    with open(os.path.join(out_dir, "power-ghostty.log"), "w") as log:
        launched = time.monotonic()
        proc = subprocess.Popen(argv, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            from state_wait import wait_until  # the script's folder is sys.path[0]

            def shell_up():
                # Ghostty's window has its shell: a child process of one of the bundle's processes.
                if proc.poll() is not None:
                    return True
                table = bm.process_table()
                ours = {pid for pid, _ppid, cmd in table if bm.in_bundle(cmd, app) is not None}
                return any(ppid in ours and pid not in ours for pid, ppid, _cmd in table)
            if not wait_until(shell_up, "Ghostty's window shell", timeout=GHOSTTY_SETTLE_S, raise_on_timeout=False):
                return {"error": f"Ghostty's window shell did not start within {GHOSTTY_SETTLE_S} s"}
            if proc.poll() is not None:
                return {"error": f"Ghostty exited {proc.returncode} before the window"}
            # sleep-ok: the idle baseline's fixed rest, counted from launch, so each day's number rests as long as the last
            time.sleep(max(0.0, GHOSTTY_SETTLE_S - (time.monotonic() - launched)))
            pids = [pid for pid, _ppid, cmd in bm.process_table() if bm.in_bundle(cmd, app) is not None]
            start = {pid: bp.counters(pid) for pid in pids}
            began = time.monotonic()
            time.sleep(GHOSTTY_MEASURE_S)  # sleep-ok: the measured energy window
            elapsed = time.monotonic() - began
            mw = cpu = wakeups = 0.0
            for pid, first in start.items():
                last = bp.counters(pid)
                if first is None or last is None:
                    continue
                mw += (last[0] - first[0]) / 1e6 / elapsed
                cpu += 100 * (last[1] - first[1]) / 1e9 / elapsed
                wakeups += (last[2] - first[2]) / elapsed
            return {"mw": round(mw, 3), "cpu_pct": round(cpu, 3), "wakeups_per_s": round(wakeups, 2),
                    "processes": len(start), "version": version, "seconds": round(elapsed, 1)}
        finally:
            proc.terminate()  # the PID this script started
            try:
                proc.wait(10)
            except subprocess.TimeoutExpired:
                proc.kill()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--json", required=True, help="the part's report.json")
    parser.add_argument("--out", default=None, help="split-spring's artifact folder (bench_power's own report goes there)")
    parser.add_argument("--ghostty-app", help="a Ghostty.app to compare with (default: the pinned release)")
    parser.add_argument("--no-ghostty", action="store_true")
    args, _rest = parser.parse_known_args(argv)  # split-spring's own args (--tag) are not this suite's
    out_dir = args.out or os.path.dirname(os.path.abspath(args.json))
    os.makedirs(out_dir, exist_ok=True)
    raw = os.path.join(out_dir, "power.json")
    cmd = [sys.executable, os.path.join(HERE, "bench_power.py"), "--app", args.app,
           "--scenarios", ",".join(s for s, _, _ in SCENARIOS), "--out", raw]
    status = subprocess.run(cmd, cwd=ROOT).returncode
    try:
        with open(raw) as f:
            report = json.load(f)
    except (OSError, ValueError):
        report = {}
    ghostty = {"error": "--no-ghostty"} if args.no_ghostty else ghostty_idle(out_dir, args.ghostty_app)
    rows = rows_from(report, ghostty.get("mw"))
    out = {"rows": rows, "bench_status": status, "ghostty": ghostty,
           "scenarios": {r.get("label"): {"total": r.get("total"), "kinds": r.get("kinds"),
                                          "powermetrics": r.get("powermetrics")}
                         for r in report.get("results") or [] if isinstance(r, dict)}}
    # A missing Ghostty is `ghostty.error`, not the cron's `incomplete`: the app's rows still stand (its budget falls
    # back to GHOSTTY_FALLBACK_MW), as terminal-throughput-bench.py keeps a missing terminal out of `incomplete`.
    missing = missing_scenarios(rows)
    if missing:
        out["incomplete"] = missing + [f"bench_power.py exit {status}"]
    with open(args.json, "w") as f:
        json.dump(out, f, indent=1)
    for r in rows:
        print(f"power: {r['name']} = {r['p95']} {r['unit']}" + (f" (budget {r['budget']})" if "budget" in r else ""))
    if "error" in ghostty:
        print(f"power: no Ghostty comparison: {ghostty['error']}")
    return status or (1 if missing else 0)


if __name__ == "__main__":
    raise SystemExit(main())
