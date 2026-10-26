#!/usr/bin/env python3
"""Idle thread and wakeup budget of cmux NEXT (Lawrence's threading list, item 6; plans/cmux-next/idle-wakeups.md).

Idle means no input, no visible change, terminals quiet. At idle every cmux process should sleep: the
app's main thread 0 wakeups a second, the app <= 1/s, the cmux-tui daemon <= 1/s, the holder 0, and
each process's thread count capped. This script launches a tagged app (bench_launch.BenchApp), builds a
session, lets it settle, then measures one window with no input and reports, per process:

  threads, wakeups/s (interrupt wakeups, proc_pid_rusage: what Activity Monitor's Idle Wake Ups and
  Chrome's GetIdleWakeupsPerSecond count; the judged number), package-idle wakeups/s (a subset of them,
  GetPackageIdleWakeupsPerSecond), CPU energy and billed energy (mW: CPU energy plus what other processes
  such as WindowServer spent for this one, less what it spent for them), GPU ms/s (IORegistry), context
  switches/s, CPU %, and the threads that ran in the window (CPU time per thread,
  PROC_PIDTHREADID64INFO: the thread names show which loop woke);
  for the app also main_wakes/s (the main run loop's wakes from sleep, debug.hangs `main_wakes`) and,
  when the build has it, the wakeup ledger's owners (debug.wakeups: DemandTimer, FrameScheduler,
  Backoff by owner and reason).
The app's resource coalition (procs.coalition_of: energy, energy billed to it, GPU time and wakeups of
everything it started, processes gone in the window included) is `coalition` in the report: null when
it cannot be read.

The script reads the app's counters only at the window's two ends (proc_pid_rusage of another process
does not wake it; the two socket reads sit outside the process counters' window), so the bench adds no
wakeup to what it measures. Each end's state reads (debug.energy, pmset, the animated page) sit outside
every counter bracket: the start reads, a quiet gap, then the counters; the counters, then the end reads.

Sessions (--sessions):
  light         the launch window with its terminal (Home's pages run in Chromium by default)
  light-webkit  the same with browser.defaultEngine webkit: no Chromium at all
  light-hidden  the light session with the app hidden (Show/Hide All Windows hidden=true)
  Each session starts from an empty saved session (`fresh_session`).
  stress-static  STRESS with its pages served without their rAF spinner (STRESS's own pages animate: not idle)
  stress   STRESS (scripts/cmux-next/perf-stress-session.py: 60 workspaces, a 12-pane grid of 6 tabs each,
           Chromium pages elsewhere); its 10 busy terminals are stopped (Ctrl-C) before the settle, so the
           terminals are quiet
  tabs-static   the launch pane with 5 WebKit and 10 Chromium tabs hidden behind 1 shown static Chromium tab,
                every page tab_pages' static page; the settle lasts past `browser.freezeHiddenTabs`
  minimized     the light session with its window minimized (action minimizeWindow)
  energy-saver  tabs-static with `energy.saver: always`, the shown tab an animated page (/anim, rAF every
                frame, no input) whose rAF count the page server reads at the window's two ends: the page keeps
                one fetch the server holds (no wake while held); the bench answers it and the page POSTs
                its count, page clock and visibilityState (any build, Release + CMUX_BENCH_HOOKS included)
  chrome-static the reference: a Chromium browser (--chrome-app) with tabs-static's 16 static pages as tabs in the
                same order, the last shown, and the uBlock Origin --app bundles (--chrome-ublock), launched as xbench
                launches Chrome (a template profile keyed on the browser build and uBlock Origin, its switches, CDP
                /json/new), every page loaded, settled as long as tabs-static; kinds browser, renderer, extension,
                gpu, utility, crashpad. The bundled uBlock Origin is Manifest V2: branded Google Chrome ignores
                --load-extension from 137 and Chromium runs no MV2 from 139, so --chrome-app must be a Chromium with
                the MV2 patch cmux's CEF carries (ungoogled-chromium of cmux's Chromium major: cmux's
                cmux_extensions_manifestv2.patch comes from it). A browser known not to run it (branded Chrome 137+,
                Chrome for Testing 139+) fails the session before it launches. The report gets a `chrome` block
                and `ratio_to_chrome` rows (the budget's, judged once with the other cross-session rows; a Chrome
                value under the field's noise floor counts as the floor, `:floor` on the field). A row whose two
                sessions did not both run uBlock Origin, or whose Chrome pages are not tabs-static's shape, is
                `unequal`: reported, not judged; --gate refuses a failed or unequal chrome-static run.
  power-visible the launch pane with 1 shown static Chromium tab and nothing else, settled 120 s, its window's power
                attributed (scripts/perf-bench/power_attribution.py, p14-energy-096): per process own + billed -
                serviced energy, split per thread by CPU time, summed into owners `<kind>/<thread>`, `<kind>/billed`
                and `<kind>/serviced` that must sum to within 10% of the app's coalition total; WindowServer's own
                energy (with `sudo -n`); unnamed threads summed per kind (`<kind>/unnamed threads`), and while that
                is >= 2 mW a stack sample of the process with the most of it names its threads; the FrameClients
                that ticked (debug.wakeups `frame` ledger owners and FrameScheduler frames) and the infinite Core
                Animation loops and playing video layers at both ends (debug.layers `frame_sources`). Reported, not
                judged: no budget row.
  chrome-power-visible  the same 1 tab in the chrome-static browser, attributed the same way. With both sessions
                measured, POWER-OVER lines list each owner group >= 2 mW (Chrome's kinds: the app and cef-host are
                `browser`) that spends more than Chrome's same group, or that Chrome does not have: reported, not
                judged.
  agent-idle    two agent chats on the ACP fake agent (cmux-tui/crates/acpmux/tests/fake_agent.py, the default
                harness of the session's own ACPMUX_HOME and ACPMUX_SOCKET) after a finished turn: one in a workspace
                that then hides behind the launch workspace, one in the launch pane; plus one pooled entry
                (_acpmux/prewarm). Settled past p14-energy-117's harness freeze (HARNESS_FREEZE_S). Its hidden chat's
                harness rows are `hidden` (under that chat's agent host, from its `hosts/<session>.json` record).
                The window is refused (IDLE-BUDGET-REFUSED) when no measured harness row is under the hidden chat's
                host or under a pooled host: a harness that exited would pass its rows with nothing measured.
  agent-working-visible  the launch pane's chat in a turn that sends nothing (the fake agent's `gate:` blocks on a
                FIFO until the session ends): the pane's working state is what moves. The chat must show in
                Chromium (`debug.agent_pane engine` == cef): its row sums the cef kinds, and a WebKit chat's work
                would fall outside them
  busy-hidden   the launch terminal prints one line every 100 ms, then a new workspace shows over it
  Every process under an acpmux agent host (`__agent-host`, pooled entries included) is kind agent-harness
  (procs.agent_harness_pids); the host itself is acpmux.

Per window the report also has, per session: `energy_mw` (CPU and billed energy, summed per kind and over the
tree), `assertions` (`pmset -g assertions` held by or created for a pid of the set), `saver` (asked by the
session, observed through debug.energy at both ends) and `thermal` (ProcessInfo.thermalState at both ends).
--gate refuses a session whose observed saver state is not the one it asked for, and energy-saver when its page's
rAF rate could not be read; a session whose thermal state reached serious or critical has `thermal_marked` on its
rows.

A session that fails (STRESS refuses a window under the Dock, a launch fails) is recorded with its exit
code (`session_exits` in the report) and the others still run; the script exits 0 unless --gate.

Shipping measurement mode (always on; plans/cmux-next/chrome-parity/p14-energy.md, task 100): every cmux session
launches with bench_launch.shipping_env (CMUX_NEXT_BENCH_SHIPPING_DRAW=1: occluded windows stop drawing as in a
user's launch; CMUX_NEXT_DEV_SENTRY=1 and CMUX_NEXT_DEV_HANG_REPORTS=1: Sentry and hang reports run;
CMUX_NEXT_ISOLATED_LAUNCH=1 instead of CMUX_NEXT_NO_ACTIVATE: the app may activate, at the bench's fixed window
frame), with `diagnostics.hangReports` on and the tag's hang report consent record written
(bench_launch.seed_hang_report_consent), and activates the app once before the settle. The bundle's build config
(debug, bench-hooks, release) is read first. `--gate` refuses a Debug build (exit 2): its code and its draw are not
what users run. `--shipping-draw off` keeps the automation draw of occluded windows for an on/off comparison; only a
Debug build has that draw, so it is refused (exit 2) on any other build. Each session records build_config,
sentry_started (a SentryCrash thread runs in the app), hang_reports (debug.shipping_mode: available, setting,
decision, enabled; `on` when the app sends), draws_when_occluded (the app's WindowDrawPolicy.drawsWhenOccluded and
PageWebView.rendersWhenCovered from debug.shipping_mode, with the launch env's prediction as a cross-check:
IDLE-BUDGET-DRAW-MISMATCH) and activated. `--gate` refuses a session that was not activated, ran without Sentry or
without hang reports.

Budget: scripts/cmux-next/idle-budget.json, schema v2 (its _doc): per process kind with per-session overrides,
sums (app+daemon, tree), ratios to another session of the run and to chrome-static (judged once every session
is measured, whatever the --sessions order), xbench rows (--xbench), allowed_periodic (wakeup-audit.py) and
assertions_allowed_when. A missing or unknown value is reported, not judged (IDLE-BUDGET-NOT-JUDGED lines); a sum
with one unknown part is unknown; a v1 file (kinds only) still loads. Every session runs with both keep-awake
settings off. Over budget prints IDLE-BUDGET-OVER lines; the exit code is 0 unless --gate (no CI gate: the perf
cron runs it and reports).

Use (fleet only, a host with a GUI console session; never on a laptop in use):
  python3 scripts/cmux-next/idle-budget.py --app "<...>/cmux DEV <tag>.app" --out DIR \\
      [--sessions light,stress|all] [--settle 60] [--measure 60] [--json DIR/idle-budget.json] [--gate]
  D6 on an xbench.py result (any host): python3 scripts/cmux-next/idle-budget.py --xbench OUT/results.json [--gate]
  On the fleet through the allowlisted entry (STRESS needs the 1920 x 1080 virtual display):
    scripts/measure/split-spring.sh --suite=idle-budget --vdisplay=120 -- --sessions tabs-static,energy-saver

Output: one `IDLE-BUDGET-MACHINE {json}` line, one `IDLE-BUDGET-ROW {json}` line per session and process
kind, IDLE-BUDGET-ENERGY / -STATE / -ASSERTION / -ANIM / -CHROME lines, IDLE-BUDGET-REFUSED for a saver mismatch, an
unread rAF rate or a failed or unequal chrome-static, IDLE-BUDGET-THERMAL for a marked session, IDLE-BUDGET-FRAME-CLIENTS
when the build has debug.wakeups, POWER-BREAKDOWN / -OWNER / -UNNAMED / -WINDOWSERVER for the power sessions and
POWER-OVER <owner> <mW>, a Markdown table, and --json with every sample.
"""
import argparse, fnmatch, hashlib, json, os, platform, plistlib, re, shutil, socket, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "perf-bench"))
import procs  # noqa: E402  (process set of one app: descendants, bundle processes, responsible XPC processes)
import tab_pages  # noqa: E402  (the tab-page server and the Chromium process classifier)
import power_attribution  # noqa: E402  (who spends the idle power: owners, breakdown, POWER-OVER)

BUDGET_FILE = os.path.join(HERE, "idle-budget.json")
STRESS_FILE = os.path.join(HERE, "perf-stress-session.py")

# ---------------------------------------------------------------------------------------------------------
# Per-thread counters (libproc, same user, no root): {thread id: (cpu ns, name)} of a pid now, {} when it is gone

threads = power_attribution.thread_cpu


# ---------------------------------------------------------------------------------------------------------
# Process kinds (the budget's keys)

# Chromium utility processes by service (content/browser/utility_process_host.cc names them by
# --utility-sub-type, the mojo interface the process serves).
UTILITY_KINDS = {"network.mojom.NetworkService": "cef-network", "storage.mojom.StorageService": "cef-storage",
                 "audio.mojom.AudioService": "cef-audio"}


def kind(cmd, under_agent_host=False):
    """The budget kind of a process of the app's set. `under_agent_host`: the process descends from an acpmux agent
    host (procs.agent_harness_pids), so it is the harness of an agent session or of a pooled entry, or a tool that
    harness runs: `agent-harness`, whatever its command. The host itself is acpmux code: `acpmux`."""
    if under_agent_host:
        return procs.AGENT_HARNESS
    if procs.is_agent_host(cmd):
        return "acpmux"
    if "__holder" in cmd:
        return "holder"
    if "__terminal-host" in cmd:
        return "terminal-host"
    if re.search(r"/bin/cmux-tui(\s|$)", cmd):
        return "daemon"
    if re.search(r"/bin/acpmux(\s|$)", cmd):
        return "acpmux"
    if "--type=crashpad-handler" in cmd or "chrome_crashpad_handler" in cmd:
        return "crashpad"
    chromium = tab_pages.chromium_kind(cmd)
    if chromium == "cef-utility":
        service = re.search(r"--utility-sub-type=(\S+)", cmd)
        return UTILITY_KINDS.get(service.group(1) if service else "", "cef-utility")
    if chromium:
        return chromium
    if "com.apple.WebKit." in cmd:
        return "webkit-" + cmd.split("com.apple.WebKit.", 1)[1].split()[0].split(".")[0].lower()
    exe = cmd.split(" --", 1)[0]
    if exe.count(".app/") == 1 and "/Contents/MacOS/" in exe:
        return "app"
    return "other:" + os.path.basename(exe.split()[0])[:32]


def process_set(instance):
    """{pid: command} of the app's processes plus their descendants (shells of the terminals are `other:`)."""
    found = dict(instance.pids())
    table = procs.process_table()
    children = {}
    commands = {}
    for pid, ppid, cmd in table:
        children.setdefault(ppid, []).append(pid)
        commands[pid] = cmd
    stack = list(found)
    while stack:
        pid = stack.pop()
        for child in children.get(pid, []):
            if child not in found and child in commands:
                found[child] = commands[child]
                stack.append(child)
    return found


# ---------------------------------------------------------------------------------------------------------
# One window


# Seconds between the start's state reads and the first counter read.
QUIET_GAP_S = 1.0


def read_rpc(app, method, params=None):
    reply = app.rpc(method, params or {}, timeout=30)
    return reply if isinstance(reply, dict) and not reply.get("error") else {}


def window_end(app, pids, read_anim=None):
    """What one end of the window records outside the process counters: the app's energy policy (debug.energy:
    the saver state), the Mac's thermal state, the power assertions of the pid set and, with `read_anim`
    (IdlePages.read_anim), the animated page's rAF count."""
    saver, reason = saver_state(read_rpc(app, "debug.energy"))
    end = {"saver": saver, "saver_reason": reason, "thermal": procs.thermal_state(),
           "assertions": procs.power_assertions(pids)}
    if read_anim is not None:
        end["anim"] = read_anim()
    return end


