#!/usr/bin/env python3
"""SCRATCH MEASUREMENT (cp/lag-newterm-*, never lands): what a NEW terminal costs a typed key, cold against warm.

Launches the measured app (bench_launch.BenchApp, the typing probe on, the hang watchdog at 8 ms) once per session,
where a session is a switch configuration written as the tag's Labs local overrides (they win over the dogfood build
defaults): `on` (the build as shipped), `off` (every switch of the dogfood set off), or `-name+name2` (the build
less those switches). In each session:

  warm0     the launch terminal, typed --keys keys after it has been open for seconds
  trials    --trials times, alternating --kinds (tab = newSurface, split = splitRight):
              create   the action, and the trace of its stages (debug.new_terminal_trace in a separate run)
              ahead    one key sent at once after the action (typeahead: its echo frame waits for the shell)
              first    --keys keys starting --first-delay s after the action (the new terminal's first seconds)
              warm     --keys keys in the same terminal --warm-delay s after the action
            each window with its main-thread hangs (debug.hangs) and frames (debug.frames)
  traces    --traces runs of debug.new_terminal_trace (action to prompt, stage by stage)
  sample    with --sample, /usr/bin/sample of the app over one more trial's create and first keys

Key to frame comes from the typing probe (send to the frame whose layer shows the echo: contents_ms) and from the
`input.latency` signposts (every stage from the event time to the presented frame), bucketed by window. Keys are
debug.key (labelled automation) unless --input real. Distributions are p50/p95/p99/max (typing_report.distribution).

  newterm-cold-warm-bench.py --app APP --out DIR [--json FILE] [--sessions on,off,-terminalHolder]
"""
import argparse, ast, json, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hid_input  # noqa: E402
import typing_report  # noqa: E402
from bench_launch import ISOLATED_LAUNCH_KEY, BenchApp, LaunchError  # noqa: E402

DOGFOOD = ["agentChromium", "agentPageRendererSharing", "automationBurstSnap", "browserLaunchPictures", "cefAttachedPages",
           "cefHelperHost", "cefLaunchOrigin", "cefLayerHosting", "cefMergedEvents", "cefPrefetchBehindFence",
           "cefPumpInputPolicy", "cefTimerSlack", "chromiumAdBlockerAtFirstTab", "chromiumHostDragIn",
           "chromiumHostFileDialogs", "chromiumHostIdleExit", "chromiumHostPopupMenus", "chromiumHostResizeFence",
           "chromiumHostSuggestions", "chromiumHostWidgets", "chromiumSpareAfterFirstTab", "chromiumTabVisibility",
           "cmuxPageRendererSharing", "coldScrollbackCompression", "compressedSnapshots", "controlSocketEarlyBind",
           "daemonRequestQos", "directionalPrewarm", "energySaver", "featureFlagsCard", "frameRateClasses",
           "frozenGrowthDiscard", "hiddenPollPause", "highEnergyTabs", "hostPressure", "intentPrewarmHover",
           "intentPrewarmPress", "ipcMethodLatencyFieldData", "launchVisiblePanesOnly", "launchWindowsByOcclusion",
           "leftoverDaemonIdleExit", "memoryAcpmuxPressure", "memoryAgentAndControlCaches", "memoryAppCaches",
           "memoryBackdropImages", "memoryBrowserCaches", "memoryDiscardAgentPagesOverBudget",
           "memoryDiscardConversations", "memoryDiscardInternalPages", "memoryDiscardPageTabs",
           "memoryDiscardParkedIdleTimeout", "memoryDiscardParkedWorkspaces", "memoryDiscardRemoteTabs",
           "memoryDiscardSidebarSections", "memoryFileHomeCaches", "memoryHiddenAppRelease", "memoryHiddenFrameLRU",
           "memoryHomeLabCaches", "memoryImageCaches", "memoryKittyShare", "memoryOpenPanelOnFirstUse",
           "memoryOverlayPagesOnFirstUse", "memorySaverBackgroundActivity", "memorySaverSetting",
           "memoryScrollbackPressure", "memoryTabCaches", "memoryTerminalLastFrames", "memoryUrgentDiscardRanking",
           "metricsView", "newTabParksHidden", "occludedWindowDiscard", "overlayTopLayer", "pageHangNotice",
           "pageLifecycle", "pageProcessGroups", "pageRendererAtFirstShow", "pageScriptFrames", "pageStandIn",
           "pageTabsShareChromiumWindow", "pagesSpareWindow", "paneHoldsContentInMotion", "pointerFrameDrags",
           "pointerFrameHover", "pointerFrameRemoteInput", "recentlyAudibleProtection", "renderStarvationGuard",
           "rendererlessSpareWindow", "resampledDrags", "savedWindowPicture", "sentryHandlersFirst", "sharedGlyphMasks",
           "sidebarRowsNearViewport", "sidebarSlideHoldsContent", "sleepWakeKeepalives", "stripPanResampling",
           "taskManagerMemorySaved", "terminalGPURelease", "terminalHolder", "terminalPointerFrames",
           "terminalSizingPerApp", "topPageDiscard", "visibilityGatedHosting", "vsyncHub", "windowOcclusionFamily"]
