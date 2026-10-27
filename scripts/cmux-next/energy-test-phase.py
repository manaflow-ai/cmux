#!/usr/bin/env python3
"""The energy program's test phase: one entry point for D1-D17 (plans/cmux-next/chrome-parity/p14-energy.md, sec. 5).

Runs on the macOS measure host (a fleet Mac's console) against a Release + CMUX_BENCH_HOOKS bundle of the measured
commit (`--app`, for example `split-spring.sh --config=bench --build-only`'s), and judges:

  D1          python3 -I scripts/cmux-next/wakeup-audit.py --strict (static, any host)
  D2-D5, D7, D11-D17  idle-budget.py --gate over every idle session in shipping mode, 3 runs (windows) of settle 60 s
              and window 60 s, judged as the median of the 3: a row is over when it is over in 2 of them (overs by
              session, `role` overs for D16, assertion overs for D11, disk/network/log overs for D15, the tabs-static
              wakeup ledger for D12, the hidden sessions' renderer rows for D17)
  D11, D13, D15 signed-in  idle-budget.py on a Debug bundle of the same commit (`--debug-app`: the app signs a test
              account in only in Debug). idle-budget reports those rows, never judges them, so they are not judged here
  D12         cef-idle-probe.py: CEFPumpStats earlyPasses in each of 3 x 60 s windows (the median)
  D8          bench-typing.py: native terminal, Chromium agent composer and Chromium page scroll, saver off and on.
              Its split-spring pane-motion part is not judged until split-spring-terminal.py can set energy.saver
  D6          xbench.py run with Chrome (cmux-chromium, cmux-terminal, chrome), then idle-budget.py --xbench
  D7 auto     launch the bundle with the energySaver feature on, `debug.energy.simulate {on_battery: true,
              percent: 15}`: reason `battery`; `{clear: true}` must restore the Mac's own policy and inputs,
              "Turn Off Energy Saver for Now" (`sessionOverride`) included (fleet Macs have no battery). With only
              `--tag` it talks to that tag's running app through scripts/cmux-debug-cli.sh instead.
  D9          the Rust idle tests (idle_wakeups, daemon_idle) on a macOS fleet step (cmux-ci run); Linux is task 131
  D10         the Swift suites of D10 on a fleet step (cmux-ci run, package-test-lane.sh suite)

The measuring steps run on a --vdisplay (120) Hz virtual display as the main display, the helper split-spring.sh
--vdisplay uses (scripts/perf-lab/run_story.py VirtualDisplay); its measured refresh goes into the report, and the
rows defined at 120 Hz (D7, D8, D14) are not judged on another rate. Before each measuring step it waits for the
1-minute load to drop under --max-load (4), at most --quiet-wait seconds; a step that starts above it says so on its
checks. A step's later commands do not run once one fails. Each check is pass, FAIL or not judged (not measured, or
its tool could not judge): not measured is never a pass, and the exit status is 0 only when every asked check
passes. A step deletes its own outputs (OUT/<step>.log and OUT/<step>/) before it runs or is skipped, and a check
reads only the outputs of steps that ran in this invocation, so an earlier run's files never judge this one. Writes
Markdown (stdout and OUT/report.md, with the rows for plans/cmux-next/perf-lead.md sec. 5) and JSON (OUT/report.json,
and --json). --dry-run prints each step's exact commands; --collect-only judges the outputs already in OUT (of the
steps OUT/steps.json records as run) without running anything.

  python3 scripts/cmux-next/energy-test-phase.py --app "<...>/cmux DEV <tag>.app" [--debug-app APP] [--checks D1,D7|all]
      [--out DIR] [--ref SHA] [--chrome-app APP] [--chrome-ublock DIR] [--vdisplay 120|0] [--json out.json]
      [--dry-run] [--collect-only]
  python3 scripts/cmux-next/energy-test-phase.py --tag energy-sim --checks D7   (D7 auto against a running tagged app)

Never referenced from .github/workflows: the person or agent runs it on the fleet.
"""
from __future__ import annotations

import argparse
import datetime
import importlib.util
import json
import os
import re
import shlex
import shutil
import socket
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
DEBUG_CLI = REPO / "scripts" / "cmux-debug-cli.sh"
BUDGET_FILE = HERE / "idle-budget.json"

SIMULATE = "debug.energy.simulate"
ENERGY = "debug.energy"
# D7 auto: below the resolver's 20% threshold, on battery (EnergyPolicyResolver.lowBatteryThresholdPercent).
D7_AUTO_SIMULATION = {"on_battery": True, "percent": 15}
CLEAR = {"clear": True}
ENERGY_FEATURE_ENV = {"CMUX_ENABLE_FEATURES": "energySaver"}

CHECKS = {
    "D1": "static wakeup audit (wakeup-audit --strict)",
    "D2": "light-webkit and light sessions",
    "D3": "light-hidden, minimized and occluded",
    "D4": "tabs-static (with chrome-static ratios)",
    "D5": "stress-static",
    "D6": "Chrome ratio (xbench) and the home session",
    "D7": "energy saver: energy-saver session and auto at 15% on battery",
    "D8": "the saver adds no visible latency (typing and scroll)",
    "D9": "Rust idle tests on fleet macOS",
    "D10": "Swift unit tests on the fleet",
    "D11": "no power assertion held at idle",
    "D12": "wakeup ledger in tabs-static, CEF early passes",
    "D13": "signed-in, app-quit and external-churn",
    "D14": "agent sessions",
    "D15": "no disk, network or log at idle",
    "D16": "process roles",
    "D17": "hidden sessions: every Chromium tab hidden, <= 1 wake/s",
}

# idle-budget sessions per D-row. The bench bundle runs all but the signed-in ones, which need a Debug bundle.
SESSION_CHECK = {"light-webkit": "D2", "light": "D2", "light-hidden": "D3", "minimized": "D3", "occluded": "D3",
                 "tabs-static": "D4", "chrome-static": "D4", "stress-static": "D5", "home": "D6", "energy-saver": "D7",
                 "app-quit": "D13", "external-churn": "D13", "signed-in": "D13", "signed-in-display-sleep": "D13",
                 "agent-idle": "D14", "agent-working-visible": "D14", "busy-hidden": "D14"}