def saver_state(reply):
    """(isSaver, reason) from a debug.energy reply (`policy`: EnergyPolicy, `inputs.reason`); (None, None) when the
    build has no debug.energy or the reply has no boolean isSaver."""
    policy = reply.get("policy") if isinstance(reply.get("policy"), dict) else {}
    inputs = reply.get("inputs") if isinstance(reply.get("inputs"), dict) else {}
    saver = policy.get("isSaver")
    if not isinstance(saver, bool):
        return None, None
    return saver, policy.get("reason") or inputs.get("reason")


def measure(app, instance, seconds, read_anim=None, attribute=False, hidden_hosts=()):
    """Counters of every process of the app over `seconds` with no input. The window's end reads (window_end) sit
    outside every counter bracket, the app's own counters included, so the bench's reads are never counted. With
    `attribute`, `power` has the window's power owners: power_attribution.PowerWindow's subprocesses (ps, sudo)
    run before `first` and after `last`, outside this bracket and its own; only its libproc reads sit inside.
    The agent harness processes (procs.Instance.harness of the last process_set read, the table that named
    `last_pids`) are kind agent-harness; those under one of `hidden_hosts` (the agent host pids of hidden panes) are
    `hidden` rows."""
    pids = process_set(instance)
    start = window_end(app, pids, read_anim)
    window = power_attribution.PowerWindow(instance.pid, lambda: process_set(instance), kind) if attribute else None
    if window:
        window.prepare()
    time.sleep(QUIET_GAP_S)  # bench: the start reads' aftermath (the page's POST, the RPC's reply) ends before the counters
    hangs0 = read_rpc(app, "debug.hangs", {"limit": 0})
    ledger0 = read_rpc(app, "debug.wakeups")
    sources0 = frame_sources(app) if attribute else None
    counters0 = app_counters(app)
    first = snapshot(pids)
    gpu0 = procs.gpu_ns_by_pid()
    if window:
        window.begin()
    coalition0 = procs.coalition_of(instance.pid)
    began = time.monotonic()
    time.sleep(seconds)  # bench: the idle window itself (nothing is sent to the app in it)
    elapsed = time.monotonic() - began
    coalition1 = procs.coalition_of(instance.pid)
    if window:
        window.end()
    gpu1 = procs.gpu_ns_by_pid()
    last_pids = process_set(instance)
    harness = {pid: host for pid, host in instance.harness.items() if pid in last_pids}
    last = snapshot(last_pids)
    power = window.finish() if window else None
    hangs1 = read_rpc(app, "debug.hangs", {"limit": 0})
    ledger1 = read_rpc(app, "debug.wakeups", {"run_loop": True})
    sources1 = frame_sources(app) if attribute else None
    counters1 = app_counters(app)
    end = window_end(app, last_pids, read_anim)
    rows = process_rows(first, last, elapsed, gpu0, gpu1, kind, harness=harness, hidden_hosts=hidden_hosts)
    result = {"seconds": round(elapsed, 1), "processes": rows, "ends": {"start": start, "end": end},
              "coalition": procs.coalition_rates(coalition0, coalition1, elapsed)}
    if "main_wakes" in hangs0 and "main_wakes" in hangs1:
        result["main_wakes_per_s"] = round((hangs1["main_wakes"] - hangs0["main_wakes"]) / elapsed, 3)
    owners = ledger_rates(ledger0, ledger1, elapsed)
    if owners is not None:
        result["ledger"] = owners
    if owners is not None or attribute:
        result["frame_clients"] = power_attribution.frame_clients(ledger0, ledger1, elapsed,
                                                                  (sources0, sources1) if attribute else None)
    if power is not None:
        result["power"] = power_attribution.attribute(power)
    rates = {key: round((counters1[key] - counters0[key]) / elapsed, 3) for key in counters1
             if key in counters0 and counters1[key] != counters0[key]}
    if rates:
        result["app_counter_rates"] = rates
    if ledger1.get("main_run_loop"):
        result["main_run_loop_timers"] = run_loop_timers(ledger1["main_run_loop"])
    return result


def frame_sources(app):
    """The app's frame sources no FrameScheduler sees (debug.layers `frame_sources`: infinite Core Animation loops
    and playing video layers per owner view), or None when the build does not report them."""
    got = read_rpc(app, "debug.layers", {"frame_sources": True}).get("frame_sources")
    return got if isinstance(got, dict) else None


def snapshot(commands):
    """{pid: (command, procs.Usage, task overhead, threads)} of `commands` ({pid: command}) now."""
    return {pid: (cmd, procs.usage(pid), procs.overhead(pid), threads(pid)) for pid, cmd in commands.items()}


def process_rows(first, last, elapsed, gpu0, gpu1, classify, harness=None, hidden_hosts=()):
    """One row per process alive at the window's end, from two snapshots and two GPU reads `elapsed` seconds
    apart, its kind from `classify`; a process that started inside the window counts from its start (`partial`).
    `harness` ({pid: agent host pid}, procs.Instance.harness) names the agent harness processes: kind agent-harness, with
    `agent_host`, and `hidden` when that host is one of `hidden_hosts`."""
    harness = harness or {}
    rows = []
    for pid, (cmd, c1, o1, t1) in sorted(last.items()):
        if c1 is None or o1 is None:
            continue
        (_, c0, o0, t0) = first.get(pid, (cmd, None, None, {}))
        partial = c0 is None
        o0 = o0 or (0, 0, 0, 0, 0)
        ran = []
        for tid, (cpu, name) in t1.items():
            before = t0.get(tid, (0, name))[0] if not partial else 0
            if cpu > before:
                ran.append({"tid": tid, "name": name or "", "cpu_us": round((cpu - before) / 1000, 1)})
        ran.sort(key=lambda t: -t["cpu_us"])
        row = process_row(pid, cmd, c0, c1, elapsed, gpu=procs.gpu_ms_per_s(gpu0, gpu1, pid, elapsed),
                          threads_now=o1[1], csw=procs._delta32(o1[4], o0[4]), ran=ran, classify=classify,
                          under_agent_host=pid in harness)
        if pid in harness:
            row["agent_host"] = harness[pid]
            if harness[pid] in hidden_hosts:
                row["hidden"] = True
        rows.append(row)
    return rows


def process_row(pid, cmd, first, last, elapsed, gpu, threads_now, csw, ran, classify=None, under_agent_host=False):
    """One process's row of the window from two procs.Usage reads (`first` None: it started inside the
    window, `partial`); its kind from `classify` (default: the cmux kinds, `kind`), agent-harness for a process
    `under_agent_host`."""
    got = procs.rates(first, last, elapsed)
    name = kind(cmd, under_agent_host=True) if under_agent_host else (classify or kind)(cmd)
    return {
        "pid": pid, "kind": name, "command": cmd[:160], "partial": first is None,
        "threads": threads_now, "threads_ran": len(ran), "ran": ran[:8],
        "cpu_pct": round(got["cpu_pct"], 4),
        "wakeups_per_s": round(got["wakeups_per_s"], 3),
        "pkg_idle_wakeups_per_s": round(got["pkg_idle_wakeups_per_s"], 3),
        "energy_mw_cpu": round(got["energy_mw_cpu"], 3),
        "energy_mw_billed": round(got["energy_mw_billed"], 3),
        "gpu_ms_per_s": None if gpu is None else round(gpu, 3),
        "csw_per_s": round(csw / elapsed, 3),
        "footprint_mb": round(last.footprint / procs.MB, 1),
    }


TIMER_RE = re.compile(r"<CFRunLoopTimer [^>]*>\{valid = (\w+), firing = \w+, interval = ([0-9.e+-]+),[^}]*?"
                      r"next fire date = ([0-9.e+-]+)[^}]*?callout = ([^,}]+)")


def run_loop_timers(description):
    """The main run loop's timers from its CFCopyDescription: callout, interval (0: one-shot) and next fire
    date, one entry per timer (a timer in several common modes appears once). Repeating timers wake the main
    thread outside the wakeup ledger."""
    seen = {}
    for valid, interval, fire, callout in TIMER_RE.findall(description):
        key = (callout.strip(), interval, fire)
        if valid == "Yes":
            seen[key] = {"callout": callout.strip()[:160], "interval_s": float(interval), "next_fire": float(fire)}
    return sorted(seen.values(), key=lambda t: (t["interval_s"] == 0, t["interval_s"]))


def window_state(app):
    """The app's main windows from its control socket (`debug.window_list`, no AX): key, visible, occluded,
    miniaturized; and whether the app is active. A system prompt over the window shows as not key or occluded."""
    reply = app.rpc("debug.window_list", timeout=10)
    windows = reply.get("windows") if isinstance(reply, dict) else None
    if not isinstance(windows, list):
        return {"error": str(reply)[:200]}
    main = [{k: w.get(k) for k in ("key", "visible", "occluded", "miniaturized", "alpha")} for w in windows if w.get("kind") == "main"]
    return {"main": main, "any_key": any(w.get("key") for w in windows)}


def sample_threads(pid, seconds, path):
    """`/usr/bin/sample` of `pid` for `seconds` after the window (it suspends the process to sample, so it
    never runs inside the measured window); per thread, the frames with the most samples outside the wait."""
    try:
        subprocess.run(["/usr/bin/sample", str(pid), str(seconds), "-mayDie", "-file", path], capture_output=True,
                       timeout=seconds + 60)
        text = open(path, errors="replace").read()
    except (OSError, subprocess.TimeoutExpired):
        return {}
    graph = text.split("Call graph:", 1)[-1].split("Total number in stack", 1)[0]
    threads_out = {}
    current = None
    for line in graph.splitlines():
        head = re.match(r"\s{4}(\d+) Thread_\d+(.*)", line)
        if head:
            name = head.group(2).strip(" :") or "thread"
            current = {"samples": int(head.group(1)), "frames": {}}
            threads_out[f"{name} ({head.group(1)})"] = current
            continue
        frame = re.match(r"[\s+!:|]*(\d+) (.+?)\s+\(in ([^)]+)\)", line)
        if current is not None and frame:
            count, symbol, image = int(frame.group(1)), frame.group(2), frame.group(3)
            if any(wait in symbol for wait in ("mach_msg", "__psynch_cvwait", "__workq_kernreturn", "kevent", "__semwait",
                                                "__select", "__ulock_wait", "start_wqthread", "thread_start", "_pthread_start")):
                continue
            key = f"{symbol} ({image})"
            current["frames"][key] = max(current["frames"].get(key, 0), count)
    for entry in threads_out.values():
        entry["frames"] = sorted(entry["frames"].items(), key=lambda kv: -kv[1])[:12]
    return threads_out


def app_counters(app):
    """The app's own cumulative counters that can wake its main thread outside the ledger (the bench diffs two
    reads): the CEF pump (`debug.cef` pump: work runs, immediate and delayed requests from any thread), the
    Chromium page trackers (geometry posts and skips) and each window's child-window reorders (`debug.layers`)."""
    out = {}
    cef = read_rpc(app, "debug.cef")
    for group in ("pump", "tracker"):
        for key, value in (cef.get(group) or {}).items():
            if isinstance(value, (int, float)) and not key.endswith("_ms"):
                out[f"cef.{group}.{key}"] = value
    layers = read_rpc(app, "debug.layers")
    out["layers.reorders"] = sum(w.get("reorders", 0) for w in layers.get("windows") or [] if isinstance(w, dict))
    return out


def ledger_rates(before, after, elapsed):
    """Wakeup ledger owners that fired in the window (debug.wakeups, when the build has it)."""
    if not before.get("ledger") and not after.get("ledger"):
        return None
    counts = {(e["owner"], e["reason"]): e.get("count", 0) for e in before.get("ledger") or []}
    out = []
    for entry in after.get("ledger") or []:
        delta = entry.get("count", 0) - counts.get((entry["owner"], entry["reason"]), 0)
        if delta > 0:
            out.append({"owner": entry["owner"], "reason": entry["reason"], "per_s": round(delta / elapsed, 3)})
    out.sort(key=lambda e: -e["per_s"])
    return {"owners": out[:20], "active_frame_clients": after.get("active_frame_clients", [])}


# ---------------------------------------------------------------------------------------------------------
# Budget


# Summed per kind (field: digits). A None in any process of the kind (GPU time with no IORegistry read)
# makes the kind's sum None: an unknown is never a 0.
SUMMED = {"wakeups_per_s": 3, "pkg_idle_wakeups_per_s": 3, "energy_mw_cpu": 3, "energy_mw_billed": 3,
          "gpu_ms_per_s": 3, "csw_per_s": 3, "cpu_pct": 4}
# Recorded only by some runs (task 003 records disk and log): a kind whose rows have none has no value, so
# all_kinds judges nothing that was not measured; a kind where some rows have it and others not is None (unknown).
SUMMED_WHEN_PRESENT = {"disk_bytes_per_s": 3, "log_lines": 0}


def aggregate(result):
    """Per kind: count, threads (sum and max per process), interrupt wakeups/s (sum and max per process, and the
    max over the processes of hidden pages), package-idle wakeups/s, CPU and billed energy (mW), GPU ms/s, context
    switches/s, CPU %, disk and log sums when the rows have them; the roles."""
    kinds = {}
    for row in result["processes"]:
        entry = kinds.setdefault(row["kind"], {"n": 0, "threads": 0, "threads_max": 0, "wakeups_max": 0.0,
                                               "threads_ran": 0, **{field: 0.0 for field in SUMMED}})
        entry["n"] += 1
        entry["threads"] += row["threads"]
        entry["threads_max"] = max(entry["threads_max"], row["threads"])
        entry["wakeups_max"] = max(entry["wakeups_max"], row["wakeups_per_s"])
        if row.get("hidden"):
            entry["hidden_wakeups_max"] = max(entry.get("hidden_wakeups_max", 0.0), row["wakeups_per_s"])
        for field, digits in SUMMED.items():
            value = row.get(field, 0.0)
            entry[field] = None if entry[field] is None or value is None else round(entry[field] + value, digits)
        entry["threads_ran"] += row["threads_ran"]
        if row.get("role"):
            entry["roles"] = sorted(set(entry.get("roles", [])) | {row["role"]})
    for name, entry in kinds.items():
        rows = [row for row in result["processes"] if row["kind"] == name]
        for field, digits in SUMMED_WHEN_PRESENT.items():
            values = [row.get(field) for row in rows]
            if all(isinstance(v, (int, float)) for v in values):
                entry[field] = round(sum(values), digits)
            elif any(isinstance(v, (int, float)) for v in values):
                entry[field] = None  # some processes reported it, others did not: unknown, not their sum
    if "main_wakes_per_s" in result and "app" in kinds:
        kinds["app"]["main_wakes_per_s"] = result["main_wakes_per_s"]
    return kinds


def energy_summary(kinds):
    """{"per_kind": {kind: {cpu, billed}}, "tree": {cpu, billed}} in mW: the CPU energy and the billed energy
    (aggregate's energy_mw_cpu and energy_mw_billed) of each kind and of the whole process set."""
    per_kind = {name: {"cpu": entry["energy_mw_cpu"], "billed": entry["energy_mw_billed"]}
                for name, entry in kinds.items()}
    tree = {field: round(sum(e[field] for e in per_kind.values()), 3) for field in ("cpu", "billed")}
    return {"per_kind": per_kind, "tree": tree}


def saver_mismatch(asked, observed):
    """Why the window's saver state is not the one the session asked for, or None. `observed` is the saver state
    debug.energy reported at each end (None: the build has no debug.energy). A session that asks for the saver
    needs both ends to show it; a session that asks for normal mode fails only on an end that shows the saver."""
    if asked and not all(state is True for state in observed):
        return f"asked energy saver on, debug.energy reported {observed}"
    if not asked and any(state is True for state in observed):
        return f"asked energy saver off, debug.energy reported {observed}"
    return None


