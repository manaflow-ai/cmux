#!/usr/bin/env python3
"""The energy program's test phase: one entry point for D1-D17 (plans/cmux-next/chrome-parity/p14-energy.md, sec. 5).

Runs on the macOS measure host (a fleet Mac's console, a 120 Hz display) against a Release + CMUX_BENCH_HOOKS
bundle of the measured commit (`--app`, for example `split-spring.sh --config=bench --build-only`'s), and judges:

  D1          python3 -I scripts/cmux-next/wakeup-audit.py --strict (static, any host)
  D2-D5, D7, D11-D17  idle-budget.py --gate over every idle session in shipping mode (one run, its JSON report:
              overs by session, `role` overs for D16, assertion overs for D11, disk/network/log overs for D15, the
              tabs-static wakeup ledger for D12, the hidden sessions' renderer rows for D17)
  D13 signed-in  idle-budget.py on a Debug bundle of the same commit (`--debug-app`: the app signs a test account in
              only in Debug; those rows are reported, not judged)
  D12         cef-idle-probe.py: CEFPumpStats earlyPasses in the window
  D8          bench-typing.py: native terminal, Chromium agent composer and Chromium page scroll, saver off and on
  D6          xbench.py run with Chrome (cmux-chromium, cmux-terminal, chrome), then idle-budget.py --xbench
  D7 auto     launch the bundle with the energySaver feature on, `debug.energy.simulate {on_battery: true,
              percent: 15}`: reason `battery`; `{clear: true}` must restore the Mac's own policy and inputs,
              "Turn Off Energy Saver for Now" (`sessionOverride`) included (fleet Macs have no battery). With only
              `--tag` it talks to that tag's running app through scripts/cmux-debug-cli.sh instead.
  D9          the Rust idle tests (idle_wakeups, daemon_idle) on a macOS fleet step (cmux-ci run); Linux is task 131
  D10         the Swift suites of D10 on a fleet step (cmux-ci run, package-test-lane.sh suite)

Before each measuring step it waits for the 1-minute load to drop under --max-load (4), at most --quiet-wait
seconds; a step that starts above it says so on its checks. Each check is pass, FAIL or not judged (not measured,
or its tool could not judge): not measured is never a pass, and the exit status is 0 only when every asked check
passes. Writes Markdown (stdout and OUT/report.md, with the rows for plans/cmux-next/perf-lead.md sec. 5) and JSON
(OUT/report.json, and --json). --dry-run prints each step's exact commands; --collect-only judges the outputs
already in OUT without running anything.

  python3 scripts/cmux-next/energy-test-phase.py --app "<...>/cmux DEV <tag>.app" [--debug-app APP] [--checks D1,D7|all]
      [--out DIR] [--ref SHA] [--chrome-app APP] [--chrome-ublock DIR] [--json out.json] [--dry-run] [--collect-only]
  python3 scripts/cmux-next/energy-test-phase.py --tag energy-sim --checks D7   (D7 auto against a running tagged app)

Never referenced from .github/workflows: the person or agent runs it on the fleet.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import shlex
import socket
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
# What a check needs beyond its own sessions: the session its relative rows compare with, or the sessions it reads.
SESSIONS_NEEDED = {"D3": ("light",), "D7": ("tabs-static",), "D12": ("tabs-static",), "D16": ROLE_SESSIONS,
                   "D17": HIDDEN_SESSIONS, "D11": BENCH_SESSIONS, "D15": BENCH_SESSIONS}


def idle_sessions(checks):
    """The bench bundle's idle-budget sessions the asked checks need, in BENCH_SESSIONS order."""
    wanted = {s for s in BENCH_SESSIONS if SESSION_CHECK[s] in checks}
    wanted |= {s for check in checks for s in SESSIONS_NEEDED.get(check, ())}
    return tuple(s for s in BENCH_SESSIONS if s in wanted)
D17_RENDERER_WAKES = 1.0  # a hidden unfrozen page: <= 1 timer wake/s
D12_OWNER_MAX = 0.1
D8_SURFACES = ("terminal", "agent-composer-chromium", "chromium-page-scroll")
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

    def lines(self):
        return list(self.text) or [shlex.join(argv) for argv in self.commands]


def tag_of(app):
    match = re.fullmatch(r"cmux DEV (.+)\.app", os.path.basename(os.path.normpath(app)))
    return re.sub(r"[^a-z0-9]+", "-", match.group(1).lower()).strip("-") if match else None


