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
  cmdd-one / cmdshiftd-one                    one Cmd-D or Cmd-Shift-D (key -> grid of each press)
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
override). The app runs with CMUX_NEXT_NO_ACTIVATE=1 (never activated), and each sequence first makes
the window a person's key would go to the app's key window (`key_window`): the shell window for the
terminal and chat rows, the Chromium page window of the pane's selected page for the Chromium rows,
as when a person clicked into the page. So a Chromium row's keys take the page-first path a key in a
focused page takes (the page window's sendEvent and the router's page-first offer).

Each press is matched to what it did by its key event's timestamp: the action signposts give each
user run's event time (begin minus input_age_ms) and `debug.burst` marks each outcome with the event
that ran it. A press matches the run and marks within half the smallest gap between presses of its
time, so a mark is never given to another press.

After the last key the bench waits for the app to say the burst is done (`debug.burst status`: no
key left to post, no create still asking the daemon, no terminal grid waiting to go or waiting for its
echo), with --deadline only as the failure bound, and stops `debug.frames` there. It then waits up to
--redraw-wait for each echoed terminal's first output (a program that does not redraw on SIGWINCH
prints nothing; those are counted, not failed).

Per scenario it reports:

  input_to_next_commit  per press that changed the layout (created or closed): the key's age at the
                        action plus the next CA commit (action.commit from perf-signposts.py),
                        p50/p95/p99/max; presses that did nothing by design (swallowed, cancelled,
                        refused) are in noop_input_to_next_commit. It is a lower bound of the time to
                        the frame that shows the result: work the action defers (Chromium
                        CreateBrowser, daemon replies, split creation) commits later, so the < 10 ms
                        target needs each action's own end signal; the resize columns below give the
                        later terminal stages
  commit_missed         presses whose commit boundary missed its turn (action.commit.missed): not in
                        the percentiles, so any is a failure
  fates                 each press's fate, from its own run and marks: created, closed, swallowed,
                        cancelled (a Cmd-W that cancelled a creation still on its way), creation_cancelled
                        (that creating press), refused (the refusal HUD), and the lost ones: missing
                        (never reached its action), no_outcome (its run did nothing and said nothing),
                        close_not_applied (a closed tab still there afterwards), swallowed_after_create
                        (a Cmd-W swallowed by the close guard though a split or new tab came between it
                        and the close that emptied the pane: the person was looking at that new pane)
  extra                 runs no press explains: a second run of one press (double dispatch) or a run
                        whose event matches no press (must be 0)
  unexplained           the model's change (panes or tabs) the created presses and the verified closes
                        do not explain: creates that never landed, or more than were asked
  lost                  missing + no_outcome + close_not_applied + swallowed_after_create + unexplained
                        (must be 0)
  frames                `debug.frames` over the burst: refresh, intervals p50/p95/p99/max, missed vsyncs
  resize                terminal grids (`debug.burst`): a grid the attach driver really sent (pty_grid),
                        the daemon's echo of it (grid_echo), and the terminal's first output after the
                        echo (first_output; the busy terminals of STRESS, which print every 20 ms, are
                        left out and counted). A grid is not tied to the press that caused it, so a
                        one-press row reports key -> grid / echo / output; a burst row reports each
                        since the latest press before it (a lower bound, labelled) and the last press
                        -> the burst's last one. Grids per terminal: more than one per motion is a
                        second resize
  invalid               why the row does not measure what it names: Chromium not running or a tab that
                        is not Chromium, agent chats replaced by the New Tab page, a STRESS shape lost

Prints one `BURST-BENCH {json}` line and writes report.json to --out. Exit 1 when a press was lost,
a run was extra, a commit missed, or a row is invalid (also when the signpost stream or the trace
dropped records). Run on a fleet GUI host, never on Lawrence's Mac, and quote the
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
SCENARIOS = ["cmdw-terminal", "cmdw-chromium", "cmdw-chat", "cmdd", "cmdshiftd", "cmdd-one", "cmdshiftd-one", "mixed",
             "held-cmdw"] + NEWTAB