# chrome-parity v1.1 (job 567b4a26d93aa86fdce19821): its all-on list (features-v1-1.md, CMUX_ENABLE_FEATURES there; the
# bench sets them as local overrides because the app strips an inherited CMUX_ENABLE_FEATURES).
V11_ON = "agentPageRendererSharing,automationBurstSnap,cefLayerHosting,cefPrefetchBehindFence,cefPumpInputPolicy,cefTimerSlack,chromiumHostIdleExit,chromiumHostWidgets,chromiumSpareAfterFirstTab,cmuxPageRendererSharing,coldScrollbackCompression,controlSocketEarlyBind,daemonRequestQos,energySaver,frameRateClasses,frozenGrowthDiscard,intentPrewarmHover,memoryAgentAndControlCaches,memoryAppCaches,memoryBrowserCaches,memoryDiscardAgentPagesOverBudget,memoryDiscardConversations,memoryDiscardInternalPages,memoryDiscardPageTabs,memoryDiscardParkedIdleTimeout,memoryDiscardParkedWorkspaces,memoryDiscardRemoteTabs,memoryFileHomeCaches,memoryHiddenFrameLRU,memoryImageCaches,memorySaverBackgroundActivity,memoryTerminalLastFrames,newTabParksHidden,occludedWindowDiscard,overlayTopLayer,pageLifecycle,pageProcessGroups,pageRendererAtFirstShow,pagesSpareWindow,pointerFrameDrags,pointerFrameHover,pointerFrameRemoteInput,recentlyAudibleProtection,renderStarvationGuard,rendererlessSpareWindow,sentryHandlersFirst,sidebarRowsNearViewport,stripPanResampling,taskManagerMemorySaved,terminalGPURelease,terminalPointerFrames,topPageDiscard,vsyncHub".split(",")
WATCH = ["terminalHolder", "vsyncHub", "frameRateClasses", "renderStarvationGuard", "cefPumpInputPolicy",
         "terminalPointerFrames", "daemonRequestQos", "energySaver", "terminalGPURelease", "sharedGlyphMasks",
         "terminalSizingPerApp", "launchVisiblePanesOnly", "windowOcclusionFamily", "paneHoldsContentInMotion"]

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--json")
parser.add_argument("--tag")  # split-spring passes its own; the bundle names the tag
parser.add_argument("--sessions", default="on,off")
parser.add_argument("--trials", type=int, default=6)
parser.add_argument("--kinds", default="tab,split")
parser.add_argument("--keys", type=int, default=30)
parser.add_argument("--interval", type=float, default=0.06)
parser.add_argument("--first-delay", type=float, default=0.8)
parser.add_argument("--warm-delay", type=float, default=10.0)
parser.add_argument("--traces", type=int, default=6)
parser.add_argument("--sample", action="store_true")
parser.add_argument("--input", choices=("debug", "real"), default="debug")
parser.add_argument("--alt-app-sha256", default="",
                    help="a second fleet app (artifact sha256) that `alt:SPEC` sessions launch, in the same step and host")
parser.add_argument("--first-key", type=int, default=0,
                    help="first-key mode: N new tabs, each typed --first-key-keys keys from the action's reply on (no wait)")