SIGNED_IN_SESSIONS = ("light-hidden", "signed-in", "signed-in-display-sleep")
BENCH_SESSIONS = tuple(s for s in SESSION_CHECK if s not in SIGNED_IN_SESSIONS[1:])
HIDDEN_SESSIONS = ("light-hidden", "minimized", "occluded")
ROLE_SESSIONS = (*HIDDEN_SESSIONS, "tabs-static")
# The session a check's relative rows compare with ("no higher than light", "<= 0.6 x tabs-static").
REFERENCE_SESSIONS = {"D3": ("light",), "D7": ("tabs-static",)}
# What a check needs beyond its own sessions: its reference session, or the sessions it reads.
SESSIONS_NEEDED = {**REFERENCE_SESSIONS, "D12": ("tabs-static",), "D16": ROLE_SESSIONS,
                   "D17": HIDDEN_SESSIONS, "D11": BENCH_SESSIONS, "D15": BENCH_SESSIONS}
# p14-energy.md sec. 5: settle 60 s, median of 3 x 60 s windows. One window is one idle-budget (or cef-idle) run.
WINDOWS = 3
SETTLE_S = MEASURE_S = 60
# The measuring steps' display (split-spring.sh --vdisplay=120's helper and size), and the checks whose rows are
# defined at that rate, with the steps that measure them: D7's 120 fps page, D8's 120 Hz scroll, D14's visible
# agent at <= 35/s.
FRAME_HZ = 120.0
FRAME_STEPS = {"D7": ("idle-budget",), "D8": ("bench-typing",), "D14": ("idle-budget",)}
VDISPLAY_SIZE = "1920x1200"
VDISPLAY_HOLD_S = 8 * 3600  # the helper ends by itself after this even when this script is killed
RUN_STORY = REPO / "scripts" / "perf-lab" / "run_story.py"


def idle_sessions(checks):
    """The bench bundle's idle-budget sessions the asked checks need, in BENCH_SESSIONS order."""
    wanted = {s for s in BENCH_SESSIONS if SESSION_CHECK[s] in checks}
    wanted |= {s for check in checks for s in SESSIONS_NEEDED.get(check, ())}
    return tuple(s for s in BENCH_SESSIONS if s in wanted)
D17_RENDERER_WAKES = 1.0  # a hidden unfrozen page: <= 1 timer wake/s
D12_OWNER_MAX = 0.1
D8_SURFACES = ("terminal", "agent-composer-chromium", "chromium-page-scroll")
D8_SPLIT_SPRING = ("split-spring pane motion (0 dropped frames at 120 Hz, saver off and always): not measured, "
                   "split-spring-terminal.py cannot set energy.saver yet")
D9_BINARIES = ("idle_wakeups", "daemon_idle")
D10_SUITES = ("MainWakeUpQueueTests", "DemandTimerLeewayTests", "DemandTimerMainQueueTests", "EnergyPolicyResolverTests",
              "BatteryLevelTests", "SuspendWatchTests", "CEFPumpScheduleTests", "FrameSchedulerRateClassTests")
# `cmux-ci run` exits that are the fleet's, not the commit's (perf-cron.py STEP_YIELD_EXITS).
FLEET_EXITS = {69: "no fleet worker takes steps", 75: "queue timeout", 76: "superseded"}


class RpcError(Exception):
    """The app answered with an error, or did not answer."""


# ---------------------------------------------------------------------------------------------------------
# D7 auto (p14-energy-123)


def rpc_command(tag, method, params):
    """The exact shell command for one debug method of the tagged build."""
    return f"CMUX_TAG={shlex.quote(tag)} {shlex.quote(str(DEBUG_CLI.relative_to(REPO)))} rpc {method} " \
           f"{shlex.quote(json.dumps(params, separators=(',', ':')))}"


RPC_TIMEOUT_SECONDS = 60


