#!/usr/bin/env python3
"""Bursts of structural keys through the real key path, light and STRESS (PL-burst).

Lawrence 2026-10-23: "need to make sure repeated cmd w is instant, and spamming a bunch of cmd
shift d and cmd d etc is laggy ish ... some cmd w doesnt register". Targets: every press reaches the
frame that shows its result in < 10 ms p95, no press is lost, and motion drops no frame.

Launches a tagged Debug or bench `cmux DEV <tag>.app` (activation-perf.py's App: no activation) once per
phase, so no phase sees what another left:

  light   the launch session; each scenario in a new workspace, closed after it
  stress  perf-stress-session.py's STRESS (Stress.build(), checked); each scenario in the measured
          workspace's first pane, and after it every pane and tab the scenario made is closed and the
          splits equalized, back to the shape build() made. The shape is checked again after each
          scenario: a row whose session left the STRESS shape is invalid, and the phase stops there.
          Each stress row carries its STRESS-SESSION summary (also printed as a line).

Scenarios:

  cmdw-terminal / cmdw-chromium / cmdw-chat   N Cmd-W on N tabs of that kind in one pane
  cmdd / cmdshiftd                            N Cmd-D or Cmd-Shift-D
  mixed                                       Cmd-D, Cmd-Shift-D, Cmd-W in turn, N presses
  held-cmdw                                   Cmd-W held: one key-down, N - 1 auto-repeats
  newtab-{terminal,chromium}-{one,burst,held,mixed}
                                              Cmd-Shift-L (openBrowser, New Browser Tab) on a pane whose
                                              selected tab is a terminal or a Chromium page: one press, N
                                              fast presses, held (auto-repeats), and mixed with Cmd-W

Keys go through `debug.key {"sequence": ...}`: real CGEvents posted to the app's queue at the given
gaps (--gap-ms). Each event carries its intended press time (the sequence's base plus its offset), as
a hardware key carries its HID time, so a press that waits behind a busy main thread has that wait in
its input age. A held key repeats as this host does: the first repeat after the app's key repeat
delay, the rest at its interval (`debug.burst` start reports both; --repeat-delay-ms / --repeat-ms
override). The app runs with CMUX_NEXT_NO_ACTIVATE=1: no window is key, so a "Chromium-focused" pane
is one whose selected tab is a Chromium page, not one whose page window is key.

Per scenario it reports:

  input_to_next_commit  per press: the key's age at the action plus the next CA commit (action.commit
                        from perf-signposts.py), p50/p95/p99/max. It is a lower bound of the time to
                        the frame that shows the result: work the action defers (Chromium
                        CreateBrowser, daemon replies, split creation) commits later, so the < 10 ms
                        target needs each action's own end signal; the resize columns below give the
                        later terminal stages
  commit_missed         presses whose commit boundary missed its turn (action.commit.missed): not in
                        the percentiles, so any is a failure
  performed             action runs of the scenario's action ids that a person started (origin user)
  swallowed             Cmd-W presses the close guard swallowed by design: quickly after one that
                        emptied its pane (TabCloseGuard.swallowsCmdW), `debug.burst` close_swallowed
  cancelled             Cmd-W presses that cancelled a creation still on its way (CancelledCreation):
                        neither that Cmd-W nor the creating press changes the layout
  refused               refusals the person saw (the refusal HUD)
  missing               presses that never reached their action (presses - performed)
  unexplained           the model's change (panes or tabs) the runs, swallows, cancels and refusals do
                        not explain
  lost                  missing + unexplained (must be 0)
  frames                `debug.frames` over the burst: refresh, intervals p50/p95/p99/max, missed vsyncs
  resize                for split and close bursts: key -> PTY grid sent and key -> first TUI output
                        after it (`debug.burst` pty_grid, first_output), p50/p95/max, and grids sent per
                        terminal (more than one per motion is a second resize)
  invalid               why the row does not measure what it names: Chromium not running or a tab that
                        is not Chromium, agent chats replaced by the New Tab page, a STRESS shape lost

Prints one `BURST-BENCH {json}` line and writes report.json to --out. Exit 1 when a press was lost,
a commit missed, or a row is invalid. Run on a fleet GUI host, never on Lawrence's Mac, and quote the
host, macOS and refresh rate:

  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/burst-bench.sh ...
  burst-bench.py --app APP --out DIR [--no-stress] [--presses N]
  burst-bench.py --self-test                     the accounting and the key sequences on synthetic runs
  burst-bench.py --scenario NAME --socket S --workspace W --pane P --out DIR   (internal: one scenario)
"""
import argparse, importlib.util, json, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

