#!/usr/bin/env python3
"""Input to presented frame for every cmux NEXT surface, with real HID input (p04-input.md task 070; DC1, DC2, DC5).

Launches the tagged app itself on a GUI host (bench_launch.BenchApp: a scratch cmux.json, the hang watchdog at
8 ms, frontmost for real input) and, per session (light, or STRESS from perf-stress-session.py), measures:

  keys     --keys real key presses at the HID event tap (hid_input.HidPoster, one key in flight) into each surface:
             terminal       a `zsh -f` prompt (STRESS: the measured workspace's last pane)
             home           the native Home composer (the Home fixture in a workspace of its own)
             omnibar        a Chromium tab's address field
             agent-pane     an agent chat's composer
             chromium-page  a textarea of a local page in a Chromium tab; the page must answer as Chromium
                            (`window.chrome` and a Chrome/ user agent) or the surface is not measured
             webkit-page    the same page in a WebKit tab
             palette        the command palette's field
  scrolls  with --scrolls N, N trackpad-like gestures (began, changed, ended, momentum) at display rate over each
           surface's content
  drags    with --drag, a press, --rate Hz drag events out and back, and the release, --drags times per target:
           divider (a vertical pane divider), tab (the first tab pill along its strip), pane-swap (an Option-press
           on a pane's empty tab strip space past its tabs and +, dropped on the next pane: PaneSwapDrag, then
           swapped back; the layout must still have its two panes), canvas-pane (a pane's tab strip in the canvas
           layout) and strip-scrollbar (the columns strip's scrollbar thumb)

under each condition: idle; --storm (automation running while the person types: `cli=HZ[:VERB]` runs the app's
CLI, `terminal current screen read` by default (words joined with `+`), at HZ; `sidebar-churn=N[@HZ]` grows the
sidebar to N workspaces (STRESS's background workspaces first, then empty ones) and rearranges it at HZ, 10 by
default, as agents do); and --stall MS/PERIOD (a `debug.stall` of MS on the main thread every PERIOD), one condition
per value (`none` is no stall). A phase whose load failed on every call is `load_failed` and has no rows: its numbers
would claim a load that did not run.

Each phase resets `debug.input` and `debug.hangs`, records the app's `input.latency` signposts (`log stream`, one
event per closed slot: every stage from the OS timestamp to the presented frame), then reads `debug.input`
(latency, gate, pump, coalescer) and `debug.hangs`. Rows are JSON objects:

  {surface, session, condition, storm, stall, kind, target, stage, presentation_source, p50, p95, p99, max, n,
   input, source}

`stage` is the time from the oldest OS event to that stage (`presented` is DC1's number; `echo_presented` is a
terminal key's presented time when the slot saw the echo; `frame_main` is a drag frame's dispatch to its commit,
DC5's main time). `source` is `signpost` (every slot, exact percentiles) or `ledger` (debug.input's histograms).
Percentiles are scripts/perf-lab/perf_stats.py's (typing_report.distribution). The report also has a header (host,
macOS, display refresh, input mode) and `dc`: every DC1, DC2 and DC5 field per session and condition, null with a
reason in `absent` where the app has no producer yet (ghostty.lock_wait, cursor-rect rebuilds, a section the build
does not register).

--input real (default) needs the GUI session and the Accessibility grant (`nx-remote --needs input` or a whole
mini); a run where no key reached the app says so (`input_reached: false`). --input debug types with `debug.key`
instead: the app labels those keys automation, so every row and the header say `input: debug`, `quotable: false`.
The bench never falls back from one to the other. It prints numbers and asserts no time: it exits 0 whatever it
measured (--self-test exits 1 when the self-test fails).

  input-latency-bench.py --app APP --out DIR [--json FILE] [--tag TAG] [--input real|debug]
      [--surfaces terminal,home,omnibar,agent-pane,chromium-page,webkit-page,palette] [--sessions light,stress]
      [--keys 400] [--scrolls 0] [--drag divider,tab,pane-swap,canvas-pane,strip-scrollbar] [--rate 1000]
      [--storm cli=10hz,sidebar-churn=400] [--stall none,50ms/100ms] [--with-idle]
  input-latency-bench.py --self-test

Fleet (an owned mini with a console; the step builds the app):
  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh --ref SHA \\
    --artifact artifacts/split-spring/report.json --arg=--suite=input-latency --arg=--vdisplay=120 \\
    [--arg=--sessions=light,stress] [--arg=--storm=cli=10hz,sidebar-churn=400]
"""
import argparse, contextlib, io, json, os, platform, re, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hid_input  # noqa: E402
import typing_report  # noqa: E402

SURFACES = ("terminal", "home", "omnibar", "agent-pane", "chromium-page", "webkit-page", "palette")
# The InputTarget a surface's keys land in (InputTargetClassifier's rules in the App's composition root).
EXPECTED_TARGETS = {
    "terminal": ("terminal",), "home": ("textView",), "omnibar": ("textView",), "agent-pane": ("agentPane",),
    "chromium-page": ("chromiumPage",), "webkit-page": ("webkitPage",), "palette": ("palette", "textView"),
}
DRAGS = ("divider", "tab", "pane-swap", "canvas-pane", "strip-scrollbar")
# The stages a row is reported for (hid_input.STAGE_FIELDS names), each from the oldest OS event.
REPORT_STAGES = ("arrived_main", "dispatch_start", "dispatch_end", "main_commit", "content_submitted",
                 "daemon_received", "pty_written", "echo_read", "presented")
SCROLL_KINDS = ("scrollBegin", "scrollFirstUpdate", "scrollUpdate", "scrollMomentum", "scrollEnd")
WINDOW = (40, 40, 1400, 900)
PAGE = ("<!doctype html><title>input latency</title><body style='margin:0'>"
        "<textarea id=t autofocus style='width:100%;height:100vh;font:16px monospace'></textarea>")
ENGINE_CHECK = ("(typeof window.chrome === 'object' && navigator.userAgent.indexOf('Chrome/') >= 0) ? 'chromium' : "
                "(navigator.userAgent.indexOf('AppleWebKit') >= 0 ? 'webkit' : navigator.userAgent)")
CHURN_STATUSES = ("todo", "working", "needs-attention", "review", "done")
# The storm's default CLI call: the focused terminal's screen, read through the daemon (docs/cli-contract.md maps
# classic `read-screen` to `cmux terminal <sel> screen read`). Words joined with `+` in --storm cli=HZ:VERB.
DEFAULT_STORM_VERB = ("terminal", "current", "screen", "read")
CLI_CONTRACT = os.path.join(HERE, "..", "..", "docs", "cli-contract.md")
# A pane-swap press: room after the last tab for the + button, and the least empty strip space on each side of it.
NEW_TAB_BUTTON_ROOM = 40.0
EMPTY_STRIP_MARGIN = 8.0
# PaneSwapDrag: in the window's top row a plain press on empty strip space moves the window; Option drags the pane.
PANE_SWAP_MODIFIERS = ("option",)
ABSENT_LOCK_WAIT = "ghostty.lock_wait: no producer in this build"
ABSENT_CURSOR_RECTS = "cursor-rect rebuilds per drag frame: no counter in this build (task 090)"


# ---------------------------------------------------------------- options
def parse_storm(spec):
    """`cli=10hz[:VERB]` and `sidebar-churn=N[@HZ]`, comma separated, all running together; {} for none."""
    storm = {}
    for part in [p.strip() for p in (spec or "").split(",") if p.strip() and p.strip() != "none"]:
        name, _, value = part.partition("=")
        if name == "cli":
            rate, _, verb = value.partition(":")
            match = re.fullmatch(r"([\d.]+)\s*hz", rate.lower())
            if not match or float(match.group(1)) <= 0:
                raise ValueError(f"--storm {part}: cli=HZ[:VERB], for example cli=10hz")
            storm["cli"] = {"hz": float(match.group(1)), "verb": verb.split("+") if verb else list(DEFAULT_STORM_VERB)}
        elif name == "sidebar-churn":
            count, _, rate = value.partition("@")
            match = re.fullmatch(r"([\d.]+)\s*(hz)?", (rate or "10hz").lower())
            if not count.isdigit() or int(count) <= 0 or not match:
                raise ValueError(f"--storm {part}: sidebar-churn=N[@HZ], for example sidebar-churn=400")
            storm["sidebar-churn"] = {"workspaces": int(count), "hz": float(match.group(1))}
        else:
            raise ValueError(f"--storm {part}: cli=HZ or sidebar-churn=N")
    return storm


def parse_stall(value):
    """`none` -> None; `50ms/100ms` -> (50, 100): a debug.stall of 50 ms every 100 ms."""
    value = value.strip().lower()
    if value in ("", "none"):
        return None
    match = re.fullmatch(r"(\d+)(?:ms)?/(\d+)(?:ms)?", value)
    if not match or int(match.group(1)) <= 0 or int(match.group(2)) < int(match.group(1)):
        raise ValueError(f"--stall {value}: none or MS/PERIOD with PERIOD >= MS, for example 50ms/100ms")
    return int(match.group(1)), int(match.group(2))


def storm_label(storm):
    parts = []
    if "cli" in storm:
        parts.append(f"cli={storm['cli']['hz']:g}hz")
    if "sidebar-churn" in storm:
        parts.append(f"sidebar-churn={storm['sidebar-churn']['workspaces']}")
    return ",".join(parts) or "none"


def conditions(storm_spec, stall_spec, with_idle):
    """The measured conditions: [{name, storm, stall}]. Idle when nothing else is asked (or --with-idle)."""
    storm = parse_storm(storm_spec)
    stalls = [parse_stall(v) for v in (stall_spec or "").split(",")] if stall_spec else []
    out = []
    if with_idle or (not storm and not any(stalls)):
        out.append({"name": "idle", "storm": {}, "stall": None})
    for stall in stalls or [None]:
        if not storm and stall is None:
            if not any(c["name"] == "idle" for c in out):
                out.append({"name": "idle", "storm": {}, "stall": None})
            continue
        names = ([f"storm:{storm_label(storm)}"] if storm else []) + ([f"stall:{stall[0]}ms/{stall[1]}ms"] if stall else [])
        out.append({"name": "+".join(names), "storm": storm, "stall": stall})
    return out


