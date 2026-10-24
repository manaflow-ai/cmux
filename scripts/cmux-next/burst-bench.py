#!/usr/bin/env python3
"""Bursts of structural keys through the real key path, light and STRESS (PL-burst).

Lawrence 2026-10-23: "need to make sure repeated cmd w is instant, and spamming a bunch of cmd
shift d and cmd d etc is laggy ish ... some cmd w doesnt register". Every press must reach its
committed frame in < 10 ms p95, no press may be lost, and motion must drop no frame.

Launches a tagged Debug `cmux DEV <tag>.app` (activation-perf.py's App: no activation), then per
phase (light: the launch session; stress: perf-stress-session.py) and per scenario:

  cmdw-terminal / cmdw-chromium / cmdw-chat   N Cmd-W on N tabs of that kind in one pane
  cmdd / cmdshiftd                            N Cmd-D or Cmd-Shift-D
  mixed                                       Cmd-D, Cmd-Shift-D, Cmd-W in turn, N presses
  held-cmdw                                   Cmd-W held: one key-down, N - 1 auto-repeats
  newtab-{terminal,chromium}-{one,burst,held,mixed}
                                              Cmd-Shift-L (openBrowser, New Browser Tab) on a
                                              terminal- or Chromium-focused pane: one press, N fast
                                              presses, held (auto-repeats), and mixed with Cmd-W

Keys go through `debug.key {"sequence": ...}`: real CGEvents posted to the app's queue at the
given gaps (--gap-ms, --repeat-ms), each stamped when it is posted, so the app's input path,
the key router and the action registry see them as hardware keys. Per scenario it reports:

  input_to_commit   per press: the key's age at the action plus the next CA commit
                    (action.input_to_commit from perf-signposts.py), p50/p95/p99/max
  performed         action runs of the scenario's action ids (signposts)
  applied           the change the model shows afterwards (tabs closed, panes made)
  refused           refusals the person saw (the HUD): `burst` signpost events
  lost              presses that neither applied nor were refused (must be 0)
  frames            `debug.frames` over the burst: refresh, intervals p50/p95/p99/max, missed vsyncs
  resize            for split and close bursts: key -> PTY grid sent and key -> first TUI output
                    after it (`burst` signpost events `pty-grid`, `first-output`), p50/p95/max,
                    and grids sent per terminal (more than one per motion is a second resize)

Prints one `BURST-BENCH {json}` line and writes report.json to --out. Exit 1 when a press was
lost. Run on a fleet GUI host, never on Lawrence's Mac, and quote the host, macOS and refresh rate:

  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \\
    python3 scripts/cmux-next/burst-bench.py --app "$NX_APP" --out "$NX_ARTIFACTS"
  burst-bench.py --scenario NAME --socket S --out DIR --presses N   (internal: one scenario)
"""
import argparse, importlib.util, json, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

KEY = {"w": 13, "d": 2, "l": 37, "cmd": 55, "shift": 56}
NEWTAB = [f"newtab-{focus}-{shape}" for focus in ("terminal", "chromium") for shape in ("one", "burst", "held", "mixed")]
SCENARIOS = ["cmdw-terminal", "cmdw-chromium", "cmdw-chat", "cmdd", "cmdshiftd", "mixed", "held-cmdw"] + NEWTAB
# Press letters: lower case with Command, upper case with Command-Shift.
ACTIONS = {"w": "closeTab", "d": "splitRight", "D": "splitDown", "L": "openBrowser"}


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sequence(presses, gap_ms, repeat_ms=None):
    """`presses` ("w", "d" or "D" = Cmd-Shift-D) as key steps with Command held throughout. With
    `repeat_ms` the first press's key stays down and the rest are its auto-repeats."""
    steps = [{"key_code": KEY["cmd"], "down": True}]
    if repeat_ms:
        code = KEY[presses[0].lower()]
        if presses[0].isupper():
            steps.append({"key_code": KEY["shift"], "down": True, "after_ms": 5})
        steps.append({"key_code": code, "down": True, "after_ms": 10})
        steps += [{"key_code": code, "down": True, "repeat": True, "after_ms": repeat_ms} for _ in presses[1:]]
        steps.append({"key_code": code, "down": False, "after_ms": 8})
        if presses[0].isupper():
            steps.append({"key_code": KEY["shift"], "down": False, "after_ms": 1})
    else:
        for index, press in enumerate(presses):
            code = KEY[press.lower()]
            lead = 10 if index == 0 else max(gap_ms - 8, 1)
            if press.isupper():
                steps.append({"key_code": KEY["shift"], "down": True, "after_ms": lead})
                lead = 1
            steps.append({"key_code": code, "down": True, "after_ms": lead})
            steps.append({"key_code": code, "down": False, "after_ms": 8})
            if press.isupper():
                steps.append({"key_code": KEY["shift"], "down": False, "after_ms": 1})
    steps.append({"key_code": KEY["cmd"], "down": False, "after_ms": 2})
    return steps