def plan(opts, checks=tuple(CHECKS)):
    """The steps of a full run with these options, each with the D-checks it feeds."""
    out, app, ref, py = opts.out, opts.app or "APP", opts.ref, "python3"
    no_app = "" if opts.app else "needs --app (a Release + CMUX_BENCH_HOOKS bundle)"
    chrome = [*(["--chrome-app", opts.chrome_app] if opts.chrome_app else []),
              *(["--chrome-ublock", opts.chrome_ublock] if opts.chrome_ublock else [])]
    idle = lambda name, bundle, sessions, gate: [  # noqa: E731
        py, "scripts/cmux-next/idle-budget.py", "--app", bundle, "--out", f"{out}/{name}", "--json",
        f"{out}/{name}/idle-budget.json", "--sessions", ",".join(sessions), *(["--gate"] if gate else []), *chrome]
    xbench = f"{out}/xbench"
    fleet = lambda name, step_class, script, *args: [  # noqa: E731
        opts.cmux_ci, "run", "--class", step_class, "--script", script, "--ref", ref,
        "--key", f"energy-test-phase-{ref}-{name}", *[f"--arg={arg}" for arg in args]]
    d7 = (*(["# launch --app (bench_launch.BenchApp, CMUX_ENABLE_FEATURES=energySaver), then on its socket:"]
            if opts.app else []), *d7_auto_commands(tag_of(app) or opts.tag or "TAG"))
    return [
        Step("audit", ("D1",), ((py, "-I", "scripts/cmux-next/wakeup-audit.py", "--strict"),), quiet=False),
        Step("idle-budget", ("D2", "D3", "D4", "D5", "D6", "D7", "D11", "D12", "D13", "D14", "D15", "D16", "D17"),
             (idle("idle-budget", app, idle_sessions(checks), True),), skip=no_app),
        Step("idle-budget-signed-in", ("D11", "D13", "D15"),
             (idle("idle-budget-signed-in", opts.debug_app or "DEBUG_APP", SIGNED_IN_SESSIONS, False),),
             skip="" if opts.debug_app else "needs --debug-app (a Debug bundle of the same commit)"),
        Step("cef-idle", ("D12",), ((py, "scripts/cmux-next/cef-idle-probe.py", "--app", app, "--out", f"{out}/cef-idle"),),
             skip=no_app),
        Step("bench-typing", ("D8",), ((py, "scripts/cmux-next/bench-typing.py", "--app", app, "--surface",
                                        ",".join(D8_SURFACES), "--energy-saver", "off,on", "--out", f"{out}/bench-typing"),),
             skip=no_app),
        Step("xbench", ("D6",), (
            (py, "scripts/perf-bench/xbench.py", "run", "--out", f"{xbench}/run", "--app", f"cmux={app}",
             *(["--app", f"chrome={opts.chrome_app}"] if opts.chrome_app else []),
             *(["--chrome-extension", opts.chrome_ublock] if opts.chrome_ublock else []),
             "--browsers", "cmux-chromium,cmux-terminal,chrome", "--rounds", "3", "--max-load", f"{opts.max_load:g}"),
            (py, "scripts/perf-bench/xbench.py", "report", "--out", f"{xbench}/run", "--json", f"{xbench}/results.json"),
            (py, "scripts/cmux-next/idle-budget.py", "--xbench", f"{xbench}/results.json")), skip=no_app),
        Step("d7-auto", ("D7",), (), quiet=False, skip="" if opts.app or opts.tag else "needs --app or --tag", text=d7),
        Step("rust-idle", ("D9",), (fleet("d9", "isolated", "scripts/ci/cmux-tui-rust-check.sh", "test", "daemon_idle"),),
             quiet=False),
        Step("swift-suites", ("D10",), (fleet("d10", "light", "scripts/ci/package-test-lane.sh", "suite",
                                              "Packages/macOS/CmuxNext", ",".join(D10_SUITES)),), quiet=False),
    ]


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
        for argv in step.commands:
            handle.write("$ " + shlex.join(argv) + "\n")
            handle.flush()
            evidence["exits"].append(runner(list(argv), cwd=REPO, stdout=handle, stderr=subprocess.STDOUT).returncode)
    return {**evidence, "log": str(log)}


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
            missing.append(f"{session}: not run")
        elif code != 0:
            missing.append(f"{session}: failed (exit {code}): {error}")
        if session in (report.get("refused") or []):
            missing.append(f"{session}: refused (IDLE-BUDGET-REFUSED)")
    return missing


