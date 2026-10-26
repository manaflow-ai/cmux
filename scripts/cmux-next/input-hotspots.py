#!/usr/bin/env python3
"""Day-1 input hotspots on the base (p04-input-077, queue MQ-input-hotspots): which main-thread stacks own the
time of a key or a click, one row per dominant stack over 4 ms.

Chrome reference: Chrome's input latency triage folds a trace's main-thread slices that overlap each EventLatency
event (cc/metrics/event_metrics.h: an input's span from its OS timestamp to the frame presented) and ranks the
slices by their share of those spans (tools/perf/core/results_processor/ and the Perfetto `chrome_input_latency`
metrics). Here the spans are the app's key and switch windows and the slices are the Time Profiler's main-thread
samples.

  input-hotspots.py run --app APP --out DIR [--sessions light,stress] [--only terminal,home,...] [--dry-run]
  input-hotspots.py fold DIR [--json FILE] [--threshold-ms 4]
  input-hotspots.py fold --recording SURFACE:SESSION:TRACE_DIR ... [--json FILE]
  input-hotspots.py schema          print the JSON schema of the output
  input-hotspots.py check FILE      exit 1 when FILE does not match the schema
  input-hotspots.py --self-test     fixtures only (Linux too): the fold, the windows, file:line, the schema, the plan

`run` records each bench below with `trace.py record --bundle APP -- BENCH ...` (wrap mode: Time Profiler of every
process plus the app's signposts) into DIR/<label>/trace, the bench's own report in DIR/<label>/bench, then folds:

  terminal, home, omnibar   typing-frame-bench.py --surfaces <surface> (idle and load phases), light and STRESS
  home-perf                 home-perf.py (its typing stage), light
  sidebar-churn             sidebar-churn-typing.py --input real (--workspaces 400 in light), light and STRESS
  clicks                    every-action-sweep.py --only nextSurface,commandPalette --repeat 20: tab switches and
                            palette opens, plus its click.tab and click.sidebar_row interactions

Each launch gets key-press flows: `BENCH_LAUNCH_TRACE_FLOWS` (bench_launch.py) sets the app's
CMUX_NEXT_TRACE_FLOWS to the recording's flows folder, as `trace.py record --app` does, so a terminal key's window
runs to the commit of the frame that shows its echo.

Windows (the input spans samples are folded over):
  key.flow     a terminal key with flows on: its `app.key.dispatch` minus its age to its `app.frame.commit`
  key.frame    any other key (the always-on interval): its dispatch minus its queue age to its turn's commit
  switch.tab   a tab switch: the intent to the commit that shows the tab (`switch.workspace` likewise)
  action.<id>  an `action.commit` of a person's input (origin=user): its input age to the commit

Fold: each main-thread sample of the app inside a window goes to its stack top, the leaf-most frame in a binary
of the app bundle (not Chromium Embedded Framework), else the leaf-most frame that is not run-loop plumbing; idle
samples (the run loop parked) are dropped. A stack top that is the largest one of at least one window with more
than --threshold-ms there is a row; its `share_ms_p95` is the p95 over every window of that surface and session
(zeros included). `file:line` comes from the Swift source (the declaration of the stack top's function in its
type; null when no declaration matches). Each row is one fix task.

`click_to_commit`: per session and window kind (switch.tab, switch.workspace, action.<id>), the window's span
p50/p95/max in ms; `prewarm_candidate` when the p95 is at least 30 ms (the threshold of p04-input-042, intent
prewarm). The sweep's own click rows (click.tab, click.sidebar_row: the app's input and commit timings) are
copied as they are. A palette row click is not driven (the debug socket gives no palette row geometry): it is
listed in `not_measured`.

Fleet (a GUI mini with the input grant, `--input real`; never Lawrence's Mac). Disk: an all-process recording
grows by about 50 MB a second and the STRESS build is recorded too, so give each recording room:
  nx-remote --needs input --app-from-fleet cmux --tag ih --ref SHA --timeout 14400 -- \\
    python3 scripts/cmux-next/input-hotspots.py run --app "$NX_APP" --out "$NX_ARTIFACTS"
The fold writes OUT/input-hotspots.json (in the job's artifacts: artifacts/input-hotspots.json). Not a CI gate.
"""
import argparse, bisect, collections, contextlib, io, json, os, re, subprocess, sys, tempfile
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
from bench_launch import TRACE_FLOWS_KEY as FLOWS_ENV, load_by_path  # noqa: E402

trace = load_by_path("cmux_trace", os.path.join(HERE, "trace.py"))

SCHEMA_ID = "cmux-input-hotspots/v1"
THRESHOLD_MS = 4.0  # a main-thread turn in an input window (p04-input goal: turn p99 <= 4 ms)
PREWARM_GAP_MS = 30.0  # p04-input-042 lands only for a target whose click-to-commit gap is at least this
SOURCE_ROOTS = ("Packages/macOS/CmuxNext/Sources", "Packages/Shared")
CAP_S = {"light": 1200, "stress": 2400}  # trace.py --seconds-cap: the STRESS build alone took 691 s on a mini
TRACE_MARGIN_S = 3 * 900 + 600  # trace.py's own stops after the cap: three table exports at most, then the build
NOT_MEASURED = [{"kind": "click.palette_row",
                 "reason": "no bench clicks a palette row: the debug socket gives no palette row geometry"}]


# ---------------------------------------------------------------- the plan

def plan(app, out, sessions, only=()):
    """[{label, surface, session, argv, trace_dir, bench_dir, cap_s}] of `run`: one recording per bench and session."""
    tag = os.path.basename(app.rstrip("/"))[len("cmux DEV "):-len(".app")] if app.endswith(".app") else "ih"
    rows = []

    def add(surface, session, script, args):
        if only and surface not in only:
            return
        label = f"{surface}-{session}"
        bench_dir = os.path.join(out, label, "bench")
        argv = [sys.executable, os.path.join(HERE, script), "--app", app, "--out", bench_dir, *args]
        if script != "home-perf.py":
            argv[4:4] = ["--tag", tag]
        rows.append({"label": label, "surface": surface, "session": session, "argv": argv,
                     "trace_dir": os.path.join(out, label, "trace"), "bench_dir": bench_dir, "cap_s": CAP_S[session]})

    for session in sessions:
        for surface in ("terminal", "home", "omnibar"):
            add(surface, session, "typing-frame-bench.py", ["--surfaces", surface, "--sessions", session, "--rounds", "1"])
        if session == "light":
            add("home-perf", session, "home-perf.py", [])
        churn = ["--input", "real", "--session", session] + (["--workspaces", "400"] if session == "light" else [])
        add("sidebar-churn", session, "sidebar-churn-typing.py", churn)
        add("clicks", session, "every-action-sweep.py",
            ["--only", "nextSurface,commandPalette", "--sessions", session, "--repeat", "20"])
    return rows