parser.add_argument("--first-key-keys", type=int, default=5)
parser.add_argument("--first-key-settle", type=float, default=1.5)
parser.add_argument("--shell", default="", help="terminal.shell for the app's cmux.json (default: the app's own)")
opts = parser.parse_args()
OUT = os.path.abspath(opts.out)
os.makedirs(OUT, exist_ok=True)
APP = os.path.abspath(opts.app.rstrip("/"))
PROBE = os.path.join(OUT, "typing.csv")
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
WINDOW = (40, 40, 1400, 900)
results = {"app": os.path.basename(APP), "host": os.uname().nodename, "opts": vars(opts), "input": opts.input,
           "sessions": [], "log": []}
dist = typing_report.distribution
CONTROL = hid_input.Control("", CLI, None)


def note(text):
    print(text, flush=True)
    results["log"].append(text)


def save():
    if opts.json:
        with open(opts.json, "w") as handle:
            json.dump(results, handle, indent=1)


def rpc(method, params=None, timeout=30):
    return CONTROL.rpc(method, params, timeout=timeout)


def action(name, args=None, timeout=60):
    return CONTROL.action(name, args, focus=True, timeout=timeout)


def load_digest():
    """typing-frame-bench.py's digest_sample (and GENERIC), without running that script's argparse."""
    source = open(os.path.join(HERE, "typing-frame-bench.py")).read()
    tree = ast.parse(source)
    keep = [n for n in tree.body if (isinstance(n, ast.Assign) and any(getattr(t, "id", "") == "GENERIC" for t in n.targets))
            or (isinstance(n, ast.FunctionDef) and n.name == "digest_sample")]
    space = {"re": __import__("re")}
    exec(compile(ast.Module(body=keep, type_ignores=[]), "digest", "exec"), space)
    return space["digest_sample"]