def build_parser():
    parser = argparse.ArgumentParser(description="Input to presented frame per cmux surface, real HID input.")
    parser.add_argument("--app")
    parser.add_argument("--tag", default="input-latency")
    parser.add_argument("--out")
    parser.add_argument("--json")
    parser.add_argument("--input", choices=("real", "debug"), default="real",
                        help="real: HID-tap events (a person's path, needs the input grant); debug: debug.key over the "
                             "control socket, labelled automation and never quoted as key latency")
    parser.add_argument("--surfaces", help=f"comma list of {','.join(SURFACES)} (default: all, none with only --drag)")
    parser.add_argument("--sessions", default="light", help="comma list of light,stress: one app launch each")
    parser.add_argument("--keys", type=int, default=400)
    parser.add_argument("--interval", type=float, default=0.05, help="seconds between keys (one key in flight)")
    parser.add_argument("--scrolls", type=int, default=0, help="trackpad gestures per surface (real input only)")
    parser.add_argument("--drag", help=f"comma list of {','.join(DRAGS)}")
    parser.add_argument("--rate", type=float, default=1000.0, help="drag events per second")
    parser.add_argument("--drags", type=int, default=5, help="out-and-back drags per target")
    parser.add_argument("--drag-seconds", type=float, default=1.0, help="one way of one drag")
    parser.add_argument("--storm", help="cli=HZ[:VERB],sidebar-churn=N[@HZ]: automation during every measured phase")
    parser.add_argument("--stall", help="comma list of none or MS/PERIOD: a main-thread debug.stall per condition")
    parser.add_argument("--with-idle", action="store_true", help="also measure idle when --storm or --stall is given")
    parser.add_argument("--self-test", action="store_true", help="run the bench against a fixture app and check every field")
    return parser


# ---------------------------------------------------------------- numbers
def dist(values):
    return typing_report.distribution(values, mean=False)


def row(ctx, kind, target, stage, source_name, values, source):
    d = dist(values) or {}
    return dict(ctx, kind=kind, target=target, stage=stage, presentation_source=source_name, p50=d.get("p50"),
                p95=d.get("p95"), p99=d.get("p99"), max=d.get("max"), n=d.get("n", 0), source=source)


def stage_rows(events, ctx, kinds):
    """Signpost rows: per kind, target and presentation source (and `*`, all sources), one row per stage some
    event reached; terminal keys add `echo_presented`, drags `frame_main` (dispatch start to commit)."""
    rows = []
    groups = {}
    for event in events:
        if event["kind"] not in kinds:
            continue
        for source_name in (event["presentation_source"], "*"):
            groups.setdefault((event["kind"], event["target"], source_name), []).append(event)
    for (kind, target, source_name), group in sorted(groups.items()):
        for stage in REPORT_STAGES:
            values = [e["stages_ms"][stage] for e in group if stage in e["stages_ms"]]
            if values:
                rows.append(row(ctx, kind, target, stage, source_name, values, "signpost"))
        if target == "terminal" and kind == "keyPress":
            echo = [e["stages_ms"]["presented"] for e in group if "echo_read" in e["stages_ms"] and "presented" in e["stages_ms"]]
            rows.append(row(ctx, kind, target, "echo_presented", source_name, echo, "signpost"))
        if kind == "drag":
            main = [e["stages_ms"]["main_commit"] - e["stages_ms"]["dispatch_start"] for e in group
                    if "main_commit" in e["stages_ms"] and "dispatch_start" in e["stages_ms"]]
            rows.append(row(ctx, kind, target, "frame_main", source_name, main, "signpost"))
    return rows


def ledger_rows(latency, ctx, kinds, entrypoint):
    """debug.input latency rows (InputLatencySnapshot) of `kinds` and `entrypoint`, as bench rows (`total` is the
    presented stage; the stage histograms are deltas from the stage before, so they keep their own names)."""
    rows = []
    for item in (latency or {}).get("rows") or []:
        if item.get("kind") not in kinds or item.get("entrypoint") != entrypoint:
            continue
        for stage, histogram in [("presented", item.get("total") or {})] + [
                ("delta:" + s.get("stage", "?"), s.get("histogram") or {}) for s in item.get("stages") or []]:
            rows.append(dict(ctx, kind=item.get("kind"), target=item.get("target"), stage=stage,
                             presentation_source=item.get("presentation_source"), p50=histogram.get("p50_ms"),
                             p95=histogram.get("p95_ms"), p99=histogram.get("p99_ms"), max=histogram.get("max_ms"),
                             n=histogram.get("count", 0), source="ledger", display=item.get("display")))
    return rows


def coalescer_max(section):
    """{"window/consumer": max deliveries per frame} from debug.input's coalescer section, whatever its nesting:
    every object with a `deliveries_per_frame` (a number, or an object with `max`) and its window and consumer."""
    found = {}

    def walk(node, window=None):
        if isinstance(node, dict):
            window = node.get("window", window)
            if "deliveries_per_frame" in node:
                value = node["deliveries_per_frame"]
                value = value.get("max") if isinstance(value, dict) else value
                if isinstance(value, (int, float)):
                    key = f"{window or '?'}/{node.get('consumer', '?')}"
                    found[key] = max(found.get(key, 0), value)
            for child in node.values():
                walk(child, window)
        elif isinstance(node, list):
            for child in node:
                walk(child, window)

    walk(section)
    return found


def p99_of(rows, target, stage="presented", kinds=("keyPress",)):
    for r in rows:
        if r["target"] in target and r["stage"] == stage and r["kind"] in kinds and r["presentation_source"] == "*" \
                and r["source"] == "signpost" and r["n"]:
            return r["p99"]
    return None


def section(debug_input, name, absent):
    """A debug.input section, or None with the reason added to `absent`."""
    if not isinstance(debug_input, dict) or debug_input.get("error"):
        absent.append(f"debug.input {name}: {debug_input.get('error') if isinstance(debug_input, dict) else 'no reply'}")
        return None
    if name in (debug_input.get("absent") or []) or name not in debug_input:
        absent.append(f"debug.input {name}: no producer in this build")
        return None
    return debug_input[name]


def dc_fields(runs):
    """Every DC1, DC2 and DC5 field, per session and condition (DC5: per drag target); null where nothing was
    measured or the build has no producer, with the reason in `absent`."""
    dc1, dc2, dc5 = [], [], []
    keyed = {}
    for run in runs:
        if run.get("phase") in ("keys", "scrolls"):
            keyed.setdefault((run["session"], run["condition"]), []).append(run)
    for (session, condition), group in keyed.items():
        absent = [ABSENT_LOCK_WAIT]
        surfaces = {}
        stalls = 0
        gate_wait, nonswift, pump_passes, pump_p99 = None, None, None, None
        for run in group:
            if run.get("phase") != "keys":
                continue
            rows = run.get("rows") or []
            expected = EXPECTED_TARGETS[run["surface"]]
            sources = sorted({r["presentation_source"] for r in rows if r["presentation_source"] != "*" and r["stage"] == "presented"
                              and r["source"] == "signpost" and r["target"] in expected and r["n"]})
            p50 = next((r["p50"] for r in rows if r["target"] in expected and r["stage"] == "presented"
                        and r["presentation_source"] == "*" and r["source"] == "signpost" and r["n"]), None)
            surfaces[run["surface"]] = {
                "p50_ms": p50, "p99_ms": p99_of(rows, expected),
                "n": next((r["n"] for r in rows if r["target"] in expected and r["stage"] == "presented"
                           and r["presentation_source"] == "*" and r["source"] == "signpost"), 0),
                "presentation_sources": sources, "status": run.get("status"),
                # webkit-page is judged only on the page's own estimate; before that it is reported.
                "judged": run["surface"] != "webkit-page" or sources == ["pageEstimated"],
            }
            stalls += (run.get("hangs") or {}).get("count") or 0
            debug_input = run.get("debug_input")
            gate = section(debug_input, "gate", absent)
            if gate:
                gate_wait = max(gate_wait or 0.0, gate.get("max_input_wait_behind_jobs_ms") or 0.0)
                nonswift = (nonswift or 0) + (gate.get("nonswift_blocks_while_input_pending") or 0)
            pump = section(debug_input, "pump", absent)
            if pump:
                passes = pump.get("passes_while_input_pending") or {}
                pump_passes = (pump_passes or 0) + sum(v for k, v in passes.items() if k != "chromiumPage")
                pump_p99 = max(pump_p99 or 0.0, pump.get("pass_ms_p99") or 0.0)
        absent += [f"{run['surface']} {run['phase']}: {run.get('reason')}" for run in group if run.get("status") == "load_failed"]
        churn = next((run["churn_workspaces"] for run in group if "churn_workspaces" in run), None)
        requested = next((run["churn_requested"] for run in group if "churn_requested" in run), None)
        if churn is not None and churn < requested:
            absent.append(f"sidebar-churn: {churn} of the {requested} workspaces asked for")
        terminal_rows = [r for run in group if run.get("surface") == "terminal" and run.get("phase") == "keys" for r in run.get("rows") or []]
        home_rows = [r for run in group if run.get("surface") == "home" and run.get("phase") == "keys" for r in run.get("rows") or []]
        storm, stall = group[0].get("storm"), group[0].get("stall")
        dc1.append({"session": session, "condition": condition, "surfaces": surfaces,
                    "terminal_echo_p99_ms": p99_of(terminal_rows, ("terminal",), stage="echo_presented"),
                    "ghostty_lock_wait_p99_ms": None, "main_stalls_over_8ms": stalls, "absent": sorted(set(absent))})
        dc2.append({"session": session, "condition": condition, "storm": storm, "stall": stall,
                    "terminal_key_p99_ms": p99_of(terminal_rows, ("terminal",)),
                    "home_key_p99_ms": p99_of(home_rows, ("textView",)),
                    "max_input_wait_behind_jobs_ms": gate_wait, "nonswift_blocks_while_input_pending": nonswift,
                    "pump_passes_while_input_pending_non_chromium": pump_passes, "cef_pass_ms_p99": pump_p99,
                    "sidebar_churn_workspaces": churn,
                    "absent": sorted({a for a in absent if a != ABSENT_LOCK_WAIT})})
    for run in runs:
        if run.get("phase") != "drag":
            continue
        absent = [ABSENT_CURSOR_RECTS] + ([run["reason"]] if run.get("status") in ("load_failed", "layout_changed") else [])
        coalescer = section(run.get("debug_input"), "coalescer", absent)
        per_consumer = coalescer_max(coalescer) if coalescer is not None else {}
        rows = run.get("rows") or []
        dc5.append({"session": run["session"], "condition": run["condition"], "target": run["target"],
                    "status": run.get("status"), "rate_hz": (run.get("posted") or {}).get("rate_hz"),
                    "events": (run.get("posted") or {}).get("events"),
                    "deliveries_per_frame_max": max(per_consumer.values()) if per_consumer else None,
                    "deliveries_per_frame": per_consumer,
                    "frame_main_p99_ms": next((r["p99"] for r in rows if r["kind"] == "drag" and r["stage"] == "frame_main"
                                               and r["presentation_source"] == "*" and r["n"]), None),
                    "cursor_rect_rebuilds_per_frame": None, "absent": absent})
    return {"dc1": dc1, "dc2": dc2, "dc5": dc5}