def trace_argv(app, row):
    return [sys.executable, os.path.join(HERE, "trace.py"), "record", "--bundle", app, "--out", row["trace_dir"],
            "--seconds-cap", str(row["cap_s"]), "--hang-ms", "8", "--", *row["argv"]]


def run(opts):
    app = os.path.realpath(opts.app).rstrip("/")
    out = os.path.abspath(opts.out)
    rows = plan(app, out, [s for s in opts.sessions.split(",") if s], set(filter(None, opts.only.split(","))))
    for row in rows:
        argv = trace_argv(app, row)
        if opts.dry_run:
            print(" ".join(f"'{a}'" if " " in a else a for a in argv))
            continue
        flows = os.path.join(row["trace_dir"], "flows")
        os.makedirs(flows, exist_ok=True)
        os.makedirs(row["bench_dir"], exist_ok=True)
        env = {**os.environ, FLOWS_ENV: flows}
        print(f"input-hotspots: recording {row['label']}", flush=True)
        try:
            row["exit"] = subprocess.run(argv, env=env, timeout=row["cap_s"] + TRACE_MARGIN_S).returncode
        except subprocess.TimeoutExpired:
            row["exit"] = "timeout"
        print(f"input-hotspots: {row['label']} exit {row['exit']}", flush=True)
    if opts.dry_run:
        return 0
    head = subprocess.run(["git", "-C", REPO, "rev-parse", "HEAD"], capture_output=True, text=True, timeout=30)
    trace.write_json(os.path.join(out, "plan.json"), {"app": app, "git_head": head.stdout.strip() or None,
                                                       "recordings": rows})
    doc = fold([(r["surface"], r["session"], r["trace_dir"], r["bench_dir"]) for r in rows], opts.threshold_ms,
               base={"app": app, "git_head": head.stdout.strip() or None})
    path = opts.json or os.path.join(out, "input-hotspots.json")
    trace.write_json(path, doc)
    print(report_text(doc))
    print(f"input-hotspots: wrote {path}")
    return 0


# ---------------------------------------------------------------- reading a recording

def parse_value(elem, vals):
    """trace.parse_value, but a frame keeps its binary: (symbol, binary path or name, or None)."""
    if elem.tag == "binary":
        return elem.get("path") or elem.get("name")
    if elem.tag == "frame":
        binary = next((vals.get(id(child)) for child in elem if child.tag == "binary"), None)
        return (elem.get("name") or elem.get("addr") or "?", binary)
    if elem.tag == "backtrace":
        return tuple(vals.get(id(child)) or ("?", None) for child in elem if child.tag == "frame")
    return trace.parse_value(elem, vals)


def main_thread_samples(path):
    """{pid: {"process": name, "samples": [(t_ns, weight_ns, frames leaf first)]}} of each process's main thread in an
    exported time-profile table. The row walk is trace.xctrace_rows' (cells keyed by the schema's mnemonics, `ref`
    resolved, streamed), with frames that keep their binary."""
    found = collections.defaultdict(lambda: {"process": "", "samples": []})
    ids, vals, node, columns = {}, {}, None, []
    for event, elem in ET.iterparse(path, events=("start", "end")):
        if event == "start":
            if elem.tag == "node":
                node, columns = elem, []
                ids.clear()
            continue
        if elem.tag == "schema":
            columns = [(col.findtext("mnemonic") or "").strip() for col in elem.findall("col")]
            continue
        if elem.tag == "row":
            row = {}
            for index, child in enumerate(elem):
                if child.tag == "sentinel":
                    continue
                if index < len(columns) and columns[index]:
                    row[columns[index]] = vals.get(id(child))
                row.setdefault(child.tag, vals.get(id(child)))
            thread = row.get("thread")
            t = trace.scalar(row.get("time") if row.get("time") is not None else row.get("sample-time"))
            stack = row.get("stack") or row.get("backtrace") or row.get("tagged-backtrace") or row.get("kperf-bt")
            if isinstance(thread, dict) and str(thread.get("name") or "").startswith("Main Thread") \
                    and isinstance(t, int) and isinstance(stack, tuple) and stack:
                weight = trace.scalar(row.get("weight"))
                entry = found[thread.get("pid")]
                entry["process"] = entry["process"] or thread.get("process") or ""
                entry["samples"].append((t, weight if isinstance(weight, int) else 1_000_000, stack))
            vals.clear()
            if node is not None:
                node.clear()
            continue
        ref = elem.get("ref")
        if ref is not None:
            value = ids.get(ref)
        else:
            value = parse_value(elem, vals)
            if elem.get("id") is not None:
                ids[elem.get("id")] = value
        vals[id(elem)] = value
    return dict(found)


def app_pid_of(signposts, processes):
    """The app's pid: the process that emitted the most key, switch and action signposts (only the app emits them),
    else the sampled process whose name is the app's (trace.role_from_name)."""
    emitters = collections.Counter(i["pid"] for i in signposts["intervals"]
                                   if i.get("pid") and i["name"] in ("key.frame", "switch.tab", "action.commit"))
    emitters.update(e["pid"] for e in signposts["events"] if e.get("pid") and e["name"] == "key.flow")
    for pid, _ in emitters.most_common():
        if pid in processes:
            return pid
    return next((pid for pid, entry in sorted(processes.items(), key=lambda kv: -len(kv[1]["samples"]))
                 if trace.role_from_name(entry["process"]) == "app"), None)