def worst_thermal(states):
    """The hottest of `states` (ProcessInfo.thermalState names; None is unknown), or None when none is known."""
    known = [s for s in states if s in procs.THERMAL_STATES]
    return max(known, key=procs.THERMAL_STATES.index) if known else None


def thermal_marked(state):
    """Rows taken at serious or critical are marked: the Mac throttles, so the numbers are not comparable."""
    return state in ("serious", "critical")


def window_assertions(start, end):
    """The power assertions of the window's two reads, one entry per assertion (owning pid and assertion ID; its
    age differs between the reads) in first-seen order, each the latest read of it."""
    by_id = {}
    for item in (start or []) + (end or []):
        by_id[(item["pid"], item["id"])] = item
    return list(by_id.values())


def summarize(session, result, budget):
    """The report entry of one measured window: kinds, overs, energy_mw, assertions, saver, thermal (and the
    animated page's rAF rate when the session has one)."""
    spec = SESSIONS[session]
    ends = result.get("ends") or {}
    start, end = ends.get("start") or {}, ends.get("end") or {}
    kinds = aggregate(result)
    thermal = worst_thermal([start.get("thermal"), end.get("thermal")])
    marked = thermal_marked(thermal)
    if marked:
        for entry in kinds.values():
            entry["thermal_marked"] = True
    observed = [start.get("saver"), end.get("saver")]
    entry = {"result": result, "kinds": kinds, "energy_mw": energy_summary(kinds),
             "assertions": window_assertions(start.get("assertions"), end.get("assertions")),
             "saver": {"asked": spec.get("saver", False), "observed": observed,
                       "reason": end.get("saver_reason") or start.get("saver_reason"),
                       "mismatch": saver_mismatch(spec.get("saver", False), observed)},
             "thermal": {"start": start.get("thermal"), "end": end.get("thermal"), "worst": thermal, "marked": marked}}
    if spec.get("anim"):
        entry["anim"] = anim_rate(start.get("anim"), end.get("anim"))
    if spec.get("power"):
        # A power session is reported, never judged: it has no budget row, and the default kinds are not its budget.
        entry["over"], entry["not_judged"] = [], []
        return entry
    entry["over"] = [list(o) for o in over_budget(session, kinds, budget, window_facts(entry))]
    entry["not_judged"] = sum_notes(session, kinds, budget) + deferred_notes(session, kinds, budget)
    return entry


def window_facts(entry):
    """over_budget's `facts` of one summarized window: the animated page's rAF rate, the saver state and reason
    both ends agree on (none when an end did not report one) and the power assertions held by the pid set."""
    facts = {"assertions": entry["assertions"]}
    observed = entry["saver"]["observed"]
    if observed and isinstance(observed[0], bool) and all(state == observed[0] for state in observed):
        facts["saver"] = observed[0]
        if entry["saver"]["reason"] is not None:
            facts["saver_reason"] = entry["saver"]["reason"]
    rate = (entry.get("anim") or {}).get("raf_per_s")
    if isinstance(rate, (int, float)):
        facts["page_raf_per_s"] = rate
    return facts


def refusals(entry):
    """[(what, why)] that refuse a session's window under --gate: it did not run the shipping configuration
    (``shipping_refusals``), its saver state is not the one it asked for, or its animated page's rAF rate (D7's
    number) could not be read."""
    out = shipping_refusals(entry)
    if entry["saver"]["mismatch"]:
        out.append(("saver", entry["saver"]["mismatch"]))
    if "error" in (entry.get("anim") or {}):
        out.append(("anim", f"no page rAF rate: {entry['anim']['error']}"))
    return out + agent_refusals(entry.get("agents"), (entry.get("result") or {}).get("processes") or [])


def agent_refusals(agents, rows):
    """[(what, why)] for an agent session (build_agents's record) whose window did not measure the harnesses it
    built: no agent-harness row under the hidden chat's host, or none under a pooled host. A harness that exited
    has no row, and a limit on a kind with no row passes, so the D14 hidden-harness row would pass unmeasured."""
    if not agents:
        return []
    plan = agents.get("plan") or {}
    hosts = {row.get("agent_host") for row in rows if row.get("kind") == procs.AGENT_HARNESS}
    out = []
    if plan.get("hidden") and not hosts & set(agents.get("hidden_hosts") or ()):
        out.append(("agents", f"no agent-harness row under the hidden chat's host {agents.get('hidden_hosts')}"))
    if plan.get("pool") and not hosts & set(agents.get("pool_hosts") or ()):
        out.append(("agents", f"no agent-harness row under a pooled host {agents.get('pool_hosts')}"))
    return out


def exit_code(gate, overs, refused):
    """1 under --gate when a value is over its budget or a session was refused (`refusals`), else 0."""
    return 1 if gate and (overs or refused) else 0


def session_budget(budget, session):
    return (budget.get("sessions") or {}).get(session) or {}


def busy_kind(own, name):
    """Whether kind `name` takes only the session's own values: every kind of a reference session (Chrome) or of a
    session with `busy: true` (an agent at work), else a kind that matches one of the session's `busy` patterns
    (STRESS's animating pages: `cef-*`)."""
    busy = own.get("busy")
    if own.get("reference") or busy is True:
        return True
    return any(fnmatch.fnmatchcase(name, pattern) for pattern in busy or [])


def limit_for(budget, session, name, field):
    """The limit of `field` for kind `name` in `session`: the session's own value (an explicit null there means
    not judged), else the kind's default (one number or {session: number}), else all_kinds. A busy kind
    (busy_kind) takes only the session's own values."""
    own = session_budget(budget, session)
    kind_limits = (own.get("kinds") or {}).get(name) or {}
    if field in kind_limits:
        return kind_limits[field]
    if busy_kind(own, name):
        return None
    defaults = (budget.get("kinds") or {}).get(name) or {}
    if field in defaults:
        limit = defaults[field]
        return limit.get(session) if isinstance(limit, dict) else limit
    return (budget.get("all_kinds") or {}).get(field)


def limited_fields(budget, session, name):
    own = session_budget(budget, session)
    fields = set((own.get("kinds") or {}).get(name) or {})
    if not busy_kind(own, name):
        fields |= set((budget.get("kinds") or {}).get(name) or {}) | set(budget.get("all_kinds") or {})
    return sorted(f for f in fields if not f.startswith("_"))


def selected(kinds, selector):
    """The kinds of `selector` that ran ('tree': every kind; 'app+daemon': those of app and daemon that ran)."""
    return list(kinds) if selector == "tree" else [n for n in selector.split("+") if n in kinds]


def selector_value(kinds, selector, field):
    """`field` summed over the selected kinds that ran; None when none ran, or when one of them has the field None
    or lacks it: an unknown is never a 0, so a partial sum is not a value."""
    values = [(kinds[n] or {}).get(field) for n in selected(kinds, selector)]
    if not values or not all(isinstance(v, (int, float)) for v in values):
        return None
    return round(sum(values), 4)


def unknown_sum(kinds, selector, field):
    """Whether `selector` ran but its sum of `field` is unknown."""
    return bool(selected(kinds, selector)) and selector_value(kinds, selector, field) is None


def setting_on(value):
    return value not in (None, False, "off", "never", 0, "")


def over_budget(session, kinds, budget, facts=None):
    """[(subject, field, value, limit)] for every value of one session over its budget (or a role or expected state
    that differs). `facts`: the session's measurements outside the kinds (page_raf_per_s, saver, saver_reason,
    `assertions` held by cmux pids, the effective `settings`). cross_overs judges the rows that compare sessions."""
    facts = facts or {}
    own = session_budget(budget, session)
    out = []
    for name in sorted(kinds):
        entry = kinds[name]
        for field in limited_fields(budget, session, name):
            limit = limit_for(budget, session, name, field)
            if limit is None:
                continue
            if field == "role":
                roles = entry.get("roles") or []
                if roles and roles != [limit]:
                    out.append((name, "role", ",".join(roles), limit))
                continue
            value = entry.get(field)
            if isinstance(value, (int, float)) and value > limit:
                out.append((name, field, value, limit))
    for selector, limits in (own.get("sums") or {}).items():
        for field, limit in limits.items():
            value = selector_value(kinds, selector, field)
            if limit is not None and value is not None and value > limit:
                out.append((selector, field, value, limit))
    for field, limit in (own.get("limits") or {}).items():
        value = facts.get(field)
        if limit is not None and isinstance(value, (int, float)) and value > limit:
            out.append(("session", field, value, limit))
    for field, expected in (own.get("expect") or {}).items():
        if field in facts and facts[field] != expected:
            out.append(("session", field, facts[field], expected))
    return out + assertion_overs(own, budget, facts)


def assertion_overs(own, budget, facts):
    """D11: in an idle session every pmset assertion held by a cmux pid is an over, unless the session itself turns
    on one of `assertions_allowed_when` in its `settings`. Every other session runs with them off (KEEP_AWAKE_OFF;
    their shipping default pluggedIn holds an assertion while an agent works or a phone serves), and an effective
    value in `facts.settings` other than the session's is an over too. Busy sessions (a working agent holds
    keep-awake) and reference sessions are not judged."""
    if own.get("reference") or own.get("busy") is True:
        return []
    keys = budget.get("assertions_allowed_when") or []
    asked, effective = own.get("settings") or {}, facts.get("settings") or {}
    out = [("session", key, effective[key], asked.get(key, "off")) for key in keys
           if key in effective and setting_on(effective[key]) != setting_on(asked.get(key))]
    held = facts.get("assertions") or []
    if held and not any(setting_on(asked.get(key)) for key in keys):
        out.append(("assertions", "held", len(held), 0))
    return out


def cross_overs(budget, measured, unequal=None):
    """The rows that compare sessions of one run, judged once after every session is measured, so the order of
    --sessions does not matter: each session's `relative` rows and the ratio_to_chrome rows (chrome_rows: the
    one judgement of those). `measured`: {session: kinds}; `unequal`: {session: [reason]} why chrome-static is no
    fair reference for that session (chrome_unequal). Returns ([(session, over)], [note]); a note names each row
    not judged and why."""
    overs, notes = [], []

    def judge(session, of, field, vs, to, max_ratio, suffix):
        kinds, reference = measured[session], measured.get(to)
        label = f"{session} {of} {field}{suffix}"
        if reference is None:
            notes.append(f"{label}: not judged: reference session {to} not measured")
            return
        for selector, rows in ((of, kinds), (vs, reference)):
            if unknown_sum(rows, selector, field):
                notes.append(f"{label}: not judged: {selector} {field} unknown")
                return
        overs.extend((session, over) for over in ratio_over(of, field, kinds, vs, reference, max_ratio, suffix))

    for session in measured:
        for rule in session_budget(budget, session).get("relative") or []:
            judge(session, rule["of"], rule["field"], rule["of"], rule["to"], rule["max_ratio"], f"/{rule['to']}")
    for row in chrome_rows(budget, measured, unequal):
        if row["verdict"] == "over":
            overs.append((row["session"], tuple(row["over"])))
        elif row["verdict"] != "ok":
            notes.append(row["note"])
    return overs, notes


def chrome_rows(budget, measured, unequal=None):
    """One row per ratio_to_chrome rule whose session was measured, against chrome-static: cmux and Chrome values,
    the ratio, the noise floor it used, and a verdict: ok, over (`over`: the over tuple), or `not judged` with the
    reason in `note`: chrome-static not measured, a side unknown or not run, Chrome's value 0 with no floor, or
    `unequal` (the reasons, also in `unequal`). cross_overs takes its overs and notes from here, the report its rows."""
    reference = measured.get(CHROME_SESSION)
    rows = []
    for rule in budget.get("ratio_to_chrome") or []:
        session, of, vs, field = rule["session"], rule["of"], rule["vs"], rule["field"]
        if session not in measured or session == CHROME_SESSION:
            continue
        kinds, suffix = measured[session], f"/chrome:{vs}"
        row = {"session": session, "of": of, "vs": vs, "field": field, "max_ratio": rule["max_ratio"],
               "cmux_value": selector_value(kinds, of, field),
               "chrome_value": None if reference is None else selector_value(reference, vs, field),
               "floor": None, "ratio": None, "verdict": "ok"}
        why = None
        if reference is None:
            why = f"reference session {CHROME_SESSION} not measured"
        else:
            for selector, values, side in ((of, kinds, "cmux"), (vs, reference, "Chrome")):
                if unknown_sum(values, selector, field):
                    why = f"{selector} {field} unknown"
                    break
                if not selected(values, selector):
                    why = f"{side} ran no {selector}"
                    break
        if why is None and (unequal or {}).get(session):
            row["unequal"] = list(unequal[session])
            why = "unequal: " + "; ".join(row["unequal"])
        if why is None:
            floor = RATIO_FLOORS.get(field)
            row["ratio"], row["floor"] = ratio_of(row["cmux_value"], row["chrome_value"], floor)
            over = ratio_over(of, field, kinds, vs, reference, rule["max_ratio"], suffix, floor)
            if row["ratio"] is None:
                why = f"Chrome's {vs} {field} is 0 and the field has no noise floor"
            elif over:
                row["verdict"], row["over"] = "over", list(over[0])
        if why is not None:
            row["verdict"], row["note"] = "not judged", f"{session} {of} {field}{suffix}: not judged: {why}"
        rows.append(row)
    return rows


def sum_notes(session, kinds, budget):
    """The session's sum rows not judged because a selected kind's value is unknown."""
    return [f"{session} {selector} {field}: not judged: unknown"
            for selector, limits in (session_budget(budget, session).get("sums") or {}).items()
            for field, limit in limits.items() if limit is not None and unknown_sum(kinds, selector, field)]


def deferred_notes(session, kinds, budget):
    """The session's kind limits set to null with a `_<field>` reason (a row a later task turns on): reported as
    not judged, with the measured value and that reason, so the gap shows in every run."""
    notes = []
    for name, limits in sorted((session_budget(budget, session).get("kinds") or {}).items()):
        for field, limit in sorted(limits.items()):
            reason = limits.get("_" + field)
            if field.startswith("_") or limit is not None or not reason:
                continue
            value = (kinds.get(name) or {}).get(field, "not measured")
            notes.append(f"{session} {name} {field}: not judged: {value} measured; {reason}")
    return notes


def xbench_overs(budget, result):
    """D6 on an xbench.py result (results.json: rows.<row>.<browser>.median). An `xbench` row with `max_ratio`
    compares the browser's median with `vs` (default chrome); one with `max` is absolute. Returns ([over], [note])."""
    rows = (result or {}).get("rows") or {}
    overs, notes = [], []
    for rule in budget.get("xbench") or []:
        per = rows.get(rule["row"]) or {}
        value = (per.get(rule["browser"]) or {}).get("median")
        label = f"xbench {rule['browser']} {rule['row']}"
        if not isinstance(value, (int, float)):
            notes.append(f"{label}: not judged: not measured")
        elif "max" in rule:
            if value > rule["max"]:
                overs.append((rule["browser"], rule["row"], value, rule["max"]))
        else:
            vs = rule.get("vs", "chrome")
            base = (per.get(vs) or {}).get("median")
            if not isinstance(base, (int, float)) or not base:
                notes.append(f"{label}: not judged: {vs} not measured")
            elif round(value / base, 3) > rule["max_ratio"]:
                overs.append((rule["browser"], f"{rule['row']}/{vs}", round(value / base, 3), rule["max_ratio"]))
    return overs, notes