def cli_rpc(tag, runner=subprocess.run):
    """An rpc(method, params) over scripts/cmux-debug-cli.sh for `tag`: the result, or RpcError (also for a
    hung app or a CLI that does not start)."""
    def call(method, params):
        try:
            completed = runner([str(DEBUG_CLI), "rpc", method, json.dumps(params)], cwd=REPO,
                               env={**os.environ, "CMUX_TAG": tag}, capture_output=True, text=True,
                               timeout=RPC_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            raise RpcError(f"{method}: no answer in {RPC_TIMEOUT_SECONDS} s") from None
        except OSError as error:
            raise RpcError(f"{method}: {DEBUG_CLI.relative_to(REPO)} did not run ({error})") from None
        if completed.returncode != 0:
            raise RpcError(f"{method}: {completed.stderr.strip() or completed.stdout.strip()}")
        return parse_reply(method, completed.stdout)
    return call


def bench_rpc(app):
    """An rpc(method, params) over a bench_launch.BenchApp's socket (rpc_at answers {"error": ...} on failure)."""
    def call(method, params):
        result = app.rpc(method, params, timeout=RPC_TIMEOUT_SECONDS)
        if isinstance(result, dict) and "error" in result and set(result) <= {"error", "unreachable"}:
            raise RpcError(f"{method}: {json.dumps(result['error'])}")
        return result
    return call


def parse_reply(method, text):
    """The `result` of one JSON-lines reply; RpcError for an error reply or anything not JSON."""
    try:
        reply = json.loads(text.strip().splitlines()[-1])
    except (IndexError, ValueError) as error:
        raise RpcError(f"{method}: no JSON reply ({error})") from None
    if not isinstance(reply, dict) or not reply.get("ok"):
        error = reply.get("error") if isinstance(reply, dict) else reply
        raise RpcError(f"{method}: {json.dumps(error)}")
    return reply.get("result")


def energy_state(report):
    """(isSaver, reason, simulated, inputs) from a debug.energy report."""
    report = report if isinstance(report, dict) else {}
    policy = report.get("policy") if isinstance(report.get("policy"), dict) else {}
    inputs = report.get("inputs") if isinstance(report.get("inputs"), dict) else {}
    return policy.get("isSaver"), policy.get("reason"), inputs.get("simulated"), inputs


# The inputs a simulation may change, and the session's "Turn Off Energy Saver for Now" (which a simulated
# power source must never end); clearing must bring each back to what it was.
RESTORED_INPUTS = ("onBattery", "hasBattery", "batteryPercent", "thermal", "lowPowerMode", "suspended", "sessionOverride")


def judge_d7_auto(before, simulated, cleared):
    """Problems with the three debug.energy reports of D7 auto (before, while simulating, after clear); [] passes."""
    problems = []
    _, _, before_simulated, before_inputs = energy_state(before)
    if before_inputs.get("featureEnabled") is not True:
        problems.append("the energySaver feature is off in this build: turn it on (schemas/features) and rerun")
    if before_inputs.get("setting") not in (None, "auto"):
        problems.append(f"energy.saver is {before_inputs.get('setting')!r}, D7 auto needs 'auto'")
    if before_simulated:
        problems.append("a simulation was already active before the check")
    held = before_inputs.get("sessionOverride") is True
    if held:
        problems.append("\"Turn Off Energy Saver for Now\" holds, so the saver stays off: turn Energy Saver back on "
                        "(energy.saver.turnOnNow) and rerun")
    saver, reason, is_simulated, inputs = energy_state(simulated)
    if not held and (saver is not True or reason != "battery"):
        problems.append(f"simulated 15% on battery: expected isSaver true with reason 'battery', got {saver!r} {reason!r}")
    if is_simulated is not True:
        problems.append("simulated 15% on battery: inputs.simulated is not true")
    if inputs.get("onBattery") is not True or inputs.get("batteryPercent") != 15:
        problems.append(f"simulated 15% on battery: inputs read onBattery={inputs.get('onBattery')!r} "
                        f"batteryPercent={inputs.get('batteryPercent')!r}")
    before_saver, before_reason, _, _ = energy_state(before)
    after_saver, after_reason, after_simulated, after_inputs = energy_state(cleared)
    if after_simulated is not False:
        problems.append("after clear: inputs.simulated is not false")
    if (after_saver, after_reason) != (before_saver, before_reason):
        problems.append(f"after clear: policy {after_saver!r} {after_reason!r} is not the Mac's {before_saver!r} {before_reason!r}")
    changed = [key for key in RESTORED_INPUTS if after_inputs.get(key) != before_inputs.get(key)]
    if changed:
        problems.append(f"after clear: inputs {', '.join(changed)} differ from the Mac's")
    return problems


def run_d7_auto(rpc):
    """D7 auto: read, simulate 15% on battery, clear (always, even after a failure), judge. A failed clear is
    one more problem, after the first failure, never in its place."""
    reports, problems = {}, []
    try:
        reports["before"] = rpc(ENERGY, {})
        reports["simulated"] = rpc(SIMULATE, D7_AUTO_SIMULATION)
    except RpcError as error:
        problems.append(str(error))
    try:
        reports["cleared"] = rpc(SIMULATE, CLEAR)
    except RpcError as error:
        problems.append(f"clear failed, so the simulation may still be active in the app: {error}")
    if problems:
        return problems, reports
    return judge_d7_auto(reports["before"], reports["simulated"], reports["cleared"]), reports


def d7_auto_commands(tag):
    return [rpc_command(tag, ENERGY, {}), rpc_command(tag, SIMULATE, D7_AUTO_SIMULATION), rpc_command(tag, SIMULATE, CLEAR)]


def launched_d7_auto(app_path, out):
    """D7 auto on a launch of `app_path` with the energySaver feature on (energy.saver at its default, auto)."""
    sys.path.insert(0, str(HERE))
    from bench_launch import BenchApp  # noqa: PLC0415 - macOS-only launch code, loaded only to launch
    app = None
    try:
        app = BenchApp(app_path, out=out, env=ENERGY_FEATURE_ENV)
        app.launch()
        return run_d7_auto(bench_rpc(app))
    except SystemExit as error:  # bench_launch.LaunchError
        return [f"the app did not launch: {error.code}"], {}
    finally:
        if app is not None:
            app.stop()


# ---------------------------------------------------------------------------------------------------------
# Steps: what runs, in order


@dataclass(frozen=True)
class Step:
    name: str
    checks: tuple
    commands: tuple  # argv lists, run from the repository root one after the other
    quiet: bool = True  # wait for a quiet host first (a measurement on this host)
    skip: str = ""  # why it cannot run with these options
    text: tuple = ()  # what --dry-run prints instead of the commands (a step that runs no command)
    ok_exits: tuple = (0,)  # the exits after which its next command runs (idle-budget --gate: 1 is overs, a result)
    display: bool = False  # measures frames or wakeups of a shown app: runs on the --vdisplay display

    def lines(self):
        return list(self.text) or [shlex.join(argv) for argv in self.commands]


def tag_of(app):
    match = re.fullmatch(r"cmux DEV (.+)\.app", os.path.basename(os.path.normpath(app)))
    return re.sub(r"[^a-z0-9]+", "-", match.group(1).lower()).strip("-") if match else None


def window_dir(out, name, window):
    """OUT/<step>/w<N>: one window's run of a windowed step."""
    return f"{out}/{name}/w{window}"


def plan(opts, checks=tuple(CHECKS)):
    """The steps of a full run with these options, each with the D-checks it feeds."""
    out, app, ref, py = opts.out, opts.app or "APP", opts.ref, "python3"
    no_app = "" if opts.app else "needs --app (a Release + CMUX_BENCH_HOOKS bundle)"
    chrome = [*(["--chrome-app", opts.chrome_app] if opts.chrome_app else []),
              *(["--chrome-ublock", opts.chrome_ublock] if opts.chrome_ublock else [])]
    windows = range(1, WINDOWS + 1)
    idle = lambda name, bundle, sessions, gate: tuple(  # noqa: E731
        (py, "scripts/cmux-next/idle-budget.py", "--app", bundle, "--out", window_dir(out, name, n), "--json",
         f"{window_dir(out, name, n)}/idle-budget.json", "--sessions", ",".join(sessions), "--settle", f"{SETTLE_S:g}",
         "--measure", f"{MEASURE_S:g}", *(["--gate"] if gate else []), *chrome) for n in windows)
    xbench = f"{out}/xbench"
    fleet = lambda name, step_class, script, *args: [  # noqa: E731
        opts.cmux_ci, "run", "--class", step_class, "--script", script, "--ref", ref,
        "--key", f"energy-test-phase-{ref}-{name}", *[f"--arg={arg}" for arg in args]]
    d7 = (*(["# launch --app (bench_launch.BenchApp, CMUX_ENABLE_FEATURES=energySaver), then on its socket:"]
            if opts.app else []), *d7_auto_commands(tag_of(app) or opts.tag or "TAG"))
    return [
        Step("audit", ("D1",), ((py, "-I", "scripts/cmux-next/wakeup-audit.py", "--strict"),), quiet=False),
        Step("idle-budget", ("D2", "D3", "D4", "D5", "D6", "D7", "D11", "D12", "D13", "D14", "D15", "D16", "D17"),
             idle("idle-budget", app, idle_sessions(checks), True), skip=no_app, ok_exits=(0, 1), display=True),
        Step("idle-budget-signed-in", ("D11", "D13", "D15"),
             idle("idle-budget-signed-in", opts.debug_app or "DEBUG_APP", SIGNED_IN_SESSIONS, False),
             skip="" if opts.debug_app else "needs --debug-app (a Debug bundle of the same commit)", display=True),
        Step("cef-idle", ("D12",), tuple(
            (py, "scripts/cmux-next/cef-idle-probe.py", "--app", app, "--out", window_dir(out, "cef-idle", n),
             "--settle", f"{SETTLE_S:g}", "--window", f"{MEASURE_S:g}") for n in windows), skip=no_app, display=True),
        Step("bench-typing", ("D8",), ((py, "scripts/cmux-next/bench-typing.py", "--app", app, "--surface",
                                        ",".join(D8_SURFACES), "--energy-saver", "off,on", "--out", f"{out}/bench-typing"),),
             skip=no_app, display=True),
        Step("xbench", ("D6",), (
            (py, "scripts/perf-bench/xbench.py", "run", "--out", f"{xbench}/run", "--app", f"cmux={app}",
             *(["--app", f"chrome={opts.chrome_app}"] if opts.chrome_app else []),
             *(["--chrome-extension", opts.chrome_ublock] if opts.chrome_ublock else []),
             "--browsers", "cmux-chromium,cmux-terminal,chrome", "--rounds", "3", "--max-load", f"{opts.max_load:g}"),
            (py, "scripts/perf-bench/xbench.py", "report", "--out", f"{xbench}/run", "--json", f"{xbench}/results.json"),
            (py, "scripts/cmux-next/idle-budget.py", "--xbench", f"{xbench}/results.json")), skip=no_app, display=True),
        Step("d7-auto", ("D7",), (), quiet=False, skip="" if opts.app or opts.tag else "needs --app or --tag", text=d7),
        Step("rust-idle", ("D9",), (fleet("d9", "isolated", "scripts/ci/cmux-tui-rust-check.sh", "test", "daemon_idle"),),
             quiet=False),
        Step("swift-suites", ("D10",), (fleet("d10", "light", "scripts/ci/package-test-lane.sh", "suite",
                                              "Packages/macOS/CmuxNext", ",".join(D10_SUITES)),), quiet=False),
    ]


def display_text(opts):
    """What --dry-run prints for the display the measuring steps run on."""
    if not opts.vdisplay:
        return ("# display: the real main display (--vdisplay 0), its refresh read by `VDisplay probe` into each "
                f"measuring step's {opts.out}/steps.json entry")
    return (f"# display: VDisplay {opts.vdisplay:g} {VDISPLAY_HOLD_S} main {VDISPLAY_SIZE} as the main display for the "
            f"measuring steps ({RUN_STORY.relative_to(REPO)} VirtualDisplay, split-spring.sh --vdisplay's helper), "
            f"its measured refresh in each measuring step's {opts.out}/steps.json entry")


def start_vdisplay(work, hz):
    """Brings up the measuring steps' display (VirtualDisplay of perf-lab's run_story.py: the helper of
    split-spring.sh --vdisplay); returns (its display block, the holder: stop() ends it, alive() says whether it still
    holds the display it reported). hz 0: the real display, probed."""
    spec = importlib.util.spec_from_file_location("perf_lab_run_story", RUN_STORY)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # before exec: its dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    holder = module.VirtualDisplay(str(work))
    try:
        return holder.start(hz, VDISPLAY_HOLD_S, VDISPLAY_SIZE), holder
    except (OSError, subprocess.SubprocessError) as error:  # no xcrun, a helper build that hung
        holder.stop()
        return {"requested_hz": hz, "vdisplay": False, "refresh_ms": None, "line": f"error: {error}"[:300]}, holder


def display_hz(display):
    """The measured refresh rate (Hz) of the measuring steps' display, or None: the virtual display's interval, or
    after a fallback the real main display's `VDisplay probe` line."""
    if not isinstance(display, dict):
        return None
    ms = display.get("refresh_ms") if display.get("vdisplay") else None
    if not ms:
        match = re.match(r"main \d+ ([\d.]+)", display.get("probe") or "")
        ms = float(match.group(1)) if match else None
    return round(1000 / ms, 1) if ms else None


def display_missing(display):
    """Why the frame-rate rows cannot be judged on this display ([] at FRAME_HZ, within VirtualDisplay's 15 %)."""
    hz = display_hz(display)
    if hz is None:
        line = (display.get("probe") or display.get("line")) if isinstance(display, dict) else None
        return [f"display: refresh not measured ({line or 'no display record'}); rows defined at {FRAME_HZ:g} Hz not judged"]
    if abs(1000 / hz - 1000 / FRAME_HZ) > 0.15 * 1000 / FRAME_HZ:
        return [f"display: measured at {hz:g} Hz, not {FRAME_HZ:g} Hz; rows defined at {FRAME_HZ:g} Hz not judged"]
    return []


def wait_quiet(max_load, wait_s, load=lambda: os.getloadavg()[0], sleep=time.sleep, clock=time.monotonic):
    """The 1-minute load once it is under `max_load`, or after `wait_s` seconds (then still above it)."""
    deadline = clock() + wait_s
    while load() >= max_load and clock() < deadline:
        sleep(5)  # waiting for a quiet host, as xbench's quiet()
    return round(load(), 2)


def run_step(step, opts, runner=subprocess.run):
    """{"exits": [...], "load": ..., "log": path}; the combined output of each command in OUT/<step>.log."""
    evidence = {"load": wait_quiet(opts.max_load, opts.quiet_wait) if step.quiet else None, "exits": []}
    log = Path(opts.out) / f"{step.name}.log"
    if step.name == "d7-auto":
        problems, reports = (launched_d7_auto(opts.app, f"{opts.out}/d7-auto") if opts.app
                             else run_d7_auto(cli_rpc(opts.tag)))
        log.write_text(json.dumps({"problems": problems, "reports": reports}, indent=1) + "\n")
        return {**evidence, "problems": problems}
    with log.open("w") as handle:
        for index, argv in enumerate(step.commands):
            handle.write("$ " + shlex.join(argv) + "\n")
            handle.flush()
            code = runner(list(argv), cwd=REPO, stdout=handle, stderr=subprocess.STDOUT).returncode
            evidence["exits"].append(code)
            if code not in step.ok_exits and index + 1 < len(step.commands):
                left = len(step.commands) - index - 1
                evidence["stopped"] = f"command {index + 1} exited {code}: the {left} after it did not run"
                handle.write(f"# {evidence['stopped']}\n")
                break
    return {**evidence, "log": str(log)}


def clear_outputs(out, name):
    """Deletes what a step writes (OUT/<name>.log and OUT/<name>/), before it runs or is skipped."""
    Path(out, f"{name}.log").unlink(missing_ok=True)
    shutil.rmtree(Path(out, name), ignore_errors=True)


# ---------------------------------------------------------------------------------------------------------
# Judging: fixture-testable parsers of each tool's output


def verdict(problems=(), missing=(), notes=()):
    """pass, fail (a problem), or not judged (something not measured); notes never change it."""
    status = "fail" if problems else "not judged" if missing else "pass"
    return {"status": status, "problems": list(problems), "missing": list(missing), "notes": list(notes)}


def merge(*parts):
    return verdict([p for v in parts for p in v["problems"]], [m for v in parts for m in v["missing"]],
                   [n for v in parts for n in v["notes"]])


def judge_audit(code, text):
    """D1 from wakeup-audit --strict: exit 0 passes; exit 1 lists the open hits."""
    if code is None:
        return verdict(missing=["wakeup-audit did not run"])
    hits = re.findall(r"^wakeup-audit: (\S+:\d+: .*)$", text or "", re.M)
    if code == 0:
        return verdict(notes=re.findall(r"^wakeup-audit \S+.*: .*$", text or "", re.M))
    if code == 1:
        return verdict([f"{len(hits)} open hit(s)", *hits[:10]])
    return verdict(missing=[f"wakeup-audit exited {code}"])


def sessions_ran(report, sessions):
    """Missing entries for each of `sessions` that did not run cleanly in an idle-budget report."""
    if not report:
        return ["idle-budget did not run (no report)"]
    missing = []
    for session in sessions:
        code = (report.get("session_exits") or {}).get(session)
        error = ((report.get("sessions") or {}).get(session) or {}).get("error")
        if code is None:
            missing.append(f"{session}: not run" + (f" ({error})" if error else ""))
        elif code != 0:
            missing.append(f"{session}: failed (exit {code}): {error}")
        if session in (report.get("refused") or []):
            missing.append(f"{session}: refused (IDLE-BUDGET-REFUSED)")
    return missing


def numeric(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def median_over(overs, windows):
    """One row's over in the median of `windows` windows, from the windows where it was over (each [session,
    subject, field, value, limit]), or None. The median of the windows' values is over its limit exactly when most
    windows are over; it is then the median's place among the over values (the others are under the limit)."""
    if len(overs) * 2 <= windows:
        return None
    values = [over[3] for over in overs]
    value = sorted(values)[(windows - 1) // 2 - (windows - len(values))] if all(map(numeric, values)) else values[0]
    return [*overs[0][:3], value, overs[0][4], f"(over in {len(overs)} of {windows} windows)"]


def merge_windows(reports):
    """One report of a step's WINDOWS idle-budget reports (None: that window wrote none), judged as their median:
    a row is over when it is over in most windows (median_over); a session ran only when it ran cleanly in every
    window; every window's refusals, not-judged notes and failed readers count. None when no window has a report."""
    reports = list(reports or []) + [None] * (WINDOWS - len(reports or []))
    present = [report for report in reports if report]
    if not present:
        return None
    by_row = {}
    for report in present:
        for over in report.get("over") or []:
            by_row.setdefault(tuple(map(str, over[:3])), []).append(list(over))
    names = list(dict.fromkeys(name for report in present for name in report.get("session_exits") or {}))
    exits, sessions = {}, {}
    for name in names:
        codes = [((report or {}).get("session_exits") or {}).get(name) for report in reports]
        entries = [((report or {}).get("sessions") or {}).get(name) or {} for report in reports]
        not_run = [index for index, code in enumerate(codes, 1) if code is None]
        failed = [code for code in codes if code]
        exits[name] = None if not_run else failed[0] if failed else 0
        errors = [f"window {index}: {entry['error']}" for index, entry in enumerate(entries, 1) if entry.get("error")]
        sessions[name] = {
            "error": f"not run in window {','.join(map(str, not_run))}" if not_run else "; ".join(errors) or None,
            "not_judged": list(dict.fromkeys(note for entry in entries for note in entry.get("not_judged") or [])),
            "readers_failed": list(dict.fromkeys(r for entry in entries for r in entry.get("readers_failed") or []))}
    return {"windows": len(reports), "session_exits": exits, "sessions": sessions,
            "over": [over for overs in by_row.values() if (over := median_over(overs, len(reports)))],
            "refused": list(dict.fromkeys(name for report in present for name in report.get("refused") or [])),
            "not_judged": list(dict.fromkeys(note for report in present for note in report.get("not_judged") or []))}


def over_checks(over, assertion_keys):
    """The D-checks one idle-budget over [session, subject, field, value, limit] fails. D17 is judge_d17's alone
    (renderer visibility and <= 1 timer wake/s); a hidden session's other renderer rows are its own check's."""
    session, subject, field = over[0], str(over[1]), str(over[2])
    if field == "role":
        return ["D16"]
    if subject == "assertions" or field in assertion_keys:
        return ["D11"]
    if field.startswith(("disk_", "network_", "log_")):
        return ["D15"]
    return [SESSION_CHECK[session]] if session in SESSION_CHECK else []


def note_checks(note, session, assertion_keys):
    """The D-checks one idle-budget not-judged note of `session` belongs to. A note names `<session> <subject>
    <field>[/<reference>]: ...`; one with no field (a Debug build's own rows) covers every row of the session."""
    head = note.split(":", 1)[0].split()
    if len(head) < 3:
        checks = [SESSION_CHECK.get(session), "D11", "D15", "D16"]
    else:
        field = head[2].split("/", 1)[0]
        checks = ["D16"] if field in ("role", "reshow") else over_checks([session, head[1], field], assertion_keys)
    if session == "chrome-static":  # the reference browser: its rows are D4's ratios, never cmux's D11 or D15
        checks = [SESSION_CHECK[session]]
    return [check for check in checks if check]


def deferred_note(note, session, budget):
    """Whether `note` is idle-budget's deferred_notes line: a kind limit set to null with a `_<field>` reason (a
    row a later task turns on). Every other not-judged note is a row not measured."""
    kinds = (((budget.get("sessions") or {}).get(session) or {}).get("kinds")) or {}
    return any(note.startswith(f"{session} {name} {field}: not judged: ")
               for name, limits in kinds.items() for field, limit in limits.items()
               if not field.startswith("_") and limit is None and limits.get("_" + field))


def judge_idle(report, budget, sessions=None):
    """{D: verdict} of the D-checks an idle-budget report judges: its overs by session and field, and as missing
    its sessions (and each check's reference session) not run cleanly, each not-judged note (but a deferred row's,
    which rides along) and each failed D15 reader."""
    keys = set(budget.get("assertions_allowed_when") or [])
    sessions = sessions or BENCH_SESSIONS
    checks = sorted({SESSION_CHECK[s] for s in sessions} | {"D11", "D15", "D16"}, key=lambda c: int(c[1:]))
    problems, missing, notes = ({check: [] for check in checks} for _ in range(3))
    for over in (report or {}).get("over") or []:
        for check in over_checks(over, keys):
            if check in problems:
                problems[check].append("IDLE-BUDGET-OVER " + " ".join(map(str, over)))
    entries = (report or {}).get("sessions") or {}
    for session in sessions:
        entry = entries.get(session) or {}
        for note in entry.get("not_judged") or []:
            into = notes if deferred_note(note, session, budget) else missing
            for check in note_checks(note, session, keys):
                if check in into:
                    into[check].append(note)
        if session != "chrome-static":
            missing["D15"] += [f"{session}: the {reader} reader failed (not measured)"
                               for reader in entry.get("readers_failed") or []]
    for note in (report or {}).get("not_judged") or []:  # the cross-session rows judge_across could not judge
        session = (note.split() or [""])[0]
        for check in note_checks(note, session, keys) if session in sessions else []:
            if check in missing:
                missing[check].append(note)
    out = {}
    for check in checks:
        own = [s for s in sessions if SESSION_CHECK.get(s) == check] or (
            list(ROLE_SESSIONS) if check == "D16" else [s for s in sessions if s != "chrome-static"])
        needed = own + [s for s in REFERENCE_SESSIONS.get(check, ()) if s not in own]
        out[check] = verdict(problems[check], sessions_ran(report, needed) + missing[check], notes[check])
    return out


def session_result(report, session):
    return (((report or {}).get("sessions") or {}).get(session) or {}).get("result") or {}


def median_ledger(ledgers):
    """The debug.wakeups ledger owners, each (owner, reason) at its median rate over the windows' ledgers (0 in
    a window that has no such owner)."""
    rates = [{(entry.get("owner"), entry.get("reason")): entry.get("per_s") or 0 for entry in ledger.get("owners") or []}
             for ledger in ledgers]
    keys = dict.fromkeys(key for window in rates for key in window)
    return [{"owner": owner, "reason": reason, "per_s": statistics.median(window.get((owner, reason), 0) for window in rates)}
            for owner, reason in keys]


def early_passes(cef):
    """CEFPumpStats earlyPasses of one cef-idle window, or None when the app did not report the counter (only the
    counters it reported are in `pump_per_s`)."""
    if not isinstance(cef, dict) or "early_passes" not in (cef.get("pump_per_s") or {}):
        return None
    return cef.get("early_passes")


def judge_d12(windows, cefs, budget):
    """D12: in the median of the windows, no ledger owner over 0.1/s in tabs-static but CEFMessagePump `delayed`
    and allowed_periodic owners, BusyWatchdog `window` at 0/s; CEFPumpStats earlyPasses 0 in cef-idle."""
    allowed = {entry.get("owner") for entry in budget.get("allowed_periodic") or []}
    windows = list(windows or []) + [None] * (WINDOWS - len(windows or []))
    problems, missing = [], sessions_ran(merge_windows(windows), ["tabs-static"])
    ledgers = [session_result(window, "tabs-static").get("ledger") for window in windows]
    if not missing and not all(ledgers):
        missing.append("tabs-static has no debug.wakeups ledger in every window (a build without it)")
    for entry in median_ledger(ledgers) if all(ledgers) else []:
        owner, reason, rate = entry["owner"], entry["reason"], entry["per_s"]
        if owner == "BusyWatchdog" and reason == "window" and rate > 0:
            problems.append(f"BusyWatchdog.window at {rate}/s (want 0)")
        elif rate > D12_OWNER_MAX and (owner, reason) != ("CEFMessagePump", "delayed") \
                and owner not in allowed and f"{owner}.{reason}" not in allowed:
            problems.append(f"ledger owner {owner} {reason} at {rate}/s > {D12_OWNER_MAX}")
    if cefs is None:
        return verdict(problems, [*missing, "cef-idle: not run"])
    cefs = list(cefs) + [None] * (WINDOWS - len(cefs))
    counts = [early_passes(cef) for cef in cefs]
    for index, (cef, count) in enumerate(zip(cefs, counts), 1):
        if count is None:
            error = cef.get("error") if isinstance(cef, dict) else "no cef-idle.json"
            missing.append(f"cef-idle window {index}: no early-pass count from the app" + (f" ({error})" if error else ""))
    if None not in counts and statistics.median(counts) != 0:
        problems.append(f"cef-idle: a median of {statistics.median(counts)} early CEF pump passes in {len(counts)} "
                        "windows (want 0)")
    return verdict(problems, missing)


def judge_d17(windows):
    """D17: in each hidden session, in the median of the windows, every Chromium renderer row is hidden (the page
    census) and the busiest is at <= 1 wake/s."""
    windows = list(windows or []) + [None] * (WINDOWS - len(windows or []))
    problems, missing, merged = [], [], merge_windows(windows)
    if merged is None:
        return verdict(missing=sessions_ran(None, HIDDEN_SESSIONS))
    for session in HIDDEN_SESSIONS:
        not_run = sessions_ran(merged, [session])
        rows = [[row for row in session_result(window, session).get("processes") or [] if row.get("kind") == "cef-renderer"]
                for window in windows]
        empty = [index for index, found in enumerate(rows, 1) if not found]
        if not_run or empty:
            missing += not_run or [f"{session}: no Chromium renderer measured (window {','.join(map(str, empty))})"]
            continue
        shown = {index: [row.get("pid") for row in found if row.get("hidden") is not True]
                 for index, found in enumerate(rows, 1)}
        if sum(bool(pids) for pids in shown.values()) * 2 > len(rows):
            problems.append(f"{session}: renderers not reported hidden: " + "; ".join(
                f"window {index} pid {','.join(map(str, pids))}" for index, pids in shown.items() if pids))
        busiest = statistics.median(max(row.get("wakeups_per_s") or 0 for row in found) for found in rows)
        if busiest > D17_RENDERER_WAKES:
            problems.append(f"{session}: the busiest renderer at a median {busiest}/s > {D17_RENDERER_WAKES}")
    return verdict(problems, missing, ["a hidden page's rAF count is not read in these sessions"])


def judge_d8(d8):
    """D8 from bench-typing's d8.json verdicts (pass, fail, unscored) of each surface; its split-spring part is
    not measured yet (D8_SPLIT_SPRING)."""
    verdicts = (d8 or {}).get("d8") or {}
    problems, missing = [], []
    for surface in D8_SURFACES:
        entry = verdicts.get(surface)
        if not entry:
            missing.append(f"{surface}: not measured with both saver states")
        elif entry.get("verdict") == "fail":
            problems.append(f"{surface}: {entry.get('check')}: on {entry.get('on')} off {entry.get('off')}")
        elif entry.get("verdict") != "pass":
            missing.append(f"{surface}: unscored: {'; '.join(entry.get('why') or [])}")
    return verdict(problems, [*missing, D8_SPLIT_SPRING])


def judge_xbench(code, text):
    """D6's xbench rows from `idle-budget.py --xbench` output."""
    if code is None or "IDLE-BUDGET over=" not in (text or ""):
        return verdict(missing=["xbench: no D6 verdict (xbench did not run, or wrote no results.json)"])
    return verdict(re.findall(r"^(IDLE-BUDGET-OVER xbench .*)$", text, re.M),
                   re.findall(r"^IDLE-BUDGET-NOT-JUDGED (xbench .*)$", text, re.M))


NEXTEST_RE = re.compile(r"^\s*(PASS|FAIL|TIMEOUT|SIG[A-Z]+|LEAK-FAIL|TRY \d+ FAIL)\s+\[[^\]]*\]\s+"
                        r"(?:\(\s*\d+/\d+\)\s+)?(\S+)\s+(\S+)\s*$", re.M)


def judge_d9(code, text):
    """D9 from the cmux-tui-rust-check.sh step (cargo nextest): both idle test binaries pass."""
    if code is None:
        return verdict(missing=["the Rust idle tests did not run"])
    if code in FLEET_EXITS:
        return verdict(missing=[f"cmux-ci: {FLEET_EXITS[code]} (exit {code}): rerun"])
    results = NEXTEST_RE.findall(text or "")
    failed = [f"{status} {binary} {test}" for status, binary, test in results if status != "PASS"]
    passed = {binary for status, binary, _ in results if status == "PASS"}
    absent = [name for name in D9_BINARIES if not any(binary.endswith(name) for binary in passed)]
    if code != 0:
        return verdict(failed or [f"the step exited {code}"])
    return verdict(missing=[f"no passing {name} test" for name in absent], notes=[f"retried: {f}" for f in failed])


def judge_d10(code, text):
    """D10 from package-test-lane.sh suite's results table: every D10 suite passed."""
    if code is None:
        return verdict(missing=["the Swift suites did not run"])
    if code in FLEET_EXITS:
        return verdict(missing=[f"cmux-ci: {FLEET_EXITS[code]} (exit {code}): rerun"])
    rows = dict(re.findall(r"^(\w+)\s+(passed|failed \(exit \d+\)|stalled/timeout)\s+\d+s\s*$", text or "", re.M))
    problems = [f"{suite}: {rows[suite]}" for suite in D10_SUITES if suite in rows and rows[suite] != "passed"]
    missing = [f"{suite}: no result" for suite in D10_SUITES if suite not in rows]
    if code != 0 and not problems and not missing:
        problems = [f"the step exited {code}"]
    return verdict(problems, missing)


def judge_all(data, budget):
    """{D: verdict} for every D-check from the collected outputs (`collect`)."""
    idle_windows = data.get("idle")
    idle = judge_idle(merge_windows(idle_windows), budget)
    signed_in = data.get("signed_in")
    signed = judge_idle(merge_windows(signed_in), budget, SIGNED_IN_SESSIONS) if signed_in is not None else {}
    no_signed = verdict(missing=["signed-in sessions: not run (--debug-app)"])
    d7_auto = data.get("d7_auto")
    checks = {
        "D1": judge_audit(*data.get("audit", (None, None))),
        **{d: idle[d] for d in ("D2", "D3", "D4", "D5", "D14", "D16")},
        "D6": merge(idle["D6"], judge_xbench(*data.get("xbench", (None, None)))),
        "D7": merge(idle["D7"], verdict(missing=["D7 auto: not run"]) if d7_auto is None
                    else verdict([f"D7 auto: {p}" for p in d7_auto])),
        "D8": judge_d8(data.get("d8")),
        "D9": judge_d9(*data.get("rust", (None, None))),
        "D10": judge_d10(*data.get("swift", (None, None))),
        "D11": merge(idle["D11"], signed.get("D11", no_signed)),
        "D12": judge_d12(idle_windows, data.get("cef"), budget),
        "D13": merge(idle["D13"], signed.get("D13", no_signed)),
        "D15": merge(idle["D15"], signed.get("D15", no_signed)),
        "D17": judge_d17(idle_windows),
    }
    displays = data.get("display") or {}
    for check, steps in FRAME_STEPS.items():
        missing = [f"{step} {problem}" for step in steps if step in displays for problem in display_missing(displays[step])]
        checks[check] = merge(checks[check], verdict(missing=missing))
    return {check: checks[check] for check in CHECKS}


def read_json(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None


def read_log(out, name, ran):
    """(last exit, text) of OUT/<name>.log and its exits in `ran` (the steps.json entries), or (None, None)."""
    exits = (ran.get(name) or {}).get("exits") or []
    try:
        return (exits[-1] if exits else None), (Path(out) / f"{name}.log").read_text(errors="replace")
    except OSError:
        return None, None


def collect(out, ran):
    """The outputs in OUT of the steps `ran` records as run (steps.json entries; a skipped or absent step's files,
    an earlier run's, are never read), for judge_all."""
    out = Path(out)
    ran = {name: entry for name, entry in (ran or {}).items() if isinstance(entry, dict) and not entry.get("skipped")}
    log = lambda name: read_log(out, name, ran) if name in ran else (None, None)  # noqa: E731
    windows = lambda name, file: (  # noqa: E731
        [read_json(out / name / f"w{n}" / file) for n in range(1, WINDOWS + 1)] if name in ran else None)
    d7 = read_json(out / "d7-auto.log") if "d7-auto" in ran else None
    return {"audit": log("audit"), "idle": windows("idle-budget", "idle-budget.json"),
            "signed_in": windows("idle-budget-signed-in", "idle-budget.json"), "cef": windows("cef-idle", "cef-idle.json"),
            "d8": read_json(out / "bench-typing" / "d8.json") if "bench-typing" in ran else None,
            "xbench": log("xbench"), "rust": log("rust-idle"), "swift": log("swift-suites"),
            "d7_auto": d7.get("problems") if isinstance(d7, dict) else None,
            "display": {name: entry.get("display") for name, entry in ran.items() if "display" in entry}}


# ---------------------------------------------------------------------------------------------------------
# Report


def cell(result):
    if result["status"] == "pass":
        return "pass" + (f" ({'; '.join(result['notes'][:3])})" if result["notes"] else "")
    detail = result["problems"] if result["status"] == "fail" else result["missing"]
    return f"{'FAIL' if result['status'] == 'fail' else 'not judged'}: " + "; ".join(detail[:6]).replace("|", "/")


def describe_display(display):
    """One measuring step's display, for the report."""
    hz = display_hz(display)
    if hz is None:
        return "refresh not measured"
    return f"{hz:g} Hz " + ("virtual display" if display.get("vdisplay") else "real display")


def markdown(checks, sha, host, loads, displays):
    date = datetime.date.today().isoformat()
    lines = [f"# cmux energy test phase, {host}, {sha}", "", "| Check | What | Result |", "| --- | --- | --- |"]
    lines += [f"| {check} | {CHECKS[check]} | {cell(result)} |" for check, result in checks.items()]
    hot = {step: load for step, load in loads.items() if load is not None}
    lines += ["", "Load (1 min) at each measuring step's start: " + (", ".join(f"{s} {l}" for s, l in hot.items()) or "none"),
              "", "Display of each measuring step: "
              + (", ".join(f"{s} {describe_display(d)}" for s, d in displays.items()) or "none"),
              "", "Rows for plans/cmux-next/perf-lead.md sec. 5:", "",
              "| Date | Workstream | sha range on feat-cmux-next | Row | Before | After |", "|---|---|---|---|---|---|"]
    lines += [f"| {date} | p14-energy test phase (energy-test-phase.py, {host}) | {sha[:11]} | {check} {CHECKS[check]} | - | "
              f"{cell(result)} |" for check, result in checks.items()]
    return "\n".join(lines)


def parse_checks(text):
    checks = list(CHECKS) if text == "all" else [name.strip() for name in text.split(",") if name.strip()]
    unknown = [name for name in checks if name not in CHECKS]
    if unknown:
        raise SystemExit(f"unknown check {unknown[0]}; known: {', '.join(CHECKS)}")
    return checks


def head_sha():
    done = subprocess.run(["git", "-C", str(REPO), "rev-parse", "HEAD"], capture_output=True, text=True, check=False)
    return done.stdout.strip() or "unknown"


LOST_DISPLAY = {"vdisplay": False, "refresh_ms": None, "line": "the virtual display helper exited during the step"}


def run_steps(steps, opts, runner, start_display, record):
    """{name: evidence} of each step, run in order: its outputs deleted first, skipped or run; the measuring
    steps on one display brought up before the first of them and ended after the last. `record(done)` after each."""
    done, holder, display = {}, None, None
    try:
        for step in steps:
            clear_outputs(opts.out, step.name)
            if step.skip:
                done[step.name] = {"skipped": step.skip}
            elif not step.display:
                done[step.name] = run_step(step, opts, runner)
            else:
                if holder is None:
                    shutil.rmtree(Path(opts.out, "vdisplay"), ignore_errors=True)
                    display, holder = start_display(Path(opts.out, "vdisplay"), opts.vdisplay)
                evidence = run_step(step, opts, runner)
                done[step.name] = {**evidence, "display": display if holder.alive() else {**display, **LOST_DISPLAY}}
            record(done)
    finally:
        if holder is not None:
            holder.stop()
    return done


def main(argv=None, runner=subprocess.run, start_display=start_vdisplay):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--app", type=os.path.abspath, help="a Release + CMUX_BENCH_HOOKS `cmux DEV <tag>.app` (not running)")
    parser.add_argument("--debug-app", type=os.path.abspath, help="a Debug bundle of the same commit (signed-in sessions)")
    parser.add_argument("--tag", help="D7 auto against this tag's running app (when no --app)")
    parser.add_argument("--checks", default="all", help=f"comma-separated: {', '.join(CHECKS)}, or all")
    parser.add_argument("--ref", default=None, help="the measured commit (default HEAD): the fleet steps' --ref")
    parser.add_argument("--out", type=os.path.abspath, default=None, help="default artifacts/energy-test-phase/<sha>")
    parser.add_argument("--chrome-app", help="the reference browser (idle-budget chrome-static, xbench chrome)")
    parser.add_argument("--chrome-ublock", help="uBlock Origin for the reference browser (fetch-ublock.sh)")
    parser.add_argument("--cmux-ci", default="cmux-ci")
    parser.add_argument("--max-load", type=float, default=4)
    parser.add_argument("--quiet-wait", type=float, default=900, help="seconds to wait for the load to drop")
    parser.add_argument("--vdisplay", type=float, default=FRAME_HZ,
                        help="Hz of the virtual main display the measuring steps run on (0: the real display, probed)")
    parser.add_argument("--json", type=Path, help="also write the report JSON here")
    parser.add_argument("--dry-run", action="store_true", help="print the exact commands of each step and run nothing")
    parser.add_argument("--collect-only", action="store_true", help="judge the outputs already in --out; run nothing")
    opts = parser.parse_args(argv)
    if opts.app and not tag_of(opts.app):
        parser.error(f"--app must be a `cmux DEV <tag>.app` bundle, not {opts.app}")
    checks = parse_checks(opts.checks)
    opts.ref = opts.ref or head_sha()
    opts.out = opts.out or str(REPO / "artifacts" / "energy-test-phase" / opts.ref[:12])
    steps = [step for step in plan(opts, checks) if set(step.checks) & set(checks)]
    if opts.dry_run:
        if any(step.display and not step.skip for step in steps):
            print(display_text(opts))
        for step in steps:
            print(f"# {step.name} ({', '.join(step.checks)})" + (f": skipped, {step.skip}" if step.skip else ""))
            print("\n".join(step.lines()))
        return 0
    os.makedirs(opts.out, exist_ok=True)
    steps_path = Path(opts.out) / "steps.json"
    earlier = read_json(steps_path) or {}
    if opts.collect_only:
        judged = earlier
    else:
        judged = run_steps(steps, opts, runner, start_display,
                           lambda done: steps_path.write_text(json.dumps({**earlier, **done}, indent=1) + "\n"))
    ran = {**earlier, **judged}
    budget = read_json(BUDGET_FILE) or {}
    results = {check: result for check, result in judge_all(collect(opts.out, judged), budget).items() if check in checks}
    for step in steps:
        load = (ran.get(step.name) or {}).get("load")
        for check in (c for c in step.checks if c in results and load is not None and load >= opts.max_load):
            results[check]["notes"].append(f"{step.name} started at load {load} (not under {opts.max_load:g})")
    loads = {name: entry.get("load") for name, entry in ran.items()}
    displays = {name: entry["display"] for name, entry in ran.items() if entry.get("display")}
    text = markdown(results, opts.ref, socket.gethostname(), loads, displays)
    print(text)
    report = {"sha": opts.ref, "host": socket.gethostname(), "steps": ran, "checks": results}
    (Path(opts.out) / "report.md").write_text(text + "\n")
    for path in [Path(opts.out) / "report.json", *([opts.json] if opts.json else [])]:
        path.write_text(json.dumps(report, indent=2) + "\n")
    return 0 if all(result["status"] == "pass" for result in results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