def load_recording(trace_dir):
    """What the fold reads from one `trace.py record` folder: the app's main-thread samples on CLOCK_UPTIME_RAW (us),
    its signposts, and the warnings that say what is missing."""
    warnings = []
    meta = trace.read_json(os.path.join(trace_dir, "meta.json"), {}) or {}
    signposts = trace.read_signposts(os.path.join(trace_dir, "signposts.ndjson"))
    if signposts["clock"].get("warning"):
        warnings.append(signposts["clock"]["warning"])
    toc = trace.parse_toc(os.path.join(trace_dir, "xctrace-toc.xml"))
    os_signpost = os.path.join(trace_dir, "xctrace-os-signpost.xml")
    xc_signposts = trace.xctrace_signposts(os_signpost) if os.path.exists(os_signpost) else None
    offset_us, how, clock_warning = trace.xctrace_offset_us(xc_signposts, toc, signposts["intervals"], meta)
    if clock_warning:
        warnings.append(clock_warning)
    profile = os.path.join(trace_dir, "xctrace-time-profile.xml")
    processes = {}
    if os.path.exists(profile):
        try:
            processes = main_thread_samples(profile)
        except ET.ParseError as error:
            warnings.append(f"xctrace-time-profile.xml does not parse: {error}")
    else:
        warnings.append("no xctrace-time-profile.xml: no main-thread samples (a `--recorder sample` run or a failed export)")
    pid = app_pid_of(signposts, processes)
    raw = (processes.get(pid) or {}).get("samples") or []
    samples = sorted((t / 1000.0 + offset_us, w / 1000.0, frames) for t, w, frames in raw)
    if pid is None:
        warnings.append("no app main thread in the time profile")
    return {"dir": trace_dir, "app_pid": pid, "samples": samples, "signposts": signposts, "clock": how,
            "warnings": warnings, "scenario_label": meta.get("scenario_label")}


# ---------------------------------------------------------------- windows

def number(fields, *keys):
    for key in keys:
        try:
            return float(fields[key])
        except (KeyError, TypeError, ValueError):
            continue
    return None


def windows(signposts):
    """[{kind, source, start_us, end_us}] of one recording: key windows (kind key.terminal or key.view) and switch or
    action windows (kind switch.tab, switch.workspace, action.<id>). A terminal key with a complete app flow (its
    dispatch and its echo frame's commit) is its key.flow window; its key.frame interval is then not counted again."""
    found = []
    hops = collections.defaultdict(dict)
    for event in signposts["events"]:
        if event["name"] != "key.flow":
            continue
        fields = trace.signposts_lib.fields(event.get("message") or "")
        try:
            flow = int(fields.get("flow", "0"))
        except ValueError:
            continue
        if flow and fields.get("hop"):
            hops[flow].setdefault(fields["hop"], (event["at_us"], fields))
    dispatches = []
    for flow in sorted(hops):
        press = hops[flow]
        if trace.KEY_START_HOP not in press or trace.KEY_COMMIT_HOP not in press:
            continue
        at, fields = press[trace.KEY_START_HOP]
        start = at - max(number(fields, "age_us") or 0.0, 0.0)
        end = press[trace.KEY_COMMIT_HOP][0]
        if end > start:
            found.append({"kind": "key.terminal", "source": "key.flow", "start_us": start, "end_us": end})
            dispatches.append(at)
    dispatches.sort()
    for interval in signposts["intervals"]:
        name, fields = interval["name"], interval["fields"]
        age_ms = max(number(fields, "age_ms", "input_age_ms") or 0.0, 0.0)
        start, end = interval["start_us"] - age_ms * 1000, interval["end_us"]
        if name == "key.frame":
            target = fields.get("target") or "view"
            if target == "terminal":
                lo = bisect.bisect_left(dispatches, interval["start_us"] - 1000)
                if lo < len(dispatches) and dispatches[lo] <= end:
                    continue  # this key's flow window already holds its turn
            found.append({"kind": f"key.{target}", "source": "key.frame", "start_us": start, "end_us": end})
        elif name in ("switch.tab", "switch.workspace") and not interval.get("missed"):
            found.append({"kind": name, "source": name, "start_us": start, "end_us": end})
        elif name == "action.commit" and fields.get("origin") == "user" and fields.get("id") \
                and not interval.get("missed"):
            found.append({"kind": f"action.{fields['id']}", "source": "action.commit", "start_us": start, "end_us": end})
    found.sort(key=lambda w: w["start_us"])
    return found


# ---------------------------------------------------------------- the fold

def owned(binary):
    """Whether a frame's binary is the app's own code (in the bundle, not Chromium Embedded Framework)."""
    return bool(binary) and ".app/Contents/" in binary and "Chromium Embedded Framework" not in binary


def stack_top(frames):
    """(stack top, its callers in the app, owned) of one sample (frames leaf first, each (symbol, binary)): the
    leaf-most frame of the app's own binaries, else the leaf-most frame that is not run-loop plumbing; None for
    an idle sample (trace.wait_class: the run loop or the workqueue parked)."""
    names = [name for name, _ in frames]
    if trace.wait_class(names) == "idle":
        return None
    for index, (name, binary) in enumerate(frames):
        if owned(binary):
            callers = tuple(n for n, b in frames[index + 1:] if owned(b) and trace.interesting(n))[:3]
            return name, callers, True
    top = next((name for name in names if trace.interesting(name)), names[0] if names else "?")
    return top, (), False


def window_shares(samples, window):
    """{stack top: ms} of the samples inside one window, and {stack top: Counter of callers}."""
    times = [s[0] for s in samples]
    lo, hi = bisect.bisect_left(times, window["start_us"]), bisect.bisect_left(times, window["end_us"])
    shares, callers, owners = collections.Counter(), collections.defaultdict(collections.Counter), {}
    for _, weight_us, frames in samples[lo:hi]:
        top = stack_top(frames)
        if top is None:
            continue
        name, chain, mine = top
        shares[name] += weight_us / 1000.0
        callers[name][chain] += 1
        owners[name] = mine
    return shares, callers, owners


