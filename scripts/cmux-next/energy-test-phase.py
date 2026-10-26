#!/usr/bin/env python3
"""The energy program's test phase (plans/cmux-next/chrome-parity/p14-energy.md, Phase P6).

Each check names its D-row and runs against a tagged Debug or bench build (`cmux-ci build cmux --ref SHA --tag TAG`,
then `cmux-ci publish-hq` so `scripts/cmux-debug-cli.sh` finds it). Task 090 adds the other D-checks to CHECKS; this
file starts with the one task 123 owns:

  D7-auto  Fleet Macs have no battery, so the `auto` saver's battery reason is checked with
           `debug.energy.simulate {on_battery: true, percent: 15}`: debug.energy must report isSaver with reason
           `battery` and `inputs.simulated`; `{clear: true}` must restore the Mac's own policy and inputs, "Turn Off
           Energy Saver for Now" (`sessionOverride`) included. The build
           needs the default-off `energySaver` feature on and `energy.saver` at `auto` (the default).

  CMUX_TAG=energy-sim scripts/cmux-debug-cli.sh rpc debug.energy.simulate '{"on_battery": true, "percent": 15}'
  python3 scripts/cmux-next/energy-test-phase.py --tag energy-sim [--checks D7-auto] [--json out.json] [--dry-run]

Writes Markdown (stdout) and, with --json, a JSON report with pass/fail per check; exits 1 when a check fails.
Never referenced from .github/workflows: the person or agent runs it on the fleet.
"""
from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DEBUG_CLI = REPO / "scripts" / "cmux-debug-cli.sh"

SIMULATE = "debug.energy.simulate"
ENERGY = "debug.energy"
# D7 auto: below the resolver's 20% threshold, on battery (EnergyPolicyResolver.lowBatteryThresholdPercent).
D7_AUTO_SIMULATION = {"on_battery": True, "percent": 15}
CLEAR = {"clear": True}


class RpcError(Exception):
    """The app answered with an error, or did not answer."""


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


# id -> (what it checks, the commands it runs for --dry-run, the runner over an rpc).
CHECKS = {
    "D7-auto": ("auto saver at 15% on battery (simulated) reports reason battery; clear restores",
                d7_auto_commands, run_d7_auto),
}


def run(checks, rpc):
    """{check: {"pass": bool, "problems": [...], "reports": {...}}} for each check id."""
    results = {}
    for check in checks:
        _, _, runner = CHECKS[check]
        try:
            problems, reports = runner(rpc)
        except RpcError as error:
            problems, reports = [str(error)], {}
        results[check] = {"pass": not problems, "problems": problems, "reports": reports}
    return results


def markdown(results):
    lines = ["| Check | What | Result |", "| --- | --- | --- |"]
    for check, result in results.items():
        verdict = "pass" if result["pass"] else "FAIL: " + "; ".join(result["problems"])
        lines.append(f"| {check} | {CHECKS[check][0]} | {verdict} |")
    return "\n".join(lines)


def parse_checks(text):
    checks = list(CHECKS) if text == "all" else [name.strip() for name in text.split(",") if name.strip()]
    unknown = [name for name in checks if name not in CHECKS]
    if unknown:
        raise SystemExit(f"unknown check {unknown[0]}; known: {', '.join(CHECKS)}")
    return checks


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--tag", required=True, help="the tagged Debug or bench build (CMUX_TAG)")
    parser.add_argument("--checks", default="all", help=f"comma-separated: {', '.join(CHECKS)}, or all")
    parser.add_argument("--json", type=Path, help="also write the results as JSON here")
    parser.add_argument("--dry-run", action="store_true", help="print the exact command of each check and run nothing")
    args = parser.parse_args(argv)
    checks = parse_checks(args.checks)
    if args.dry_run:
        for check in checks:
            print(f"# {check}: {CHECKS[check][0]}")
            print("\n".join(CHECKS[check][1](args.tag)))
        return 0
    results = run(checks, cli_rpc(args.tag))
    print(markdown(results))
    if args.json:
        args.json.write_text(json.dumps(results, indent=2) + "\n")
    return 0 if all(result["pass"] for result in results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