# ---------------------------------------------------------------- geometry
def empty_strip_point(pane):
    """A point of `pane`'s empty tab strip space (debug.pane_chrome, top-left window coordinates): past the run of
    tabs and its + button, before the pane's toolbar, where PaneSwapDrag starts (TabStripView.mouseRects: a press
    on a tab, chip or + is the strip's own). A reason string when the strip has no such space."""
    strip = pane.get("strip")
    if not strip or pane.get("strip_hidden"):
        return "the pane shows no tab strip in debug.pane_chrome"
    x, y, w, h = (float(v) for v in strip)
    pill, slots = pane.get("pill"), pane.get("tab_slots") or []
    if pill and slots:  # tab_slots are strip content points: the first pill places them in the window
        origin = float(pill[0]) - float(slots[0][0])
        run_end = origin + max(float(s[0]) + float(s[1]) for s in slots)
    elif pill:
        run_end = float(pill[0]) + float(pill[2])
    else:
        run_end = x
    run_end += NEW_TAB_BUTTON_ROOM
    toolbar = (pane.get("toolbar") or {}).get("frame")
    right = min(x + w, float(toolbar[0])) if toolbar else x + w
    if right - run_end < 2 * EMPTY_STRIP_MARGIN:
        return f"the pane's tab strip has no empty space past its tabs and + ({right - run_end:.0f} pt)"
    return (run_end + right) / 2, y + h / 2