def session_overrides(spec):
    if spec == "on":
        return {}
    if spec == "off":
        return {name: False for name in DOGFOOD}
    if spec == "v11":
        return {name: True for name in V11_ON}
    if spec.startswith("half:"):
        # half:<i>/<n>: the build less DOGFOOD's i-th n-th (by index ranges), for the switch bisect
        index, count = (int(x) for x in spec[5:].split("/"))
        size = -(-len(DOGFOOD) // count)
        return {name: False for name in DOGFOOD[index * size:(index + 1) * size]}
    if spec.startswith("only-on:"):
        # only-on:a+b: every DOGFOOD switch off except those
        keep = set(spec[8:].split("+"))
        return {name: name in keep for name in DOGFOOD}
    overrides = {}
    for part in spec.replace("+", " +").replace("-", " -").split():
        overrides[part[1:]] = part[0] == "+"
    return overrides


def probe_count():
    return len(hid_input.probe_rows(PROBE))


def probe_since(start):
    return hid_input.probe_rows(PROBE)[start:]


def hops(rows, column="contents_ms"):
    """Key-to-frame and the probe's hop split of the complete rows."""
    done = [r for r in rows if r.get("complete") == "1" and r.get(column)]
    f = lambda key: [float(r[key]) for r in done if r.get(key)]
    gap = lambda a, b: [float(r[b]) - float(r[a]) for r in done if r.get(a) and r.get(b)]
    return {"n_rows": len(rows), "n_complete": len(done),
            "key_to_frame_ms": dist(f(column)),
            "send_to_dispatch_ms": dist(f("dispatch_start_ms")),
            "dispatch_ms": dist(gap("dispatch_start_ms", "dispatch_end_ms")),
            "dispatch_to_io_write_ms": dist(gap("dispatch_end_ms", "io_write_ms")),
            "io_write_to_submit_ms": dist(gap("io_write_ms", "socket_submit_ms")),
            "submit_to_output_received_ms": dist(gap("socket_submit_ms", "output_received_ms")),
            "received_to_parsed_ms": dist(gap("output_received_ms", "output_parsed_ms")),
            "parsed_to_contents_ms": dist(gap("output_parsed_ms", "contents_ms")),
            "values": [round(v, 2) for v in f(column)]}


def type_keys(poster, count, interval):
    trips = []
    start = probe_count()
    window = [hid_input.uptime_raw(), None]
    for index in range(count):
        t0 = time.perf_counter()
        reply = poster.key(hid_input.LETTERS[index % 26])
        trips.append((time.perf_counter() - t0) * 1000)
        if isinstance(reply, dict) and reply.get("error"):
            note(f"key {index}: {reply.get('error')}")
        rest = interval - (time.perf_counter() - t0)
        if rest > 0:
            time.sleep(rest)  # one key in flight, at the bench's pace
    time.sleep(0.4)  # the last frame lands
    window[1] = hid_input.uptime_raw()
    return start, trips, window


def window_stats():
    hangs = rpc("debug.hangs", {"limit": 8}, timeout=20)
    frames = rpc("debug.frames", {"action": "stop"}, timeout=20)
    h = {k: hangs.get(k) for k in ("count", "max_ms", "total_ms", "frames_over_8_3ms", "max_gap_ms")} \
        if isinstance(hangs, dict) else hangs
    records = (hangs or {}).get("records") if isinstance(hangs, dict) else None
    return h, records, frames


def window_begin():
    rpc("debug.hangs", {"clear": True})
    rpc("debug.frames", {"action": "start"})


def measure_window(label, poster, count, interval, extra=None):
    window_begin()
    start, trips, window = type_keys(poster, count, interval)
    hangs, records, frames = window_stats()
    entry = {"label": label, **hops(probe_since(start)), "key_rpc_ms": dist(trips), "hangs": hangs,
             "hang_records": (records or [])[:6], "frames": frames, "uptime_window": window, **(extra or {})}
    k = entry["key_to_frame_ms"] or {}
    note(f"  {label}: key-to-frame p50 {k.get('p50')} p95 {k.get('p95')} p99 {k.get('p99')} max {k.get('max')} "
         f"(n={k.get('n')}/{count}) hangs {(hangs or {}).get('count') if isinstance(hangs, dict) else hangs} "
         f"max {(hangs or {}).get('max_ms') if isinstance(hangs, dict) else ''}")
    return entry


COLUMNS = ("contents_ms", "dispatch_start_ms", "dispatch_end_ms", "io_write_ms", "socket_submit_ms",
           "output_received_ms", "output_parsed_ms")


def run_first_key(session, poster):
    """Each trial: newSurface, then --first-key-keys keys at --interval from the reply (key 0 is the first key a person
    types into the new tab); per key index the probe row's key-to-frame and hops, or why it has none."""
    trials = session["first_key"] = []
    session_start = probe_count()  # the probe CSV is shared by every session; each launch numbers presses from 0
    for trial in range(opts.first_key):
        t0 = time.perf_counter()
        reply = action("newSurface")
        reply_ms = round((time.perf_counter() - t0) * 1000, 2)
        start = probe_count()
        before = hid_input.probe_rows(PROBE)[session_start:]
        base = max([int(r["index"]) for r in before if (r.get("index") or "").isdigit()], default=-1) + 1
        sent = []
        for index in range(opts.first_key_keys):
            k0 = time.perf_counter()
            answer = poster.key(hid_input.LETTERS[index % 26])
            sent.append({"at_ms": round((k0 - t0) * 1000, 2), "rpc_ms": round((time.perf_counter() - k0) * 1000, 2),
                         "error": answer.get("error") if isinstance(answer, dict) else None,
                         "handled_by": answer.get("handled_by") if isinstance(answer, dict) else None,
                         "trace": (answer.get("trace") or [])[:8] if isinstance(answer, dict) else None})
            rest = opts.interval - (time.perf_counter() - k0)
            if rest > 0 and index + 1 < opts.first_key_keys:
                time.sleep(rest)
        time.sleep(opts.first_key_settle)  # the echoes land (a shell still starting echoes late)
        typed = "".join(hid_input.LETTERS[i % 26] for i in range(opts.first_key_keys))
        screen = focused_terminal_text()
        rows = probe_since(start)
        by_index = {int(r["index"]): r for r in rows if (r.get("index") or "").isdigit()}
        keys = []
        for index in range(opts.first_key_keys):
            row = by_index.get(base + index)
            entry = {"sent": sent[index], "row": None if row is None else {c: row.get(c) for c in ("complete",) + COLUMNS}}
            if row is not None and row.get("complete") == "1" and row.get("contents_ms"):
                entry["ms"] = float(row["contents_ms"])
            keys.append(entry)
        last_line = next((line for line in reversed((screen.get("text") or "").splitlines()) if line.strip()), "")
        entry = {"trial": trial, "reply_ms": reply_ms, "reply": json.dumps(reply)[:160], "rows": len(rows), "base": base,
                 "typed": typed, "screen_line": last_line[-120:], "attach": screen.get("attach"),
                 "on_screen": typed in last_line, "on_screen_less_first": typed[1:] in last_line and typed not in last_line,
                 "row_indices": sorted(by_index), "keys": keys}
        if trial < 3:
            entry["focus"] = focus_brief()
        trials.append(entry)
        k = keys[0]
        note(f"  ft{trial}: key0 {sent[0].get('handled_by')} {sent[0].get('trace')}")
        note(f"  ft{trial}: screen {'ALL' if entry['on_screen'] else ('LOST-FIRST' if entry['on_screen_less_first'] else 'OTHER')} {last_line[-40:]!r}")
        note(f"  ft{trial}: reply {reply_ms} ms; first key {k.get('ms')} ms (row {'complete' if k.get('ms') is not None else (k['row'] or {}).get('complete')}); "
             f"keys 1..: {[x.get('ms') for x in keys[1:]]}")
        action("terminal.sendText", {"text": "\x15"})
        action("closeTab")
        time.sleep(1.0)  # the close settles
    screen_counts = {"all": sum(t["on_screen"] for t in trials), "lost_first": sum(t["on_screen_less_first"] for t in trials),
                     "other": sum(not t["on_screen"] and not t["on_screen_less_first"] for t in trials)}
    note(f"SCREEN {session['spec']}: {json.dumps(screen_counts)} of {len(trials)} tabs")
    first = [t["keys"][0].get("ms") for t in trials]
    got = [v for v in first if v is not None]
    session["first_key_summary"] = {"screen": screen_counts, "first": dist(got), "missing": len(first) - len(got),
                                    "by_index": [dist([t["keys"][i].get("ms") for t in trials if t["keys"][i].get("ms") is not None])
                                                 for i in range(opts.first_key_keys)],
                                    "reply_ms": dist([t["reply_ms"] for t in trials])}
    for column in COLUMNS[1:]:
        vals = [float(t["keys"][0]["row"][column]) for t in trials if t["keys"][0].get("row") and (t["keys"][0]["row"].get(column) or "") != ""]
        session["first_key_summary"]["first_" + column] = dist(vals)
    f = session["first_key_summary"]["first"] or {}
    note(f"FIRSTKEY {session['spec']}: p50 {f.get('p50')} p95 {f.get('p95')} p99 {f.get('p99')} max {f.get('max')} n {f.get('n')} "
         f"missing {len(first) - len(got)}")
    for i, d in enumerate(session["first_key_summary"]["by_index"]):
        note(f"FIRSTKEY {session['spec']} key{i}: p50 {(d or {}).get('p50')} p95 {(d or {}).get('p95')} n {(d or {}).get('n')}")
    for column in COLUMNS[1:]:
        d = session["first_key_summary"]["first_" + column] or {}
        note(f"FIRSTKEY {session['spec']} key0 {column}: p50 {d.get('p50')} p95 {d.get('p95')} n {d.get('n')}")
    save()


def focused_terminal_text():
    """The focused terminal pane's viewport text and attach phase (debug.surfaces text:true)."""
    reply = rpc("debug.surfaces", {"text": True}, timeout=20)
    best = {}
    def walk(node):
        nonlocal best
        if isinstance(node, dict):
            if "text" in node and node.get("focused") is True and isinstance(node.get("text"), str):
                best = {"text": node["text"], "attach": node.get("attach")}
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)
    walk(reply)
    if not best:
        best = {"text": "", "attach": None, "raw": json.dumps(reply)[:400]}
    return best