KEY = {"w": 13, "d": 2, "l": 37, "cmd": 55, "shift": 56}
NEWTAB = [f"newtab-{focus}-{shape}" for focus in ("terminal", "chromium") for shape in ("one", "burst", "held", "mixed")]
SCENARIOS = ["cmdw-terminal", "cmdw-chromium", "cmdw-chat", "cmdd", "cmdshiftd", "mixed", "held-cmdw"] + NEWTAB
# Press letters: lower case with Command, upper case with Command-Shift.
ACTIONS = {"w": "closeTab", "d": "splitRight", "D": "splitDown", "L": "openBrowser"}
CLOSE_KINDS = {"cmdw-terminal": "terminal", "cmdw-chromium": "chromium", "cmdw-chat": "chat", "held-cmdw": "terminal"}
FRAME_FIELDS = ("frames", "refresh_ms", "p50_ms", "p95_ms", "p99_ms", "max_ms", "missed", "main_p95_ms", "main_max_ms")
FOCUS_NOTE = ("focus is the selected tab: the app runs with CMUX_NEXT_NO_ACTIVATE=1, so no window is key "
              "(a Chromium-focused pane has a Chromium page selected; its page window is not key)")


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def scenario_presses(name, n):
    """The press letters of scenario `name` with `n` presses."""
    if name.startswith("newtab-"):
        shape = name.split("-")[-1]
        return {"one": ["L"], "burst": ["L"] * n, "held": ["L"] * n, "mixed": (["L", "w"] * n)[:n]}[shape]
    return {"cmdd": ["d"] * n, "cmdshiftd": ["D"] * n, "mixed": (["d", "D", "w"] * n)[:n]}.get(name, ["w"] * n)


def is_held(name):
    return name == "held-cmdw" or name.endswith("-held")


def sequence(presses, gap_ms, repeat=None):
    """`presses` ("w", "d", "L", or upper case with Shift) as key steps with Command held throughout,
    and each press's key-down offset (ms from the sequence's start). With `repeat` = (delay_ms,
    interval_ms) the first press's key stays down and the rest are its auto-repeats: the first after
    the delay, the others at the interval, as macOS repeats a held key."""
    steps = [{"key_code": KEY["cmd"], "down": True}]
    at, offsets = 0.0, []

    def step(code, down, after, **extra):
        nonlocal at
        at += after
        steps.append({"key_code": code, "down": down, "after_ms": after, **extra})
        if down and code not in (KEY["cmd"], KEY["shift"]):
            offsets.append(at)

    first = presses[0]
    if repeat:
        delay_ms, interval_ms = repeat
        code = KEY[first.lower()]
        if first.isupper():
            step(KEY["shift"], True, 5)
        step(code, True, 10)
        for index in range(1, len(presses)):
            step(code, True, delay_ms if index == 1 else interval_ms, repeat=True)
        step(code, False, 8)
        if first.isupper():
            step(KEY["shift"], False, 1)
    else:
        for index, press in enumerate(presses):
            code = KEY[press.lower()]
            lead = 10 if index == 0 else max(gap_ms - 8, 1)
            if press.isupper():
                step(KEY["shift"], True, lead)
                lead = 1
            step(code, True, lead)
            step(code, False, 8)
            if press.isupper():
                step(KEY["shift"], False, 1)
    step(KEY["cmd"], False, 2)
    return steps, offsets


def percentiles(values):
    v = sorted(values)
    if not v:
        return None
    pick = lambda q: v[min(len(v) - 1, int(q * len(v)))]
    return {"n": len(v), "p50": round(pick(0.5), 2), "p95": round(pick(0.95), 2), "p99": round(pick(0.99), 2), "max": round(v[-1], 2)}


def unit_of(name):
    """What a scenario's presses change in the model: the scenario pane's tabs, or the workspace's panes."""
    return "panes" if name in ("cmdd", "cmdshiftd", "mixed") else "tabs"