# Press letters: lower case with Command, upper case with Command-Shift.
ACTIONS = {"w": "closeTab", "d": "splitRight", "D": "splitDown", "L": "openBrowser"}
CLOSE_KINDS = {"cmdw-terminal": "terminal", "cmdw-chromium": "chromium", "cmdw-chat": "chat", "held-cmdw": "terminal"}
FRAME_FIELDS = ("frames", "refresh_ms", "p50_ms", "p95_ms", "p99_ms", "max_ms", "missed", "main_p95_ms", "main_max_ms")
FOCUS_NOTE = ("each sequence makes its key window first (debug.key key_window, the app never activated): the shell "
              "window for terminal and chat rows, the selected Chromium page's window for Chromium rows")
# What a press's `debug.burst` marks can say it did.
PRESS_MARKS = ("refusal", "close_swallowed", "creation_cancelled", "closed")
LOST_FATES = ("missing", "no_outcome", "close_not_applied", "swallowed_after_create")
APPLIED_FATES = ("created", "closed")


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
    return {"cmdd": ["d"] * n, "cmdshiftd": ["D"] * n, "cmdd-one": ["d"], "cmdshiftd-one": ["D"],
            "mixed": (["d", "D", "w"] * n)[:n]}.get(name, ["w"] * n)


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
    return "panes" if name in ("cmdd", "cmdshiftd", "cmdd-one", "cmdshiftd-one", "mixed") else "tabs"


def is_chromium(name):
    """A row whose keys go to a Chromium page window."""
    return name == "cmdw-chromium" or name.startswith("newtab-chromium-")


def press_bound(times):
    """How far (s) a run or mark may be from its press's time: half the smallest gap between presses, so
    a record is never given to the press next to it; unbounded for one press."""
    gaps = [b - a for a, b in zip(times, times[1:])]
    return min(gaps) / 2 if gaps else float("inf")


def nearest(times, at, bound):
    """The index of the press nearest `at` (seconds, the key event's timestamp) within `bound`, or None."""
    if not isinstance(at, (int, float)) or not times:
        return None
    index = min(range(len(times)), key=lambda i: abs(times[i] - at))
    return index if abs(times[index] - at) <= bound else None