def focus_brief():
    """What has the keyboard: debug.focus's context and the Ghostty tabs it holds focused (the measured terminal)."""
    reply = rpc("debug.focus", timeout=20)
    if not isinstance(reply, dict):
        return reply
    windows = reply.get("windows") or []
    return {"app_active": reply.get("app_active"), "context": reply.get("context"),
            "ghostty_focused_tabs": reply.get("ghostty_focused_tabs"),
            "first_responders": [((w.get("appkit") or {}).get("first_responder")) for w in windows][:4]}


def tag_processes(bench):
    try:
        procs = bench.tag_processes()
    except Exception as error:  # the census is context only
        return {"error": repr(error)}
    names = {"holder": sum("__holder" in c for _, c in procs), "terminal_host": sum("__terminal-host" in c for _, c in procs)}
    return {"count": len(procs), "by_name": names, "commands": [c[:160] for _, c in procs][:40]}


ALT_APP = {}


def alt_app(index=0):
    """The index-th app of --alt-app-sha256 (comma separated), fetched once."""
    if index not in ALT_APP:
        sha = opts.alt_app_sha256.split(",")[index]
        dest = os.path.join(os.path.dirname(OUT), f"fleet-apps-alt{index}")
        got = subprocess.run([sys.executable, os.path.join(HERE, "fleet-app-fetch.py"), "--sha256", sha,
                              "--dest", dest], capture_output=True, text=True, check=True)
        ALT_APP[index] = os.path.abspath(got.stdout.strip().splitlines()[-1])
        note(f"alt app {index}: {ALT_APP[index]} (sha256 {sha[:12]})")
    return ALT_APP[index]