# The noise floors a Chrome reference value is raised to (the cron rows' floors, CRON_FLOORS and CRON_SUM_FLOORS):
# Chrome's GPU process at 0 wakeups against cmux's at 1 in a minute is idle noise, not an infinite ratio, while
# cmux at 3/s against it is 6 times the floor.
RATIO_FLOORS = {"wakeups_per_s": 0.5, "wakeups_max": 0.5, "hidden_wakeups_max": 0.5, "main_wakes_per_s": 0.5,
                "energy_mw_billed": 1.0, "energy_mw_cpu": 1.0, "gpu_ms_per_s": 1.0, "threads": 2, "threads_max": 2}


def ratio_of(value, base, floor=None):
    """(value / reference, the floor used or None). A reference below `floor` counts as the floor; a reference of
    0 with no floor, or a side not measured, gives (None, None): no ratio."""
    if value is None or base is None:
        return None, None
    used = floor if floor and base < floor else None
    base = used or base
    return (round(value / base, 3), used) if base else (None, None)


def ratio_over(of, field, kinds, vs, reference, max_ratio, suffix, floor=None):
    """[(of, field + suffix, ratio, max)] when `of` in `kinds` over `vs` in `reference` is above `max_ratio`; a
    reference of 0 or one that was not measured judges nothing. With `floor`, a reference below it counts as the
    floor and the field says so (`:floor`), so the printed ratio is the one compared."""
    ratio, used = ratio_of(selector_value(kinds, of, field), selector_value(reference, vs, field), floor)
    if ratio is None or ratio <= max_ratio:
        return []
    return [(of, field + suffix + (":floor" if used else ""), ratio, max_ratio)]


def over_line(session, over):
    name, field, value, limit = over
    relation = ">" if isinstance(limit, (int, float)) and not isinstance(limit, bool) else "!="
    return f"IDLE-BUDGET-OVER {session} {name} {field} {value} {relation} {limit}"


def load_budget(path):
    """The budget file; a v1 file (kinds only) is read as v2 with no session overrides."""
    with open(path) as handle:
        budget = json.load(handle)
    budget.setdefault("version", 1)
    for key in ("kinds", "sessions", "all_kinds"):
        budget.setdefault(key, {})
    for key in ("ratio_to_chrome", "xbench", "allowed_periodic", "assertions_allowed_when"):
        budget.setdefault(key, [])
    return budget


# Noise floors of the cron rows: one wakeup a second, two threads (a pool thread parks or exits late).
CRON_FLOORS = {"wakeups_per_s": 0.5, "wakeups_max": 0.5, "main_wakes_per_s": 0.5, "threads_max": 2, "threads": 2,
               "energy_mw_billed": 1.0, "gpu_ms_per_s": 1.0}
CRON_UNITS = {"threads_max": "threads", "threads": "threads", "energy_mw_billed": "mW", "energy_mw_cpu": "mW",
              "gpu_ms_per_s": "ms/s"}
# The sums every session reports, plus the ones its budget names.
CRON_SUMS = ("app+daemon", "tree")
CRON_SUM_FLOORS = {"wakeups_per_s": 0.5, "energy_mw_billed": 1.0, "energy_mw_cpu": 1.0}


def cron_rows(report, budget=None):
    """{row: {p50, p95, unit, budget, floor}} for the perf cron (scripts/cmux-next/perf-cron.py) from one
    idle-budget report: `idle_budget.<session>.<kind>.<field>` and the sums `idle_budget.<session>.<selector>.<field>`,
    one value per run (p50 = p95)."""
    budget = budget if budget is not None else load_budget(BUDGET_FILE)
    out = {}
    for session, entry in ((report or {}).get("sessions") or {}).items():
        kinds = entry.get("kinds") or {}
        for name, values in kinds.items():
            for field, floor in CRON_FLOORS.items():
                value = values.get(field)
                if not isinstance(value, (int, float)):
                    continue
                unit = CRON_UNITS.get(field, "/s")
                out[f"idle_budget.{session}.{name}.{field}"] = {"p50": value, "p95": value, "unit": unit,
                                                                 "budget": limit_for(budget, session, name, field),
                                                                 "floor": floor}
        sums = session_budget(budget, session).get("sums") or {}
        for selector in dict.fromkeys([*CRON_SUMS, *sums]):
            for field, floor in CRON_SUM_FLOORS.items():
                value = selector_value(kinds, selector, field)
                if value is None:
                    continue
                out[f"idle_budget.{session}.{selector}.{field}"] = {
                    "p50": value, "p95": value, "unit": CRON_UNITS.get(field, "/s"),
                    "budget": (sums.get(selector) or {}).get(field), "floor": floor}
    return out


# ---------------------------------------------------------------------------------------------------------
# The Chrome reference (chrome-static): a Chromium with the tabs-static pages and the uBlock Origin cmux bundles

CHROME_SESSION = "chrome-static"
CHROME_APP = "/Applications/Chromium.app"  # where ungoogled-chromium installs (the comment above BRANDED_CHROME_IDS)
UBLOCK_ID = "cjpalhdlnbpafiamejdnhcphjbkeiagm"  # fetch-ublock.sh keeps the Web Store key, so the id is stable
UBLOCK_IN_APP = "Contents/Resources/Extensions/ublock-origin"  # bundle-ublock.sh
# Google Chrome's kinds from tab_pages' --type classifier (the switches cmux's helpers carry too). Chrome's
# helpers are not in a cmux Helper app, so chromium_kind does not apply; any other --type is `other`.
CHROME_KINDS = {"cef-renderer": "renderer", "cef-extension": "extension", "cef-gpu": "gpu", "cef-utility": "utility",
                "cef-helper": "other"}
# Builds that cannot run the bundled uBlock Origin (Manifest V2, loaded with --load-extension): branded Google
# Chrome ignores --load-extension from 137 and has no switch back from 142 (Chromium 04f6233ce5be: the
# GOOGLE_CHROME_BRANDING check in extensions' command-line loader); Chromium runs no MV2 extension from 139, and
# Chrome for Testing carries no patch for it. cmux's CEF runs MV2 through cmux_extensions_manifestv2.patch, from
# ungoogled-chromium (plans/cmux-next/browser.md), so ungoogled-chromium of cmux's Chromium major is the reference.
# A plain Chromium has the same bundle id as ungoogled-chromium, so only the run tells them apart: uBlock Origin
# does not start, the rows are unequal and --gate refuses.
BRANDED_CHROME_IDS = ("com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary")
CHROME_FOR_TESTING_ID = "com.google.chrome.for.testing"
LOAD_EXTENSION_GONE_MAJOR = 137
MANIFEST_V2_GONE_MAJOR = 139


def chrome_kind(cmd):
    """The kind of a Chrome process: browser, renderer, extension, gpu, utility, crashpad, other (Chromium's
    process types, content/public/common/content_switches.cc; an extension's renderer carries
    --extension-process, extensions/common/switches.cc; Crashpad's handler runs with no --type)."""
    typed = tab_pages.process_type_kind(cmd)
    if typed:
        return CHROME_KINDS[typed]
    exe = cmd.split(" --", 1)[0].strip()
    if os.path.basename(exe) == "chrome_crashpad_handler":
        return "crashpad"
    if exe.count(".app/") == 1 and "/Contents/MacOS/" in exe:
        return "browser"
    return "other:" + os.path.basename(exe)[:32]


def read_manifest(folder):
    """The manifest.json of an unpacked extension folder, or None when it has no readable one."""
    try:
        with open(os.path.join(folder, "manifest.json")) as handle:
            manifest = json.load(handle)
    except (OSError, ValueError):
        return None
    return manifest if isinstance(manifest, dict) else None


def manifest_version(folder):
    """The `version` of an unpacked extension folder, or None when it has no readable manifest."""
    return (read_manifest(folder) or {}).get("version")


def major_version(version):
    head = str(version or "").split(".", 1)[0]
    return int(head) if head.isdigit() else None


def reference_refusal(bundle_id, version, manifest):
    """Why the browser `bundle_id` at `version` cannot run the extension of `manifest` loaded with
    --load-extension, or None when it may (whether it did is checked when it runs)."""
    major = major_version(version)
    if major is None:
        return None
    if bundle_id in BRANDED_CHROME_IDS and major >= LOAD_EXTENSION_GONE_MAJOR:
        return f"branded Google Chrome {version} ignores --load-extension (Chrome {LOAD_EXTENSION_GONE_MAJOR}+)"
    if manifest.get("manifest_version") == 2 and bundle_id == CHROME_FOR_TESTING_ID and major >= MANIFEST_V2_GONE_MAJOR:
        return (f"Chrome for Testing {version} runs no Manifest V2 extension (Chromium {MANIFEST_V2_GONE_MAJOR}+); "
                f"uBlock Origin {manifest.get('version')} is MV2")
    return None


def ublock_parity(cmux_version, cmux_running, chrome_version, chrome_running):
    """Whether both sides ran the same uBlock Origin: `*_version` the copy each side has (None: none), `*_running`
    whether it ran in the measured session (chrome_unequal's rule). Without it one side does less work, so the
    reference is unequal and its ratio rows are reported, not judged."""
    unequal = []
    if cmux_version is None:
        unequal.append("the cmux app bundles no uBlock Origin")
    elif not cmux_running:
        unequal.append(f"uBlock Origin {cmux_version} did not run in the cmux session (no cef-extension process)")
    if chrome_version is None:
        unequal.append("no uBlock Origin was loaded into Chrome")
    elif not chrome_running:
        unequal.append(f"uBlock Origin {chrome_version} did not run in Chrome (no extension target or process)")
    if cmux_version and chrome_version and cmux_version != chrome_version:
        unequal.append(f"uBlock Origin {chrome_version} in Chrome, {cmux_version} in cmux")
    return {"id": UBLOCK_ID, "cmux_version": cmux_version, "chrome_version": chrome_version,
            "cmux_running": bool(cmux_running), "chrome_running": bool(chrome_running), "equal": not unequal,
            "unequal": unequal}


def kind_ran(kinds, name):
    return bool((kinds.get(name) or {}).get("n"))


def chrome_unequal(kinds, chrome):
    """(parity, reasons) of chrome-static (its block `chrome`, with its `kinds`) as the reference of a cmux session
    measured as `kinds`. The same rule on both sides: uBlock Origin ran when an extension renderer was measured in
    the window (cmux: cef-extension; Chrome: extension, and DevTools listed uBlock Origin's own target, as Chrome
    may run component extensions). The reasons add chrome's own shape reasons (chrome_shape_unequal)."""
    ublock = chrome.get("ublock") or {}
    parity = ublock_parity(ublock.get("cmux_version"), kind_ran(kinds, "cef-extension"), ublock.get("chrome_version"),
                           bool(ublock.get("running")) and kind_ran(chrome.get("kinds") or {}, "extension"))
    return parity, list(chrome.get("unequal") or []) + parity["unequal"]


def chrome_shape_unequal(page_targets, visibility, keys):
    """Why Chrome's pages at the window's end are not tabs-static's shape: one page target per key of `keys` (the
    tab_plan's loaded keys in opening order, the last one shown), the last visible and every other hidden
    (`visibility`: the static pages' last document.visibilityState reports)."""
    reasons = []
    if page_targets != len(keys):
        reasons.append(f"Chrome had {page_targets} page targets, tabs-static has {len(keys)}")
    want = {key: "visible" if index == len(keys) - 1 else "hidden" for index, key in enumerate(keys)}
    wrong = [f"{key}={visibility.get(key)}" for key in want if visibility.get(key) != want[key]]
    if wrong:
        reasons.append(f"Chrome's tab visibility is not 1 shown, {len(keys) - 1} hidden: " + ", ".join(wrong))
    return reasons


def template_key(bundle, version, ublock, ublock_version):
    """The template profile's key: a profile built by another browser build or with another uBlock Origin (or
    none) is another template."""
    text = json.dumps([os.path.realpath(bundle), version, ublock and os.path.realpath(ublock), ublock_version])
    return hashlib.sha256(text.encode()).hexdigest()[:12]


def chrome_refusals(asked, entry, rows):
    """Why --gate cannot pass on the Chrome ratios: chrome-static was asked (`asked`) and failed (`entry`), or a
    ratio row of a measured session is unequal. A reference that can never judge must not pass in silence."""
    if not asked:
        return []
    if not entry or entry.get("exit") or not entry.get("kinds"):
        return [f"{CHROME_SESSION} not measured: {(entry or {}).get('error', 'no result')}"[:400]]
    return list(dict.fromkeys(f"{row['session']}: {reason}" for row in rows for reason in row.get("unequal") or []))


def judge_across(report, budget, chrome_asked=False):
    """After every session ran: the cross-session rows (cross_overs) with each session's chrome-static parity,
    so the --sessions order does not matter. Puts `not_judged`, and with chrome-static measured the `chrome` block
    (with each session's uBlock Origin parity) and the `ratio_to_chrome` rows into `report`, each over into its
    session's `over`. Returns (overs [(session, over)], notes, refused: chrome_refusals)."""
    sessions = report["sessions"]
    measured = {name: done["kinds"] for name, done in sessions.items() if done.get("kinds")}
    chrome = chrome_reference(report)
    unequal = {}
    if chrome:
        chrome["parity"] = {}
        for name, kinds in measured.items():
            if not SESSIONS.get(name, {}).get("chrome"):
                chrome["parity"][name], unequal[name] = chrome_unequal(kinds, chrome)
        report["chrome"] = chrome
    overs, notes = cross_overs(budget, measured, unequal)
    rows = chrome_rows(budget, measured, unequal)
    if chrome:
        report["ratio_to_chrome"] = rows
    for name, over in overs:
        sessions[name].setdefault("over", []).append(list(over))
    report["not_judged"] = notes
    return overs, notes, chrome_refusals(chrome_asked, sessions.get(CHROME_SESSION), rows)


def ratio_table(rows):
    lines = ["\n### ratio to Chrome (chrome-static)\n",
             "| session | cmux | Chrome | field | cmux value | Chrome value | floor | ratio | max | verdict |",
             "|---|---|---|---|---|---|---|---|---|---|"]
    for row in rows:
        verdict = ("**over**" if row["verdict"] == "over" else
                   row["note"].split(": not judged: ", 1)[-1] if row["verdict"] != "ok" else "ok")
        lines.append(f"| {row['session']} | {row['of']} | {row['vs']} | {row['field']} | {row['cmux_value']} | "
                     f"{row['chrome_value']} | {row['floor'] or '-'} | {row['ratio']} | {row['max_ratio']} | {verdict} |")
    return "\n".join(lines)


# ---------------------------------------------------------------------------------------------------------
# Sessions