def fold_rows(groups, threshold_ms, index):
    """One row per stack top that is the largest of at least one window with more than threshold_ms in it, per
    (surface, session); groups is {(surface, session): [(window, shares, callers, owners)]}."""
    rows = []
    for (surface, session), entries in sorted(groups.items()):
        candidates = set()
        for _, shares, _, _ in entries:
            if shares:
                name, ms = max(shares.items(), key=lambda kv: (kv[1], kv[0]))
                if ms > threshold_ms:
                    candidates.add(name)
        for name in sorted(candidates):
            values = [shares.get(name, 0.0) for _, shares, _, _ in entries]
            present = [v for v in values if v > 0]
            chains = collections.Counter()
            mine = False
            for _, shares, callers, owners in entries:
                chains.update(callers.get(name) or {})
                mine = mine or owners.get(name, False)
            dominant = sum(1 for _, shares, _, _ in entries if shares and max(shares, key=lambda k: (shares[k], k)) == name
                           and shares[name] > threshold_ms)
            where, resolution = index.resolve(name) if mine else (None, "not app code")
            all_pct, present_pct = trace.pct(values), trace.pct(present)
            rows.append({"surface": surface, "session": session, "stack_top": name, "file:line": where,
                         "resolution": resolution, "share_ms_p95": all_pct["p95"], "share_ms_p50": all_pct["p50"],
                         "share_ms_max": all_pct["max"], "share_ms_p95_present": present_pct["p95"],
                         "windows": len(values), "windows_present": len(present), "windows_dominant_over": dominant,
                         "callers": list(chains.most_common(1)[0][0]) if chains else [], "app_code": mine})
    rows.sort(key=lambda r: (-r["share_ms_p95"], -r["share_ms_max"], r["surface"], r["session"], r["stack_top"]))
    return rows


def sweep_clicks(bench_dir, session):
    """The sweep's own click rows (click.tab, click.sidebar_row) of one session: its input and commit timings."""
    report = trace.read_json(os.path.join(bench_dir or "", "every-action.json"), None) if bench_dir else None
    found = []
    for entry in (report or {}).get("sessions") or []:
        for row in entry.get("interactions") or []:
            if str(row.get("id", "")).startswith("click.") and row.get("id") != "click.during_motion":
                found.append({"session": row.get("session") or session, "kind": row["id"], "source": "every-action.json",
                              "commit_ms": row.get("commit_ms"), "input_ms": row.get("input_ms"),
                              "skipped": row.get("skipped"), "error": row.get("error")})
    return found


def fold(recordings, threshold_ms=THRESHOLD_MS, base=None, source_roots=None):
    """The output document from [(surface, session, trace_dir, bench_dir or None)]."""
    index = SourceIndex(source_roots or [os.path.join(REPO, root) for root in SOURCE_ROOTS])
    groups = collections.defaultdict(list)
    spans = collections.defaultdict(list)
    meta, sweep = [], []
    for surface, session, trace_dir, bench_dir in recordings:
        recording = load_recording(trace_dir)
        found = windows(recording["signposts"])
        kinds = collections.Counter(w["kind"] for w in found)
        sources = collections.Counter(w["source"] for w in found)
        warnings = list(recording["warnings"])
        if kinds.get("key.terminal") and not sources.get("key.flow"):
            warnings.append("terminal keys have no key.flow window (flows off): only the key's own turn is folded, "
                            "not its echo frame")
        for window in found:
            shares, callers, owners = window_shares(recording["samples"], window)
            key = surface if window["kind"].startswith("key.") else window["kind"]
            groups[(key, session)].append((window, shares, callers, owners))
            if not window["kind"].startswith("key."):
                spans[(session, window["kind"])].append((window["end_us"] - window["start_us"]) / 1000.0)
        sweep += sweep_clicks(bench_dir, session)
        meta.append({"surface": surface, "session": session, "dir": trace_dir, "app_pid": recording["app_pid"],
                     "main_samples": len(recording["samples"]), "windows": dict(kinds), "window_sources": dict(sources),
                     "xctrace_clock": recording["clock"], "scenario_label": recording["scenario_label"],
                     "warnings": warnings})
    clicks = []
    for (session, kind), values in sorted(spans.items()):
        p = trace.pct(values)
        clicks.append({"session": session, "kind": kind, "source": "signposts", "n": p["n"], "p50_ms": p["p50"],
                       "p95_ms": p["p95"], "max_ms": p["max"], "prewarm_candidate": p["p95"] >= PREWARM_GAP_MS})
    return {"schema": SCHEMA_ID, "generated_by": "scripts/cmux-next/input-hotspots.py", "base": base or {},
            "threshold_ms": threshold_ms, "prewarm_gap_ms": PREWARM_GAP_MS, "recordings": meta,
            "rows": fold_rows(groups, threshold_ms, index), "click_to_commit": clicks, "sweep_clicks": sweep,
            "not_measured": NOT_MEASURED}


def report_text(doc):
    lines = [f"input hotspots: {len(doc['rows'])} rows over {doc['threshold_ms']} ms"]
    for row in doc["rows"][:40]:
        lines.append(f"  {row['surface']:<16} {row['session']:<6} p95 {row['share_ms_p95']:7.2f} ms  max "
                     f"{row['share_ms_max']:7.2f}  {row['stack_top'][:70]}  {row['file:line'] or '-'}")
    for click in doc["click_to_commit"]:
        lines.append(f"  gap {click['session']:<6} {click['kind']:<28} n {click['n']:4} p95 {click['p95_ms']:7.2f} ms"
                     + ("  prewarm candidate (042)" if click["prewarm_candidate"] else ""))
    for recording in doc["recordings"]:
        for warning in recording["warnings"]:
            lines.append(f"  WARNING {recording['surface']}-{recording['session']}: {warning}")
    return "\n".join(lines)


# ---------------------------------------------------------------- file:line

ACCESSORS = ("getter", "setter", "modify", "_modify", "read", "_read", "didset", "willset", "unsafeAddressor",
             "unsafeMutableAddressor")
WRAPPERS = re.compile(r"^(?:(?:implicit )?closure #\d+ (?:\([^)]*\) )?in |partial apply (?:forwarder )?for |"
                      r"(?:reabstraction )?thunk (?:helper )?(?:from |for )|specialized |merged |@objc |@nonobjc |"
                      r"static |dispatch thunk of |outlined [\w ]+? of |async function pointer to |"
                      r"\(\d+\) (?:suspend|await) resume partial function for |DYLD-STUB\$\$)")
TYPE_DECL = re.compile(r"^(\s*)(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|package|open|final|"
                       r"nonisolated|indirect)\s+)*(?:class|struct|enum|actor|extension|protocol)\s+([A-Za-z_][\w.]*)")