def account(presses, times, runs, marks, before, after, unit, tabs_after):
    """Each press's fate from its own run and marks, then the model change the fates must explain.

    `presses`/`times`: the press letters and their key times (s); `runs`: the user runs of the scenario's
    action ids, each {"id", "event_s"} (event_s: the run's begin minus its input age, None without
    one); `marks`: `debug.burst` events (kind, event_s, tabs, empties_pane); `before`/`after`:
    {"tabs", "panes"}; `tabs_after`: every tab id of the workspace after the burst.

    A Cmd-W's fate is what the app marked for its key event: closed (its tabs must be gone afterwards),
    swallowed, cancelled (and the latest create before it is then creation_cancelled) or refused; a
    create's is refused (its HUD) or created. Closes are checked by tab id, so the model change left to
    explain is the creates': observed - (created - removed by closes) is unexplained either way."""
    bound = press_bound(times)
    runs_of = [0] * len(presses)
    extra = 0
    for run in runs:
        index = nearest(times, run.get("event_s"), bound)
        if index is None or ACTIONS[presses[index]] != run.get("id"):
            extra += 1  # a run no press explains
        else:
            runs_of[index] += 1
    double = sum(max(0, count - 1) for count in runs_of)
    marks_of = [[] for _ in presses]
    unattributed = {}
    for mark in marks:
        if mark.get("kind") not in PRESS_MARKS:
            continue
        index = nearest(times, mark.get("event_s"), bound)
        if index is None:
            unattributed[mark["kind"]] = unattributed.get(mark["kind"], 0) + 1
        else:
            marks_of[index].append(mark)
    fates, closes = [], {}
    for index, letter in enumerate(presses):
        kinds = [m["kind"] for m in marks_of[index]]
        if not runs_of[index]:
            fate = "missing"
        elif letter == "w":
            fate = next((f for k, f in (("creation_cancelled", "cancelled"), ("close_swallowed", "swallowed"),
                                        ("closed", "closed"), ("refusal", "refused")) if k in kinds), "no_outcome")
            if fate == "closed":
                closes[index] = next(m for m in marks_of[index] if m["kind"] == "closed")
                if set(closes[index].get("tabs") or []) & set(tabs_after):
                    fate = "close_not_applied"
        else:
            fate = "refused" if "refusal" in kinds else "created"
        fates.append(fate)
    for index, fate in enumerate(fates):
        if fate == "cancelled":
            # The creation it cancelled: the latest create before it that still counts as created.
            made = [i for i in range(index) if fates[i] == "created"]
            if made:
                fates[made[-1]] = "creation_cancelled"
        elif fate == "swallowed":
            # The close guard is for a Cmd-W that would close a tab the person never looked at, after one
            # that emptied its pane. A split or new tab since then moved them to a pane they look at.
            emptied = [i for i in range(index) if i in closes and closes[i].get("empties_pane")]
            if emptied and any(fates[i] == "created" for i in range(emptied[-1] + 1, index)):
                fates[index] = "swallowed_after_create"
    created = fates.count("created")
    removed = sum((len(closes[i].get("tabs") or []) if unit == "tabs" else int(bool(closes[i].get("empties_pane"))))
                  for i, fate in enumerate(fates) if fate == "closed")
    expected = created - removed
    observed = after[unit] - before[unit]
    unexplained = abs(observed - expected)
    counts = {fate: fates.count(fate) for fate in dict.fromkeys(fates)}
    lost = sum(counts.get(f, 0) for f in LOST_FATES) + unexplained
    return {"fates": counts, "press_fates": fates, "performed": sum(runs_of), "extra": extra + double,
            "double_dispatch": double, "unattributed_marks": unattributed, "unit": unit,
            "observed_delta": observed, "expected_delta": expected, "unexplained": unexplained, "lost": lost}


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
    # The window a person's keys go to: the selected Chromium page's own window for the Chromium rows.
    key_window = "page" if is_chromium(name) else "shell"
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
    sent = rpc("debug.key", {"sequence": steps, "key_window": key_window, "pane": pane}) or {}
    if sent.get("error") or "base_s" not in sent:
        record["errors"].append(f"debug.key: {sent}")
    duration = float(sent.get("duration_ms") or 0) / 1000
    started = time.monotonic()

    def status():
        return rpc("debug.burst", {"action": "status"}) or {}

    def done(reply):
        return (reply.get("recording") and not reply.get("sequence_playing") and reply.get("pending_intents") == 0
                and reply.get("resize_idle") and reply.get("terminals_awaiting_echo") == 0)

    # The keys are scheduled for `duration`: no status call while they play, so the bench adds no
    # main-thread work to the presses it measures.
    time.sleep(duration)  # test script: the sequence's own schedule, not a settle
    # The burst is done when the app says so: every key posted, no create still asking the daemon, no grid
    # waiting to go or for its echo. The deadline only bounds a burst that never settles (a failure).
    settled = stress.wait(lambda: done(status()), opts.deadline, step=0.1)
    settled_after = time.monotonic() - started
    frames = rpc("debug.frames", {"action": "stop", "raw": True}) or {}
    if not settled:
        record["invalid"].append(f"the burst never settled within {opts.deadline:.0f} s of its last key: {status()}")
    # Each echoed grid's first output: a program that does not redraw at a new size prints nothing, so
    # this is bounded and what never came is counted in the row, not failed.
    stress.wait(lambda: status().get("awaiting_output_surfaces") == 0, opts.redraw_wait, step=0.1)
    trace = rpc("debug.burst", {"action": "stop"}) or {}
    after = {"tabs": len(builder.tabs(workspace, pane)), "panes": len(builder.panes(builder.workspace(workspace)))}
    tabs_after = [t.get("id") for p in builder.panes(builder.workspace(workspace)) for t in p.get("tabs") or []]
    if chromium:
        # After a Cmd-Shift-L burst the pane shows the last tab it opened, which must be Chromium.
        problems = browser_problems(builder, stress, want_chromium=newtab and after["tabs"] > before["tabs"])
        if problems:
            record["invalid"].append(f"after the burst: {'; '.join(problems)[:300]}")
    base = sent.get("base_s")
    record.update({"before": before, "after": after, "unit": unit_of(name), "press_letters": presses,
                   "press_times_s": [base + o / 1000 for o in offsets] if isinstance(base, (int, float)) else [],
                   "key_repeat": {k: armed.get(k) for k in ("key_repeat_delay_s", "key_repeat_interval_s")},
                   "held_repeat_ms": repeat, "trace": trace, "frames": {k: frames.get(k) for k in FRAME_FIELDS},
                   "sequence_ms": duration * 1000, "settled_ms": round(settled_after * 1000), "key_window": key_window,
                   "tabs_after": tabs_after})
    return dump(opts, record)