def load_stress():
    import importlib.util
    spec = importlib.util.spec_from_file_location("perf_stress_session", STRESS_FILE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# The animated page of energy-saver: one box turned on every rAF, the count in window.__rafCount. It reports
# /loaded/anim as the shared static page reports /loaded/<n>, then keeps one GET of ANIM_READ_PATH open: the
# server holds it until the bench reads (IdlePages.read_anim), and the page then POSTs
# ANIM_COUNT_PATH/<count>/<performance.now()>/<visibilityState> and asks again. A held request runs no timer in the
# page, so the read path costs no wake inside the window and needs no DevTools port (Release builds have none).
ANIM_PATH = "/anim"
ANIM_READ_PATH = "/anim-read"
ANIM_COUNT_PATH = "/anim-count"
ANIM_PAGE = ("<!doctype html><meta charset='utf-8'><title>idle anim</title>"
             "<style>body{margin:0;background:#f4f4f6}#b{width:64px;height:64px;margin:40px;border-radius:12px;"
             "background:#20304a}</style><div id='b'></div><script>window.__rafCount=0;"
             "const b=document.getElementById('b');requestAnimationFrame(function f(){window.__rafCount++;"
             "b.style.transform='rotate('+(window.__rafCount*3%360)+'deg)';requestAnimationFrame(f)});"
             f"function ask(){{fetch('{ANIM_READ_PATH}',{{cache:'no-store'}}).then(function(){{"
             f"return fetch('{ANIM_COUNT_PATH}/'+window.__rafCount+'/'+performance.now()+'/'+document.visibilityState,"
             "{method:'POST'})}).then(ask,function(){setTimeout(ask,1000)})}"
             "fetch('/loaded/anim',{method:'POST'}).then(ask)</script>")


def parse_anim_count(path):
    """{count, t_ms, visibility} from the page's ANIM_COUNT_PATH POST, or {"error": ...}."""
    parts = path.split("?", 1)[0].removeprefix(ANIM_COUNT_PATH + "/").split("/")
    try:
        return {"count": int(parts[0]), "t_ms": float(parts[1]), "visibility": parts[2]}
    except (IndexError, ValueError):
        return {"error": f"unreadable rAF count post {path[:80]}"}


class IdlePages(tab_pages.TabPages):
    """The shared tab-page server plus energy-saver's animated page at ANIM_PATH and its read path."""

    def __init__(self, *args, **kwargs):
        self._anim = threading.Condition()
        self._anim_asked = 0  # reads the bench asked for (read_anim)
        self._anim_answered = 0  # reads a held ANIM_READ_PATH GET answered; a GET is held while this equals asked
        self._anim_reads = []  # the page's parsed ANIM_COUNT_PATH posts, in order
        super().__init__(*args, **kwargs)

    def body(self, path):
        path = path.split("?", 1)[0]
        if path == ANIM_PATH:
            return ANIM_PAGE.encode()
        if path == ANIM_READ_PATH:
            with self._anim:
                self._anim.wait_for(lambda: self._anim_asked > self._anim_answered or self.closing.is_set())
                self._anim_answered = self._anim_asked
            return b""
        return super().body(path)

    def report(self, path):
        if path.startswith(ANIM_COUNT_PATH + "/"):
            with self._anim:
                self._anim_reads.append(parse_anim_count(path))
                self._anim.notify_all()
            return
        super().report(path)

    def read_anim(self, seconds=10):
        """The animated page's {count, t_ms, visibility} now: answers the page's held read and waits for the count
        it posts (a read asked before the page's next GET arrives is answered by that GET); {"error": ...} when none
        comes in `seconds`."""
        with self._anim:
            posted = len(self._anim_reads)
            self._anim_asked += 1
            self._anim.notify_all()
            if not self._anim.wait_for(lambda: len(self._anim_reads) > posted, seconds):
                return {"error": f"the page posted no rAF count in {seconds:g} s (no held {ANIM_READ_PATH})"}
            return self._anim_reads[posted]

    def close(self):
        """Ends the held reads with the other held loads."""
        super().close()
        with self._anim:
            self._anim.notify_all()

    def wait_loaded(self, key, seconds):
        """True once the page `key` reported /loaded/<key>, False after `seconds`."""
        deadline = time.monotonic() + seconds
        while key not in self.loaded:
            if time.monotonic() > deadline:
                return False
            time.sleep(0.2)  # bench: bounded wait for the tab's page to load
        return True


class SessionShapeError(RuntimeError):
    """The session could not be built as its table entry says (a tab that never opened, a window not minimized)."""


def run_action(app, action, args=None, focus=False, timeout=30):
    """action.run from a script; raises SessionShapeError on the app's refusal. A reply that times out is no
    refusal (a cold CefInitialize can outlast the reply while the tab still opens): the caller checks the result.
    `focus` selects what the action opens, as STRESS and browser-idle-cost-live open their tabs."""
    reply = app.rpc("action.run", {"action": action, "args": args or {}, "focus": focus, "origin": "script"},
                    timeout=timeout)
    error = reply.get("error") if isinstance(reply, dict) else None
    code = error.get("code") if isinstance(error, dict) else None
    if error and code != "timeout" and not (isinstance(reply, dict) and reply.get("unreachable")):
        raise SessionShapeError(f"{action} refused: {str(error)[:200]}")
    return reply


def tab_plan(pages, tabs):
    """[(engine, url, loaded key)] of a session's tabs in opening order: the hidden WebKit tabs, the hidden Chromium
    tabs, then the shown Chromium tab (`tabs["shown"]`: "static" or "anim")."""
    plan = ([("webkit", pages.url("static", f"w{n}"), f"w{n}") for n in range(tabs["webkit_hidden"])]
            + [("chromium", pages.url("static", f"c{n}"), f"c{n}") for n in range(tabs["chromium_hidden"])])
    if tabs["shown"] == "anim":
        return plan + [("chromium", pages.origin + ANIM_PATH, "anim")]
    return plan + [("chromium", pages.url("static", "shown"), "shown")]


def build_tabs(app, pages, tabs):
    """Opens the session's tabs (tab_plan) in the launch pane; a new tab is selected, so every earlier one is hidden
    behind the last. Waits for each page to load. Returns {engine: count} of the opened tabs."""
    opened = {}
    for engine, url, key in tab_plan(pages, tabs):
        run_action(app, f"openBrowser.{engine}", {"url": url}, focus=True, timeout=90)
        if not pages.wait_loaded(key, 90):
            raise SessionShapeError(f"{engine} tab {url} did not load in 90 s")
        opened[engine] = opened.get(engine, 0) + 1
    return opened


def anim_rate(start, end):
    """{raf_per_s, visibility} of the animated page between two IdlePages.read_anim results (the page's own clock),
    or the first error."""
    for read in (start, end):
        if not isinstance(read, dict) or "error" in read or not isinstance(read.get("count"), (int, float)):
            return {"error": (read or {}).get("error", "no rAF count") if isinstance(read, dict) else "not read"}
    seconds = (end["t_ms"] - start["t_ms"]) / 1000
    if seconds <= 0:
        return {"error": "the page clock did not advance"}
    return {"raf_per_s": round((end["count"] - start["count"]) / seconds, 2), "seconds": round(seconds, 1),
            "visibility": [start.get("visibility"), end.get("visibility")]}


def build_stress(app, static=False):
    """STRESS, then its busy terminals stopped (Ctrl-C), so the terminals are quiet. With `static` its pages
    have no rAF spinner (STRESS's own pages animate, which is not idle)."""
    stress_module = load_stress()
    stress = stress_module.Stress(app.rpc)
    if static:
        stress.pages = tab_pages.TabPages(default_kind="grid")
    summary = stress.build()
    for tab in getattr(stress, "busy", []):
        stress.send(tab, "\x03")
    summary["busy_terminals_stopped"] = len(getattr(stress, "busy", []))
    print("STRESS-SESSION " + json.dumps(summary), flush=True)
    return summary


# ---------------------------------------------------------------------------------------------------------
# The agent sessions and busy-hidden (p14-energy-103, D14)

# The app runs its own acpmux home whose default harness is the ACP fake agent, as readiness-soak.py runs it: no
# network and no credential, but the same agent hosts and session pool a real harness gets.
FAKE_AGENT = os.path.join(HERE, "..", "..", "cmux-tui", "crates", "acpmux", "tests", "fake_agent.py")
AGENT_HARNESS_ID = "idle-budget-agent"
# p14-energy-117 freezes the harness of an idle hidden session this long after it hides (freezeAfterSeconds); agent-idle
# settles past it (FREEZE_GRACE_S more), so its rows are the frozen state D14 judges once 117 lands.
HARNESS_FREEZE_S = 300
# The pooled entry outlives the settle and the window (acpmux's default pool.idleMinutes is 10).
POOL_IDLE_MINUTES = 60
# How long acpmux, an agent page, a chat start or a turn may take to answer while the session is built.
AGENT_STEP_S = 60
# busy-hidden: the hidden terminal prints one line this often.
BUSY_PERIOD_S = 0.1


def agent_config(python, agent):
    """config.json of the session's acpmux home: the fake agent is the default harness, and a pooled entry stays
    for POOL_IDLE_MINUTES."""
    return {"harnesses": {AGENT_HARNESS_ID: {"argv": [python, agent]}}, "defaultHarness": AGENT_HARNESS_ID,
            "pool": {"idleMinutes": POOL_IDLE_MINUTES}}


def chat_session(reply):
    """The session id in a debug.agent_pane chat_state reply (its `result` is the page's JSON, as text or an
    object), or None."""
    if not isinstance(reply, dict) or "error" in reply:
        return None
    result = reply.get("result", reply)
    if isinstance(result, str):
        try:
            result = json.loads(result)
        except ValueError:
            return None
    return result.get("sessionId") if isinstance(result, dict) else None


def turn_done(entry):
    """Whether an acpmux session entry (`_acpmux/sessions`) finished a turn, runs none and still has its harness:
    `ready` (store.rs SessionStatus::Ready, child alive). `idle` is no child process: a harness that exited, which
    the session would then measure as nothing."""
    return entry.get("status") == "ready" and bool((entry.get("lastTurn") or {}).get("endedAt"))


def answered(reply):
    return isinstance(reply, dict) and "error" not in reply


class AgentHome:
    """The session's acpmux home and socket (ACPMUX_HOME, ACPMUX_SOCKET in the app's env, which its acpmux and agent
    hosts inherit): config.json (agent_config), the chats' folder, the gates of working turns, and JSON-RPC over
    the socket (one request per connection after `initialize`, as readiness-soak.py's Acpmux)."""

    def __init__(self, folder, session):
        self.folder = folder
        self.home = os.path.join(folder, "acpmux")
        self.cwd = os.path.join(folder, "agent-work")
        self.pool_cwd = os.path.join(folder, "agent-pool")
        # One socket per run, short enough for AF_UNIX (104 bytes) whatever --out is.
        self.socket = f"/tmp/idle-budget-acp-{os.getpid()}-{session}.sock"
        self.gates = []

    def env(self):
        return {"ACPMUX_HOME": self.home, "ACPMUX_SOCKET": self.socket}

    def write(self):
        shutil.rmtree(self.home, ignore_errors=True)
        for folder in (self.home, self.cwd, self.pool_cwd):
            os.makedirs(folder, exist_ok=True)
        agent = os.path.join(self.folder, "fake_agent.py")
        shutil.copy(FAKE_AGENT, agent)
        with open(os.path.join(self.home, "config.json"), "w") as handle:
            json.dump(agent_config(sys.executable, agent), handle)

    def call(self, method, params=None, timeout=10):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(timeout)
            try:
                conn.connect(self.socket)
                init = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {"protocolVersion": 1, "clientInfo": {"name": "idle-budget", "version": "1"}}}
                request = {"jsonrpc": "2.0", "id": 2, "method": method, "params": params or {}}
                conn.sendall((json.dumps(init) + "\n" + json.dumps(request) + "\n").encode())
                buffer = b""
                while True:
                    chunk = conn.recv(1 << 16)
                    if not chunk:
                        return {"error": "acpmux closed the connection"}
                    buffer += chunk
                    while b"\n" in buffer:
                        line, buffer = buffer.split(b"\n", 1)
                        message = json.loads(line or b"{}")
                        if message.get("id") == 2:
                            if "error" in message:
                                return {"error": message["error"]}
                            result = message.get("result")
                            return {} if result is None else result  # a null result is an answer
            except (OSError, ValueError) as error:
                return {"error": str(error)}

    def sessions(self):
        reply = self.call("_acpmux/sessions")
        found = reply.get("sessions") if answered(reply) else None
        return {s.get("sessionId"): s for s in found or [] if isinstance(s, dict)}

    def host_pid(self, session_id):
        """The agent host pid of `session_id` from its discovery record (`hosts/<session id>.json`), or None."""
        try:
            with open(os.path.join(self.home, "hosts", f"{session_id}.json")) as handle:
                pid = json.load(handle).get("host_pid")
        except (OSError, ValueError, AttributeError):
            return None
        return pid if isinstance(pid, int) and pid > 1 else None

    def pool_ready(self, cwd):
        """The ready pooled entries in `cwd` (`_acpmux/status` pool.entries, hub/pool pool_view_json): not an entry
        the agent page hinted for its own folder."""
        reply = self.call("_acpmux/status")
        entries = ((reply.get("pool") or {}).get("entries") if answered(reply) else None) or []
        folder = os.path.realpath(cwd)
        return [e for e in entries if isinstance(e, dict) and e.get("state") == "ready"
                and isinstance(e.get("cwd"), str) and os.path.realpath(e["cwd"]) == folder]

    def pool_host_pids(self):
        """The host pids of the pooled entries' records (`hosts/pool/*.json`, agent_host::POOL_DIR_NAME)."""
        folder = os.path.join(self.home, "hosts", "pool")
        pids = []
        for name in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
            if not name.endswith(".json"):
                continue
            try:
                with open(os.path.join(folder, name)) as handle:
                    pid = json.load(handle).get("host_pid")
            except (OSError, ValueError, AttributeError):
                continue
            if isinstance(pid, int) and pid > 1:
                pids.append(pid)
        return pids

    def trust(self, cwd):
        """acp.trust.set `cwd` trusted; returns the refusal (an error reply), printed as AGENT-SESSION-TRUST-REFUSED,
        or None."""
        reply = self.call("acp.trust.set", {"cwd": cwd, "level": "trusted"})
        if answered(reply):
            return None
        refusal = {"cwd": cwd, "error": reply.get("error") if isinstance(reply, dict) else reply}
        print("AGENT-SESSION-TRUST-REFUSED " + json.dumps(refusal), flush=True)
        return refusal

    def gate(self):
        """A FIFO the fake agent's `gate:` turn blocks on until release(): a turn that sends nothing meanwhile."""
        path = os.path.join(self.folder, f"gate-{len(self.gates)}")
        if not os.path.exists(path):
            os.mkfifo(path)
        self.gates.append(path)
        return path

    def release(self):
        """Ends every gated turn (its reader is the fake agent; with none, there is nothing to end)."""
        for path in self.gates:
            try:
                fd = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
            except OSError:
                continue
            try:
                os.write(fd, b"go\n")
            finally:
                os.close(fd)