def account(presses, performed, counts, before, after, unit):
    """Each press's fate from the app's own records, not from a model delta alone.

    `performed`: user action runs by action id (signposts); `counts`: `debug.burst` marks by kind;
    `before`/`after`: {"tabs", "panes"}. A create (split, new tab) adds one `unit`; a close removes one
    (in `mixed` the Cmd-W closes a fresh split's only tab, so its pane goes with it). A swallowed Cmd-W
    changes nothing; a cancelled creation takes away both its Cmd-W's close and the creating press's
    add. A refusal changes nothing, whichever press it was, so it may account for one unit either way."""
    closes = presses.count("w")
    create_ids = {ACTIONS[p] for p in presses if p != "w"}
    ran_creates = sum(performed.get(i, 0) for i in create_ids)
    ran_closes = performed.get(ACTIONS["w"], 0) if closes else 0
    swallowed, cancelled, refused = (counts.get(k, 0) for k in ("close_swallowed", "creation_cancelled", "refusal"))
    expected = (ran_creates - cancelled) - (ran_closes - swallowed - cancelled)
    observed = after[unit] - before[unit]
    missing = max(0, len(presses) - ran_creates - ran_closes)
    unexplained = max(0, abs(observed - expected) - refused)
    return {"performed": ran_creates + ran_closes, "swallowed": swallowed, "cancelled": cancelled, "refused": refused,
            "missing": missing, "unit": unit, "observed_delta": observed, "expected_delta": expected,
            "unexplained": unexplained, "lost": missing + unexplained}


def browser_problems(builder, stress, want_chromium):
    """Why the shown pages of the scenario's workspace may not be Chromium: debug.cef's problems, and with
    `want_chromium` a shown browser tab that is not a CEF tab (debug.layers browsers), or none shown."""
    problems = stress.cef_problems(builder.rpc("debug.cef"), builder.web_dev_config)
    if want_chromium:
        engines = [b.get("engine") for b in builder.shown_window().get("browsers") or []]
        if not engines or any(e != "cef" for e in engines):
            problems.append(f"shown browser tabs by engine {engines}, not Chromium")
    return problems


def scenario(opts):
    """One scenario on the running app, in --workspace (shown) and --pane; writes scenario.json to --out."""
    stress = load("perf_stress_session", "perf-stress-session.py")
    rpc = stress.socket_rpc(opts.socket)
    builder = stress.Stress(rpc, log=lambda line: None)
    builder.measured = opts.workspace  # shown_window() reads the window that shows it
    n, name, workspace, pane = opts.presses, opts.scenario, opts.workspace, opts.pane
    record = {"scenario": name, "presses": n, "errors": [], "invalid": []}
    kind = CLOSE_KINDS.get(name)
    newtab = name.startswith("newtab-")
    chromium = kind == "chromium" or newtab
    try:
        builder.focus_pane(pane)
        if newtab and name.split("-")[1] == "chromium":
            # The pane's selected tab is a Chromium page: Cmd-Shift-L from a page.
            builder.add_tab(workspace, pane, "chromium")
            builder.focus_pane(pane)
        if kind:
            # N tabs of `kind` to close; the pane's own tabs stay.
            for _ in range(n):
                builder.add_tab(workspace, pane, kind)
            builder.focus_pane(pane)
    except stress.StressShapeError as error:
        record["errors"].append(str(error))
        return dump(opts, record)
    record["chat_fallbacks"] = builder.chat_fallbacks
    if builder.chat_fallbacks:
        record["invalid"].append(f"{builder.chat_fallbacks} agent chats were replaced by the New Tab page")
    if chromium:
        problems = browser_problems(builder, stress, want_chromium=name.split("-")[1] == "chromium")
        if problems:
            record["invalid"].append(f"before the burst: {'; '.join(problems)[:300]}")
    presses = scenario_presses(name, n)
    before = {"tabs": len(builder.tabs(workspace, pane)), "panes": len(builder.panes(builder.workspace(workspace)))}
    rpc("debug.frames", {"action": "start"})
    armed = rpc("debug.burst", {"action": "start"}) or {}
    if armed.get("error"):
        record["errors"].append(f"debug.burst: {armed['error']}")
    repeat = None
    if is_held(name):
        repeat = (opts.repeat_delay_ms if opts.repeat_delay_ms is not None else float(armed.get("key_repeat_delay_s") or 0) * 1000,
                  opts.repeat_ms if opts.repeat_ms is not None else float(armed.get("key_repeat_interval_s") or 0) * 1000)
        if not all(repeat):
            record["errors"].append(f"no key repeat to play a held key with: {armed}")
            return dump(opts, record)
    steps, offsets = sequence(presses, opts.gap_ms, repeat)
    sent = rpc("debug.key", {"sequence": steps}) or {}
    if sent.get("error") or "base_s" not in sent:
        record["errors"].append(f"debug.key: {sent}")
    duration = float(sent.get("duration_ms") or 0) / 1000
    time.sleep(duration + opts.settle)  # test script: the burst lands, then the motion and the daemon settle
    frames = rpc("debug.frames", {"action": "stop", "raw": True}) or {}
    trace = rpc("debug.burst", {"action": "stop"}) or {}
    after = {"tabs": len(builder.tabs(workspace, pane)), "panes": len(builder.panes(builder.workspace(workspace)))}
    if chromium:
        # After a Cmd-Shift-L burst the pane shows the last tab it opened, which must be Chromium.
        problems = browser_problems(builder, stress, want_chromium=newtab and after["tabs"] > before["tabs"])
        if problems:
            record["invalid"].append(f"after the burst: {'; '.join(problems)[:300]}")
    base = sent.get("base_s")
    record.update({"before": before, "after": after, "unit": unit_of(name), "press_letters": presses,
                   "press_times_s": [base + o / 1000 for o in offsets] if isinstance(base, (int, float)) else [],
                   "key_repeat": {k: armed.get(k) for k in ("key_repeat_delay_s", "key_repeat_interval_s", "quick_press_window_s")},
                   "held_repeat_ms": repeat, "trace": trace, "frames": {k: frames.get(k) for k in FRAME_FIELDS},
                   "sequence_ms": duration * 1000})
    return dump(opts, record)