def over_checks(over, assertion_keys):
    """The D-checks one idle-budget over [session, subject, field, value, limit] fails."""
    session, subject, field = over[0], str(over[1]), str(over[2])
    if field == "role":
        return ["D16"]
    if subject == "assertions" or field in assertion_keys:
        return ["D11"]
    if field.startswith(("disk_", "network_", "log_")):
        return ["D15"]
    checks = [SESSION_CHECK[session]] if session in SESSION_CHECK else []
    return checks + (["D17"] if session in HIDDEN_SESSIONS and subject == "cef-renderer" else [])


def judge_idle(report, budget, sessions=None):
    """{D: verdict} of the D-checks an idle-budget report judges (its overs by session and field)."""
    keys = set(budget.get("assertions_allowed_when") or [])
    sessions = sessions or BENCH_SESSIONS
    out = {}
    for check in sorted({SESSION_CHECK[s] for s in sessions} | {"D11", "D15", "D16"}, key=lambda c: int(c[1:])):
        own = [s for s in sessions if SESSION_CHECK.get(s) == check] or (
            ROLE_SESSIONS if check == "D16" else [s for s in sessions if s != "chrome-static"])
        overs = [over for over in (report or {}).get("over") or [] if check in over_checks(over, keys)]
        notes = [note for s in own for note in ((report or {}).get("sessions") or {}).get(s, {}).get("not_judged") or []]
        out[check] = verdict(["IDLE-BUDGET-OVER " + " ".join(map(str, over)) for over in overs],
                             sessions_ran(report, own), notes)
    return out


def session_result(report, session):
    return (((report or {}).get("sessions") or {}).get(session) or {}).get("result") or {}


def judge_d12(report, cef, budget):
    """D12: no ledger owner over 0.1/s in tabs-static but CEFMessagePump `delayed` and allowed_periodic owners,
    BusyWatchdog `window` at 0/s; CEFPumpStats earlyPasses 0 in cef-idle."""
    allowed = {entry.get("owner") for entry in budget.get("allowed_periodic") or []}
    problems, missing = [], sessions_ran(report, ["tabs-static"])
    ledger = session_result(report, "tabs-static").get("ledger")
    if not missing and not ledger:
        missing.append("tabs-static has no debug.wakeups ledger (a build without it)")
    for entry in (ledger or {}).get("owners") or []:
        owner, reason, rate = entry.get("owner"), entry.get("reason"), entry.get("per_s") or 0
        if owner == "BusyWatchdog" and reason == "window" and rate > 0:
            problems.append(f"BusyWatchdog.window at {rate}/s (want 0)")
        elif rate > D12_OWNER_MAX and (owner, reason) != ("CEFMessagePump", "delayed") \
                and owner not in allowed and f"{owner}.{reason}" not in allowed:
            problems.append(f"ledger owner {owner} {reason} at {rate}/s > {D12_OWNER_MAX}")
    if not isinstance(cef, dict) or "early_passes" not in cef:
        missing.append("cef-idle: no early-pass count" + (f" ({cef['error']})" if isinstance(cef, dict) and cef.get("error") else ""))
    elif cef["early_passes"] != 0:
        problems.append(f"cef-idle: {cef['early_passes']} early CEF pump passes (want 0)")
    return verdict(problems, missing)


def judge_d17(report):
    """D17: in each hidden session every Chromium renderer row is hidden (the page census) and at <= 1 wake/s."""
    problems, missing = [], []
    for session in HIDDEN_SESSIONS:
        rows = [row for row in session_result(report, session).get("processes") or [] if row.get("kind") == "cef-renderer"]
        missing += sessions_ran(report, [session]) or ([] if rows else [f"{session}: no Chromium renderer measured"])
        for row in rows:
            if row.get("hidden") is not True:
                problems.append(f"{session}: renderer pid {row.get('pid')} is not reported hidden")
            if (row.get("wakeups_per_s") or 0) > D17_RENDERER_WAKES:
                problems.append(f"{session}: renderer pid {row.get('pid')} at {row['wakeups_per_s']}/s > {D17_RENDERER_WAKES}")
    return verdict(problems, missing, ["a hidden page's rAF count is not read in these sessions"])