# ---------------------------------------------------------------- the bench
class Bench:
    """One bench run. The app, the poster, the signpost recorder and time are injected (the self-test fakes them)."""

    def __init__(self, opts, control, poster, recorder, pid=None, out=None, sleep=time.sleep, log=print):
        self.opts, self.control, self.poster, self.recorder = opts, control, poster, recorder
        self.pid, self.out, self.sleep, self.log_line = pid, out or tempfile.mkdtemp(prefix="input-latency-"), sleep, log
        self.session = "light"
        self.subject = None  # the surface or drag target being measured (`drag:<target>`)
        self.state = {}
        self.runs = []
        self.notes = []
        self.stress = None

    def note(self, text):
        self.notes.append(text)
        self.log_line(text)

    @property
    def entrypoint(self):
        return "person" if self.poster.input == "real" else "automation"

    # ------------------------------------------------------------ load
    def prepare_load(self, condition):
        """What a condition's load needs before its phases start, so building it is never inside a measured phase:
        the sidebar churn's workspaces (STRESS's background workspaces, or N empty ones made here)."""
        churn = condition["storm"].get("sidebar-churn")
        if not churn:
            return
        made = self.state.setdefault("churn_ids", [])
        if self.stress is not None and not made:
            made.extend(list(getattr(self.stress, "background", []) or [])[:churn["workspaces"]])
        for index in range(len(made), churn["workspaces"]):
            ref = self.control.cli("workspace", "create", "--empty", "--name", f"churn {index:04d}").stdout.strip()
            if ref:
                made.append(ref)
        if len(made) < churn["workspaces"]:
            self.note(f"{self.session} storm sidebar-churn: {len(made)} of {churn['workspaces']} workspaces")

    def load_facts(self, condition):
        """What the condition's load really had: the sidebar churn's workspace count (its label says the asked one)."""
        churn = condition["storm"].get("sidebar-churn")
        if not churn:
            return {}
        return {"churn_workspaces": min(len(self.state.get("churn_ids", [])), churn["workspaces"]),
                "churn_requested": churn["workspaces"]}

    @staticmethod
    def load_failure(load):
        """Why the phase's load did not run (a load thread whose every call failed), or None."""
        failed = [f"{t['name']}: {t['errors']} of {t['calls']} calls failed" for t in load or []
                  if t.get("calls") and t.get("errors", 0) >= t["calls"]]
        return "; ".join(failed) or None

    def start_load(self, condition):
        threads = []
        storm, stall = condition["storm"], condition["stall"]
        if "cli" in storm:
            verb = storm["cli"]["verb"]
            threads.append(hid_input.Periodic("storm.cli", lambda _: self.control.cli(*verb, timeout=20), 1.0 / storm["cli"]["hz"]))
        if "sidebar-churn" in storm:
            churn = storm["sidebar-churn"]
            ids = self.state.get("churn_ids", [])[:churn["workspaces"]]
            if ids:
                threads.append(hid_input.Periodic("storm.sidebar-churn", lambda i: self.churn_step(ids, i), 1.0 / churn["hz"]))
            else:
                self.note("storm sidebar-churn: no workspaces to rearrange")
        if stall:
            ms, period = stall
            threads.append(hid_input.Periodic("stall", lambda _: self.control.rpc("debug.stall", {"ms": ms}, timeout=10), period / 1000.0))
        for thread in threads:
            thread.start()
        if threads:
            self.sleep(1.0)  # the load runs before the first input
        return threads

    def churn_step(self, ids, index):
        """One sidebar rearrangement, round robin: to the top, a task status, a status pill (sidebar-churn-typing.py)."""
        ws = ids[(index * 7919) % len(ids)]
        kind = index % 3
        if kind == 0:
            return self.control.cli("workspace", ws, "move", "--index", "0", timeout=20)
        if kind == 1:
            return self.control.cli("workspace", ws, "update", "--task-status", CHURN_STATUSES[index % len(CHURN_STATUSES)], timeout=20)
        return self.control.cli("workspace", ws, "status", "set", "bench", f"step {index}", timeout=20)

    @staticmethod
    def stop_load(threads):
        for thread in threads:
            thread.stop()
        return [thread.report() for thread in threads]

    # ------------------------------------------------------------ surfaces
    def workspace(self, key, name, *extra):
        ref = self.state.get(key)
        if not ref:
            ref = self.control.cli("workspace", "create", "--name", name, "--focus", *extra).stdout.strip()
            self.state[key] = ref
            self.sleep(1.5)  # the workspace shows and its first content draws
        if ref:
            self.control.cli("workspace", ref, "focus")
        return ref

    def page_url(self):
        path = os.path.join(self.out, "input-latency-page.html")
        if not os.path.exists(path):
            with open(path, "w") as handle:
                handle.write(PAGE)
        return "file://" + path

    def setup_terminal(self):
        if self.stress is not None and self.state.get("stress_terminal"):
            self.stress.show(self.stress.measured)
            self.stress.focus_pane(self.state["stress_terminal"])
        else:
            self.workspace("terminal_ws", "input latency terminal", "--shell", "exec /bin/zsh -f")
        self.sleep(0.5)  # focus settles
        return {"ok": True, "clear": lambda poster: self.control.action("terminal.sendText", {"text": "\x15"})}

    def setup_home(self):
        if not self.state.get("home_ws"):
            self.workspace("home_ws", "input latency home")
            opened = self.control.rpc("debug.home_native_fixture.open", {"new": True})
            if hid_input.is_error(opened):
                return {"ok": False, "reason": f"no Home fixture: {json.dumps(opened)[:160]}"}
            self.sleep(2.0)  # the transcript lays out
        else:
            self.workspace("home_ws", "input latency home")
        focused = self.control.rpc("debug.home.drive", {"action": "focus"})
        if not (isinstance(focused, dict) and focused.get("ok")):
            return {"ok": False, "reason": f"no Home composer to focus: {json.dumps(focused)[:160]}"}
        return {"ok": True, "clear": self.clear_field}

    def setup_omnibar(self):
        if not self.state.get("omnibar_open"):
            self.workspace("omnibar_ws", "input latency omnibar")
            self.control.action("openBrowser.chromium", {"url": "about:blank"}, timeout=120)
            self.sleep(3.0)  # Chromium starts
            self.state["omnibar_open"] = True
        else:
            self.workspace("omnibar_ws", "input latency omnibar")
        self.control.action("focusBrowserAddressBar")
        self.sleep(0.5)  # the field editor takes the keyboard
        bar = self.control.rpc("debug.omnibar") or {}
        if not bar.get("field_editor_active"):
            return {"ok": False, "reason": f"the omnibar's field editor is not active: {json.dumps(bar)[:160]}"}
        return {"ok": True, "clear": lambda poster: poster.key("escape")}

    def setup_page(self, engine, surface):
        key = f"{engine}_page_ws"
        first = not self.state.get(key)
        self.workspace(key, f"input latency {engine}")
        if first:
            self.control.action(f"openBrowser.{engine}", {"url": self.page_url()}, timeout=120)
            ready = hid_input.wait(lambda: (self.control.rpc("browser.page.eval", {"script": "document.readyState === 'complete' && !!document.getElementById('t')"},
                                                              timeout=20) or {}).get("value") is True, 60, step=0.5, sleep=self.sleep)
            if not ready:
                return {"ok": False, "reason": f"the {engine} page did not load"}
        answered = (self.control.rpc("browser.page.eval", {"script": ENGINE_CHECK}, timeout=20) or {}).get("value")
        if answered != engine:
            return {"ok": False, "reason": f"the {surface} answers as {answered!r}, not {engine}", "engine": answered}
        focused = (self.control.rpc("browser.page.eval", {"script": "document.getElementById('t').focus(); document.activeElement.id"},
                                    timeout=20) or {}).get("value")
        if focused != "t":
            return {"ok": False, "reason": f"the {surface}'s textarea did not take focus ({focused!r})", "engine": answered}
        return {"ok": True, "engine": answered, "clear": self.clear_field, "debug_params": {"target": "page"}}

    def setup_agent_pane(self):
        if not self.state.get("agent_ws"):
            self.workspace("agent_ws", "input latency agent")
            self.control.action("palette.newAgentChat", timeout=60)
            ready = hid_input.wait(lambda: (self.control.rpc("debug.agent_pane", {"action": "readiness"}, timeout=5) or {}).get("document_ready"),
                                   30, step=0.5, sleep=self.sleep)
            if not ready:
                return {"ok": False, "reason": "the agent chat's page did not become ready"}
        else:
            self.workspace("agent_ws", "input latency agent")
        engine = (self.control.rpc("debug.agent_pane", {"action": "engine"}) or {}).get("engine")
        focused = self.control.rpc("debug.agent_pane", {"action": "focus_composer"})
        if hid_input.is_error(focused):
            return {"ok": False, "reason": f"no agent composer to focus: {json.dumps(focused)[:160]}", "engine": engine}
        return {"ok": True, "engine": engine, "clear": self.clear_field}

    def setup_palette(self):
        self.control.action("commandPalette")
        self.sleep(0.5)  # the palette opens and its field takes the keyboard
        return {"ok": True, "clear": lambda poster: poster.key("escape"), "debug_params": {"target": "palette"}}

    @staticmethod
    def clear_field(poster):
        poster.key("a", modifiers=("command",))
        poster.key("delete")

    def setup(self, surface):
        return {
            "terminal": self.setup_terminal, "home": self.setup_home, "omnibar": self.setup_omnibar,
            "agent-pane": self.setup_agent_pane, "palette": self.setup_palette,
            "chromium-page": lambda: self.setup_page("chromium", surface),
            "webkit-page": lambda: self.setup_page("webkit", surface),
        }[surface]()

    # ------------------------------------------------------------ geometry
    def window_frame(self):
        layers = self.control.rpc("debug.layers") or {}
        window = ((layers.get("windows") or [{}]) if isinstance(layers, dict) else [{}])[0]
        return window, window.get("frame")

    def display_height(self):
        backend = getattr(self.poster, "backend", None)
        return backend.main_display_height() if backend else None

    def chrome_window(self):
        chrome = self.control.rpc("debug.pane_chrome") or {}
        return ((chrome.get("windows") or [{}]) if isinstance(chrome, dict) else [{}])[0]

    def content_point(self):
        """The middle of the main pane area (debug.pane_chrome, top-left window coordinates) on the display."""
        _, frame = self.window_frame()
        main = self.chrome_window().get("main_pane")
        height = self.display_height()
        if not frame or not main or height is None:
            return None
        return hid_input.window_point(frame, hid_input.rect_center(main), height, top_left=True)

    # ------------------------------------------------------------ measuring
    def phase_start(self, subject):
        self.subject = subject
        self.control.rpc("debug.input", {"action": "reset"})
        self.control.rpc("debug.hangs", {"clear": True})
        return self.recorder(self.pid)

    def phase_end(self, recording, threads):
        self.sleep(0.5)  # the last frame lands
        load = self.stop_load(threads)
        events, lost = recording.stop() if recording else ([], 0)
        debug_input = self.control.rpc("debug.input", {"sections": ["latency", "gate", "pump", "coalescer"]}, timeout=30)
        hangs = self.control.rpc("debug.hangs", {"limit": 12}, timeout=20)
        hangs = {k: hangs.get(k) for k in ("count", "max_ms", "total_ms", "frames_over_8_3ms", "max_gap_ms")} \
            if isinstance(hangs, dict) and not hangs.get("error") else {"error": (hangs or {}).get("error") if isinstance(hangs, dict) else None}
        return events, lost, debug_input, hangs, load

    def context(self, surface, condition):
        return {"surface": surface, "session": self.session, "condition": condition["name"],
                "storm": storm_label(condition["storm"]),
                "stall": f"{condition['stall'][0]}ms/{condition['stall'][1]}ms" if condition["stall"] else "none",
                "input": self.poster.input}

    def record_run(self, entry):
        """Keeps a phase's result; a phase whose load failed on every call keeps no rows (they would claim the load)."""
        failure = self.load_failure(entry.get("load"))
        if failure:
            self.note(f"{self.session} {entry.get('surface')} {entry.get('condition')}: not measured: the load did not run ({failure})")
            entry = dict(entry, status="load_failed", reason=f"the load did not run: {failure}", rows=[])
        self.runs.append(entry)
        return entry

    def measure_keys(self, surface, condition):
        ctx = self.context(surface, condition)
        base = dict(session=self.session, condition=condition["name"], storm=ctx["storm"], stall=ctx["stall"],
                    surface=surface, phase="keys", input=self.poster.input, **self.load_facts(condition))
        try:
            ready = self.setup(surface)
        except hid_input.InputRefused as error:
            ready = {"ok": False, "reason": str(error)}
        if not ready.get("ok"):
            self.note(f"{self.session} {surface} {condition['name']}: not measured: {ready.get('reason')}")
            return self.record_run(dict(base, status="skipped", reason=ready.get("reason"), engine=ready.get("engine"), rows=[]))
        focus = self.control.rpc("debug.focus") or {}
        recording = self.phase_start(surface)
        threads = self.start_load(condition)
        errors = 0
        # debug.key needs the surface's target (a page, the palette panel); a real key goes where the window sends it.
        poster = self.poster if self.poster.input == "real" else \
            hid_input.poster_for("debug", control=self.control, debug_params=ready.get("debug_params"))
        for index in range(self.opts.keys):
            t0 = time.perf_counter()
            reply = poster.key(hid_input.LETTERS[index % len(hid_input.LETTERS)])
            errors += hid_input.is_error(reply)
            rest = self.opts.interval - (time.perf_counter() - t0)
            if rest > 0:
                self.sleep(rest)  # one key in flight at a time
        events, lost, debug_input, hangs, load = self.phase_end(recording, threads)
        keys = [e for e in events if e["kind"] == "keyPress" and e["entrypoint"] == self.entrypoint]
        expected = EXPECTED_TARGETS[surface]
        landed = {}
        for event in keys:
            landed[event["target"]] = landed.get(event["target"], 0) + 1
        rows = stage_rows([e for e in keys if e["target"] in expected], ctx, ("keyPress",))
        latency = section(debug_input, "latency", [])
        rows += ledger_rows(latency, ctx, ("keyPress",), self.entrypoint)
        if ready.get("clear"):
            ready["clear"](poster)
        matched = sum(landed.get(t, 0) for t in expected)
        status = "ok" if matched else ("wrong_target" if keys else "no_input")
        presented = next((r for r in rows if r["stage"] == "presented" and r["presentation_source"] == "*" and r["source"] == "signpost"), {})
        self.note(f"{self.session} {surface} {condition['name']}: {status}, key->presented p50 {presented.get('p50')} "
                  f"p99 {presented.get('p99')} ms (n={presented.get('n', 0)}/{self.opts.keys}); landed {landed}; hangs {hangs.get('count')}")
        return self.record_run(dict(base, status=status, keys=self.opts.keys, key_errors=errors, landed=landed,
                                    engine=ready.get("engine"), focus=focus.get("resolved") or focus.get("focus"),
                                    signposts_lost=lost, hangs=hangs, load=load, debug_input=debug_input, rows=rows))

    def measure_scrolls(self, surface, condition):
        ctx = self.context(surface, condition)
        base = dict(session=self.session, condition=condition["name"], storm=ctx["storm"], stall=ctx["stall"],
                    surface=surface, phase="scrolls", input=self.poster.input, **self.load_facts(condition))
        point = self.content_point()
        if point is None:
            return self.record_run(dict(base, status="unlocated", reason="no window frame or main pane", rows=[]))
        recording = self.phase_start(surface)
        threads = self.start_load(condition)
        posted = [self.poster.scroll_gesture(point, dy=-12.0 if i % 2 == 0 else 12.0) for i in range(self.opts.scrolls)]
        events, lost, debug_input, hangs, load = self.phase_end(recording, threads)
        scrolls = [e for e in events if e["kind"] in SCROLL_KINDS and e["entrypoint"] == self.entrypoint]
        rows = stage_rows(scrolls, ctx, SCROLL_KINDS) + ledger_rows(section(debug_input, "latency", []), ctx, SCROLL_KINDS, self.entrypoint)
        latency = section(debug_input, "latency", []) or {}
        return self.record_run(dict(base, status="ok" if scrolls else "no_input", point=point, gestures=len(posted),
                                    signposts_lost=lost, hangs=hangs, load=load, scroll_jank=latency.get("scroll_jank"),
                                    debug_input=debug_input, rows=rows))

    # ------------------------------------------------------------ drags
    def locate_drag(self, target):
        """(start, end, back, cleanup) in display points for drag `target`, or a reason string."""
        height = self.display_height()
        if height is None:
            return "no display height (drags need --input real)"
        if target in ("divider", "pane-swap"):
            self.workspace(f"drag_{target}_ws", f"input latency {target}")
            if not self.state.get(f"drag_{target}_split"):
                self.control.action("splitRight")
                self.sleep(1.0)  # the split lays out
                self.state[f"drag_{target}_split"] = True
        elif target == "tab":
            self.workspace("drag_tab_ws", "input latency tab")
            if not self.state.get("drag_tab_tabs"):
                for _ in range(3):
                    self.control.action("newTab")
                self.sleep(1.0)  # the tabs lay out
                self.state["drag_tab_tabs"] = True
        elif target == "canvas-pane":
            self.workspace("drag_canvas_ws", "input latency canvas")
            if not self.state.get("drag_canvas_split"):
                self.control.action("splitRight")
                self.state["drag_canvas_split"] = True
            self.control.action("toggleCanvasLayout")
            self.sleep(1.0)  # the canvas lays out
        elif target == "strip-scrollbar":
            self.workspace("drag_strip_ws", "input latency strip")
            if not self.state.get("drag_strip_columns"):
                for _ in range(5):
                    self.control.action("newColumn")
                self.sleep(1.0)  # the columns lay out
                self.state["drag_strip_columns"] = True
        window, frame = self.window_frame()
        if not frame:
            return "debug.layers has no window frame"
        if target == "divider":
            dividers = sorted((d for d in window.get("divider_areas_in_window") or [] if d[3] > d[2]), key=lambda d: d[0])
            if not dividers:
                return "no vertical divider in debug.layers"
            start = hid_input.window_point(frame, hid_input.rect_center(dividers[0]), height)
            return start, (start[0] - 120, start[1]), True, None
        panes = sorted(self.chrome_window().get("panes") or [], key=lambda p: (p.get("cell") or [0])[0])
        if target == "tab":
            pill = next((p.get("pill") for p in panes if p.get("pill")), None)
            if not pill:
                return "no tab pill in debug.pane_chrome"
            start = hid_input.window_point(frame, hid_input.rect_center(pill), height, top_left=True)
            return start, (start[0] + 150, start[1]), True, None
        if target == "pane-swap":
            if len(panes) != 2 or not panes[1].get("cell"):
                return f"the pane-swap workspace has {len(panes)} panes in debug.pane_chrome, not 2"
            press = empty_strip_point(panes[0])
            if isinstance(press, str):
                return press
            start = hid_input.window_point(frame, press, height, top_left=True)
            end = hid_input.window_point(frame, hid_input.rect_center(panes[1]["cell"]), height, top_left=True)
            return start, end, False, None
        if target == "canvas-pane":
            strip = next((p.get("strip") for p in panes if p.get("strip")), None)
            if not strip:
                self.control.action("toggleCanvasLayout")
                return "no pane tab strip in debug.pane_chrome"
            x, y, w, h = strip
            start = hid_input.window_point(frame, (x + w * 0.75, y + h / 2), height, top_left=True)
            return start, (start[0] + 150, start[1] + 80), True, lambda: self.control.action("toggleCanvasLayout")
        if target == "strip-scrollbar":
            dock = self.control.rpc("debug.dock") or {}
            windows = dock.get("windows") if isinstance(dock, dict) else None
            thumb = (((windows or [{}])[0].get("scrollbar") or {}).get("thumb_in_window"))
            if not thumb:
                return "no strip scrollbar thumb in debug.dock"
            start = hid_input.window_point(frame, hid_input.rect_center(thumb), height)
            return start, (start[0] + 200, start[1]), True, None
        return f"unknown drag target {target}"

    def measure_drag(self, target, condition):
        ctx = self.context(f"drag:{target}", condition)
        base = dict(session=self.session, condition=condition["name"], storm=ctx["storm"], stall=ctx["stall"],
                    surface=f"drag:{target}", target=target, phase="drag", input=self.poster.input,
                    **self.load_facts(condition))
        try:
            located = self.locate_drag(target)
        except hid_input.InputRefused as error:
            located = str(error)
        if isinstance(located, str):
            self.note(f"{self.session} drag {target}: not measured: {located}")
            return self.record_run(dict(base, status="unlocated", reason=located, rows=[]))
        start, end, back, cleanup = located
        modifiers = PANE_SWAP_MODIFIERS if target == "pane-swap" else ()
        panes_before = self.pane_ids() if target == "pane-swap" else None
        swapped = None
        recording = self.phase_start(f"drag:{target}")
        threads = self.start_load(condition)
        posted = []

        def drag(out_and_back):
            posted.append(self.poster.drag(start, end, rate_hz=self.opts.rate, seconds=self.opts.drag_seconds,
                                           back=out_and_back, modifiers=modifiers))
            self.sleep(0.3)  # the drop settles before the next press

        for index in range(self.opts.drags):
            drag(back)
            if not back:  # a pane swap drops on the other pane: swap back for the next drag
                if index == 0:
                    swapped = self.pane_ids()[:1] != panes_before[:1]
                drag(False)
        events, lost, debug_input, hangs, load = self.phase_end(recording, threads)
        if cleanup:
            cleanup()
        status, reason = None, None
        if panes_before is not None:
            panes_after = self.pane_ids()
            if len(panes_after) != len(panes_before):
                status = "layout_changed"
                reason = f"the pane swaps left {len(panes_after)} panes, not {len(panes_before)}: {panes_before} -> {panes_after}"
                self.note(f"{self.session} drag {target} {condition['name']}: not measured: {reason}")
        kinds = ("drag", "mousePress", "mouseRelease")
        mine = [e for e in events if e["kind"] in kinds and e["entrypoint"] == self.entrypoint]
        rows = stage_rows(mine, ctx, kinds) + ledger_rows(section(debug_input, "latency", []), ctx, kinds, self.entrypoint)
        rates = [p["rate_hz"] for p in posted if p.get("rate_hz")]
        summary = {"drags": len(posted), "events": sum(p["events"] for p in posted), "late": sum(p["late"] for p in posted),
                   "rate_hz": round(sum(rates) / len(rates), 1) if rates else None}
        frame_main = next((r for r in rows if r["stage"] == "frame_main" and r["presentation_source"] == "*" and r["n"]), {})
        self.note(f"{self.session} drag {target} {condition['name']}: {summary['events']} events at {summary['rate_hz']} Hz; "
                  f"frame main p99 {frame_main.get('p99')} ms (n={frame_main.get('n', 0)})"
                  + ("; the first drop did not swap the panes" if swapped is False else ""))
        return self.record_run(dict(base, status=status or ("ok" if mine else "no_input"), reason=reason, start=start, end=end,
                                    modifiers=list(modifiers), swapped=swapped, posted=summary, signposts_lost=lost,
                                    hangs=hangs, load=load, debug_input=debug_input, rows=[] if status else rows))

    def pane_ids(self):
        """The shown workspace's pane ids, left to right (debug.pane_chrome)."""
        panes = sorted(self.chrome_window().get("panes") or [], key=lambda p: (p.get("cell") or [0])[0])
        return [p.get("pane") for p in panes]

    # ------------------------------------------------------------ session
    def run_session(self, session):
        self.session = session
        surfaces = selected_surfaces(self.opts)
        drags = [d for d in (self.opts.drag or "").split(",") if d]
        for condition in conditions(self.opts.storm, self.opts.stall, self.opts.with_idle):
            self.guarded(f"{condition['name']} load", lambda: self.prepare_load(condition))
            for surface in surfaces:
                self.guarded(f"{surface} keys", lambda: self.measure_keys(surface, condition))
                if self.opts.scrolls and self.poster.input == "real":
                    self.guarded(f"{surface} scrolls", lambda: self.measure_scrolls(surface, condition))
            for target in drags:
                self.guarded(f"drag {target}", lambda: self.measure_drag(target, condition))

    def guarded(self, label, body):
        try:
            body()
        except Exception as error:  # one surface failing must not hide the others
            self.note(f"{self.session} {label}: failed: {error!r}")
            self.runs.append({"session": self.session, "phase": "error", "label": label, "error": repr(error)})