def dump(opts, record):
    with open(os.path.join(opts.out, "scenario.json"), "w") as f:
        json.dump(record, f, indent=1)
    return 0


def summarize(signposts, ndjson, record):
    """The scenario's row from its signpost stream and its record."""
    with open(ndjson) as f:
        parsed = signposts.parse(f.read().splitlines(), signposts.local_timebase())
    ids = {ACTIONS[p] for p in record.get("press_letters") or []}
    user = [i for i in parsed["intervals"] if i["fields"].get("id") in ids and i["fields"].get("origin") == "user"]
    performed = {}
    for i in user:
        if i["name"] == "action.perform":
            performed[i["fields"]["id"]] = performed.get(i["fields"]["id"], 0) + 1
    aged = [i for i in user if i["name"] == "action.commit" and float(i["fields"].get("input_age_ms", "-1")) >= 0]
    trace = record.get("trace") or {}
    out = {"scenario": record.get("scenario"), "presses": record.get("presses"),
           "input_to_next_commit_ms": percentiles([float(i["fields"]["input_age_ms"]) + i["ms"] for i in aged if not i.get("missed")]),
           "commit_missed": sum(1 for i in aged if i.get("missed")),
           "chat_fallbacks": record.get("chat_fallbacks"), "frames": record.get("frames"),
           "key_repeat": record.get("key_repeat"), "held_repeat_ms": record.get("held_repeat_ms"),
           "stream_lost": parsed["lost"], "trace_dropped": trace.get("dropped"),
           "errors": record.get("errors"), "invalid": list(record.get("invalid") or [])}
    if record.get("before") and record.get("after"):
        out.update(account(record["press_letters"], performed, trace.get("counts") or {}, record["before"], record["after"], record["unit"]))
    else:
        out["invalid"].append("the scenario never ran its burst")
    events = trace.get("events") or []
    grids = [e for e in events if e.get("kind") == "pty_grid"]
    if grids:
        presses = sorted(record.get("press_times_s") or [])

        def since_press(at):
            earlier = [p for p in presses if p <= at]
            return (at - max(earlier)) * 1000 if earlier else None
        per_surface = {}
        for grid in grids:
            per_surface[grid.get("surface")] = per_surface.get(grid.get("surface"), 0) + 1
        sent = [d for d in (since_press(g["at_s"]) for g in grids) if d is not None]
        first = [d for d in (since_press(e["at_s"]) for e in events if e.get("kind") == "first_output") if d is not None]
        out["resize"] = {"key_to_grid_sent_ms": percentiles(sent), "key_to_first_output_ms": percentiles(first),
                         "grids_per_terminal_max": max(per_surface.values()), "terminals": len(per_surface)}
    return out