MEMBER_DECL = re.compile(r"^(\s*)(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|package|open|"
                         r"final|static|class|override|nonisolated|mutating|nonmutating|convenience|required|dynamic|"
                         r"lazy|weak|unowned|isolated|consuming|borrowing|(?:public|private|package|internal|"
                         r"fileprivate)\(set\))\s+)*(func|init|deinit|var|let|subscript)\b[?!]?\s*([A-Za-z_]\w*)?")


def without_brackets(text, open_="<", close=">"):
    out, depth = [], 0
    for ch in text:
        if ch == open_:
            depth += 1
        elif ch == close and depth:
            depth -= 1
        elif not depth:
            out.append(ch)
    return "".join(out)


def swift_symbol(symbol):
    """(member name, owning type or None, kind func|var|init|deinit|subscript) of a demangled Swift frame name, or None
    for a name that is not one (C, Objective-C, Rust, Zig, an address)."""
    text = symbol.strip()
    if not text or text.startswith(("-[", "+[", "0x")) or "::" in text:
        return None
    witness = re.match(r"^protocol witness for (.*?) in conformance ", text)
    if witness:
        text = witness.group(1)
    while True:
        spec = re.match(r"^(?:generic|function signature) specialization ", text)
        if spec:
            rest = text[spec.end():]
            depth, cut = 0, None
            for index, ch in enumerate(rest):
                depth += ch == "<"
                depth -= ch == ">"
                if depth == 0 and rest[index + 1:].startswith(" of "):
                    cut = index + 5
                    break
            if cut is None:
                return None
            text = rest[cut:]
            continue
        stripped = WRAPPERS.sub("", text, count=1)
        if stripped == text:
            break
        text = stripped
    text = re.sub(r" (?:in conformance|with unmangled suffix) .*$", "", text)
    text = without_brackets(text)
    text = text.split(" : ", 1)[0]
    paren = text.find("(")
    if paren >= 0:
        text = text[:paren]
    text = text.split(" -> ", 1)[0].strip()
    parts = [p for p in text.split(".") if p]
    if not parts or not all(re.fullmatch(r"[A-Za-z_]\w*", p) for p in parts):
        return None
    kind = "func"
    if parts[-1] in ACCESSORS and len(parts) >= 2:
        parts, kind = parts[:-1], "var"
        if parts[-1] == "subscript":
            kind = "subscript"
    elif parts[-1] in ("init", "deinit", "subscript"):
        kind = parts[-1]
    name = parts[-1]
    owner = parts[-2] if len(parts) >= 2 else None
    return name, owner, kind


class SourceIndex:
    """Declarations of the Swift sources under `roots`, read once on the first lookup: name -> [(path, line, kind,
    enclosing type)]. The enclosing type is the nearest type or extension declared at a smaller indent."""

    def __init__(self, roots):
        self.roots = [root for root in roots if os.path.isdir(root)]
        self.decls = None

    def build(self):
        self.decls = collections.defaultdict(list)
        for root in self.roots:
            for folder, dirs, files in os.walk(root):
                dirs[:] = sorted(d for d in dirs if not d.startswith(".") and d not in ("Tests", ".build"))
                for name in sorted(files):
                    if name.endswith(".swift"):
                        self.read(os.path.join(folder, name))

    def read(self, path):
        try:
            lines = open(path, errors="replace").read().splitlines()
        except OSError:
            return
        types = []  # [(indent, type name)]
        rel = os.path.relpath(path, REPO) if path.startswith(REPO + os.sep) else path
        for number, line in enumerate(lines, 1):
            stripped = line.lstrip()
            if not stripped or stripped.startswith(("//", "*", "/*")):
                continue
            indent = len(line) - len(stripped)
            while types and types[-1][0] >= indent:
                types.pop()
            match = TYPE_DECL.match(line)
            if match and match.group(2) not in ("func", "var", "let"):
                types.append((indent, match.group(2).split(".")[-1]))
                continue
            match = MEMBER_DECL.match(line)
            if match:
                kind = match.group(2)
                name = match.group(3) if kind in ("func", "var", "let") else kind
                if name:
                    self.decls[name].append((rel, number, "var" if kind == "let" else kind,
                                             types[-1][1] if types else None))

    def resolve(self, symbol):
        """("path:line" or None, how): the declaration of a frame's function, in its type when the frame names one."""
        parsed = swift_symbol(symbol)
        if parsed is None:
            return None, "not a Swift symbol"
        if self.decls is None:
            self.build()
        name, owner, kind = parsed
        found = [d for d in self.decls.get(name, ()) if d[2] == kind]
        if owner:
            scoped = [d for d in found if d[3] == owner]
            if scoped:
                path, line = scoped[0][0], scoped[0][1]
                return f"{path}:{line}", "type" if len(scoped) == 1 else f"type, first of {len(scoped)}"
        if len(found) == 1:
            return f"{found[0][0]}:{found[0][1]}", "name"
        return None, f"{len(found)} declarations of {name}" if found else "no declaration"


# ---------------------------------------------------------------- the schema

ROW_FIELDS = {"surface": "string", "session": "string", "stack_top": "string", "file:line": ["string", "null"],
              "resolution": "string", "share_ms_p95": "number", "share_ms_p50": "number", "share_ms_max": "number",
              "share_ms_p95_present": "number", "windows": "integer", "windows_present": "integer",
              "windows_dominant_over": "integer", "callers": "array", "app_code": "boolean"}
CLICK_FIELDS = {"session": "string", "kind": "string", "source": "string", "n": "integer", "p50_ms": "number",
                "p95_ms": "number", "max_ms": "number", "prewarm_candidate": "boolean"}
RECORDING_FIELDS = {"surface": "string", "session": "string", "dir": "string", "app_pid": ["integer", "null"],
                    "main_samples": "integer", "windows": "object", "window_sources": "object",
                    "xctrace_clock": "string", "scenario_label": ["string", "null"], "warnings": "array"}


def obj(fields):
    return {"type": "object", "required": sorted(fields), "additionalProperties": False,
            "properties": {key: {"type": kind} for key, kind in fields.items()}}