def percentiles(values):
    v = sorted(values)
    if not v:
        return None
    pick = lambda q: v[min(len(v) - 1, int(q * len(v)))]
    return {"n": len(v), "p50": round(pick(0.5), 2), "p95": round(pick(0.95), 2), "p99": round(pick(0.99), 2), "max": round(v[-1], 2)}


def scenario(opts):
    """One scenario on the running app; writes scenario.json to --out."""
    stress = load("perf_stress_session", "perf-stress-session.py")
    rpc = stress.socket_rpc(opts.socket)
    builder = stress.Stress(rpc, log=lambda line: None)
    n, name = opts.presses, opts.scenario
    record = {"scenario": name, "presses": n, "errors": []}
    workspace = builder.focused_workspace()
    pane = (builder.topology().get("focus") or {}).get("pane")
    if not workspace or not pane:
        record["errors"].append("no focused pane")
        return dump(opts, record)
    kind = {"cmdw-terminal": "terminal", "cmdw-chromium": "chromium", "cmdw-chat": "chat", "held-cmdw": "terminal"}.get(name)
    newtab = name.startswith("newtab-")
    if newtab and name.split("-")[1] == "chromium":
        # The pane's selected tab is a Chromium page: Cmd-Shift-L from a page.
        builder.add_tab(workspace, pane, "chromium")
        builder.focus_pane(pane)
    if kind:
        # N tabs of `kind` to close, plus the pane's own first tab, which stays.
        for _ in range(n):
            builder.add_tab(workspace, pane, kind)
        builder.focus_pane(pane)
        record["chat_fallbacks"] = builder.chat_fallbacks
    shape = name.split("-")[-1] if newtab else None
    presses = {"cmdd": ["d"] * n, "cmdshiftd": ["D"] * n, "mixed": (["d", "D", "w"] * n)[:n]}.get(name, ["w"] * n)
    if newtab:
        presses = {"one": ["L"], "burst": ["L"] * n, "held": ["L"] * n, "mixed": (["L", "w"] * n)[:n]}[shape]
    before = {"tabs": len(builder.tabs(workspace, pane)), "panes": len(builder.panes(builder.workspace(workspace)))}
    rpc("debug.frames", {"action": "start"})
    steps = sequence(presses, opts.gap_ms, opts.repeat_ms if name == "held-cmdw" or shape == "held" else None)
    sent = rpc("debug.key", {"sequence": steps}) or {}
    duration = float(sent.get("duration_ms") or 0) / 1000
    time.sleep(duration + opts.settle)  # test script: the burst lands, then the motion and the daemon settle
    frames = rpc("debug.frames", {"action": "stop", "raw": True}) or {}
    after = {"tabs": len(builder.tabs(workspace, pane)), "panes": len(builder.panes(builder.workspace(workspace)))}
    closes = presses.count("w")
    splits = len(presses) - closes
    # Applied: the model's change. Closes on the scenario's pane (its first tab stays); splits as
    # panes; new tabs as tabs (each mixed Cmd-W closes the tab the Cmd-Shift-L before it opened).
    if kind:
        applied = before["tabs"] - after["tabs"]
    elif newtab:
        # Every applied press: the tabs added, plus each close and the tab it took away.
        applied = (after["tabs"] - before["tabs"]) + 2 * closes
    else:
        applied = (after["panes"] - before["panes"]) + closes  # a mixed close of a fresh split's tab removes its pane again
    record.update({"before": before, "after": after, "applied": applied, "expected": len(presses),
                   "closes": closes, "splits": splits, "frames": {k: frames.get(k) for k in
                   ("frames", "refresh_ms", "p50_ms", "p95_ms", "p99_ms", "max_ms", "missed", "main_p95_ms", "main_max_ms")},
                   "sequence_ms": duration * 1000})
    return dump(opts, record)