def open_agent_chat(app, home, stress, wait, pane, prompt):
    """An agent chat in `pane` on the fake harness in home.cwd with `prompt` sent, as a person opens one: the agent
    tab (palette.newAgentChat), then the page's own new-chat and send verbs (debug.agent_pane), each sent once: a
    retry after an error reply (a timeout after the page acted) would open a second chat or send the prompt twice.
    Only read-only state (chat_state, acpmux status) is polled. `stress` and `wait` are perf-stress-session.py's
    builder and bounded poll. Returns {session, engine (`debug.agent_pane engine`: cef or webkit:<reason>), trust
    (acp.trust.set's refusal, or None)}; SessionShapeError when a step does not answer."""
    stress.action("palette.newAgentChat", target=f"pane:{pane}")

    def page(action, **args):
        return app.rpc("debug.agent_pane", {"action": action, "pane": pane, **args}, timeout=AGENT_STEP_S)

    def once(action, **args):
        reply = page(action, **args)
        if not answered(reply):
            raise SessionShapeError(f"pane {pane}: {action} refused: {json.dumps(reply)[:300]}")
        return reply

    def state():
        reply = page("chat_state")
        return reply if answered(reply) else None

    before = wait(state, AGENT_STEP_S, step=1)
    if not before:
        raise SessionShapeError(f"no agent page in pane {pane} (refusals: {stress.refusals[-3:]})")
    if not wait(lambda: answered(home.call("_acpmux/status", timeout=3)), AGENT_STEP_S, step=1):
        raise SessionShapeError(f"acpmux does not answer on {home.socket}")
    trust = home.trust(home.cwd)
    started = once("new_chat", harness=AGENT_HARNESS_ID, cwd=home.cwd)
    if started.get("pending"):
        raise SessionShapeError(f"pane {pane}: new_chat waits on a question (folder trust: {trust or 'set'})")
    sent = once("send_prompt", text=prompt)
    prior = chat_session(before)

    def new_session(candidate):
        return candidate if candidate and candidate != prior else None

    session = new_session(sent.get("sessionId")) or wait(lambda: new_session(chat_session(state())), AGENT_STEP_S, step=1)
    if not session:
        raise SessionShapeError(f"pane {pane}: the chat has no new session after its prompt")
    engine = page("engine")
    return {"session": session, "engine": engine.get("engine") if answered(engine) else None, "trust": trust}


def build_agents(app, home, plan, stress_module=None):
    """The agent panes of `plan` (SESSIONS `agents`): with `hidden`, a chat in a new workspace that then hides
    behind the launch workspace; with `visible`, a chat in the launch pane, its turn gated (sends nothing until
    AgentHome.release) when `working`, else finished, on `engine` when the plan names one; `pool` ready pooled
    entries in home.pool_cwd (_acpmux/prewarm). Returns what it built: `plan`, `hidden_hosts` the agent host pids of
    the hidden chats (measure's hidden rows), `pool_hosts` the pooled hosts' pids (agent_refusals), `trust` the
    refused acp.trust.set calls. `stress_module`: perf-stress-session.py (load_stress) or a test's fake."""
    module = stress_module or load_stress()
    stress, wait = module.Stress(app.rpc), module.wait
    shown = stress.focused_workspace()
    built = {"plan": plan, "shown_workspace": shown, "hidden_hosts": [], "pool_hosts": [], "chats": [], "trust": []}

    def opened(pane, prompt):
        chat = open_agent_chat(app, home, stress, wait, pane, prompt)
        if chat["trust"]:
            built["trust"].append(chat["trust"])
        return chat

    def first_pane(workspace):
        panes = stress.panes(stress.workspace(workspace))
        if not panes:
            raise SessionShapeError(f"workspace {workspace} has no pane")
        return panes[0]["id"]

    def finished(session):
        if not wait(lambda: turn_done(home.sessions().get(session) or {}), AGENT_STEP_S, step=1):
            raise SessionShapeError(f"chat {session}: its turn did not finish ({home.sessions().get(session)})")

    if plan.get("hidden"):
        workspace = stress.new_workspace()
        if not workspace:
            raise SessionShapeError("the hidden chat's workspace did not appear")
        stress.show(workspace)
        chat = opened(first_pane(workspace), "hello")
        session = chat["session"]
        finished(session)
        host = home.host_pid(session)
        if host is None:
            raise SessionShapeError(f"chat {session} has no agent host record in {home.home}/hosts")
        built["hidden_hosts"].append(host)
        built["chats"].append({"session": session, "workspace": workspace, "visible": False, "host_pid": host,
                               "engine": chat["engine"]})
        stress.show(shown)
        if stress.window_showing(workspace):
            raise SessionShapeError(f"workspace {workspace} still shows after the launch workspace was shown")
    if plan.get("visible"):
        working = plan.get("working", False)
        chat = opened(first_pane(shown), f"gate: {home.gate()}" if working else "hello")
        session = chat["session"]
        if plan.get("engine") and chat["engine"] != plan["engine"]:
            # The session's row sums the kinds of `engine` (agent-working-visible: cef); a chat on another engine
            # does its work in kinds the row does not read.
            raise SessionShapeError(f"chat {session} shows on {chat['engine']}, the session measures {plan['engine']}")
        if working:
            if not wait(lambda: (home.sessions().get(session) or {}).get("status") == "running", AGENT_STEP_S, step=1):
                raise SessionShapeError(f"chat {session}: its gated turn does not run ({home.sessions().get(session)})")
        else:
            finished(session)
        built["chats"].append({"session": session, "workspace": shown, "visible": True, "working": working,
                               "host_pid": home.host_pid(session), "engine": chat["engine"]})
    if plan.get("pool"):
        trust = home.trust(home.pool_cwd)
        if trust:
            built["trust"].append(trust)
        reply =home.call("_acpmux/prewarm", {"harness": AGENT_HARNESS_ID, "cwd": home.pool_cwd, "wait": True},
                          timeout=AGENT_STEP_S * 2)
        built["prewarm"] = reply
        if not answered(reply) or reply.get("accepted") is not True:
            raise SessionShapeError(f"_acpmux/prewarm in {home.pool_cwd} refused: {json.dumps(reply)[:300]}"
                                    + (f" (trust: {json.dumps(trust)[:200]})" if trust else ""))
        if not wait(lambda: len(home.pool_ready(home.pool_cwd)) >= plan["pool"], AGENT_STEP_S, step=1):
            raise SessionShapeError(f"{plan['pool']} ready pooled entries in {home.pool_cwd} wanted, "
                                    f"{len(home.pool_ready(home.pool_cwd))} (prewarm: {json.dumps(reply)[:300]})")
        built["pool_entries"] = len(home.pool_ready(home.pool_cwd))
        built["pool_hosts"] = home.pool_host_pids()
        if not built["pool_hosts"]:
            raise SessionShapeError(f"no pooled host record in {home.home}/hosts/pool")
    if stress.refusals:
        built["refusals"] = stress.refusals
    print("AGENT-SESSION " + json.dumps(built), flush=True)
    return built


def build_busy_hidden(app, period_s, stress_module=None):
    """The launch terminal prints one line every `period_s`, then a new workspace shows over it: the printing
    terminal is hidden."""
    stress = (stress_module or load_stress()).Stress(app.rpc)
    printing = stress.focused_workspace()
    tabs = [tab for pane in stress.panes(stress.workspace(printing)) for tab in pane.get("tabs") or []]
    tab = next((t for t in tabs if t.get("selected")), tabs[0] if tabs else None)
    if not tab or not tab.get("id"):
        raise SessionShapeError(f"the launch workspace {printing} has no terminal tab")
    stress.send(tab["id"], f"while :; do echo idle-budget-tick; sleep {period_s:g}; done\n")
    if stress.refusals:
        raise SessionShapeError(f"terminal.sendText refused: {stress.refusals}")
    shown = stress.new_workspace()
    if not shown:
        raise SessionShapeError("the workspace over the printing terminal did not appear")
    stress.show(shown)
    if stress.window_showing(printing):
        raise SessionShapeError(f"the printing workspace {printing} still shows")
    built = {"printing_workspace": printing, "printing_tab": tab["id"], "period_s": period_s, "shown_workspace": shown}
    print("BUSY-HIDDEN-SESSION " + json.dumps(built), flush=True)
    return built


def session_app(app_class, app_path, out, session, env):
    """(app, agents) of one cmux session: an agent session's AgentHome (else None), whose ACPMUX_HOME and
    ACPMUX_SOCKET join the launch `env`, so the app's acpmux and agent hosts run in it. `app_class`: BenchApp."""
    agents = AgentHome(os.path.join(out, session), session) if SESSIONS[session].get("agents") else None
    app = app_class(app_path, out=os.path.join(out, session), env={**env, **(agents.env() if agents else {})},
                    config=session_config(session))
    return app, agents


def start_session(app, agents, spec, entry, stress_module=None):
    """Writes the agent home before the launch (acpmux reads its config.json at start), launches, then builds the
    agent panes and the printing hidden terminal of `spec` into `entry`."""
    if agents:
        agents.write()
    app.launch()
    if spec.get("agents"):
        entry["agents"] = build_agents(app, agents, spec["agents"], stress_module)
    if spec.get("busy_terminal"):
        entry["busy_terminal"] = build_busy_hidden(app, spec["busy_terminal"], stress_module)


def stop_session(app, agents):
    """Ends the gated turns before the app stops (a turn blocked on its gate would outlive the teardown), and stops
    the app whatever the release did."""
    try:
        if agents:
            agents.release()
    finally:
        app.stop()


# Both keep-awake settings off (D11): their shipping default is pluggedIn, and a session that asks for keep-awake
# names them in its budget `settings`.
KEEP_AWAKE_OFF = {"sessions": {"keepAwake": "off"}, "phone": {"keepAwake": "off"}}
# The shipping measurement mode's hang reports (HangReportsSetting.path); with the tag's consent record they send.
HANG_REPORTS_ON = {"diagnostics": {"hangReports": True}}
# BenchApp's default, keep-awake off, hang reports on.
BASE_CONFIG = {"appearance": {"backgroundOpacity": 1}, **KEEP_AWAKE_OFF, **HANG_REPORTS_ON}
# Hidden Chromium tabs freeze this long after they hide (BrowserHibernationSetting's default, set explicitly so the
# settle below is known to outlast it); the tab sessions settle at least FREEZE_GRACE_S past it.
FREEZE_HIDDEN_TABS_S = 30
FREEZE_GRACE_S = 15
TABS_CONFIG = {"browser": {"freezeHiddenTabs": FREEZE_HIDDEN_TABS_S}}
TABS_STATIC = {"webkit_hidden": 5, "chromium_hidden": 10, "shown": "static"}
# The power sessions (p14-energy-096): one shown static Chromium tab and nothing else, in cmux and in the reference
# browser, every owner of the window's power attributed; settled past Chromium's two minutes of post-load work.
ONE_TAB = {"webkit_hidden": 0, "chromium_hidden": 0, "shown": "static"}
POWER_SESSION, CHROME_POWER_SESSION = "power-visible", "chrome-power-visible"
POWER_SETTLE_S = 120
# The sessions (the docstring describes each). Keys: config (adds to BASE_CONFIG: session_config), hide, minimize,
# stress, static (STRESS without its rAF spinner), tabs (build_tabs's plan), settle_min (seconds), saver (the energy
# saver state the session asks for; --gate refuses a window that shows another), anim (read the animated page's rAF
# count at both ends), power (attribute the window's power: power_attribution), chrome (the reference browser with
# the session's tabs), agents (build_agents's plan, in the session's own acpmux home: AgentHome), busy_terminal (the
# hidden terminal's print period: build_busy_hidden).
SESSIONS = {
    "light": {},
    "light-webkit": {"config": {"browser": {"defaultEngine": "webkit"}}},
    "light-hidden": {"hide": True},
    "minimized": {"minimize": True},
    "stress": {"stress": True},
    "stress-static": {"stress": True, "static": True},
    "tabs-static": {"config": TABS_CONFIG, "tabs": TABS_STATIC, "settle_min": FREEZE_HIDDEN_TABS_S + FREEZE_GRACE_S},
    "energy-saver": {"config": {**TABS_CONFIG, "energy": {"saver": "always"}}, "tabs": {**TABS_STATIC, "shown": "anim"},
                     "settle_min": FREEZE_HIDDEN_TABS_S + FREEZE_GRACE_S, "saver": True, "anim": True},
    # The references (run_chrome_static): the cmux session's pages in a Chromium, settled as long as it.
    CHROME_SESSION: {"chrome": True, "tabs": TABS_STATIC, "settle_min": FREEZE_HIDDEN_TABS_S + FREEZE_GRACE_S},
    POWER_SESSION: {"tabs": ONE_TAB, "power": True, "settle_min": POWER_SETTLE_S},
    CHROME_POWER_SESSION: {"chrome": True, "tabs": ONE_TAB, "power": True, "settle_min": POWER_SETTLE_S},
    "agent-idle": {"agents": {"visible": True, "hidden": True, "pool": 1},
                   "settle_min": HARNESS_FREEZE_S + FREEZE_GRACE_S},
    "agent-working-visible": {"agents": {"visible": True, "working": True, "engine": "cef"}},
    "busy-hidden": {"busy_terminal": BUSY_PERIOD_S},
}


def session_config(session):
    """The cmux-next.json of `session`: BASE_CONFIG with the session's own keys on top."""
    return {**BASE_CONFIG, **(SESSIONS[session].get("config") or {})}


def parse_sessions(text):
    """The --sessions list (`all`: every session); SystemExit naming the first unknown one, before any launch."""
    names = list(SESSIONS) if text == "all" else [s for s in text.split(",") if s]
    for name in names:
        if name not in SESSIONS:
            raise SystemExit(f"idle-budget: unknown session {name} (one of {', '.join(SESSIONS)})")
    return names


def settle_seconds(session, asked):
    """The settle of `session`: the asked one, at least the session's settle_min (past the hidden-tab freeze)."""
    return max(asked, SESSIONS[session].get("settle_min", 0))


def wait_for(check, seconds, what):
    """Waits until `check()` is true; RuntimeError naming `what` after `seconds`."""
    deadline = time.monotonic() + seconds
    while not check():
        if time.monotonic() > deadline:
            raise RuntimeError(f"{CHROME_SESSION}: {what} after {seconds:g} s")
        time.sleep(0.2)  # bench: bounded wait for the reference browser


def build_template(browser, template, settle):
    """The template profile at `template`: built in a sibling folder and renamed into place only after the
    browser ran `settle` seconds (uBlock Origin compiles its filter lists into it), so an interrupted build
    leaves no half-built template behind."""
    if os.path.isdir(template):
        return False
    building = f"{template}.building-{os.getpid()}"
    shutil.rmtree(building, ignore_errors=True)
    os.makedirs(building)
    try:
        browser.launch(building, None)
        try:
            browser.ready()
            time.sleep(settle)  # bench: uBlock Origin compiles its lists into the template profile
        finally:
            browser.quit()
        os.replace(building, template)
    finally:
        shutil.rmtree(building, ignore_errors=True)
    return True