SCHEMA = {
    "$schema": "https://json-schema.org/draft/2020-12/schema", "$id": SCHEMA_ID, "type": "object",
    "required": ["schema", "generated_by", "base", "threshold_ms", "prewarm_gap_ms", "recordings", "rows",
                 "click_to_commit", "sweep_clicks", "not_measured"],
    "properties": {
        "schema": {"type": "string", "enum": [SCHEMA_ID]}, "generated_by": {"type": "string"},
        "base": {"type": "object"}, "threshold_ms": {"type": "number"}, "prewarm_gap_ms": {"type": "number"},
        "recordings": {"type": "array", "items": obj(RECORDING_FIELDS)},
        "rows": {"type": "array", "items": obj(ROW_FIELDS)},
        "click_to_commit": {"type": "array", "items": obj(CLICK_FIELDS)},
        "sweep_clicks": {"type": "array", "items": {"type": "object", "required": ["session", "kind", "source"]}},
        "not_measured": {"type": "array", "items": {"type": "object", "required": ["kind", "reason"]}},
    },
}
JSON_TYPES = {"string": str, "number": (int, float), "integer": int, "boolean": bool, "array": list, "object": dict,
              "null": type(None)}


def validate(value, schema=SCHEMA, where="$"):
    """The schema errors of `value` (the subset of JSON Schema that SCHEMA uses: type, enum, required, properties,
    additionalProperties false, items); [] when it matches."""
    errors = []
    kinds = schema.get("type")
    if kinds:
        kinds = kinds if isinstance(kinds, list) else [kinds]
        ok = any(isinstance(value, JSON_TYPES[k]) and not (k in ("number", "integer") and isinstance(value, bool))
                 for k in kinds)
        if not ok:
            return [f"{where}: {type(value).__name__} is not {'|'.join(kinds)}"]
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{where}: {value!r} not in {schema['enum']}")
    if isinstance(value, dict):
        errors += [f"{where}: missing {key}" for key in schema.get("required", ()) if key not in value]
        properties = schema.get("properties") or {}
        for key, item in value.items():
            if key in properties:
                errors += validate(item, properties[key], f"{where}.{key}")
            elif schema.get("additionalProperties") is False:
                errors.append(f"{where}: unexpected {key}")
    if isinstance(value, list) and "items" in schema:
        for index, item in enumerate(value):
            errors += validate(item, schema["items"], f"{where}[{index}]")
    return errors


# ---------------------------------------------------------------- self-test

APP_BINARY = "/Users/user/Library/Developer/Xcode/DerivedData/x/cmux DEV ih.app/Contents/MacOS/cmux DEV ih"
APPKIT = "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"
CF = "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation"
PID = 42
XCTRACE_START_US = 1_000_000.0  # meta.json's xctrace start: xctrace time 0 is uptime 1 s


class Fixture:
    """A hand-written `trace.py record` folder: signposts.ndjson, meta.json and an xctrace time-profile table."""

    def __init__(self, folder):
        self.folder = folder
        self.lines = ["#timebase 1/1", "#continuous-minus-uptime-us 0"]
        self.rows = []
        self.next_id = 100
        self.ids = 0

    def signpost(self, kind, name, category, at_us, message="", signpost_id=1, pid=PID):
        self.lines.append(json.dumps({"eventType": "signpostEvent", "subsystem": trace.SUBSYSTEM, "category": category,
                                      "signpostName": name, "signpostID": signpost_id, "signpostType": kind,
                                      "processID": pid, "threadID": 1, "machTimestamp": int(at_us * 1000),
                                      "eventMessage": message}))

    def interval(self, name, category, start_us, end_us, message="", end_message=""):
        self.ids += 1
        self.signpost("begin", name, category, start_us, message, self.ids)
        self.signpost("end", name, category, end_us, end_message, self.ids)

    def samples(self, start_us, ms, frames, thread="Main Thread", pid=PID, process="cmux DEV ih"):
        """One 1 ms sample per ms from start_us; frames leaf first, each (symbol, binary)."""
        for step in range(int(ms)):
            t_ns = int((start_us + step * 1000 - XCTRACE_START_US) * 1000)
            stack = "".join(f'<frame name="{trace_escape(name)}" addr="0x1"><binary name="b" path="{binary}"/></frame>'
                            for name, binary in frames)
            self.rows.append(f'<row><sample-time>{t_ns}</sample-time><thread fmt="{thread} 0x1a ({process}, pid: {pid})">'
                             f'<tid>26</tid><process fmt="{process} ({pid})"><pid>{pid}</pid></process></thread>'
                             f'<weight>1000000</weight><backtrace>{stack}</backtrace></row>')

    def write(self):
        os.makedirs(self.folder, exist_ok=True)
        open(os.path.join(self.folder, "signposts.ndjson"), "w").write("\n".join(self.lines) + "\n")
        schema = "".join(f"<col><mnemonic>{m}</mnemonic></col>" for m in ("time", "thread", "weight", "stack"))
        open(os.path.join(self.folder, "xctrace-time-profile.xml"), "w").write(
            f'<?xml version="1.0"?><trace-query-result><node><schema name="time-profile">{schema}</schema>'
            + "".join(self.rows) + "</node></trace-query-result>")
        trace.write_json(os.path.join(self.folder, "meta.json"), {"xctrace": {"started_us": XCTRACE_START_US},
                                                                  "scenario_label": "wrap-key-unknown"})
        return self.folder


