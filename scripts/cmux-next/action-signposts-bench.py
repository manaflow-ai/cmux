#!/usr/bin/env python3
"""Action signposts on a running app, light and STRESS (perf-lead.md row 23, PL-arch).

Launches a tagged Debug `cmux DEV <tag>.app` (as perf-gate.py launches it: no activation), asks
`debug.commit_boundary` for the main run loop's display and commit observers against the commit
boundary, then measures the always-on `action.*` signposts with perf-signposts.py in two
phases: a light session (the launch workspace) and STRESS (perf-stress-session.py, built
outside the measured stream). Each phase runs the same scenario:

  * key runs: --rounds pairs of Cmd-T (new tab) and Cmd-W (close tab) through `debug.key`, the
    app's own key dispatch (origin user, input_age_ms >= 0);
  * CLI runs: the same two action ids through `action.run` (origin cli, input_age_ms -1);
  * one Cmd-Shift-W in a workspace made for it: one action.gate (the confirmation presenter)
    and one run of closeWorkspace (one action.perform, one action.commit or commit.missed).

Checks, per phase (exit 1 when one fails): the stream lost nothing; every cli-origin begin
carries input_age_ms -1, so no CLI run reaches action.input_to_commit; the Cmd-Shift-W gives
exactly 1 gate, 1 perform and 1 commit for closeWorkspace. It reports the action.commit.missed
count. Prints one `ACTION-SIGNPOSTS {json}` line and writes report.json to --out.

Usage (fleet GUI host, never Lawrence's Mac):
  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \\
    python3 scripts/cmux-next/action-signposts-bench.py --app "$NX_APP" --out "$NX_ARTIFACTS"
  action-signposts-bench.py --scenario --socket S --out DIR   (internal: one phase's scenario)
"""
import argparse, importlib.util, json, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def key(rpc, letter, *modifiers):
    reply = rpc("debug.key", {"key": letter, "modifiers": list(modifiers)})
    last = rpc("debug.key", {"last": True}) or {}
    return reply, last.get("action")


def scenario(opts):
    """One phase: key runs, CLI runs and one Cmd-Shift-W. Writes scenario.json to --out."""
    rpc = load("perf_stress_session", "perf-stress-session.py").socket_rpc(opts.socket)
    record = {"key": [], "cli": [], "errors": []}
    ids = {}
    for _ in range(opts.rounds):
        for letter, name in (("t", "new"), ("w", "close")):
            reply, action = key(rpc, letter, "cmd")
            ids.setdefault(name, action)
            record["key"].append(action)
            if isinstance(reply, dict) and reply.get("error"):
                record["errors"].append({"key": letter, "error": reply["error"]})
    for _ in range(opts.rounds):
        for name in ("new", "close"):
            if not ids.get(name):
                continue
            reply = rpc("action.run", {"action": ids[name]})
            record["cli"].append(ids[name])
            if isinstance(reply, dict) and reply.get("error"):
                record["errors"].append({"cli": ids[name], "error": reply["error"]})
    # A workspace to close, so the measured one stays.
    _, made = key(rpc, "n", "cmd")
    record["new_workspace"] = made
    reply, closed = key(rpc, "w", "cmd", "shift")
    record["close_workspace"] = {"action": closed, "reply": reply}
    with open(os.path.join(opts.out, "scenario.json"), "w") as f:
        json.dump(record, f, indent=1)


def check(signposts, ndjson):
    """The phase's checks over a saved stream; returns (report, failures)."""
    with open(ndjson) as f:
        lines = f.read().splitlines()
    parsed = signposts.parse(lines, signposts.local_timebase())
    rows = signposts.summarize(parsed["intervals"])
    failures = []
    if parsed["lost"]:
        failures.append(f"lost {parsed['lost']}")
    begins = [i for i in parsed["intervals"] if i["category"] == "action"]
    cli_aged = [i for i in begins if i["fields"].get("origin") == "cli" and float(i["fields"].get("input_age_ms", "-1")) >= 0]
    if cli_aged:
        failures.append(f"{len(cli_aged)} cli runs carry an input age")
    user_aged = [i for i in begins if i["name"] == "action.commit" and i["fields"].get("origin") == "user"
                 and float(i["fields"].get("input_age_ms", "-1")) >= 0]
    close = [i for i in begins if i["fields"].get("id") == "closeWorkspace"]
    counts = {name: sum(1 for i in close if i["name"] == name) for name in ("action.gate", "action.perform", "action.commit")}
    if counts != {"action.gate": 1, "action.perform": 1, "action.commit": 1}:
        failures.append(f"Cmd-Shift-W gave {counts}")
    missed = sum(1 for i in begins if i["name"] == "action.commit" and i.get("missed"))
    keep = {"action.perform", "action.commit", "action.commit.missed", "action.input_to_commit", "action.gate"}
    report = {"lost": parsed["lost"], "unpaired": parsed["unpaired"], "commit_missed": missed,
              "cli_runs_with_input_age": len(cli_aged), "user_commits_with_input_age": len(user_aged),
              "close_workspace": counts, "rows": [r for r in rows if r["name"] in keep]}
    return report, failures