def run_chrome_static(opts, out, session=CHROME_SESSION):
    """A reference session (chrome-static, chrome-power-visible): the --chrome-app browser through xbench's launcher
    (an APFS clone of a template profile keyed on the browser build and uBlock Origin, --user-data-dir, xbench's
    switches, tabs over CDP /json/new) with the session's tab_plan pages (tabs-static's for chrome-static) from the
    shared page server in its order, every page loaded, the last shown, and the uBlock Origin the cmux app bundles;
    settled and measured as the cmux sessions are, its processes classified by chrome_kind; a `power` session's
    window attributed as a cmux one is (`power`). Raises before launch when the browser cannot run that uBlock
    Origin."""
    import xbench  # scripts/perf-bench (on sys.path): the Chrome launcher the cross-browser bench uses
    spec = SESSIONS[session]
    bundle = os.path.abspath(opts.chrome_app)
    if not os.path.isdir(bundle):
        raise RuntimeError(f"{session}: no {bundle}")
    if procs.main_pid(bundle):
        raise RuntimeError(f"{session}: {bundle} is already running; its processes would be measured too")
    with open(os.path.join(bundle, "Contents/Info.plist"), "rb") as handle:
        info = plistlib.load(handle)
    bundle_id, version = info.get("CFBundleIdentifier"), xbench.bundle_version(bundle)
    cmux_ublock = os.path.join(os.path.realpath(opts.app), UBLOCK_IN_APP)
    ublock = None if opts.chrome_ublock == "none" else opts.chrome_ublock or cmux_ublock
    manifest = read_manifest(ublock) if ublock else None
    if manifest:
        refusal = reference_refusal(bundle_id, version, manifest)
        if refusal:
            raise RuntimeError(f"{session}: {refusal}; pass --chrome-app a Chromium that runs MV2 "
                               "(ungoogled-chromium of cmux's Chromium major)")
    chrome_version = (manifest or {}).get("version")
    work = os.path.join(out, CHROME_SESSION)  # the keyed template profile, shared by every reference session
    helper = xbench.Helper(opts.chrome_helper_cache)
    pages = IdlePages()
    browser = xbench.ChromiumBrowser("chrome", bundle, helper, None, extensions=[ublock] if manifest else [])
    profile = os.path.join(out, session, "run")
    try:
        template = os.path.join(work, "template-" + template_key(bundle, version, ublock if manifest else None,
                                                                 chrome_version))
        built = build_template(browser, template, opts.chrome_template_settle)
        xbench.clone(template, profile)
        browser.launch(profile, None)
        browser.ready()
        # DevTools answers before the startup browser opens its first tab (the handler starts in
        # PreMainMessageLoopRun, StartupBrowserCreator opens the window after it): wait for that tab, then every
        # page that is not one of the session's closes, as xbench's adopt_first does.
        wait_for(lambda: browser.pages(), 30, "no startup page target")
        # The session's own plan and pages, in its order; each new tab is selected, so the last one is shown.
        plan = tab_plan(pages, spec["tabs"])
        urls = [url for _engine, url, _key in plan]
        for _engine, url, key in plan:
            browser.new_tab(url, key)
            if not pages.wait_loaded(key, 90):
                raise SessionShapeError(f"{session}: tab {url} did not load in 90 s")
        for target in browser.pages():
            if target.get("url") not in urls:
                browser.close(target["id"])
        browser.activate(browser.tabs[-1])
        settle = settle_seconds(session, opts.settle)
        time.sleep(settle)  # bench: the pages settle and hidden tabs pass Chrome's background throttling
        # As measure: PowerWindow's subprocesses before `first` and after `last`, its libproc reads around the sleep.
        window = (power_attribution.PowerWindow(browser.instance.pid, browser.instance.pids, chrome_kind)
                  if spec.get("power") else None)
        if window:
            window.prepare()
        first = snapshot(browser.instance.pids())
        gpu0 = procs.gpu_ns_by_pid()
        if window:
            window.begin()
        began = time.monotonic()
        time.sleep(opts.measure)  # bench: the idle window itself (nothing is sent to Chrome in it)
        elapsed = time.monotonic() - began
        if window:
            window.end()
        gpu1 = procs.gpu_ns_by_pid()
        last = snapshot(browser.instance.pids())
        power = window.finish() if window else None
        targets = browser.extension_targets()
        page_targets = len(browser.pages())
        result = {"seconds": round(elapsed, 1), "processes": process_rows(first, last, elapsed, gpu0, gpu1, chrome_kind)}
        if power is not None:
            # Named while the browser still runs: a stack sample of each process with an unnamed owner over the floor.
            result["power"] = name_power_owners(power_attribution.attribute(power), opts.sample, os.path.join(out, session))
        visibility = dict(pages.visibility)
        running = any(t.get("url", "").startswith(f"chrome-extension://{UBLOCK_ID}/") for t in targets)
        chrome = {"app": bundle, "bundle_id": bundle_id, "version": version, "build": info.get("CFBundleVersion"),
                  "switches": browser.switches(), "settle_s": settle, "template_built": built,
                  "pages": {"tabs": len(urls), "page_targets": page_targets, "shown": 1,
                            "set": "tabs-static" if session == CHROME_SESSION else session,
                            "loaded": len(pages.loaded), "visibility": visibility},
                  "ublock": {"cmux_version": manifest_version(cmux_ublock), "chrome_version": chrome_version,
                             "running": running},
                  "unequal": chrome_shape_unequal(page_targets, visibility, [key for _engine, _url, key in plan]),
                  "extension_targets": [target.get("url", "")[:120] for target in targets]}
        return {"chrome": chrome, "result": result}
    finally:
        browser.quit()
        pages.close()
        shutil.rmtree(profile, ignore_errors=True)  # the keyed template stays for a rerun into `out`


def chrome_static_entry(opts, out, session, markdown):
    """Runs a reference session (run_chrome_static) and prints its rows; a failure is recorded as a cmux session's
    failure is."""
    try:
        entry = run_chrome_static(opts, out, session)
        entry["kinds"] = aggregate(entry["result"])
        entry["over"] = []
        entry["exit"] = 0
        for name, values in entry["kinds"].items():
            print("IDLE-BUDGET-ROW " + json.dumps({"session": session, "kind": name, **values}), flush=True)
        print("IDLE-BUDGET-CHROME " + json.dumps({k: v for k, v in entry["chrome"].items() if k != "switches"}), flush=True)
        if entry["result"].get("power"):
            entry["power"] = entry["result"]["power"]
            for line in power_attribution.report_lines(session, entry["power"]):
                print(line, flush=True)
        markdown.append(table(session, entry["kinds"], []) + power_table(entry.get("power")))
    except Exception as error:  # noqa: BLE001 - as a cmux session's failure: recorded, the others still run
        entry = {"exit": 1, "error": f"{type(error).__name__}: {error}"[:500]}
        print(f"IDLE-BUDGET-SESSION-FAILED {session} exit=1 {entry['error'][:300]}", flush=True)
        markdown.append(f"\n### {session}\n\nnot measured: {entry['error'][:300]}")
    return entry


def name_power_owners(power, sample_seconds, folder, samples=None, sampler=None):
    """Names the unnamed thread owners at or above the floor from one stack sample of each process that has one
    (`samples`: {pid: text} already taken, as the app's after its window; `sampler` defaults to /usr/bin/sample);
    returns `power`. No new sample with `sample_seconds` 0. The process with the most unnamed thread mW goes
    first, and sampling stops once no `unnamed threads` owner at or above the floor is left."""
    sampler = sampler or power_attribution.sample_text
    tried = set()
    while True:
        weight = {}
        for entry in power_attribution.unnamed(power["owners"]):
            for thread in entry.get("threads") or []:
                if thread["pid"] not in tried:
                    weight[thread["pid"]] = weight.get(thread["pid"], 0.0) + thread["mw"]
        if not weight:
            return power
        pid = max(sorted(weight), key=weight.get)
        tried.add(pid)
        text = (samples or {}).get(pid)
        if text is None and sample_seconds:
            os.makedirs(folder, exist_ok=True)
            text = sampler(pid, sample_seconds, os.path.join(folder, f"sample-power-{pid}.txt"))
        if text:
            power_attribution.name_threads(power["owners"], pid, power_attribution.sample_labels(text))


def power_table(power, floor=power_attribution.FLOOR_MW):
    """The session's power owners under its process table (empty without `power`)."""
    if not power:
        return ""
    got = power["breakdown"]
    lines = [f"\n\npower owners: sum {got['sum_mw']} mW of {got['total_mw']} mW measured (ratio {got['ratio']}, "
             f"within {power_attribution.TOLERANCE:.0%}: {got['within']}); WindowServer {power['window_server']}\n",
             "| owner | mW | named |", "|---|---|---|"]
    lines += [f"| {e['owner']} | {e['mw']} | {'yes' if e['named'] else '**no**'} |" for e in power["owners"]
              if abs(e["mw"]) >= floor]
    return "\n".join(lines)


def power_overs(report):
    """POWER-OVER rows (power_attribution.power_over) of power-visible against chrome-power-visible, when both have
    an attributed window; None when either is missing (nothing to compare)."""
    sessions = report["sessions"]
    mine = (sessions.get(POWER_SESSION) or {}).get("power")
    reference = (sessions.get(CHROME_POWER_SESSION) or {}).get("power")
    if not mine or not reference:
        return None
    return power_attribution.power_over(mine["owners"], reference["owners"])


def chrome_reference(report):
    """The chrome-static block with its kinds, or None when it was not measured."""
    entry = report["sessions"].get(CHROME_SESSION) or {}
    return {**entry["chrome"], "kinds": entry["kinds"]} if entry.get("kinds") and entry.get("chrome") else None


def minimize(app):
    """Minimizes the launch window (action minimizeWindow) and waits until debug.window_list reports it so."""
    run_action(app, "minimizeWindow")
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        main = window_state(app).get("main") or []
        if main and all(w.get("miniaturized") for w in main):
            return {"miniaturized": len(main)}
        time.sleep(0.2)  # bench: bounded wait for the window to reach the Dock
    raise SessionShapeError(f"the window is not minimized after 10 s: {window_state(app)}")


def bundle_build_config(app):
    """The bundle's build config as bench_launch reads it: `debug`, `bench-hooks` or `release`."""
    import bench_launch
    app = os.path.realpath(app).rstrip("/")
    return bench_launch.bundle_kind(app, bench_launch.main_binary(app))


def gate_refusal(build_config, gate, shipping_draw="on"):
    """Why this run is refused before any launch, or None: under `--gate` a Debug build is not the code or the draw
    users run; `--shipping-draw off` on another build would measure the same draw twice (only a Debug automation
    launch draws occluded windows, WindowDrawPolicy.drawsOccludedWindows)."""
    if gate and build_config == "debug":
        return ("--gate refuses a Debug build: measure a Release build with CMUX_BENCH_HOOKS "
                "(its code, occlusion draw and Sentry are what users run)")
    if shipping_draw == "off" and build_config != "debug":
        return (f"--shipping-draw off has no effect on a {build_config} build: only a Debug build draws occluded "
                "windows in an automation launch, so the on/off comparison is a Debug-only diagnostic")
    return None


def launch_env(shipping_draw=True):
    """BenchApp's `env` of every cmux session: the shipping measurement mode (bench_launch.shipping_env)."""
    import bench_launch
    return bench_launch.shipping_env(draw=shipping_draw)


def predicted_draws_when_occluded(build_config, env):
    """What WindowDrawPolicy.drawsOccludedWindows should say for this build and launch env: only a Debug build
    draws occluded windows, in an automation launch without CMUX_NEXT_BENCH_SHIPPING_DRAW=1. Only a cross-check of
    the app's own answer (debug.shipping_mode), never the recorded value."""
    if build_config != "debug" or env.get("CMUX_NEXT_BENCH_SHIPPING_DRAW") == "1":
        return False
    return env.get("CMUX_NEXT_NO_ACTIVATE") == "1" or env.get("CMUX_NEXT_SOCKET_MODE") == "automation"


SENTRY_THREAD_PREFIX = "SentryCrash"  # Sentry's Mach exception handler threads (crash-ends-app-gate.py PRIMARY)
SHIPPING_FIELDS = ("build_config", "sentry_started", "hang_reports", "draws_when_occluded", "activated")


def shipping_fields(build_config, env, thread_names, mode, activation):
    """The five shipping-mode fields of a session, read from the app: `mode` is its debug.shipping_mode reply ({}
    when it did not answer: every value unknown). draws_when_occluded is the app's answer (null when unknown) with
    the launch env's prediction beside it."""
    mode = mode or {}
    hang = mode.get("hang_reports") if isinstance(mode.get("hang_reports"), dict) else {}
    draws = mode.get("draws_when_occluded")
    pages = mode.get("pages_render_when_covered")
    return {
        "build_config": build_config,
        "sentry_started": any(name.startswith(SENTRY_THREAD_PREFIX) for name in thread_names),
        "hang_reports": {"available": hang.get("available"), "setting": hang.get("setting"),
                         "decision": hang.get("decision"), "enabled": hang.get("enabled"),
                         "on": hang.get("available") is True and hang.get("enabled") is True},
        "draws_when_occluded": {"windows": draws if isinstance(draws, bool) else None,
                                "pages": pages if isinstance(pages, bool) else None,
                                "predicted": predicted_draws_when_occluded(build_config, env)},
        "activated": dict(activation),
    }


def draw_mismatch(fields):
    """A line when the app's draw answer differs from the launch env's prediction (the Swift rule changed, or a
    key the prediction does not know), else None. An unknown answer is no mismatch; the record shows it as null."""
    draw = fields["draws_when_occluded"]
    wrong = {name: draw[name] for name in ("windows", "pages")
             if draw[name] is not None and draw[name] != draw["predicted"]}
    if not wrong:
        return None
    return (f"the app says {', '.join(f'{name} draw occluded={value}' for name, value in wrong.items())}, "
            f"the launch env predicts {draw['predicted']}")


def shipping_refusals(entry):
    """[(what, why)] for a session that did not run the shipping configuration it is judged as: not activated,
    Sentry not started, hang reports not on (not available, setting off, no consent, or not enabled)."""
    out = []
    activated = entry.get("activated") or {}
    if activated.get("activated") is not True:
        out.append(("activated", f"the app was not activated: {activated.get('error') or 'not recorded'}"))
    if entry.get("sentry_started") is not True:
        out.append(("sentry", "no SentryCrash thread runs in the app (CMUX_NEXT_DEV_SENTRY=1 not honored, or "
                              "telemetry off)"))
    hang = entry.get("hang_reports") or {}
    if hang.get("on") is not True:
        out.append(("hang_reports", "hang reports do not run: " + json.dumps(
            {key: hang.get(key) for key in ("available", "setting", "decision", "enabled")})))
    return out


def fresh_session(app):
    """Starts the session from empty: ends the tag's leftover daemons (TagTeardown: exact PIDs of this app
    bundle) and removes the tag's saved terminal session, as bench_pane_scale.py does. A bench host's tag
    (split-spring) is shared, and its saved session restored 509 terminals into a "light" run (cmux20,
    2026-10-24). Returns what it removed."""
    if app.teardown:
        app.teardown.end()
        app.teardown.done = False
    state = os.path.join(os.path.expanduser("~"), "Library/Application Support/cmux/tags", app.tag, "tui")
    existed = os.path.isdir(state)
    shutil.rmtree(state, ignore_errors=True)
    return {"tui_state_removed": existed}