def run_session(spec, digest):
    app = APP
    if spec.startswith("alt"):
        head, spec_core = spec.split(":", 1)
        app = alt_app(int(head[3:] or 0))
    else:
        spec_core = spec
    CONTROL.cli_path = os.path.join(app, "Contents/Resources/bin/cmux")
    overrides = session_overrides(spec_core)
    env = {"CMUX_NEXT_TYPING_PROBE": PROBE, "CMUX_NEXT_HANG_THRESHOLD_MS": "8"}
    if opts.input == "real":
        env["CMUX_NEXT_NO_ACTIVATE"] = None
        env[ISOLATED_LAUNCH_KEY] = "1"
    config = {"browser": {"defaultEngine": "chromium"}}
    if opts.shell:
        config["terminal"] = {"shell": opts.shell}
    bench = BenchApp(app, out=OUT, config=config, window=WINDOW, log_name=f"app-{spec.replace(':', '_').replace('/', '_')}.log", env=env,
                     local_features=overrides)
    session = {"spec": spec, "app": os.path.basename(app), "overrides": len(overrides), "trials": [], "traces": []}
    results["sessions"].append(session)
    note(f"session {spec}: {len(overrides)} local overrides")
    try:
        try:
            bench.launch(timeout=180)
        except LaunchError as error:
            note(f"{spec}: the app did not come up: {error.reason}")
            session["launch_failure"] = error.reason
            return
        CONTROL.socket_path, CONTROL.config = bench.socket, os.path.join(bench.scratch, "cmux.json")
        pid = bench.process.pid
        feats = rpc("features.list", timeout=30) or {}
        states = {f.get("name"): (f.get("state"), f.get("source")) for f in feats.get("features") or [] if isinstance(f, dict)}
        on = [n for n in DOGFOOD if (states.get(n) or ("",))[0] in ("on", "enabled", True)]
        on11 = [n for n in V11_ON if (states.get(n) or ("",))[0] in ("on", "enabled", True)]
        session["features_on_of_set"] = len(on)
        session["features_on_of_v11"] = len(on11)
        note(f"  features: {len(on11)}/{len(V11_ON)} of the v1.1 all-on list on")
        session["watched"] = {n: states.get(n) for n in WATCH}
        note(f"  features: {len(on)}/{len(DOGFOOD)} of the set on; watched {json.dumps(session['watched'])}")
        if opts.input == "real":
            hid_input.bring_front(pid)
        poster = hid_input.poster_for(opts.input, control=CONTROL)
        signposts = None
        try:
            signposts = hid_input.SignpostRecording(pid)
        except Exception as error:  # the signposts are a second source; the probe still measures
            note(f"  signposts: not recorded ({error!r})")
        time.sleep(6)  # the launch settles
        session["focus_launch"] = focus_brief()
        if opts.first_key:
            run_first_key(session, poster)
            return
        # The launch window shows Home (its first responder is HomeDockView, not a terminal: warm0 had no probe
        # rows in d0cb9743), so warm0 is a terminal tab opened here and typed into after --warm-delay s.
        session["warm0_open"] = json.dumps(action("newSurface"))[:200]
        time.sleep(opts.warm_delay)
        session["warm0_focus"] = focus_brief()
        session["warm0"] = measure_window(f"warm0 (a tab {opts.warm_delay}s old)", poster, opts.keys, opts.interval)
        action("terminal.sendText", {"text": "\x15"})
        session["warm0_close"] = json.dumps(action("closeTab"))[:120]
        time.sleep(1.5)  # the close settles
        session["processes_before"] = tag_processes(bench)
        kinds = opts.kinds.split(",")
        for trial in range(opts.trials):
            kind = kinds[trial % len(kinds)]
            name = {"tab": "newSurface", "split": "splitRight", "workspace": "newWorkspace"}[kind]
            entry = {"trial": trial, "kind": kind}
            if kind == "split":
                # The split needs a terminal to split (after a close the focus is the Home agent chat, which
                # "can't be split": every split row of d0cb9743 was empty): a tab opened 3 s before it.
                entry["base_open"] = json.dumps(action("newSurface"))[:200]
                time.sleep(3.0)
                entry["base_focus"] = focus_brief()
            window_begin()
            t0 = time.perf_counter()
            reply = action(name)
            entry["action_ms"] = round((time.perf_counter() - t0) * 1000, 2)
            entry["action_reply"] = json.dumps(reply)[:200]
            start = probe_count()
            ahead_at = hid_input.uptime_raw()
            if opts.first_delay > 0:
                poster.key("x")  # typeahead: sent right after the action (with --first-delay 0 the first window is it)
            ahead_wait = opts.first_delay - (time.perf_counter() - t0)
            if ahead_wait > 0:
                time.sleep(ahead_wait)  # the bench's schedule: the first keys start first-delay after the action
            entry["ahead"] = hops(probe_since(start))
            entry["ahead"]["uptime_window"] = [ahead_at, hid_input.uptime_raw()]
            if opts.first_delay > 0:
                hangs, records, frames = window_stats()
                entry["create_window"] = {"hangs": hangs, "hang_records": (records or [])[:6], "frames": frames}
                entry["focus"] = focus_brief()
            entry["first"] = measure_window(f"t{trial} {kind} first ({opts.first_delay}s)", poster, opts.keys, opts.interval)
            rest = opts.warm_delay - (time.perf_counter() - t0)
            if rest > 0:
                time.sleep(rest)  # the terminal warms
            entry["warm"] = measure_window(f"t{trial} {kind} warm ({opts.warm_delay}s)", poster, opts.keys, opts.interval)
            entry["focus_warm"] = focus_brief()
            if trial == 0:
                entry["processes"] = tag_processes(bench)
            action("terminal.sendText", {"text": "\x15"})
            entry["close"] = json.dumps(action("closePane" if kind == "split" else "closeTab"))[:120]
            if kind == "split":
                time.sleep(0.5)
                action("terminal.sendText", {"text": "\x15"})
                entry["base_close"] = json.dumps(action("closeTab"))[:120]
            session["trials"].append(entry)
            save()
            time.sleep(1.5)  # the close settles
        if opts.sample:
            path = os.path.join(OUT, f"sample-{spec.replace(':', '_').replace('/', '_')}.txt")
            sampler = subprocess.Popen(["/usr/bin/sample", str(pid), "4", "1", "-file", path],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(0.5)  # the sampler attaches
            action("newSurface")
            poster.key("x")
            time.sleep(opts.first_delay)
            type_keys(poster, opts.keys, opts.interval)
            try:
                sampler.wait(timeout=60)
            except subprocess.TimeoutExpired:
                sampler.terminate()
            try:
                session["sample_main"] = digest(open(path, errors="replace").read())
            except OSError as error:
                session["sample_main"] = {"error": repr(error)}
            action("terminal.sendText", {"text": "\x15"})
            action("closeTab")
            time.sleep(1.5)  # the close settles
        for index in range(opts.traces):
            trace = rpc("debug.new_terminal_trace", {"action": "run", "timeout_ms": 10000}, timeout=30)
            session["traces"].append(trace)
            marks = (trace or {}).get("marks_ms") if isinstance(trace, dict) else None
            note(f"  trace {index}: {json.dumps(marks) if marks else json.dumps(trace)[:300]}")
            time.sleep(1.0)  # the close settles
        if signposts:
            events, lost = signposts.stop()
            session["signposts"] = {"events": len(events), "lost": lost}
            buckets = {"warm0": [session["warm0"]["uptime_window"]]}
            for t in session["trials"]:
                buckets.setdefault("ahead", []).append(t["ahead"]["uptime_window"])
                buckets.setdefault("first", []).append(t["first"]["uptime_window"])
                buckets.setdefault("warm", []).append(t["warm"]["uptime_window"])
            stages = {}
            for label, windows in buckets.items():
                chosen = [e for e in events if e["kind"] == "keyPress" and any(
                    w[0] * 1e9 <= e["generated_ns"] <= w[1] * 1e9 for w in windows)]
                per = {}
                for e in chosen:
                    for stage, ms in e["stages_ms"].items():
                        per.setdefault(stage, []).append(ms)
                stages[label] = {"n": len(chosen), "targets": sorted({e["target"] for e in chosen}),
                                 "sources": sorted({e["presentation_source"] for e in chosen}),
                                 "stages": {s: dist(v) for s, v in per.items()}}
            session["signpost_stages"] = stages
            note(f"  signposts: {len(events)} events, lost {lost}; presented p50/p95 "
                 + json.dumps({k: ((v["stages"].get("presented") or {}).get("p50"), (v["stages"].get("presented") or {}).get("p95"))
                               for k, v in stages.items()}))
        session["input_report"] = rpc("debug.input", {}, timeout=30)
    finally:
        save()
        bench.stop()


def summarize():
    if opts.first_key:
        results["summary"] = {s["spec"]: s.get("first_key_summary") for s in results["sessions"]}
        return
    rows = {}
    for s in results["sessions"]:
        pick = lambda entries: [v for e in entries for v in (e.get("values") or [])]
        trials = s.get("trials") or []
        row = {"warm0": dist((s.get("warm0") or {}).get("values") or []),
               "ahead_first_key": dist(pick([t["ahead"] for t in trials])),
               "first": dist(pick([t["first"] for t in trials])),
               "warm": dist(pick([t["warm"] for t in trials]))}
        for kind in opts.kinds.split(","):
            row[f"first.{kind}"] = dist(pick([t["first"] for t in trials if t["kind"] == kind]))
            row[f"warm.{kind}"] = dist(pick([t["warm"] for t in trials if t["kind"] == kind]))
        row["create_hangs_max_ms"] = [((t.get("create_window") or {}).get("hangs") or {}).get("max_ms")
                                      if isinstance((t.get("create_window") or {}).get("hangs"), dict) else None for t in trials]
        row["first_hangs_max_ms"] = [((t["first"].get("hangs") or {}).get("max_ms")) if isinstance(t["first"].get("hangs"), dict) else None
                                     for t in trials]
        row["action_ms"] = [t.get("action_ms") for t in trials]
        marks = {}
        for trace in s.get("traces") or []:
            for mark, ms in ((trace or {}).get("marks_ms") or {}).items() if isinstance(trace, dict) else []:
                if ms is not None:
                    marks.setdefault(mark, []).append(ms)
        row["trace_marks_ms"] = {m: dist(v) for m, v in marks.items()}
        rows[s["spec"]] = row
    results["summary"] = rows
    for spec, row in rows.items():
        brief = {k: (v or {}).get("p50") if isinstance(v, dict) else v for k, v in row.items() if k != "trace_marks_ms"}
        note(f"SUMMARY {spec} p50: " + json.dumps({k: v for k, v in brief.items() if not k.endswith("_ms") or k == "action_ms"}))
        note(f"SUMMARY {spec} p95: " + json.dumps({k: (v or {}).get("p95") for k, v in row.items() if isinstance(v, dict) and "p95" in (v or {})}))
        for key, v in row.items():
            if isinstance(v, dict) and "p50" in v:
                note(f"ROW {spec} {key}: p50 {v.get('p50')} p95 {v.get('p95')} p99 {v.get('p99')} max {v.get('max')} n {v.get('n')}")
        note(f"SUMMARY {spec} trace p50: " + json.dumps({k: v.get("p50") for k, v in row["trace_marks_ms"].items()}))


def main():
    results["refresh_hz"] = hid_input.display_refresh()
    results["macos"] = hid_input.macos_version()
    digest = load_digest()
    try:
        for spec in opts.sessions.split(","):
            try:
                run_session(spec, digest)
            except Exception as error:  # one session failing must not hide the others
                note(f"session {spec}: failed: {error!r}")
    finally:
        summarize()
        save()


if __name__ == "__main__":
    main()