def trace_escape(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def swift_fixture(root):
    folder = os.path.join(root, "Sources", "CmuxNextSidebar")
    os.makedirs(folder)
    open(os.path.join(folder, "SidebarStore.swift"), "w").write(
        "import Foundation\n\n@MainActor\npublic final class SidebarStore {\n    var rows: [Int] = []\n\n"
        "    public func apply(_ change: Int) {\n        rows.append(change)\n    }\n}\n\n"
        "extension SidebarStore {\n    func reorder() {}\n}\n\nstruct Other {\n    func apply(_ change: Int) {}\n}\n")
    open(os.path.join(folder, "TerminalOutputLane.swift"), "w").write(
        "final class TerminalOutputLane {\n    nonisolated func parse(_ bytes: [UInt8]) {}\n}\n")
    return [os.path.join(root, "Sources")]


def check_symbols():
    cases = {
        "SidebarStore.apply(_:)": ("apply", "SidebarStore", "func"),
        "CmuxNextSidebar.SidebarStore.apply(_:) -> ()": ("apply", "SidebarStore", "func"),
        "closure #1 in closure #2 in SidebarStore.reorder()": ("reorder", "SidebarStore", "func"),
        "partial apply for closure #1 in TerminalOutputLane.parse(_:)": ("parse", "TerminalOutputLane", "func"),
        "SidebarStore.rows.getter : [Swift.Int]": ("rows", "SidebarStore", "var"),
        "SidebarStore.init(seed:)": ("init", "SidebarStore", "init"),
        "generic specialization <Swift.Int> of Store<A>.apply(_:)": ("apply", "Store", "func"),
        "protocol witness for Foo.bar() in conformance Baz": ("bar", "Foo", "func"),
        "@objc TerminalSurfaceView.keyDown(with:)": ("keyDown", "TerminalSurfaceView", "func"),
        "fixtureSpin(_:)": ("fixtureSpin", None, "func"),
        "-[NSView layout]": None, "cmux_tui::run": None, "0x1821753fd": None, "CA::Transaction::commit()": None,
    }
    for symbol, expected in cases.items():
        assert swift_symbol(symbol) == expected, (symbol, swift_symbol(symbol), expected)


def check_fold(tmp):
    """The fold of a recording: key.frame windows of a view, a terminal key's flow window to its echo commit, an idle
    and an outside sample left out, a stack under the threshold with no row, a tab switch's gap."""
    fx = Fixture(os.path.join(tmp, "home-light"))
    apply = ("SidebarStore.apply(_:)", APP_BINARY)
    send = ("-[NSApplication sendEvent:]", APPKIT)
    run_loop = ("__CFRunLoopRun", CF)
    for key in range(10):
        start = 2_000_000 + key * 100_000  # a key every 100 ms from 2 s
        # dispatch at +2 ms, age 2 ms: the window opens at the key's OS time
        fx.interval("key.frame", "key", start + 2000, start + 12_000, "target=view age_ms=2.00", "commit=committed")
        fx.samples(start + 1000, 7 if key < 9 else 3, [("objc_msgSend", APPKIT), apply, send])  # 7 ms in 9 windows
        fx.samples(start + 9000, 1, [("SidebarStore.reorder()", APP_BINARY), send])
        fx.samples(start + 10_000, 1, [("mach_msg2_trap", "/usr/lib/system/libsystem_kernel.dylib"),
                                       ("__CFRunLoopServiceMachPort", CF), run_loop])  # idle: dropped
    fx.samples(1_500_000, 50, [apply, send])  # outside every window: not counted
    # A terminal key with flows on: dispatch at 3.1 s (age 1000 us), its echo frame's commit 20 ms later.
    fx.signpost("event", "key.flow", "key", 3_101_000, "flow=7 hop=app.key.dispatch age_us=1000")
    fx.signpost("event", "key.flow", "key", 3_121_000, "flow=7 hop=app.frame.commit")
    fx.interval("key.frame", "key", 3_101_000, 3_103_000, "target=terminal age_ms=1.00", "commit=committed")
    fx.samples(3_110_000, 6, [("TerminalOutputLane.parse(_:)", APP_BINARY), run_loop])
    # A tab switch of 40 ms, and one that missed its commit (not a window).
    fx.interval("switch.tab", "switch", 4_000_000, 4_040_000, "kind=warm")
    fx.interval("switch.tab", "switch", 4_100_000, 4_190_000, "kind=cold", "commit=missed")
    fx.samples(4_005_000, 30, [("CEFHostView.show()", APP_BINARY), send])
    fx.write()
    terminal = Fixture(os.path.join(tmp, "terminal-stress"))
    terminal.interval("key.frame", "key", 2_000_000, 2_010_000, "target=terminal age_ms=0.50", "commit=committed")
    terminal.samples(2_001_000, 5, [("TerminalOutputLane.parse(_:)", APP_BINARY)])
    terminal.write()
    doc = fold([("home", "light", fx.folder, None), ("terminal", "stress", terminal.folder, None)], THRESHOLD_MS,
               {"git_head": "abc"}, swift_fixture(os.path.join(tmp, "src")))
    errors = validate(doc)
    assert not errors, errors
    rows = {(r["surface"], r["session"], r["stack_top"]): r for r in doc["rows"]}
    home = rows[("home", "light", "SidebarStore.apply(_:)")]
    assert home["windows"] == 11 and home["windows_present"] == 10 and home["windows_dominant_over"] == 9, home
    assert home["share_ms_max"] == 7 and home["share_ms_p95"] == 7, home
    assert home["file:line"].endswith("CmuxNextSidebar/SidebarStore.swift:7") and home["resolution"] == "type", home
    assert ("home", "light", "SidebarStore.reorder()") not in rows  # 1 ms a window: under the threshold
    flow = rows[("home", "light", "TerminalOutputLane.parse(_:)")]  # the echo frame's work, inside the flow window
    assert flow["windows_dominant_over"] == 1 and flow["file:line"].endswith("TerminalOutputLane.swift:2"), flow
    switch = rows[("switch.tab", "light", "CEFHostView.show()")]
    assert switch["share_ms_max"] == 30 and switch["file:line"] is None and switch["windows"] == 1, switch
    (gap,) = doc["click_to_commit"]
    assert gap["kind"] == "switch.tab" and gap["n"] == 1 and gap["p95_ms"] == 40 and gap["prewarm_candidate"], gap
    home_meta = doc["recordings"][0]
    assert home_meta["windows"] == {"key.view": 10, "key.terminal": 1, "switch.tab": 1}, home_meta
    assert home_meta["window_sources"]["key.flow"] == 1 and not home_meta["warnings"], home_meta
    stress_meta = doc["recordings"][1]
    assert any("flows off" in w for w in stress_meta["warnings"]), stress_meta
    assert rows[("terminal", "stress", "TerminalOutputLane.parse(_:)")]["share_ms_p95"] == 5
    bad = json.loads(json.dumps(doc))
    del bad["rows"][0]["file:line"]
    bad["click_to_commit"][0]["n"] = "1"
    assert len(validate(bad)) == 2, validate(bad)
    return doc


def check_plan():
    rows = plan("/x/cmux DEV ih.app", "/out", ["light", "stress"])
    labels = [r["label"] for r in rows]
    assert labels == ["terminal-light", "home-light", "omnibar-light", "home-perf-light", "sidebar-churn-light",
                      "clicks-light", "terminal-stress", "home-stress", "omnibar-stress", "sidebar-churn-stress",
                      "clicks-stress"], labels
    churn = next(r for r in rows if r["label"] == "sidebar-churn-light")["argv"]
    assert churn[churn.index("--input") + 1] == "real" and churn[churn.index("--workspaces") + 1] == "400", churn
    assert churn[churn.index("--tag") + 1] == "ih", churn
    home_perf = next(r for r in rows if r["label"] == "home-perf-light")["argv"]
    assert "--tag" not in home_perf, home_perf
    argv = trace_argv("/x/cmux DEV ih.app", rows[0])
    assert argv[2:5] == ["record", "--bundle", "/x/cmux DEV ih.app"] and argv[argv.index("--") + 3] == "--app", argv
    assert [r["label"] for r in plan("/x/cmux DEV ih.app", "/out", ["stress"], {"clicks"})] == ["clicks-stress"]


def check_flows_env(tmp):
    """bench_launch.BenchApp passes BENCH_LAUNCH_TRACE_FLOWS to the app as CMUX_NEXT_TRACE_FLOWS; a bench's own env wins."""
    import bench_launch
    old = os.environ.get(FLOWS_ENV)
    try:
        os.environ[FLOWS_ENV] = os.path.join(tmp, "flows")
        app = bench_launch.BenchApp(os.path.join(tmp, "cmux DEV ih.app"), out=os.path.join(tmp, "bench"), teardown=False)
        assert app.environment()["CMUX_NEXT_TRACE_FLOWS"] == os.path.join(tmp, "flows")
        own = bench_launch.BenchApp(os.path.join(tmp, "cmux DEV ih.app"), out=os.path.join(tmp, "bench"), teardown=False,
                                    env={"CMUX_NEXT_TRACE_FLOWS": "/own"})
        assert own.environment()["CMUX_NEXT_TRACE_FLOWS"] == "/own"
        del os.environ[FLOWS_ENV]
        assert "CMUX_NEXT_TRACE_FLOWS" not in app.environment()
    finally:
        if old is None:
            os.environ.pop(FLOWS_ENV, None)
        else:
            os.environ[FLOWS_ENV] = old


def check_real_export():
    """The Xcode 26.6 time-profile export of trace.py's fixtures parses with binaries kept: fixtureSpin is the main
    thread's stack top of the emitter, whose binary is not an app bundle's (so it is the leaf-most named frame)."""
    path = os.path.join(trace.FIXTURES, "xcode-26", "time-profile.xml")
    found = main_thread_samples(path)
    entry = next(e for e in found.values() if e["process"] == "fixture-emitter")
    tops = collections.Counter(stack_top(frames)[0] for _, _, frames in entry["samples"] if stack_top(frames))
    assert any("fixtureSpin" in name for name, _ in tops.most_common(3)), tops.most_common(5)
    binaries = {binary for _, _, frames in entry["samples"] for _, binary in frames if binary}
    assert any(b.endswith("fixture-emitter") for b in binaries), sorted(binaries)[:5]


def self_test():
    failed = []
    with tempfile.TemporaryDirectory(prefix="input-hotspots-") as tmp:
        checks = [("symbols", check_symbols), ("fold", lambda: check_fold(os.path.join(tmp, "fold"))),
                  ("plan", check_plan), ("flows env", lambda: check_flows_env(os.path.join(tmp, "env"))),
                  ("real export", check_real_export)]
        for name, check in checks:
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    check()
                print(f"ok   {name}")
            except Exception as error:  # each check reports on its own; the self-test exits 1
                failed.append(name)
                print(f"FAIL {name}: {type(error).__name__}: {str(error)[:800]}")
    print("self-test ok" if not failed else f"self-test FAILED: {', '.join(failed)}")
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true")
    sub = parser.add_subparsers(dest="verb")
    rec = sub.add_parser("run", help="record every bench under trace.py, then fold")
    rec.add_argument("--app", required=True, help="a Debug `cmux DEV <tag>.app` (not running)")
    rec.add_argument("--out", required=True)
    rec.add_argument("--sessions", default="light,stress")
    rec.add_argument("--only", default="", help="comma list of surfaces: terminal,home,omnibar,home-perf,sidebar-churn,clicks")
    rec.add_argument("--json", help="the output (default OUT/input-hotspots.json)")
    rec.add_argument("--threshold-ms", type=float, default=THRESHOLD_MS)
    rec.add_argument("--dry-run", action="store_true", help="print the trace.py commands only")
    fld = sub.add_parser("fold", help="fold recordings into the hotspot rows")
    fld.add_argument("dir", nargs="?", help="a `run` OUT (its plan.json names the recordings)")
    fld.add_argument("--recording", action="append", default=[], metavar="SURFACE:SESSION:TRACE_DIR")
    fld.add_argument("--json")
    fld.add_argument("--threshold-ms", type=float, default=THRESHOLD_MS)
    sub.add_parser("schema", help="print the output's JSON schema")
    chk = sub.add_parser("check", help="exit 1 when FILE does not match the schema")
    chk.add_argument("file")
    opts = parser.parse_args()
    if opts.self_test:
        return self_test()
    if opts.verb == "run":
        return run(opts)
    if opts.verb == "fold":
        recordings, base = [], {}
        if opts.dir:
            saved = trace.read_json(os.path.join(opts.dir, "plan.json"), None)
            if not saved:
                parser.error(f"no plan.json in {opts.dir}")
            base = {"app": saved.get("app"), "git_head": saved.get("git_head")}
            recordings += [(r["surface"], r["session"], r["trace_dir"], r.get("bench_dir")) for r in saved["recordings"]]
        for spec in opts.recording:
            surface, session, folder = spec.split(":", 2)
            recordings.append((surface, session, folder, None))
        if not recordings:
            parser.error("fold needs DIR or --recording")
        doc = fold(recordings, opts.threshold_ms, base)
        path = opts.json or os.path.join(opts.dir or ".", "input-hotspots.json")
        trace.write_json(path, doc)
        print(report_text(doc))
        print(f"input-hotspots: wrote {path}")
        return 0
    if opts.verb == "schema":
        print(json.dumps(SCHEMA, indent=1))
        return 0
    if opts.verb == "check":
        errors = validate(trace.read_json(opts.file, None))
        print("\n".join(errors) if errors else f"{opts.file}: matches {SCHEMA_ID}")
        return 1 if errors else 0
    parser.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