def host_facts():
    display = subprocess.run(["system_profiler", "SPDisplaysDataType"], capture_output=True, text=True).stdout
    return {"host": platform.node(), "macos": platform.mac_ver()[0], "chip": subprocess.run(
        ["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip(),
        "load": os.getloadavg(), "display": [l.strip() for l in display.splitlines() if "Refresh" in l or "Resolution" in l][:4]}


def table(session, kinds, overs, entry=None):
    over_keys = {(k, f) for k, f, _, _ in overs}
    lines = [f"\n### {session}\n"]
    if entry:
        saver, thermal, energy = entry["saver"], entry["thermal"], entry["energy_mw"]["tree"]
        lines.append(f"energy {energy['cpu']} mW CPU, {energy['billed']} mW billed (tree); saver asked {saver['asked']}, "
                     f"observed {saver['observed']}{' REFUSED' if saver['mismatch'] else ''}; thermal {thermal['worst']}"
                     f"{' (marked)' if thermal['marked'] else ''}; {len(entry['assertions'])} power assertion(s)"
                     + (f"; page rAF {entry['anim']}" if "anim" in entry else "") + "\n")
    lines += ["| process | n | threads (max) | wakeups/s (max) | pkg-idle wakeups/s | main wakes/s | "
              "CPU mW | billed mW | GPU ms/s | csw/s | CPU % | threads that ran |",
              "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    order = ["app", "daemon", "holder", "terminal-host", "acpmux"]
    for name in sorted(kinds, key=lambda k: (order.index(k) if k in order else len(order), k)):
        e = kinds[name]
        mark = lambda f, v: f"**{v}**" if (name, f) in over_keys else f"{v}"  # noqa: E731
        lines.append(f"| {name} | {e['n']} | {e['threads']} ({mark('threads_max', e['threads_max'])}) | "
                     f"{mark('wakeups_per_s', e['wakeups_per_s'])} ({mark('wakeups_max', e['wakeups_max'])}) | "
                     f"{e['pkg_idle_wakeups_per_s']} | {mark('main_wakes_per_s', e.get('main_wakes_per_s', '-'))} | "
                     f"{mark('energy_mw_cpu', e['energy_mw_cpu'])} | {mark('energy_mw_billed', e['energy_mw_billed'])} | "
                     f"{mark('gpu_ms_per_s', '-' if e['gpu_ms_per_s'] is None else e['gpu_ms_per_s'])} | "
                     f"{e['csw_per_s']} | {e['cpu_pct']} | {e['threads_ran']} |")
    return "\n".join(lines)


def coalition_line(coalition):
    """The app's resource coalition under the session's table (None: it could not be read)."""
    if coalition is None:
        return "app coalition: not readable"
    return (f"app coalition: {coalition['wakeups_per_s']} wakeups/s ({coalition['pkg_idle_wakeups_per_s']} pkg-idle), "
            f"{coalition['energy_mw_cpu']} mW CPU, {coalition['energy_mw_billed']} mW billed, "
            f"{coalition['gpu_ms_per_s']} GPU ms/s, {coalition['cpu_pct']} % CPU")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", help='a tagged "cmux DEV <tag>.app" (not running)')
    parser.add_argument("--xbench", metavar="RESULTS_JSON",
                        help="judge an xbench.py results.json against the budget's xbench rows (D6) and exit; no --app")
    parser.add_argument("--tag", help="ignored (split-spring passes it); the tag comes from the app")
    parser.add_argument("--out", default=None)
    parser.add_argument("--json", default=None)
    parser.add_argument("--sessions", default="light,stress")
    parser.add_argument("--settle", type=float, default=60)
    parser.add_argument("--measure", type=float, default=60)
    parser.add_argument("--budget", default=BUDGET_FILE)
    parser.add_argument("--gate", action="store_true",
                        help="exit 1 when a value is over its budget, a session's saver state is not the one it asked "
                        "for, or chrome-static failed or is no equal reference; exit 2 at once on a Debug build")
    parser.add_argument("--shipping-draw", choices=("on", "off"), default="on",
                        help="off: keep the automation draw of occluded windows, to compare with the shipping draw "
                        "(a Debug build only: refused on another build, which has no such draw)")
    parser.add_argument("--sample", type=float, default=10,
                        help="seconds of /usr/bin/sample of the app after the window, to name the threads that woke (0: none)")
    parser.add_argument("--chrome-app", default=CHROME_APP,
                        help="the chrome-static browser: a Chromium that runs Manifest V2 (ungoogled-chromium of "
                        "cmux's Chromium major); branded Chrome 137+ and Chrome for Testing 139+ are refused")
    parser.add_argument("--chrome-ublock", default=None,
                        help="the unpacked uBlock Origin chrome-static loads (default: the copy in --app; "
                        "`none`: without it, which marks the Chrome ratios unequal)")
    parser.add_argument("--chrome-template-settle", type=float, default=45,
                        help="seconds the reference browser's template profile runs before its first clone")
    parser.add_argument("--chrome-helper-cache", default=os.path.expanduser("~/Library/Caches/cmux-perf-bench"),
                        help="xbench's benchhelper cache")
    opts, _unknown = parser.parse_known_args(argv)
    budget = load_budget(opts.budget)
    if opts.xbench:
        with open(opts.xbench) as handle:
            overs, notes = xbench_overs(budget, json.load(handle))
        for note in notes:
            print(f"IDLE-BUDGET-NOT-JUDGED {note}", flush=True)
        for over in overs:
            print(over_line("xbench", over), flush=True)
        print(f"IDLE-BUDGET over={len(overs)} xbench={opts.xbench}", flush=True)
        sys.exit(1 if opts.gate and overs else 0)
    if not opts.app:
        parser.error("--app is required (or --xbench RESULTS_JSON)")
    sessions = parse_sessions(opts.sessions)
    build_config = bundle_build_config(opts.app)
    refusal = gate_refusal(build_config, opts.gate, opts.shipping_draw)
    if refusal:
        print(f"IDLE-BUDGET-REFUSED build_config={build_config}: {refusal}", flush=True)
        sys.exit(2)
    import bench_launch
    from bench_launch import BenchApp
    env = launch_env(shipping_draw=opts.shipping_draw == "on")
    out = opts.out or os.path.join(os.getcwd(), "artifacts", "idle-budget")
    os.makedirs(out, exist_ok=True)
    machine = host_facts()
    print("IDLE-BUDGET-MACHINE " + json.dumps(machine), flush=True)
    report = {"machine": machine, "app": opts.app, "build_config": build_config, "shipping_draw": opts.shipping_draw,
              "settle_s": opts.settle, "measure_s": opts.measure, "sessions": {}}
    all_overs = []
    refused = []
    markdown = []
    for session in sessions:
        spec = SESSIONS[session]
        if spec.get("chrome"):
            report["sessions"][session] = chrome_static_entry(opts, out, session, markdown)
            continue
        app, agents = session_app(BenchApp, opts.app, out, session, env)
        pages = IdlePages() if spec.get("tabs") else None
        try:
            entry = {"fresh_session": fresh_session(app)}
            report["sessions"][session] = entry
            consent = bench_launch.seed_hang_report_consent(app.app)
            if consent:
                print(f"IDLE-BUDGET-NO-HANG-CONSENT {session}: {consent}", flush=True)
            start_session(app, agents, spec, entry)
            if spec.get("stress"):
                entry["stress"] = build_stress(app, static=spec.get("static", False))
            if spec.get("tabs"):
                entry["tabs"] = build_tabs(app, pages, spec["tabs"])
            activation = app.activate()  # once, before the settle (and before a hide or minimize): users run an active app
            if not activation["activated"]:
                print(f"IDLE-BUDGET-NOT-ACTIVATED {session}: {activation['error']}", flush=True)
            if spec.get("hide"):
                entry["hide"] = app.rpc("action.run", {"action": "showHideAllWindows", "args": {"hidden": True},
                                                       "focus": False, "origin": "script"}, timeout=30)
            if spec.get("minimize"):
                entry["minimize"] = minimize(app)
            settle = settle_seconds(session, opts.settle)
            entry["settle_s"] = settle
            time.sleep(settle)  # bench: the session settles (page loads, Chromium's post-load work, the hidden-tab freeze)
            instance = procs.Instance(app.app, app.process.pid)
            names = [name for _cpu, name in threads(app.process.pid).values()]
            entry.update(shipping_fields(build_config, app.launched_env or {}, names,
                                         read_rpc(app, "debug.shipping_mode"), activation))
            print(f"IDLE-BUDGET-MODE {session} " + json.dumps({k: entry[k] for k in SHIPPING_FIELDS}), flush=True)
            mismatch = draw_mismatch(entry)
            if mismatch:
                print(f"IDLE-BUDGET-DRAW-MISMATCH {session}: {mismatch}", flush=True)
            window_before = window_state(app)
            result = measure(app, instance, opts.measure, pages.read_anim if spec.get("anim") else None,
                             attribute=spec.get("power", False),
                             hidden_hosts=tuple((entry.get("agents") or {}).get("hidden_hosts") or ()))
            result["window_state"] = {"start": window_before, "end": window_state(app)}
            print(f"IDLE-BUDGET-WINDOW {session} " + json.dumps(result["window_state"]), flush=True)
            app_sample = os.path.join(out, session, "sample-app.txt")
            if opts.sample:
                result["sample"] = sample_threads(app.process.pid, opts.sample, app_sample)
            if result.get("power"):
                # Named while the app runs: the app's sample above, and one sample of each other process with an
                # unnamed owner over the floor.
                taken = {app.process.pid: open(app_sample, errors="replace").read()} if os.path.exists(app_sample) else {}
                name_power_owners(result["power"], opts.sample, os.path.join(out, session), samples=taken)
            entry.update(summarize(session, result, budget))
            if result.get("power"):
                entry["power"] = result["power"]
                for line in power_attribution.report_lines(session, entry["power"]):
                    print(line, flush=True)
            if result.get("frame_clients"):
                print(f"IDLE-BUDGET-FRAME-CLIENTS {session} " + json.dumps(result["frame_clients"]), flush=True)
            kinds, overs, notes = entry["kinds"], [tuple(o) for o in entry["over"]], entry["not_judged"]
            for name, values in kinds.items():
                print("IDLE-BUDGET-ROW " + json.dumps({"session": session, "kind": name, **values}), flush=True)
            print(f"IDLE-BUDGET-ENERGY {session} " + json.dumps(entry["energy_mw"]), flush=True)
            print(f"IDLE-BUDGET-STATE {session} " + json.dumps({"saver": entry["saver"], "thermal": entry["thermal"]}), flush=True)
            for item in entry["assertions"]:
                print(f"IDLE-BUDGET-ASSERTION {session} {item['line']}", flush=True)
            if "anim" in entry:
                print(f"IDLE-BUDGET-ANIM {session} " + json.dumps(entry["anim"]), flush=True)
            for row in result["processes"]:
                if row["kind"] in ("app", "daemon", "holder", "acpmux", "agent-harness") and row["ran"]:
                    names = ", ".join(f"{t['name'] or t['tid']}={t['cpu_us']}us" for t in row["ran"])
                    print(f"IDLE-BUDGET-THREADS {session} {row['kind']} pid {row['pid']}: {names}", flush=True)
            if result.get("ledger"):
                print(f"IDLE-BUDGET-LEDGER {session} " + json.dumps(result["ledger"]), flush=True)
            if result.get("app_counter_rates"):
                print(f"IDLE-BUDGET-APP-COUNTERS {session} per s " + json.dumps(result["app_counter_rates"]), flush=True)
            for timer in result.get("main_run_loop_timers") or []:
                if timer["interval_s"] > 0:
                    print(f"IDLE-BUDGET-MAIN-TIMER {session} every {timer['interval_s']:g} s: {timer['callout']}", flush=True)
            for name, sampled in (result.get("sample") or {}).items():
                top = "; ".join(f"{frame} x{count}" for frame, count in sampled["frames"][:6])
                if top:
                    print(f"IDLE-BUDGET-SAMPLE {session} {name}: {top}", flush=True)
            for note in notes:
                print(f"IDLE-BUDGET-NOT-JUDGED {note}", flush=True)
            for over in overs:
                print(over_line(session, over), flush=True)
            reasons = refusals(entry)
            if reasons:
                refused.append(session)
            for what, why in reasons:
                print(f"IDLE-BUDGET-REFUSED {session} {what}: {why}", flush=True)
            if entry["thermal"]["marked"]:
                print(f"IDLE-BUDGET-THERMAL {session} rows taken at {entry['thermal']['worst']}: not comparable", flush=True)
            all_overs += [(session, *o) for o in overs]
            markdown.append(table(session, kinds, overs, entry) + "\n\n" + coalition_line(result.get("coalition"))
                            + power_table(entry.get("power")))
            print(f"IDLE-BUDGET-COALITION {session} " + json.dumps(result.get("coalition")), flush=True)
            entry["exit"] = 0
        except BaseException as error:  # noqa: BLE001 - one session's failure (a STRESS shape refusal, a launch
            # failure) is recorded with its exit code; the other sessions still measure and report.
            code = error.code if isinstance(error, SystemExit) and isinstance(error.code, int) else 1
            report["sessions"].setdefault(session, {}).update({"exit": code or 1, "error": f"{type(error).__name__}: {error}"[:500]})
            print(f"IDLE-BUDGET-SESSION-FAILED {session} exit={code or 1} {type(error).__name__}: {str(error)[:300]}", flush=True)
            markdown.append(f"\n### {session}\n\nnot measured: {type(error).__name__}: {str(error)[:300]}")
            if isinstance(error, KeyboardInterrupt):
                raise
        finally:
            stop_session(app, agents)
            if pages is not None:
                pages.close()
    cross, cross_notes, chrome_refused = judge_across(report, budget, CHROME_SESSION in sessions)
    for note in cross_notes:
        print(f"IDLE-BUDGET-NOT-JUDGED {note}", flush=True)
    for session, over in cross:
        print(over_line(session, over), flush=True)
    for why in chrome_refused:
        print(f"IDLE-BUDGET-REFUSED {CHROME_SESSION} reference: {why}", flush=True)
    if chrome_refused:
        refused.append(CHROME_SESSION)
        report["chrome_refused"] = chrome_refused
    all_overs += [(session, *over) for session, over in cross]
    if cross or cross_notes:
        markdown.append("\n### across sessions\n\n" + "\n".join(
            [f"- {over_line(session, over)}" for session, over in cross] + [f"- {note}" for note in cross_notes]))
    if report.get("ratio_to_chrome"):
        markdown.append(ratio_table(report["ratio_to_chrome"]))
    over_power = power_overs(report)
    if over_power is not None:
        # Q9's work list for visible power (p14-energy.md): reported, never a budget over (D6 judges the total).
        report["power_over"] = over_power
        lines = power_attribution.over_lines(over_power)
        for line in lines:
            print(line, flush=True)
        markdown.append(f"\n### {POWER_SESSION} over {CHROME_POWER_SESSION}\n\n" + ("\n".join(f"- {l}" for l in lines) or "none"))
    report["over"] = [list(o) for o in all_overs]
    report["refused"] = refused
    report["session_exits"] = {name: entry.get("exit") for name, entry in report["sessions"].items()}
    text = f"# cmux idle budget, {machine['host']} (macOS {machine['macos']}), settle {opts.settle:g} s, window {opts.measure:g} s\n" + "\n".join(markdown)
    print(text, flush=True)
    with open(os.path.join(out, "idle-budget.md"), "w") as handle:
        handle.write(text + "\n")
    path = opts.json or os.path.join(out, "idle-budget.json")
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w") as handle:
        json.dump(report, handle, indent=1)
    print(f"IDLE-BUDGET over={len(all_overs)} refused={json.dumps(refused)} sessions={json.dumps(report['session_exits'])} "
          f"json={path}", flush=True)
    sys.exit(exit_code(opts.gate, all_overs, refused))


if __name__ == "__main__":
    main()