def host_facts():
    """The host name, macOS version and each display's resolution line (it names the refresh rate)."""
    facts = {"host": os.uname().nodename,
             "macos": subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()}
    try:
        shown = json.loads(subprocess.run(["system_profiler", "-json", "SPDisplaysDataType"], capture_output=True,
                                          text=True, timeout=60).stdout or "{}")
        facts["displays"] = [d.get("_spdisplays_resolution") or d.get("spdisplays_resolution")
                             for gpu in shown.get("SPDisplaysDataType", []) for d in gpu.get("spdisplays_ndrvs", [])]
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        facts["displays"] = [f"unknown: {error}"]
    return facts


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", help="a Debug `cmux DEV <tag>.app` to launch (not running)")
    parser.add_argument("--socket", help="(--scenario) the running app's debug socket")
    parser.add_argument("--scenario", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or "/tmp/action-signposts")
    parser.add_argument("--rounds", type=int, default=20)
    parser.add_argument("--no-stress", action="store_true", help="the light phase only")
    opts = parser.parse_args()
    os.makedirs(opts.out, exist_ok=True)
    if opts.scenario:
        return scenario(opts)
    if not opts.app:
        parser.error("--app is required")
    signposts = load("perf_signposts", "perf-signposts.py")
    app = load("activation_perf", "activation-perf.py").App(os.path.abspath(opts.app), opts.out, 50)
    app.launch()
    report = {"host": host_facts(), "phases": {}, "failures": []}
    try:
        report["commit_boundary"] = app.rpc("debug.commit_boundary")
        if not (report["commit_boundary"] or {}).get("ok"):
            report["failures"].append(f"commit boundary: {json.dumps(report['commit_boundary'])[:400]}")
        phases = ["light"] if opts.no_stress else ["light", "stress"]
        for phase in phases:
            if phase == "stress":
                stress = load("perf_stress_session", "perf-stress-session.py").Stress(app.rpc).build()
                report["stress_session"] = stress
                # Chromium pages that fell back to WebKit make STRESS lighter than it says.
                report["stress_cef"] = json.dumps(app.rpc("debug.cef"))[:600]
                print("STRESS-SESSION " + json.dumps(stress), flush=True)
            out = os.path.join(opts.out, phase)
            os.makedirs(out, exist_ok=True)
            ndjson = os.path.join(out, "run.ndjson")
            command = [sys.executable, os.path.join(HERE, "perf-signposts.py"), "--pid", str(app.process.pid),
                       "--category", "action", "--save", ndjson, "--allow-loss", "--json", "--",
                       sys.executable, os.path.abspath(__file__), "--scenario", "--socket", app.socket,
                       "--out", out, "--rounds", str(opts.rounds)]
            subprocess.run(command, check=False, stdout=subprocess.DEVNULL)
            phase_report, failures = check(signposts, ndjson)
            with open(os.path.join(out, "scenario.json")) as f:
                phase_report["scenario"] = json.load(f)
            report["phases"][phase] = phase_report
            report["failures"] += [f"{phase}: {failure}" for failure in failures]
    finally:
        app.stop()
    with open(os.path.join(opts.out, "report.json"), "w") as f:
        json.dump(report, f, indent=1)
    print("ACTION-SIGNPOSTS " + json.dumps(report), flush=True)
    return 1 if report["failures"] else 0


if __name__ == "__main__":
    sys.exit(main())