def dump(opts, record):
    with open(os.path.join(opts.out, "scenario.json"), "w") as f:
        json.dump(record, f, indent=1)
    return 0


def event_time(interval):
    """A user run's key event time (s): its begin minus its input age, or None without one."""
    age = float(interval["fields"].get("input_age_ms", "-1"))
    return interval["at_s"] - age / 1000 if age >= 0 and isinstance(interval.get("at_s"), (int, float)) else None


def resize_stats(events, times, busy):
    """Terminal grids from the trace: sent, echoed and the first output after each echo, timed from the
    press. A grid carries no press id, so only a one-press row times each from its press; a burst row
    reports each since the latest press before it (a lower bound) and the last press -> the last one."""
    busy = set(busy)
    grids = [e for e in events if e.get("kind") == "pty_grid"]
    if not grids:
        return None
    echoes = [e for e in events if e.get("kind") == "grid_echo"]
    outputs = [e for e in events if e.get("kind") == "first_output" and e.get("surface") not in busy]
    per_surface = {}
    for grid in grids:
        per_surface[grid.get("surface")] = per_surface.get(grid.get("surface"), 0) + 1
    out = {"grids": len(grids), "echoed": len(echoes), "terminals": len(per_surface),
           "grids_per_terminal_max": max(per_surface.values()),
           "first_output": len(outputs), "busy_left_out": sum(1 for e in events if e.get("kind") == "first_output" and e.get("surface") in busy),
           "echoed_without_output": len({e.get("surface") for e in echoes} - {e.get("surface") for e in events if e.get("kind") == "first_output"})}
    if not times:
        return out

    def since(at):
        earlier = [t for t in times if t <= at]
        return (at - max(earlier)) * 1000 if earlier else None
    stages = (("grid_sent", grids), ("grid_echo", echoes), ("first_output", outputs))
    if len(times) == 1:
        for stage, marks in stages:
            out[f"key_to_{stage}_ms"] = percentiles([d for d in (since(m["at_s"]) for m in marks) if d is not None])
    else:
        for stage, marks in stages:
            out[f"since_latest_press_to_{stage}_ms"] = percentiles([d for d in (since(m["at_s"]) for m in marks) if d is not None])
            out[f"last_press_to_last_{stage}_ms"] = round((max(m["at_s"] for m in marks) - times[-1]) * 1000, 2) if marks else None
    return out


def summarize(signposts, ndjson, record, busy_surfaces=()):
    """The scenario's row from its signpost stream and its record."""
    with open(ndjson) as f:
        parsed = signposts.parse(f.read().splitlines(), signposts.local_timebase())
    letters = record.get("press_letters") or []
    ids = {ACTIONS[p] for p in letters}
    user = [i for i in parsed["intervals"] if i["fields"].get("id") in ids and i["fields"].get("origin") == "user"]
    trace = record.get("trace") or {}
    times = list(record.get("press_times_s") or [])
    out = {"scenario": record.get("scenario"), "presses": record.get("presses"), "key_window": record.get("key_window"),
           "chat_fallbacks": record.get("chat_fallbacks"), "frames": record.get("frames"),
           "key_repeat": record.get("key_repeat"), "held_repeat_ms": record.get("held_repeat_ms"),
           "settled_ms": record.get("settled_ms"), "stream_lost": parsed["lost"], "trace_dropped": trace.get("dropped"),
           "errors": record.get("errors"), "invalid": list(record.get("invalid") or [])}
    if parsed["lost"]:
        # A lost action.perform would read as a missing press: the app would be blamed for the stream's loss.
        out["invalid"].append(f"the signpost stream lost {parsed['lost']} records")
    if trace.get("dropped"):
        out["invalid"].append(f"debug.burst dropped {trace['dropped']} marks")
    if not record.get("before") or not record.get("after") or len(times) != len(letters):
        out["invalid"].append("the scenario never ran its burst")
        return out
    runs = [{"id": i["fields"]["id"], "event_s": event_time(i)} for i in user if i["name"] == "action.perform"]
    out.update(account(letters, times, runs, trace.get("events") or [], record["before"], record["after"],
                       record["unit"], record.get("tabs_after") or []))
    # input -> next commit, apart for presses that did something and presses that did nothing by design.
    fates, bound = out["press_fates"], press_bound(times)
    applied, noop, missed = [], [], 0
    for interval in user:
        if interval["name"] != "action.commit" or float(interval["fields"].get("input_age_ms", "-1")) < 0:
            continue
        if interval.get("missed"):
            missed += 1
            continue
        index = nearest(times, event_time(interval), bound)
        total = float(interval["fields"]["input_age_ms"]) + interval["ms"]
        (applied if index is not None and fates[index] in APPLIED_FATES else noop).append(total)
    out.update({"input_to_next_commit_ms": percentiles(applied), "noop_input_to_next_commit_ms": percentiles(noop),
                "commit_missed": missed, "resize": resize_stats(trace.get("events") or [], times, busy_surfaces)})
    return out