def dump(opts, record):
    with open(os.path.join(opts.out, "scenario.json"), "w") as f:
        json.dump(record, f, indent=1)
    return 0


def summarize(signposts, ndjson, record):
    """The scenario's numbers from its signpost stream and its record."""
    with open(ndjson) as f:
        parsed = signposts.parse(f.read().splitlines(), signposts.local_timebase())
    ids = set(ACTIONS.values())
    aged = [i for i in parsed["intervals"] if i["name"] == "action.commit" and i["fields"].get("id") in ids
            and i["fields"].get("origin") == "user" and float(i["fields"].get("input_age_ms", "-1")) >= 0 and not i.get("missed")]
    input_to_commit = [float(i["fields"]["input_age_ms"]) + i["ms"] for i in aged]
    performed = sum(1 for i in parsed["intervals"] if i["name"] == "action.perform" and i["fields"].get("id") in ids)
    burst = burst_events(signposts, ndjson)
    refused = len(burst["refusals"])
    lost = max(0, record.get("expected", 0) - record.get("applied", 0) - refused)
    out = {"scenario": record.get("scenario"), "presses": record.get("presses"), "performed": performed,
           "applied": record.get("applied"), "refused": refused, "lost": lost,
           "input_to_commit_ms": percentiles(input_to_commit), "frames": record.get("frames"),
           "stream_lost": parsed["lost"], "errors": record.get("errors")}
    resizes = burst["resizes"]
    if resizes:
        presses = press_times(signposts, ndjson, ids)
        def since_press(at):
            earlier = [p for p in presses if p <= at]
            return (at - max(earlier)) * 1000 if earlier else None
        per_surface = {}
        for r in resizes:
            per_surface[r["surface"]] = per_surface.get(r["surface"], 0) + 1
        sent = [d for d in (since_press(r["at"]) for r in resizes) if d is not None]
        first = [d for d in (since_press(o["at"]) for o in burst["first_outputs"]) if d is not None]
        out["resize"] = {"key_to_grid_sent_ms": percentiles(sent), "key_to_first_output_ms": percentiles(first),
                         "grids_per_terminal_max": max(per_surface.values()), "terminals": len(per_surface)}
    return out


def burst_events(signposts, ndjson):
    """The `burst` signpost events of the stream, on the mach clock in seconds."""
    timebase = signposts.local_timebase()
    found = {"refusals": [], "resizes": [], "first_outputs": []}
    with open(ndjson) as f:
        for line in f:
            if not line.startswith("{"):
                continue
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if event.get("category") != "burst" or event.get("signpostType") != "event" or not timebase:
                continue
            at = event["machTimestamp"] * timebase[0] / timebase[1] / 1e9
            info = signposts.fields(event.get("eventMessage", ""))
            name = event.get("signpostName")
            if name == "refusal":
                found["refusals"].append({"at": at})
            elif name == "pty-grid":
                found["resizes"].append({"at": at, "surface": info.get("surface"), "cols": info.get("cols"), "rows": info.get("rows")})
            elif name == "first-output":
                found["first_outputs"].append({"at": at, "surface": info.get("surface")})
    return found