def judge_d8(d8):
    """D8 from bench-typing's d8.json verdicts (pass, fail, unscored) of each surface."""
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
    return verdict(problems, missing)


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
    idle = judge_idle(data.get("idle"), budget)
    signed = judge_idle(data.get("signed_in"), budget, SIGNED_IN_SESSIONS) if data.get("signed_in") is not None else {}
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
        "D11": merge(idle["D11"], *([signed["D11"]] if signed else [])),
        "D12": judge_d12(data.get("idle"), data.get("cef"), budget),
        "D13": merge(idle["D13"], signed.get("D13", no_signed)),
        "D15": merge(idle["D15"], *([signed["D15"]] if signed else [])),
        "D17": judge_d17(data.get("idle")),
    }
    if signed:
        checks["D13"]["notes"].append("signed-in rows come from a Debug bundle: reported, not judged by idle-budget")
    return {check: checks[check] for check in CHECKS}


def read_json(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None


def read_log(out, name):
    """(last exit, text) of OUT/<name>.log and its exits in OUT/steps.json, or (None, None)."""
    exits = ((read_json(Path(out) / "steps.json") or {}).get(name) or {}).get("exits") or []
    try:
        return (exits[-1] if exits else None), (Path(out) / f"{name}.log").read_text(errors="replace")
    except OSError:
        return None, None


def collect(out):
    """The outputs a run left in OUT, for judge_all."""
    out = Path(out)
    d7 = read_json(out / "d7-auto.log")
    return {"audit": read_log(out, "audit"), "idle": read_json(out / "idle-budget" / "idle-budget.json"),
            "signed_in": read_json(out / "idle-budget-signed-in" / "idle-budget.json"),
            "cef": read_json(out / "cef-idle" / "cef-idle.json"), "d8": read_json(out / "bench-typing" / "d8.json"),
            "xbench": read_log(out, "xbench"), "rust": read_log(out, "rust-idle"), "swift": read_log(out, "swift-suites"),
            "d7_auto": d7.get("problems") if isinstance(d7, dict) else None}


# ---------------------------------------------------------------------------------------------------------
# Report


def cell(result):
    if result["status"] == "pass":
        return "pass" + (f" ({'; '.join(result['notes'][:3])})" if result["notes"] else "")
    detail = result["problems"] if result["status"] == "fail" else result["missing"]
    return f"{'FAIL' if result['status'] == 'fail' else 'not judged'}: " + "; ".join(detail[:6]).replace("|", "/")


def markdown(checks, sha, host, loads):
    date = datetime.date.today().isoformat()
    lines = [f"# cmux energy test phase, {host}, {sha}", "", "| Check | What | Result |", "| --- | --- | --- |"]
    lines += [f"| {check} | {CHECKS[check]} | {cell(result)} |" for check, result in checks.items()]
    hot = {step: load for step, load in loads.items() if load is not None}
    lines += ["", "Load (1 min) at each measuring step's start: " + (", ".join(f"{s} {l}" for s, l in hot.items()) or "none"),
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


def main(argv=None, runner=subprocess.run):
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
        for step in steps:
            print(f"# {step.name} ({', '.join(step.checks)})" + (f": skipped, {step.skip}" if step.skip else ""))
            print("\n".join(step.lines()))
        return 0
    os.makedirs(opts.out, exist_ok=True)
    ran = read_json(Path(opts.out) / "steps.json") or {}
    if not opts.collect_only:
        for step in steps:
            ran[step.name] = {"skipped": step.skip} if step.skip else run_step(step, opts, runner)
            (Path(opts.out) / "steps.json").write_text(json.dumps(ran, indent=1) + "\n")
    budget = read_json(BUDGET_FILE) or {}
    results = {check: result for check, result in judge_all(collect(opts.out), budget).items() if check in checks}
    for step in steps:
        load = (ran.get(step.name) or {}).get("load")
        for check in (c for c in step.checks if c in results and load is not None and load >= opts.max_load):
            results[check]["notes"].append(f"{step.name} started at load {load} (not under {opts.max_load:g})")
    loads = {name: entry.get("load") for name, entry in ran.items()}
    text = markdown(results, opts.ref, socket.gethostname(), loads)
    print(text)
    report = {"sha": opts.ref, "host": socket.gethostname(), "steps": ran, "checks": results}
    (Path(opts.out) / "report.md").write_text(text + "\n")
    for path in [Path(opts.out) / "report.json", *([opts.json] if opts.json else [])]:
        path.write_text(json.dumps(report, indent=2) + "\n")
    return 0 if all(result["status"] == "pass" for result in results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