def failures_of(phase, row):
    """The report's failures for one row."""
    found = []
    if row.get("lost"):
        lost = {f: n for f, n in (row.get("fates") or {}).items() if f in LOST_FATES}
        found.append(f"{phase} {row['scenario']}: {row['lost']} presses lost ({lost}, {row.get('unexplained')} unexplained)")
    if row.get("extra"):
        found.append(f"{phase} {row['scenario']}: {row['extra']} runs no press explains "
                     f"({row.get('double_dispatch')} a second run of one press)")
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
    busy_surfaces = []
    if phase == "stress":
        session = builder.build()  # raises StressShapeError: another shape is never measured as STRESS
        report["stress_session"] = session
        print("STRESS-SESSION " + json.dumps(session), flush=True)
        measured = builder.measured
        state = start_state(builder, measured)
        # The terminals STRESS keeps printing: their next output is no redraw, so the redraw stats leave them out.
        busy = set(getattr(builder, "busy", []) or [])
        busy_surfaces = [t.get("surface") for p in builder.panes(builder.workspace(measured))
                         for t in p.get("tabs") or [] if t.get("id") in busy]
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
                   "--gap-ms", str(opts.gap_ms), "--deadline", str(opts.deadline), "--redraw-wait", str(opts.redraw_wait)]
        for flag, value in (("--repeat-ms", opts.repeat_ms), ("--repeat-delay-ms", opts.repeat_delay_ms)):
            if value is not None:
                command += [flag, str(value)]
        done = subprocess.run(command, check=False, stdout=subprocess.DEVNULL)
        try:
            with open(os.path.join(out, "scenario.json")) as f:
                record = json.load(f)
        except (OSError, ValueError) as error:
            record = {"scenario": name, "presses": opts.presses, "errors": [f"no scenario record (exit {done.returncode}): {error}"]}
        row = summarize(signposts, ndjson, record, busy_surfaces) if os.path.exists(ndjson) else \
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
    parser.add_argument("--deadline", type=float, default=30.0,
                        help="seconds after the last key by which the app must say the burst is done (a failure bound)")
    parser.add_argument("--redraw-wait", type=float, default=2.0,
                        help="seconds to wait for each echoed terminal's first output (a program that never redraws prints nothing)")
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
    """The per-press accounting on synthetic runs of each scenario shape, the resize stats and the key sequences."""
    gap = 0.04

    class Burst:
        """A synthetic burst of scenario `name`: the press times, and runs and marks to add per press."""
        def __init__(self, name, n):
            self.name, self.letters = name, scenario_presses(name, n)
            self.times = [100 + i * gap for i in range(len(self.letters))]
            self.runs, self.marks = [], []

        def run(self, i, jitter=0.002, letter=None):
            self.runs.append({"id": ACTIONS[letter or self.letters[i]], "event_s": self.times[i] + jitter})

        def mark(self, i, kind, **extra):
            self.marks.append({"kind": kind, "event_s": self.times[i], **extra})

        def close(self, i, tab, empties=False):
            self.mark(i, "closed", tabs=[tab], empties_pane=empties)

        def account(self, before, after, tabs_after=()):
            return account(self.letters, self.times, self.runs, self.marks, before, after, unit_of(self.name), list(tabs_after))

    def mixed(swallow_after_create=False, extra_close_run=False, lost_split=None):
        """mixed, 21 presses (d, D, w x 7): each Cmd-W closes the split the Cmd-Shift-D before it made, which
        empties that pane; 14 splits, 7 closes, 7 panes more."""
        burst = Burst("mixed", 21)
        for i, letter in enumerate(burst.letters):
            if i == lost_split:
                continue
            burst.run(i)
            if letter == "w":
                if swallow_after_create and i > 2:
                    burst.mark(i, "close_swallowed")
                else:
                    burst.close(i, f"t{i}", empties=True)
        if extra_close_run:
            burst.run(2, jitter=0.004)  # one Cmd-W dispatched twice
        return burst

    one = {"tabs": 1, "panes": 1}
    row = mixed().account(one, {"tabs": 1, "panes": 8})
    assert row["lost"] == 0 and row["extra"] == 0 and row["expected_delta"] == 7, row
    # The close guard swallows every Cmd-W after the first, though a split came between: each is lost (the
    # person was looking at the split they just made: "some cmd w doesnt register").
    row = mixed(swallow_after_create=True).account(one, {"tabs": 1, "panes": 14})
    assert row["fates"]["swallowed_after_create"] == 6 and row["lost"] == 6, row
    # One Cmd-W runs twice and one Cmd-D never reaches its action: the pane count matches (7 more), yet
    # the per-press view says one missing and one double dispatch.
    burst = mixed(extra_close_run=True, lost_split=3)
    row = burst.account(one, {"tabs": 1, "panes": 7})
    assert row["fates"]["missing"] == 1 and row["double_dispatch"] == 1 and row["extra"] == 1, row
    # A split that ran but created nothing and a Cmd-W that ran but closed nothing: the pane count matches.
    burst = mixed()
    burst.marks = [m for m in burst.marks if m["event_s"] != burst.times[5]]  # press 5 (w) said nothing
    # 13 splits landed of 14 and 6 closes: 7 more, as the pooled count of 14 - 7 would have it.
    row = burst.account(one, {"tabs": 1, "panes": 8})
    assert row["fates"]["no_outcome"] == 1 and row["unexplained"] == 1 and row["lost"] == 2, row
    # A refusal belongs to its own press: a refused Cmd-D does not cover a Cmd-W that closed nothing.
    burst = mixed()
    burst.mark(0, "refusal")
    burst.marks = [m for m in burst.marks if m["event_s"] != burst.times[2]]
    row = burst.account(one, {"tabs": 1, "panes": 8})  # 13 splits, 6 closes
    assert row["fates"]["refused"] == 1 and row["fates"]["no_outcome"] == 1 and row["lost"] == 1, row
    # A Cmd-W that cancelled the split before it: neither press changes the panes, nothing lost.
    burst = mixed()
    burst.marks = [m for m in burst.marks if m["event_s"] != burst.times[2]]
    burst.mark(2, "creation_cancelled")
    row = burst.account(one, {"tabs": 1, "panes": 8})  # 13 splits landed, 6 closes
    assert row["lost"] == 0 and row["fates"]["creation_cancelled"] == 1 and row["fates"]["cancelled"] == 1, row
    # A run whose event matches no press (another press's time is too far): extra.
    burst = mixed()
    burst.runs.append({"id": "splitRight", "event_s": burst.times[-1] + 1})
    assert burst.account(one, {"tabs": 1, "panes": 8})["extra"] == 1

    # cmdw-terminal: 20 Cmd-W on 20 added tabs, all closed.
    burst = Burst("cmdw-terminal", 20)
    for i in range(20):
        burst.run(i)
        burst.close(i, f"t{i}")
    row = burst.account({"tabs": 21, "panes": 1}, {"tabs": 1, "panes": 1}, tabs_after=["kept"])
    assert row["lost"] == 0, row
    # A closed tab that is still there afterwards: the close did not apply.
    row = burst.account({"tabs": 21, "panes": 1}, {"tabs": 2, "panes": 1}, tabs_after=["kept", "t7"])
    assert row["fates"]["close_not_applied"] == 1 and row["lost"] == 1, row
    # held-cmdw: 2 repeats ran and said nothing.
    burst = Burst("held-cmdw", 20)
    for i in range(20):
        burst.run(i)
        if i < 18:
            burst.close(i, f"t{i}")
    row = burst.account({"tabs": 21, "panes": 1}, {"tabs": 3, "panes": 1})
    assert row["lost"] == 2 and row["fates"]["no_outcome"] == 2, row
    # cmdd: 5 splits refused at the minimum pane size, with their HUD.
    burst = Burst("cmdd", 20)
    for i in range(20):
        burst.run(i)
        if i >= 15:
            burst.mark(i, "refusal")
    row = burst.account(one, {"tabs": 1, "panes": 16})
    assert row["lost"] == 0 and row["fates"]["refused"] == 5, row
    # cmdshiftd: 5 splits did nothing and showed nothing: unexplained.
    burst = Burst("cmdshiftd", 20)
    for i in range(20):
        burst.run(i)
    row = burst.account(one, {"tabs": 1, "panes": 16})
    assert row["lost"] == 5 and row["unexplained"] == 5, row
    # newtab-*-mixed: each Cmd-W closes the tab the Cmd-Shift-L before it opened.
    burst = Burst("newtab-chromium-mixed", 20)
    for i, letter in enumerate(burst.letters):
        burst.run(i)
        if letter == "w":
            burst.close(i, f"t{i}")
    row = burst.account({"tabs": 2, "panes": 1}, {"tabs": 2, "panes": 1})
    assert row["lost"] == 0, row
    burst = Burst("newtab-terminal-one", 20)
    row = burst.account(one, one)
    assert row["lost"] == 1 and row["fates"]["missing"] == 1, row

    # Resize: one press times each stage from it; a burst labels its values as since the latest press.
    events = [{"kind": "pty_grid", "at_s": 100.004, "surface": "1"}, {"kind": "pty_grid", "at_s": 100.006, "surface": "2"},
              {"kind": "grid_echo", "at_s": 100.008, "surface": "1"}, {"kind": "first_output", "at_s": 100.010, "surface": "1"},
              {"kind": "grid_echo", "at_s": 100.009, "surface": "2"}, {"kind": "first_output", "at_s": 100.011, "surface": "2"}]
    stats = resize_stats(events, [100.0], busy=["2"])
    assert stats["key_to_grid_sent_ms"]["max"] == 6 and stats["key_to_first_output_ms"]["n"] == 1, stats
    assert stats["busy_left_out"] == 1 and stats["echoed_without_output"] == 0, stats
    stats = resize_stats(events, [99.9, 100.0], busy=[])
    assert "key_to_grid_sent_ms" not in stats and stats["since_latest_press_to_grid_sent_ms"]["n"] == 2, stats
    assert stats["last_press_to_last_first_output_ms"] == 11, stats
    assert press_bound([1.0]) == float("inf") and abs(press_bound([1.0, 1.04, 1.1]) - 0.02) < 1e-9

    # Sequences: one key-down per press, Command held around them; a held key repeats after the delay, then at the interval.
    steps, offsets = sequence(["d", "D", "w"], 40)
    assert len(offsets) == 3 and steps[0] == {"key_code": KEY["cmd"], "down": True}, steps
    assert steps[-1]["key_code"] == KEY["cmd"] and not steps[-1]["down"], steps
    assert [s["key_code"] for s in steps if s.get("down")].count(KEY["shift"]) == 1, steps
    assert all(b - a >= 32 for a, b in zip(offsets, offsets[1:])), offsets
    steps, offsets = sequence(["w"] * 5, 40, repeat=(375, 30))
    assert len(offsets) == 5 and offsets[1] - offsets[0] == 375 and offsets[4] - offsets[3] == 30, offsets
    assert sum(1 for s in steps if s.get("repeat")) == 4 and steps[1]["key_code"] == KEY["w"], steps
    assert scenario_presses("cmdd-one", 20) == ["d"] and is_chromium("newtab-chromium-held") and not is_chromium("cmdw-chat")
    print("self-test ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