def failures_of(phase, row):
    """The report's failures for one row."""
    found = []
    if row.get("lost"):
        found.append(f"{phase} {row['scenario']}: {row['lost']} presses lost ({row.get('missing')} missing, "
                     f"{row.get('unexplained')} unexplained)")
    if row.get("commit_missed"):
        found.append(f"{phase} {row['scenario']}: {row['commit_missed']} commits missed their boundary (not in the percentiles)")
    if row.get("invalid"):
        found.append(f"{phase} {row['scenario']}: invalid: {'; '.join(row['invalid'])}")
    if row.get("errors"):
        found.append(f"{phase} {row['scenario']}: errors: {'; '.join(row['errors'])[:300]}")
    return found


def start_state(builder, workspace):
    """Each pane of `workspace` and its tab ids."""
    return {p["id"]: {t.get("id") for t in p.get("tabs") or []} for p in builder.panes(builder.workspace(workspace))}


def restore(builder, stress, workspace, first_pane, state):
    """Closes every pane and tab of `workspace` that is not in `state` and equalizes the splits, as
    build() left them; returns what is still different (empty when restored)."""
    for pane in builder.panes(builder.workspace(workspace)):
        if pane["id"] not in state:
            builder.action("closePane", target=f"pane:{pane['id']}", focus=False)
            continue
        for tab in pane.get("tabs") or []:
            if tab.get("id") not in state[pane["id"]]:
                builder.action("closeTab", target=f"tab:{tab.get('id')}", focus=False)
    stress.wait(lambda: start_state(builder, workspace) == state, 20, step=0.1)
    builder.action("equalizeSplits", target=f"pane:{first_pane}", settle=0.8)
    now = start_state(builder, workspace)
    if now == state:
        return []
    return [f"panes {sorted(set(now) ^ set(state))[:4]} differ"] + \
           [f"pane {p} tabs differ" for p in state if p in now and now[p] != state[p]][:4]