def selected_surfaces(opts):
    if opts.surfaces:
        return [s for s in opts.surfaces.split(",") if s]
    return [] if opts.drag else list(SURFACES)


def validate(opts, parser):
    for surface in selected_surfaces(opts):
        if surface not in SURFACES:
            parser.error(f"--surfaces: unknown surface {surface} (one of {', '.join(SURFACES)})")
    for target in [d for d in (opts.drag or "").split(",") if d]:
        if target not in DRAGS:
            parser.error(f"--drag: unknown target {target} (one of {', '.join(DRAGS)})")
    for session in opts.sessions.split(","):
        if session not in ("light", "stress"):
            parser.error(f"--sessions: unknown session {session} (light or stress)")
    try:
        conditions(opts.storm, opts.stall, opts.with_idle)
    except ValueError as error:
        parser.error(str(error))
    if opts.input == "debug" and (opts.drag or opts.scrolls):
        parser.error("--input debug types keys over the control socket only: --drag and --scrolls need --input real")
    if opts.rate <= 0 or opts.keys < 0:
        parser.error("--rate must be positive and --keys not negative")


def header(opts):
    real = opts.input == "real"
    return {"schema": "cmux-input-latency/v1", "host": platform.node(), "macos": hid_input.macos_version(),
            "refresh": hid_input.display_refresh(),
            "input": opts.input, "quotable": real,
            "label": None if real else "debug.key: the control socket's injected-input lane, labelled automation; "
                                       "not a person's key latency, never quote it",
            "tag": opts.tag, "app": opts.app, "sessions": opts.sessions.split(","), "keys": opts.keys,
            "storm": opts.storm or "none", "stall": opts.stall or "none", "drag": opts.drag, "rate_hz": opts.rate,
            "started": time.strftime("%Y-%m-%dT%H:%M:%S%z")}


def report(head, bench_runs, notes):
    rows = [r for run in bench_runs for r in run.get("rows") or []]
    reached = any(run.get("status") == "ok" for run in bench_runs if run.get("phase") in ("keys", "scrolls", "drag"))
    head = dict(head, input_reached=reached)
    return {"header": head, "rows": rows, "dc": dc_fields(bench_runs), "runs": bench_runs, "log": notes}