def press_times(signposts, ndjson, ids):
    """Each press's time (system uptime seconds, NSEvent.timestamp's clock): an aged action begin's
    machTimestamp minus its input age."""
    timebase = signposts.local_timebase()
    times = []
    with open(ndjson) as f:
        for line in f:
            if not line.startswith("{"):
                continue
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if event.get("signpostName") != "action.commit" or event.get("signpostType") != "begin" or not timebase:
                continue
            info = signposts.fields(event.get("eventMessage", ""))
            age = float(info.get("input_age_ms", "-1"))
            if info.get("id") in ids and age >= 0 and isinstance(event.get("machTimestamp"), int):
                times.append(event["machTimestamp"] * timebase[0] / timebase[1] / 1e9 - age / 1000)
    return sorted(times)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", help="a Debug `cmux DEV <tag>.app` to launch (not running)")
    parser.add_argument("--socket", help="(--scenario) the running app's debug socket")
    parser.add_argument("--scenario", choices=SCENARIOS, help=argparse.SUPPRESS)
    parser.add_argument("--scenarios", default=",".join(SCENARIOS))
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or "/tmp/burst-bench")
    parser.add_argument("--presses", type=int, default=20)
    parser.add_argument("--gap-ms", type=float, default=40, help="between presses (a fast person: 40-60 ms)")
    parser.add_argument("--repeat-ms", type=float, default=33, help="auto-repeat interval of the held key")
    parser.add_argument("--settle", type=float, default=2.0, help="seconds after the burst before reading")
    parser.add_argument("--no-stress", action="store_true", help="the light phase only")
    opts = parser.parse_args()
    os.makedirs(opts.out, exist_ok=True)
    if opts.scenario:
        return scenario(opts)
    if not opts.app:
        parser.error("--app is required")
    signposts = load("perf_signposts", "perf-signposts.py")
    stress_module = load("perf_stress_session", "perf-stress-session.py")
    actions = load("action_signposts_bench", "action-signposts-bench.py")
    app = load("activation_perf", "activation-perf.py").App(os.path.abspath(opts.app), opts.out, 50)
    app.launch()
    report = {"host": actions.host_facts(), "gap_ms": opts.gap_ms, "repeat_ms": opts.repeat_ms, "phases": {}, "failures": []}
    try:
        for phase in (["light"] if opts.no_stress else ["light", "stress"]):
            builder = stress_module.Stress(app.rpc)
            if phase == "stress":
                report["stress_session"] = builder.build()
                report["stress_cef"] = json.dumps(app.rpc("debug.cef"))[:600]
                print("STRESS-SESSION " + json.dumps(report["stress_session"]), flush=True)
            rows = []
            for name in opts.scenarios.split(","):
                # Each scenario in a fresh workspace of this phase, shown (STRESS keeps its background load).
                workspace = builder.new_workspace()
                if workspace:
                    builder.show(workspace)
                out = os.path.join(opts.out, phase, name)
                os.makedirs(out, exist_ok=True)
                ndjson = os.path.join(out, "run.ndjson")
                command = [sys.executable, os.path.join(HERE, "perf-signposts.py"), "--pid", str(app.process.pid),
                           "--category", "action", "--category", "burst", "--save", ndjson, "--allow-loss", "--json", "--",
                           sys.executable, os.path.abspath(__file__), "--scenario", name, "--socket", app.socket,
                           "--out", out, "--presses", str(opts.presses), "--gap-ms", str(opts.gap_ms),
                           "--repeat-ms", str(opts.repeat_ms), "--settle", str(opts.settle)]
                subprocess.run(command, check=False, stdout=subprocess.DEVNULL)
                with open(os.path.join(out, "scenario.json")) as f:
                    record = json.load(f)
                row = summarize(signposts, ndjson, record)
                rows.append(row)
                if row["lost"]:
                    report["failures"].append(f"{phase} {name}: {row['lost']} presses lost")
                print(f"{phase} {name}: " + json.dumps(row), flush=True)
            report["phases"][phase] = rows
    finally:
        app.stop()
    with open(os.path.join(opts.out, "report.json"), "w") as f:
        json.dump(report, f, indent=1)
    print("BURST-BENCH " + json.dumps(report), flush=True)
    return 1 if report["failures"] else 0


if __name__ == "__main__":
    sys.exit(main())