def run_phase(opts, phase, app, signposts, stress, report):
    builder = stress.Stress(app.rpc)
    rows = []
    measured = state = first = None
    if phase == "stress":
        session = builder.build()  # raises StressShapeError: another shape is never measured as STRESS
        report["stress_session"] = session
        print("STRESS-SESSION " + json.dumps(session), flush=True)
        measured = builder.measured
        state = start_state(builder, measured)
        first = builder.panes(builder.workspace(measured))[0]["id"]
    for name in opts.scenarios.split(","):
        if phase == "light":
            workspace = builder.new_workspace()
            if not workspace:
                report["failures"].append(f"light {name}: its workspace never appeared")
                continue
            builder.show(workspace)
            pane = builder.panes(builder.workspace(workspace))[0]["id"]
        else:
            workspace, pane = measured, first
            builder.show(workspace)
        out = os.path.join(opts.out, phase, name)
        os.makedirs(out, exist_ok=True)
        ndjson = os.path.join(out, "run.ndjson")
        command = [sys.executable, os.path.join(HERE, "perf-signposts.py"), "--pid", str(app.process.pid),
                   "--category", "action", "--save", ndjson, "--allow-loss", "--json", "--",
                   sys.executable, os.path.abspath(__file__), "--scenario", name, "--socket", app.socket,
                   "--workspace", workspace, "--pane", pane, "--out", out, "--presses", str(opts.presses),
                   "--gap-ms", str(opts.gap_ms), "--settle", str(opts.settle)]
        for flag, value in (("--repeat-ms", opts.repeat_ms), ("--repeat-delay-ms", opts.repeat_delay_ms)):
            if value is not None:
                command += [flag, str(value)]
        done = subprocess.run(command, check=False, stdout=subprocess.DEVNULL)
        try:
            with open(os.path.join(out, "scenario.json")) as f:
                record = json.load(f)
        except (OSError, ValueError) as error:
            record = {"scenario": name, "presses": opts.presses, "errors": [f"no scenario record (exit {done.returncode}): {error}"]}
        row = summarize(signposts, ndjson, record) if os.path.exists(ndjson) else \
            {"scenario": name, "presses": opts.presses, "errors": record.get("errors", []) + ["no signpost stream"], "invalid": []}
        if phase == "light":
            builder.action("closeWorkspace", {"confirm": True}, target=f"workspace:{workspace}", focus=False)
            if not stress.wait(lambda: builder.workspace(workspace) is None, 20, step=0.1):
                row["invalid"].append("its workspace did not close: the next rows would run beside it")
        else:
            left = restore(builder, stress, workspace, first, state)
            session = builder.summary()
            try:
                if left:
                    raise stress.StressShapeError("not back to the built shape: " + "; ".join(left))
                stress.Stress.check(session)
            except stress.StressShapeError as error:
                row["invalid"].append(f"the STRESS shape after the scenario: {str(error)[:400]}")
            row["stress_session"] = session
            print("STRESS-SESSION " + json.dumps(session), flush=True)
        rows.append(row)
        report["failures"] += failures_of(phase, row)
        print(f"{phase} {name}: " + json.dumps({k: v for k, v in row.items() if k != "stress_session"}), flush=True)
        if phase == "stress" and any(r.startswith("the STRESS shape") for r in row["invalid"]):
            report["failures"].append(f"stress: stopped after {name}: the session is no longer STRESS")
            break
    report["phases"][phase] = rows


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", help="a Debug or bench `cmux DEV <tag>.app` to launch (not running)")
    parser.add_argument("--socket", help="(--scenario) the running app's debug socket")
    parser.add_argument("--scenario", choices=SCENARIOS, help=argparse.SUPPRESS)
    parser.add_argument("--workspace", help=argparse.SUPPRESS)
    parser.add_argument("--pane", help=argparse.SUPPRESS)
    parser.add_argument("--scenarios", default=",".join(SCENARIOS))
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or "/tmp/burst-bench")
    parser.add_argument("--presses", type=int, default=20)
    parser.add_argument("--gap-ms", type=float, default=40, help="between presses (a fast person: 40-60 ms)")
    parser.add_argument("--repeat-delay-ms", type=float, help="a held key's first repeat (default: the app's key repeat delay)")
    parser.add_argument("--repeat-ms", type=float, help="a held key's repeat interval (default: the app's key repeat interval)")
    parser.add_argument("--settle", type=float, default=2.0, help="seconds after the burst before reading")
    parser.add_argument("--no-stress", action="store_true", help="the light phase only")
    parser.add_argument("--self-test", action="store_true", help="check the accounting and the key sequences")
    opts = parser.parse_args()
    if opts.self_test:
        return self_test()
    os.makedirs(opts.out, exist_ok=True)
    if opts.scenario:
        return scenario(opts)
    if not opts.app:
        parser.error("--app is required")
    signposts = load("perf_signposts", "perf-signposts.py")
    stress = load("perf_stress_session", "perf-stress-session.py")
    actions = load("action_signposts_bench", "action-signposts-bench.py")
    App = load("activation_perf", "activation-perf.py").App
    report = {"host": actions.host_facts(), "gap_ms": opts.gap_ms, "repeat_delay_ms": opts.repeat_delay_ms,
              "repeat_ms": opts.repeat_ms, "focus": FOCUS_NOTE, "phases": {}, "failures": []}
    for phase in (["light"] if opts.no_stress else ["light", "stress"]):
        # A new app per phase: nothing the light phase made is in STRESS, which then has exactly its 60 workspaces.
        app = App(os.path.abspath(opts.app), os.path.join(opts.out, phase), 50)
        os.makedirs(app.out, exist_ok=True)
        app.launch()
        try:
            run_phase(opts, phase, app, signposts, stress, report)
        except stress.StressShapeError as error:
            report["failures"].append(f"{phase}: {error}")
        finally:
            app.stop()
    with open(os.path.join(opts.out, "report.json"), "w") as f:
        json.dump(report, f, indent=1)
    print("BURST-BENCH " + json.dumps(report), flush=True)
    return 1 if report["failures"] else 0