def write(path, document):
    if path:
        with open(path, "w") as handle:
            json.dump(document, handle, indent=1, default=str)


# ---------------------------------------------------------------- launch
def load_stress_module():
    import importlib.util
    spec = importlib.util.spec_from_file_location("perf_stress_session", os.path.join(HERE, "perf-stress-session.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def launch_env(opts):
    """The app's environment for a bench launch. Real input needs the app frontmost (no CMUX_NEXT_NO_ACTIVATE); the
    launch stays isolated all the same (bench_launch.shipping_env's pair; LaunchIsolation: the fixed test window
    frame, no `cmux` shim pointer, no global hot keys, no relaunch at login, no browser import offer)."""
    from bench_launch import ISOLATED_LAUNCH_KEY
    env = {"CMUX_NEXT_HANG_THRESHOLD_MS": "8"}
    if opts.input == "real":
        env["CMUX_NEXT_NO_ACTIVATE"] = None
        env[ISOLATED_LAUNCH_KEY] = "1"
    return env


def run_launched(opts, make_app=None):
    """Launches the app once per session and measures it; returns the report. Every app this starts is stopped,
    whether its launch, its STRESS build or its phases failed; a signal (bench_launch's teardown turns TERM and HUP
    into SystemExit) stops the app and ends the bench. `make_app` replaces BenchApp (the self-test)."""
    from bench_launch import BenchApp, LaunchError
    make_app = make_app or BenchApp
    out = os.path.abspath(opts.out or tempfile.mkdtemp(prefix="input-latency-"))
    os.makedirs(out, exist_ok=True)
    head = header(opts)
    runs, notes = [], []
    for session in opts.sessions.split(","):
        try:
            app = make_app(os.path.abspath(opts.app.rstrip("/")), out=out, config={"browser": {"defaultEngine": "chromium"}},
                           window=WINDOW, log_name=f"app-{session}.log", perf_session=session, env=launch_env(opts))
        except SystemExit as error:
            if not isinstance(error.code, str):  # a signal's exit, not BenchApp's wrong-bundle message
                raise
            notes.append(f"{session}: the app did not come up: {error.code}")
            runs.append({"session": session, "phase": "launch", "status": "failed", "reason": error.code})
            break  # the bundle is wrong for every session
        bench = None
        try:
            try:
                app.launch(timeout=180)
            except LaunchError as error:
                notes.append(f"{session}: the app did not come up: {error.reason}")
                runs.append({"session": session, "phase": "launch", "status": "failed", "reason": error.reason,
                             "detail": (error.report or {}).get("detail")})
            else:
                bench = new_bench(opts, app, out)
                measure_session(opts, bench, app, session, head)
        except Exception as error:  # STRESS did not build, or the app went away: report what was measured
            notes.append(f"{session}: stopped: {error!r}")
            runs.append({"session": session, "phase": "error", "label": "session", "error": repr(error)})
        finally:
            if bench is not None:
                runs += bench.runs
                notes += bench.notes
            app.stop()  # a no-op when no process started; a launch that timed out leaves one running
        write(opts.json, report(head, runs, notes))
    return report(head, runs, notes)


def new_bench(opts, app, out):
    """The bench of a launched app: its socket, its CLI and scratch config, the poster of --input."""
    cli = os.path.join(os.path.abspath(opts.app.rstrip("/")), "Contents/Resources/bin/cmux")
    control = hid_input.Control(app.socket, cli, os.path.join(app.scratch, "cmux.json"))
    poster = hid_input.poster_for(opts.input, control=control)
    return Bench(opts, control, poster, hid_input.SignpostRecording, pid=app.process.pid, out=out)


def measure_session(opts, bench, app, session, head):
    """One launched session: STRESS built first, the app frontmost for real input, then every condition's phases."""
    control = bench.control
    if session == "stress":
        stress = load_stress_module().Stress(control.rpc, log=bench.note)
        head.setdefault("stress", {})[session] = stress.build()
        bench.stress = stress
        panes = stress.panes(stress.workspace(stress.measured))
        if panes:
            last = panes[-1]
            stress.focus_pane(last["id"])
            tab = next((t for t in reversed(last.get("tabs") or []) if t.get("kind") == "terminal"), None)
            if tab:
                stress.action("tab.focus", target=f"tab:{tab['id']}")
                control.action("terminal.sendText", {"text": "exec /bin/zsh -f\r"})
            bench.state["stress_terminal"] = last["id"]
        time.sleep(5)  # the STRESS grid settles before the first measured input
    if opts.input == "real":
        hid_input.bring_front(app.process.pid)
        time.sleep(1)  # activation settles
    bench.run_session(session)


# ---------------------------------------------------------------- self-test
class FixtureControl:
    """A fake app: canned replies for every method the bench calls, and the engine of the last opened tab."""

    def __init__(self, sections=("latency", "gate", "pump", "coalescer")):
        self.calls, self.keys, self.sections = [], [], sections
        self.engines, self.shown = {}, None  # the engine of the tab each workspace opened; the workspace shown

    def rpc(self, method, params=None, timeout=30):
        params = params or {}
        self.calls.append(method)
        if method == "debug.key":
            self.keys.append(params)
        if method == "action.run":
            if params["action"].startswith("openBrowser."):
                self.engines[self.shown] = params["action"].split(".", 1)[1]
            return {"ok": True}
        if method == "browser.page.eval":
            script = params.get("script", "")
            if "readyState" in script:
                return {"value": True}
            if "window.chrome" in script:
                return {"value": self.engines.get(self.shown)}
            return {"value": "t"}
        if method == "debug.omnibar":
            return {"field_editor_active": True}
        if method == "debug.agent_pane":
            return {"readiness": {"document_ready": True}, "engine": {"engine": "cef", "pane": "p1"}}.get(params.get("action"), {"ok": True})
        if method in ("debug.home.drive", "debug.home_native_fixture.open"):
            return {"ok": True}
        if method == "debug.input":
            if params.get("action") == "reset":
                return {"reset": list(self.sections)}
            body = {"absent": [s for s in ("latency", "gate", "pump", "coalescer") if s not in self.sections]}
            if "latency" in self.sections:
                body["latency"] = {"rows": [{"kind": "keyPress", "target": "terminal", "entrypoint": "person",
                                             "presentation_source": "metalPresented", "display": {"refresh_hz": 120},
                                             "total": {"count": 3, "p50_ms": 7.0, "p95_ms": 9.0, "p99_ms": 9.5, "max_ms": 10.0},
                                             "stages": [{"stage": "arrivedMain", "histogram": {"count": 3, "p50_ms": 0.2}}]}],
                                   "scroll_jank": {"presented_frames": 10, "delayed_frames": 0}}
            if "gate" in self.sections:
                body["gate"] = {"max_input_wait_behind_jobs_ms": 0.4, "nonswift_blocks_while_input_pending": 0}
            if "pump" in self.sections:
                body["pump"] = {"passes_while_input_pending": {"terminal": 1, "chromiumPage": 5}, "pass_ms_p99": 1.5}
            if "coalescer" in self.sections:
                body["coalescer"] = {"windows": [{"window": "w1", "consumers": [{"consumer": "divider", "deliveries_per_frame": {"max": 2}}]}]}
            return body
        if method == "debug.hangs":
            return {"count": 1, "max_ms": 9.0, "total_ms": 9.0}
        if method == "debug.layers":
            return {"windows": [{"frame": [40, 40, 1400, 900], "divider_areas_in_window": [[700, 20, 6, 840]]}]}
        if method == "debug.pane_chrome":
            return {"windows": [{"main_pane": [0, 40, 1400, 860], "panes": [
                {"pane": "a", "cell": [0, 40, 700, 860], "pill": [10, 40, 120, 28], "strip": [0, 40, 700, 28],
                 "tab_slots": [[0, 124]], "toolbar": {"frame": [640, 40, 60, 28]}},
                {"pane": "b", "cell": [706, 40, 694, 860], "pill": [716, 40, 120, 28], "strip": [706, 40, 694, 28],
                 "tab_slots": [[0, 124]]}]}]}
        if method == "debug.dock":
            return {"windows": [{"scrollbar": {"thumb_in_window": {"x": 100, "y": 10, "width": 200, "height": 6}}}]}
        if method == "debug.focus":
            return {"resolved": "fixture"}
        return {"ok": True}

    def action(self, name, args=None, focus=True, timeout=60, target=None):
        return self.rpc("action.run", {"action": name, "args": args or {}})

    def cli(self, *args, timeout=60):
        self.calls.append("cli " + " ".join(args[:2]))
        if args[0] not in FIXTURE_CLI_SCOPES:
            return subprocess.CompletedProcess(args, 2, "", f"cmux: unknown scope `{args[0]}`")
        if args[:2] == ("workspace", "create"):
            ref = "workspace:" + args[args.index("--name") + 1]
            self.shown = ref if "--focus" in args else self.shown
            return subprocess.CompletedProcess(args, 0, ref + "\n", "")
        if args[0] == "workspace" and args[-1] == "focus":
            self.shown = args[1]
        return subprocess.CompletedProcess(args, 0, "", "")


# The fixture CLI's scopes (cmux-tui's cli/command.rs has these among others; `read-screen` is not one).
FIXTURE_CLI_SCOPES = ("app", "pane", "tab", "terminal", "workspace")
# In the fixture's pane chrome, the run of pane a's tabs and its + button ends here (window x): TabStripView.mouseRects.
FIXTURE_RUN_END = 160
FIXTURE_DISPLAY_HEIGHT = 1080.0


def fixture_pane_swap_refusal(control, posted, display_height=FIXTURE_DISPLAY_HEIGHT):
    """Why the fixture's PaneSwapDrag would not start for the presses in `posted`, or None: each press must hold
    Option (the panes are in the window's top row) and land on a strip's empty space, past its tabs and +."""
    frame = control.rpc("debug.layers")["windows"][0]["frame"]
    panes = control.rpc("debug.pane_chrome")["windows"][0]["panes"]
    presses = [e for e in posted if e["type"] == "mouse" and e["kind"] == hid_input.LEFT_MOUSE_DOWN]
    if not presses:
        return "no press"
    for press in presses:
        if not press.get("flags", 0) & hid_input.FLAGS["option"]:
            return f"a press without Option at {press['x']}, {press['y']}: in the top row it moves the window"
        fx, fy, _, fh = frame
        x, y = press["x"] - fx, press["y"] - display_height + fy + fh  # global display -> top-left window points
        strip = next((p["strip"] for p in panes if p["strip"][0] <= x < p["strip"][0] + p["strip"][2]
                      and p["strip"][1] <= y < p["strip"][1] + p["strip"][3]), None)
        if strip is None:
            return f"a press off every tab strip at {x}, {y}"
        if x < strip[0] + FIXTURE_RUN_END:
            return f"a press on the tabs or + at {x}, {y}: the tab strip's own press (TabDragSession), not a pane swap"
    return None


def fixture_lines(surface, keys, drags, entrypoint):
    """The `log stream` ndjson a phase of the fixture app prints: one input.latency event per key press (and its
    release), and per drag event, with stages in microseconds; the terminal's keys carry the echo."""
    target = {"terminal": 0, "home": 1, "omnibar": 1, "chromium-page": 2, "webkit-page": 3, "agent-pane": 4,
              "palette": 7}.get(surface, 5)
    source = {"chromium-page": 2, "webkit-page": 3, "terminal": 1}.get(surface, 0)
    entry = hid_input.ENTRYPOINTS.index(entrypoint)
    lines = ["Filtering the log data using \"subsystem == ...\""]

    def event(kind, presented_us, echo):
        message = (f"kind={kind} target={target} entry={entry} source={source} vrr=0 coalesced=1 frame=1 gen_ns=1000 "
                   f"last_gen_us=-1 arrived_us=120 dispatch_start_us=200 ti_start_us=-1 ti_end_us=-1 dispatch_end_us=900 "
                   f"commit_us=1600 content_us=-1 daemon_us={2000 if echo else -1} pty_us={2200 if echo else -1} "
                   f"echo_read_us={3000 if echo else -1} echo_sent_us={3100 if echo else -1} presented_us={presented_us}")
        return json.dumps({"eventType": "signpostEvent", "subsystem": hid_input.SIGNPOST_SUBSYSTEM, "category": "input",
                           "signpostName": hid_input.INPUT_LATENCY, "signpostType": "event", "eventMessage": message})

    for index in range(keys):
        lines.append(event(0, 6000 + 100 * (index % 20), surface == "terminal"))
        lines.append(event(1, 5000, False))
    for index in range(drags):
        lines.append(event(6, 7000 + 10 * (index % 30), False))
    return lines


class FixtureRecording:
    """Records nothing: on stop, the fixture app's signposts for what the bench posted since the phase began."""

    def __init__(self, bench, backend):
        self.bench, self.backend, self.start = bench, backend, len(backend.events)

    def stop(self):
        posted = self.backend.events[self.start:]
        keys = sum(1 for e in posted if e["type"] == "key" and e["down"] and e["code"] != hid_input.KEYCODES["delete"]
                   and e["code"] not in hid_input.MODIFIER_KEYCODES.values())
        drags = sum(1 for e in posted if e["type"] == "mouse" and e["kind"] == hid_input.LEFT_MOUSE_DRAGGED)
        if self.bench.subject == "drag:pane-swap" and fixture_pane_swap_refusal(self.bench.control, posted):
            drags = 0  # the strip's own press, or the window's: no pane drag ran
        return hid_input.latency_events(fixture_lines(self.bench.subject, keys, drags, "person"))


def self_test():
    failures = []

    def check(name, condition, detail=""):
        if not condition:
            failures.append(f"{name}: {str(detail)[:400]}")

    # Options.
    check("storm", parse_storm("cli=10hz,sidebar-churn=400") == {"cli": {"hz": 10.0, "verb": list(DEFAULT_STORM_VERB)},
                                                                  "sidebar-churn": {"workspaces": 400, "hz": 10.0}},
          parse_storm("cli=10hz,sidebar-churn=400"))
    # The default verb is a CLI command: the contract's form of it, with `current` for the selector.
    with open(CLI_CONTRACT) as handle:
        contract = handle.read()
    documented = "`cmux " + " ".join(w if i != 1 else "<sel>" for i, w in enumerate(DEFAULT_STORM_VERB)) + "`"
    check("default storm verb in the CLI contract", documented in contract, documented)
    check("default storm verb's scope", DEFAULT_STORM_VERB[0] in FIXTURE_CLI_SCOPES, DEFAULT_STORM_VERB)
    check("storm verb", parse_storm("cli=5hz:tab+list")["cli"]["verb"] == ["tab", "list"])
    for bad in ("cli=fast", "sidebar-churn=x", "storm=1"):
        try:
            parse_storm(bad)
            failures.append(f"parse_storm({bad!r}) did not refuse")
        except ValueError:
            pass
    check("stall", parse_stall("50ms/100ms") == (50, 100) and parse_stall("none") is None)
    check("conditions idle", [c["name"] for c in conditions(None, None, False)] == ["idle"])
    check("conditions storm", [c["name"] for c in conditions("cli=10hz", None, False)] == ["storm:cli=10hz"])
    check("conditions stall", [c["name"] for c in conditions(None, "none,50ms/100ms", False)] == ["idle", "stall:50ms/100ms"],
          [c["name"] for c in conditions(None, "none,50ms/100ms", False)])

    # The refusal: debug.key only with --input debug, and never with pointer input.
    parser = build_parser()
    for argv in (["--input", "debug", "--drag", "divider"], ["--input", "debug", "--scrolls", "2"], ["--input", "hid"]):
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                validate(parser.parse_args(["--app", "x"] + argv), parser)
            failures.append(f"{argv} was not refused")
        except SystemExit:
            pass

    # A whole run against the fixture app: every surface, a storm, a stall, scrolls and every drag target.
    now = [0.0]

    def clock():
        return now[0]

    def sleep(seconds):
        now[0] += max(0.0, seconds)

    opts = parser.parse_args(["--app", "fixture", "--keys", "30", "--interval", "0", "--scrolls", "1",
                              "--drag", ",".join(DRAGS), "--rate", "1000", "--drags", "1", "--drag-seconds", "0.05",
                              "--surfaces", ",".join(SURFACES), "--storm", "cli=50hz,sidebar-churn=4", "--with-idle"])
    validate(opts, parser)
    backend = hid_input.RecordingBackend(display_height=1080.0, clock=clock)
    poster = hid_input.HidPoster(backend, clock=clock, sleep=sleep)
    control = FixtureControl()
    bench = Bench(opts, control, poster, None, pid=1, sleep=sleep, log=lambda _: None)
    bench.recorder = lambda pid: FixtureRecording(bench, backend)
    bench.run_session("light")
    document = report(header(opts), bench.runs, bench.notes)
    json.dumps(document, default=str)
    errors = [r for r in bench.runs if r.get("phase") == "error"]
    check("no failed phase", not errors, errors)
    keys = [r for r in bench.runs if r.get("phase") == "keys"]
    check("every surface measured", sorted({r["surface"] for r in keys if r["status"] == "ok"}) == sorted(SURFACES),
          [(r["surface"], r["status"], r.get("reason")) for r in keys])
    check("two conditions", sorted({r["condition"] for r in keys}) == ["idle", "storm:cli=50hz,sidebar-churn=4"],
          {r["condition"] for r in keys})
    row_fields = {"surface", "session", "condition", "storm", "stall", "kind", "target", "stage", "presentation_source",
                  "p50", "p95", "p99", "max", "n", "input", "source"}
    check("row fields", document["rows"] and all(row_fields <= set(r) for r in document["rows"]),
          [sorted(row_fields - set(r)) for r in document["rows"] if not row_fields <= set(r)][:3])
    terminal = [r for r in document["rows"] if r["surface"] == "terminal" and r["stage"] == "presented" and r["source"] == "signpost"
                and r["presentation_source"] == "*"]
    check("terminal presented", terminal and terminal[0]["n"] == 30 and terminal[0]["p50"] == 6.7, terminal[:1])
    check("ledger rows", any(r["source"] == "ledger" and r["stage"] == "presented" and r["p99"] == 9.5 for r in document["rows"]))
    check("debug rows only from automation", all(r["input"] == "real" for r in document["rows"]))
    dc = document["dc"]
    for entry in dc["dc1"]:
        check("dc1 fields", {"surfaces", "terminal_echo_p99_ms", "ghostty_lock_wait_p99_ms", "main_stalls_over_8ms", "absent"} <= set(entry), entry)
        for surface in SURFACES:
            check(f"dc1 {surface}", {"p50_ms", "p99_ms", "n", "presentation_sources", "judged"} <= set(entry["surfaces"].get(surface) or {}),
                  entry["surfaces"].get(surface))
        check("dc1 echo", entry["terminal_echo_p99_ms"] is not None, entry)
        check("dc1 lock wait absent", ABSENT_LOCK_WAIT in entry["absent"], entry["absent"])
    check("dc1 webkit judged only on the page estimate",
          all(e["surfaces"]["webkit-page"]["judged"] for e in dc["dc1"]) and all(e["surfaces"]["terminal"]["judged"] for e in dc["dc1"]))
    for entry in dc["dc2"]:
        check("dc2 fields", {"storm", "terminal_key_p99_ms", "home_key_p99_ms", "max_input_wait_behind_jobs_ms",
                             "nonswift_blocks_while_input_pending", "pump_passes_while_input_pending_non_chromium",
                             "cef_pass_ms_p99"} <= set(entry), entry)
        check("dc2 values", entry["max_input_wait_behind_jobs_ms"] == 0.4 and entry["home_key_p99_ms"] is not None, entry)
        check("dc2 non-chromium passes", entry["pump_passes_while_input_pending_non_chromium"] == 7, entry)
    check("dc5 targets", sorted({e["target"] for e in dc["dc5"]}) == sorted(DRAGS),
          [(e["target"], e["status"]) for e in dc["dc5"]] + [r.get("reason") for r in bench.runs if r.get("phase") == "drag"])
    for entry in dc["dc5"]:
        check("dc5 fields", {"deliveries_per_frame_max", "deliveries_per_frame", "frame_main_p99_ms", "cursor_rect_rebuilds_per_frame",
                             "rate_hz"} <= set(entry), entry)
        check("dc5 values", entry["deliveries_per_frame_max"] == 2 and entry["frame_main_p99_ms"] == 1.4
              and entry["rate_hz"] and 900 <= entry["rate_hz"] <= 1100, entry)
    check("storm ran", any("cli workspace" in c for c in control.calls) and any(
        (load.get("name") == "storm.cli") for r in keys for load in r.get("load") or []), [r.get("load") for r in keys][:2])
    check("header", document["header"]["input"] == "real" and document["header"]["quotable"] and document["header"]["input_reached"])
    swap = next((r for r in bench.runs if r.get("phase") == "drag" and r["target"] == "pane-swap"), {})
    check("pane swap: an Option-press on empty strip space, dropped on the other pane",
          swap.get("status") == "ok" and swap.get("modifiers") == ["option"] and swap.get("start", (0,))[0] > 40 + FIXTURE_RUN_END
          and swap.get("start", (0,))[0] < 40 + 640 and swap.get("end", (0,))[0] > 40 + 706,
          {k: swap.get(k) for k in ("status", "reason", "start", "end", "modifiers")})
    pill_press = [{"type": "mouse", "kind": hid_input.LEFT_MOUSE_DOWN, "x": 40 + 70, "y": 1080 - (40 + 900 - 54),
                   "flags": hid_input.FLAGS["option"]}]
    check("the fixture refuses a pane-swap press on a pill", fixture_pane_swap_refusal(control, pill_press))
    check("the fixture refuses a pane-swap press without Option",
          fixture_pane_swap_refusal(control, [dict(pill_press[0], x=40 + 400, flags=0)]))
    check("the fixture takes an Option-press on empty strip space",
          fixture_pane_swap_refusal(control, [dict(pill_press[0], x=40 + 400)]) is None)
    check("no empty strip space is a reason", isinstance(empty_strip_point(
        {"strip": [0, 0, 180, 28], "pill": [10, 0, 120, 28], "tab_slots": [[0, 124]]}), str))
    check("dc2 churn count", all(e["sidebar_churn_workspaces"] in (None, 4) for e in dc["dc2"]), dc["dc2"])

    # A storm whose every call fails measures nothing: its rows would claim a load that did not run.
    control = FixtureControl()
    opts = parser.parse_args(["--app", "fixture", "--keys", "3", "--interval", "0", "--surfaces", "terminal",
                              "--storm", "cli=50hz:read-screen"])
    backend = hid_input.RecordingBackend(clock=clock)
    bench = Bench(opts, control, hid_input.HidPoster(backend, clock=clock, sleep=sleep), None, sleep=sleep, log=lambda _: None)
    bench.recorder = lambda pid: FixtureRecording(bench, backend)
    bench.run_session("light")
    failed = [r for r in bench.runs if r.get("phase") == "keys"]
    check("a failed storm is not measured", failed and failed[0]["status"] == "load_failed" and not failed[0]["rows"]
          and "storm.cli" in failed[0]["reason"], [(r.get("status"), r.get("reason")) for r in failed])
    dc = report(header(opts), bench.runs, bench.notes)["dc"]
    check("a failed storm is absent in dc2", dc["dc2"] and dc["dc2"][0]["terminal_key_p99_ms"] is None
          and any("storm.cli" in a for a in dc["dc2"][0]["absent"]), dc["dc2"])

    # STRESS's background workspaces come first; the churn makes the rest up to N.
    control = FixtureControl()
    bench = Bench(opts, control, hid_input.HidPoster(hid_input.RecordingBackend()), None, sleep=sleep, log=lambda _: None)
    bench.stress = type("FakeStress", (), {"background": ["ws_bg1", "ws_bg2"]})()
    churn = {"name": "storm:sidebar-churn=5", "storm": parse_storm("sidebar-churn=5"), "stall": None}
    bench.prepare_load(churn)
    check("STRESS churn grows to N", bench.state["churn_ids"][:2] == ["ws_bg1", "ws_bg2"] and len(bench.state["churn_ids"]) == 5
          and bench.load_facts(churn) == {"churn_workspaces": 5, "churn_requested": 5}, bench.state["churn_ids"])

    # The launch: real input stays isolated; every started app stops, a failed launch goes on to the next session,
    # a signal ends the bench, and a wrong bundle stops the sessions.
    from bench_launch import ISOLATED_LAUNCH_KEY, LaunchError
    env = launch_env(parser.parse_args(["--app", "x"]))
    check("real input launch is isolated", env.get(ISOLATED_LAUNCH_KEY) == "1" and "CMUX_NEXT_NO_ACTIVATE" in env
          and env["CMUX_NEXT_NO_ACTIVATE"] is None, env)
    check("debug input launch", ISOLATED_LAUNCH_KEY not in launch_env(parser.parse_args(["--app", "x", "--input", "debug"])))

    class FakeApp:
        made = []

        def __init__(self, path, failure=None, **kwargs):
            self.failure, self.stopped = failure, False
            FakeApp.made.append(self)

        def launch(self, timeout=180):
            if self.failure:
                raise self.failure

        def stop(self):
            self.stopped = True

    def launched(failures, sessions="light,stress"):
        FakeApp.made = []
        queue = list(failures)
        run_opts = parser.parse_args(["--app", "fixture", "--out", tempfile.mkdtemp(prefix="input-latency-test-"),
                                      "--sessions", sessions])
        return run_launched(run_opts, make_app=lambda path, **kw: FakeApp(path, failure=queue.pop(0), **kw))

    timeout = LaunchError("timeout", {"detail": "debug.windows did not answer"})
    launch_report = launched([timeout, timeout])
    check("a failed launch stops its app and goes on", len(FakeApp.made) == 2 and all(a.stopped for a in FakeApp.made)
          and [r.get("reason") for r in launch_report["runs"]] == ["timeout", "timeout"], [vars(a) for a in FakeApp.made])
    try:
        launched([SystemExit(143), None])
        failures.append("a signal during the launch did not end the bench")
    except SystemExit as error:
        check("a signal during the launch ends the bench and stops the app", error.code == 143 and len(FakeApp.made) == 1
              and FakeApp.made[0].stopped, [vars(a) for a in FakeApp.made])

    def wrong_bundle(path, **kwargs):
        raise SystemExit("bench-launch: expected a `cmux DEV <tag>.app` bundle, got x.app")

    launch_report = run_launched(parser.parse_args(["--app", "x.app", "--out", tempfile.mkdtemp(prefix="input-latency-test-"),
                                               "--sessions", "light,stress"]), make_app=wrong_bundle)
    check("a wrong bundle is reported once", [r["status"] for r in launch_report["runs"]] == ["failed"]
          and "bundle" in launch_report["runs"][0]["reason"], launch_report["runs"])

    # A build without the gate, pump and coalescer: the DC fields stay, null, with the reason.
    control = FixtureControl(sections=("latency",))
    opts = parser.parse_args(["--app", "fixture", "--keys", "3", "--interval", "0", "--surfaces", "terminal", "--drag", "divider",
                              "--drags", "1", "--drag-seconds", "0.01"])
    backend = hid_input.RecordingBackend(clock=clock)
    bench = Bench(opts, control, hid_input.HidPoster(backend, clock=clock, sleep=sleep), None, sleep=sleep, log=lambda _: None)
    bench.recorder = lambda pid: FixtureRecording(bench, backend)
    bench.run_session("light")
    dc = report(header(opts), bench.runs, bench.notes)["dc"]
    check("absent gate", dc["dc2"][0]["max_input_wait_behind_jobs_ms"] is None
          and any("gate" in a for a in dc["dc2"][0]["absent"]), dc["dc2"])
    check("absent coalescer", dc["dc5"] and dc["dc5"][0]["deliveries_per_frame_max"] is None
          and any("coalescer" in a for a in dc["dc5"][0]["absent"]), dc["dc5"])

    # --input debug: debug.key over the socket, the rows labelled, the header not quotable.
    control = FixtureControl()
    opts = parser.parse_args(["--app", "fixture", "--input", "debug", "--keys", "2", "--interval", "0",
                              "--surfaces", "terminal,chromium-page"])
    validate(opts, parser)
    poster = hid_input.poster_for("debug", control=control)
    bench = Bench(opts, control, poster, lambda pid: None, sleep=sleep, log=lambda _: None)
    bench.run_session("light")
    head = header(opts)
    check("debug keys over the socket", len(control.keys) == 6 and all("timestamp" in k for k in control.keys), control.keys)
    check("debug page keys target the page", [k.get("target") for k in control.keys] == [None, None, "page", "page", "page", "page"], control.keys)
    check("debug labelled", head["input"] == "debug" and head["quotable"] is False and head["label"]
          and all(r.get("input") == "debug" for r in bench.runs), head)

    if failures:
        print("input-latency-bench self-test FAILED:\n  " + "\n  ".join(failures))
        return 1
    print(f"input-latency-bench self-test: ok ({len(document['rows'])} rows)")
    return 0


def main():
    parser = build_parser()
    opts = parser.parse_args()
    if opts.self_test:
        return self_test()
    if not opts.app:
        parser.error("--app is required")
    validate(opts, parser)
    document = None
    try:
        document = run_launched(opts)
    except Exception as error:  # the bench reports what it measured and exits 0; the error is in the report
        print(f"input-latency-bench: stopped: {error!r}", flush=True)
        document = {"header": header(opts), "rows": [], "dc": dc_fields([]), "runs": [], "log": [f"stopped: {error!r}"]}
    write(opts.json or (os.path.join(opts.out, "report.json") if opts.out else None), document)
    print(json.dumps({"dc": document["dc"], "header": document["header"]}, indent=1, default=str), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