def self_test():
    """The accounting on synthetic runs of each scenario shape, and the key sequences."""
    def run(name, n, performed, counts, before, after):
        return account(scenario_presses(name, n), performed, counts, before, after, unit_of(name))

    one = {"tabs": 1, "panes": 1}
    # mixed, 20 presses = 14 splits + 6 closes, every close applied: 8 panes more, nothing lost.
    row = run("mixed", 20, {"splitRight": 7, "splitDown": 7, "closeTab": 6}, {}, one, {"tabs": 1, "panes": 9})
    assert row["lost"] == 0 and row["expected_delta"] == 8, row
    # mixed with the close guard: the first Cmd-W empties its pane, the 5 after it come quickly and are swallowed.
    row = run("mixed", 20, {"splitRight": 7, "splitDown": 7, "closeTab": 6}, {"close_swallowed": 5}, one, {"tabs": 1, "panes": 14})
    assert row["lost"] == 0 and row["swallowed"] == 5, row
    # mixed with one Cmd-W that cancelled the split before it: neither press changes the panes.
    row = run("mixed", 20, {"splitRight": 7, "splitDown": 7, "closeTab": 6}, {"creation_cancelled": 1}, one, {"tabs": 1, "panes": 9})
    assert row["lost"] == 0, row
    # mixed: one Cmd-W ran and closed nothing, with no reason: lost.
    row = run("mixed", 20, {"splitRight": 7, "splitDown": 7, "closeTab": 6}, {}, one, {"tabs": 1, "panes": 10})
    assert row["lost"] == 1 and row["unexplained"] == 1, row
    # mixed: one Cmd-D never reached its action: lost.
    row = run("mixed", 20, {"splitRight": 6, "splitDown": 7, "closeTab": 6}, {}, one, {"tabs": 1, "panes": 8})
    assert row["lost"] == 1 and row["missing"] == 1, row
    # A lost split and a lost close cancel in the pane count, but not in the runs: both lost.
    row = run("mixed", 20, {"splitRight": 6, "splitDown": 7, "closeTab": 5}, {}, one, {"tabs": 1, "panes": 9})
    assert row["lost"] == 2, row
    # cmdw-terminal: 20 Cmd-W on 20 added tabs, all closed.
    row = run("cmdw-terminal", 20, {"closeTab": 20}, {}, {"tabs": 21, "panes": 1}, {"tabs": 1, "panes": 1})
    assert row["lost"] == 0, row
    # held-cmdw: 2 repeats ran and closed nothing.
    row = run("held-cmdw", 20, {"closeTab": 20}, {}, {"tabs": 21, "panes": 1}, {"tabs": 3, "panes": 1})
    assert row["lost"] == 2, row
    # cmdd: 5 splits refused at the minimum pane size, with their HUD.
    row = run("cmdd", 20, {"splitRight": 20}, {"refusal": 5}, one, {"tabs": 1, "panes": 16})
    assert row["lost"] == 0 and row["refused"] == 5, row
    # cmdshiftd: 5 splits did nothing and showed nothing: lost.
    row = run("cmdshiftd", 20, {"splitDown": 20}, {}, one, {"tabs": 1, "panes": 16})
    assert row["lost"] == 5, row
    # newtab-*-mixed: each Cmd-W closes the tab the Cmd-Shift-L before it opened.
    row = run("newtab-chromium-mixed", 20, {"openBrowser": 10, "closeTab": 10}, {}, {"tabs": 2, "panes": 1}, {"tabs": 2, "panes": 1})
    assert row["lost"] == 0, row
    row = run("newtab-terminal-burst", 20, {"openBrowser": 20}, {}, one, {"tabs": 21, "panes": 1})
    assert row["lost"] == 0, row
    row = run("newtab-terminal-one", 20, {}, {}, one, one)
    assert row["lost"] == 1 and row["missing"] == 1, row

    # Sequences: one key-down per press, Command held around them; a held key repeats after the delay, then at the interval.
    steps, offsets = sequence(["d", "D", "w"], 40)
    assert len(offsets) == 3 and steps[0] == {"key_code": KEY["cmd"], "down": True}, steps
    assert steps[-1]["key_code"] == KEY["cmd"] and not steps[-1]["down"], steps
    assert [s["key_code"] for s in steps if s.get("down")].count(KEY["shift"]) == 1, steps
    assert all(b - a >= 32 for a, b in zip(offsets, offsets[1:])), offsets
    steps, offsets = sequence(["w"] * 5, 40, repeat=(375, 30))
    assert len(offsets) == 5 and offsets[1] - offsets[0] == 375 and offsets[4] - offsets[3] == 30, offsets
    assert sum(1 for s in steps if s.get("repeat")) == 4 and steps[1]["key_code"] == KEY["w"], steps
    print("self-test ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
