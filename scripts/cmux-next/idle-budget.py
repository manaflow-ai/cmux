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
wakeup to what it measures.

Sessions (--sessions):
  light         the launch window with its terminal (Home's pages run in Chromium by default)
  light-webkit  the same with browser.defaultEngine webkit: no Chromium at all
  light-hidden  the light session with the app hidden (Show/Hide All Windows hidden=true)
  Each session starts from an empty saved session (`fresh_session`).
  stress-static  STRESS with its pages served without their rAF spinner (STRESS's own pages animate: not idle)
  stress   STRESS (scripts/cmux-next/perf-stress-session.py: 60 workspaces, a 12-pane grid of 6 tabs each,
           Chromium pages elsewhere); its 10 busy terminals are stopped (Ctrl-C) before the settle, so the
           terminals are quiet
  chrome-static  the reference: a Chromium browser (--chrome-app) with tabs-static's 16 pages as tabs, the first
           shown, and the uBlock Origin --app bundles (--chrome-ublock), launched as xbench launches Chrome
           (cloned template profile, its switches, CDP /json/new), settled as long as tabs-static; kinds browser,
           renderer, extension, gpu, utility, crashpad. The bundled uBlock Origin is Manifest V2: branded Google
           Chrome ignores --load-extension since 137 and Chromium runs no MV2 since 139, so --chrome-app must be a
           Chromium that carries the MV2 patch cmux's CEF carries (ungoogled-chromium of cmux's Chromium major:
           cmux_extensions_manifestv2.patch comes from it). A browser that cannot run it (branded Chrome 137+,
           Chrome for Testing 139+) fails the session before it launches. The report gets a `chrome` block and
           `ratio_to_chrome` rows (the budget's, judged once with the other cross-session rows; a Chrome value
           under the field's noise floor counts as the floor). A row whose two sessions did not both run uBlock
           Origin, or whose Chrome pages are not tabs-static's shape, is `unequal`: reported, not judged; with
           --gate a failed or unequal chrome-static run exits 1 (IDLE-BUDGET-REFUSED).

A session that fails (STRESS refuses a window under the Dock, a launch fails) is recorded with its exit
code (`session_exits` in the report) and the others still run; the script exits 0 unless --gate.

Budget: scripts/cmux-next/idle-budget.json, schema v2 (its _doc): per process kind with per-session overrides,
sums (app+daemon, tree), ratios to another session of the run and to chrome-static (judged once every session
is measured, whatever the --sessions order), xbench rows (--xbench), allowed_periodic (wakeup-audit.py) and
assertions_allowed_when. A missing or unknown value is reported, not judged (IDLE-BUDGET-NOT-JUDGED lines); a sum
with one unknown part is unknown; a v1 file (kinds only) still loads. Every session runs with both keep-awake
settings off. Over budget prints IDLE-BUDGET-OVER lines; the exit code is 0 unless --gate (no CI gate: the perf
cron runs it and reports).

Use (fleet only, a host with a GUI console session; never on a laptop in use):
  python3 scripts/cmux-next/idle-budget.py --app "<...>/cmux DEV <tag>.app" --out DIR \\
      [--sessions light,stress] [--settle 60] [--measure 60] [--json DIR/idle-budget.json]
  D6 on an xbench.py result (any host): python3 scripts/cmux-next/idle-budget.py --xbench OUT/results.json [--gate]
  On the fleet through the allowlisted entry (STRESS needs the 1920 x 1080 virtual display):
    scripts/measure/split-spring.sh --suite=idle-budget --vdisplay=120 [...]

Output: one `IDLE-BUDGET-MACHINE {json}` line, one `IDLE-BUDGET-ROW {json}` line per session and process
kind, a Markdown table, and --json with every sample.
"""
import argparse, ctypes, fnmatch, hashlib, json, os, platform, plistlib, re, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "perf-bench"))
import procs  # noqa: E402  (process set of one app: descendants, bundle processes, responsible XPC processes)
import tab_pages  # noqa: E402  (the tab-page server and the Chromium process classifier)

BUDGET_FILE = os.path.join(HERE, "idle-budget.json")
STRESS_FILE = os.path.join(HERE, "perf-stress-session.py")

# ---------------------------------------------------------------------------------------------------------
# Per-thread counters (libproc, same user, no root)

PROC_PIDLISTTHREADIDS = 28
PROC_PIDTHREADID64INFO = 15


class _ThreadInfo(ctypes.Structure):
    _fields_ = [("user_time", ctypes.c_uint64), ("system_time", ctypes.c_uint64), ("cpu_usage", ctypes.c_int32),
                ("policy", ctypes.c_int32), ("run_state", ctypes.c_int32), ("flags", ctypes.c_int32),
                ("sleep_time", ctypes.c_int32), ("curpri", ctypes.c_int32), ("priority", ctypes.c_int32),
                ("maxpriority", ctypes.c_int32), ("name", ctypes.c_char * 64)]


def threads(pid):
    """{thread id: (cpu ns, name)} of `pid` now; {} when it is gone."""
    libproc = procs._darwin().libproc
    ids = (ctypes.c_uint64 * 8192)()
    size = libproc.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(PROC_PIDLISTTHREADIDS), ctypes.c_uint64(0),
                                ctypes.byref(ids), ctypes.c_int(ctypes.sizeof(ids)))
    out = {}
    for index in range(max(0, size) // 8):
        info = _ThreadInfo()
        got = libproc.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(PROC_PIDTHREADID64INFO), ctypes.c_uint64(ids[index]),
                                   ctypes.byref(info), ctypes.c_int(ctypes.sizeof(info)))
        if got == ctypes.sizeof(info):
            out[ids[index]] = (info.user_time + info.system_time, info.name.decode(errors="replace"))
    return out


# ---------------------------------------------------------------------------------------------------------
# Process kinds (the budget's keys)

# Chromium utility processes by service (content/browser/utility_process_host.cc names them by
# --utility-sub-type, the mojo interface the process serves).
UTILITY_KINDS = {"network.mojom.NetworkService": "cef-network", "storage.mojom.StorageService": "cef-storage",
                 "audio.mojom.AudioService": "cef-audio"}


def kind(cmd):
    """The budget kind of a process of the app's set."""
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


def read_rpc(app, method, params=None):
    reply = app.rpc(method, params or {}, timeout=30)
    return reply if isinstance(reply, dict) and not reply.get("error") else {}


def snapshot(commands):
    """{pid: (command, procs.Usage, task overhead, threads)} of `commands` ({pid: command}) now."""
    return {pid: (cmd, procs.usage(pid), procs.overhead(pid), threads(pid)) for pid, cmd in commands.items()}


def process_rows(first, last, elapsed, gpu0, gpu1, classify):
    """One row per process alive at the window's end, from two snapshots and two GPU reads `elapsed` seconds
    apart, its kind from `classify`; a process that started inside the window counts from its start (`partial`)."""
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
        rows.append(process_row(pid, cmd, c0, c1, elapsed, gpu=procs.gpu_ms_per_s(gpu0, gpu1, pid, elapsed),
                                threads_now=o1[1], csw=procs._delta32(o1[4], o0[4]), ran=ran, classify=classify))
    return rows


def measure(app, instance, seconds):
    """Counters of every process of the app over `seconds` with no input."""
    hangs0 = read_rpc(app, "debug.hangs", {"limit": 0})
    ledger0 = read_rpc(app, "debug.wakeups")
    counters0 = app_counters(app)
    first = snapshot(process_set(instance))
    gpu0 = procs.gpu_ns_by_pid()
    coalition0 = procs.coalition_of(instance.pid)
    began = time.monotonic()
    time.sleep(seconds)  # bench: the idle window itself (nothing is sent to the app in it)
    elapsed = time.monotonic() - began
    coalition1 = procs.coalition_of(instance.pid)
    gpu1 = procs.gpu_ns_by_pid()
    last = snapshot(process_set(instance))
    hangs1 = read_rpc(app, "debug.hangs", {"limit": 0})
    ledger1 = read_rpc(app, "debug.wakeups", {"run_loop": True})
    counters1 = app_counters(app)
    result = {"seconds": round(elapsed, 1), "processes": process_rows(first, last, elapsed, gpu0, gpu1, kind),
              "coalition": procs.coalition_rates(coalition0, coalition1, elapsed)}
    if "main_wakes" in hangs0 and "main_wakes" in hangs1:
        result["main_wakes_per_s"] = round((hangs1["main_wakes"] - hangs0["main_wakes"]) / elapsed, 3)
    owners = ledger_rates(ledger0, ledger1, elapsed)
    if owners is not None:
        result["ledger"] = owners
    rates = {key: round((counters1[key] - counters0[key]) / elapsed, 3) for key in counters1
             if key in counters0 and counters1[key] != counters0[key]}
    if rates:
        result["app_counter_rates"] = rates
    if ledger1.get("main_run_loop"):
        result["main_run_loop_timers"] = run_loop_timers(ledger1["main_run_loop"])
    return result


def process_row(pid, cmd, first, last, elapsed, gpu, threads_now, csw, ran, classify=None):
    """One process's row of the window from two procs.Usage reads (`first` None: it started inside the
    window, `partial`); its kind from `classify` (default: the cmux kinds, `kind`)."""
    got = procs.rates(first, last, elapsed)
    return {
        "pid": pid, "kind": (classify or kind)(cmd), "command": cmd[:160], "partial": first is None,
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
# tabs-static's page set (1 shown Chromium tab, 10 hidden Chromium, 5 hidden WebKit, p14-energy-003): in Chrome
# every page is a tab, the first one shown.
TABS_STATIC_PAGES = 1 + 10 + 5
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


def chrome_shape_unequal(page_targets, visibility, tabs=TABS_STATIC_PAGES):
    """Why Chrome's pages at the window's end are not tabs-static's shape: `tabs` page targets, page 0 visible and
    every other hidden (`visibility`: the static pages' last document.visibilityState reports)."""
    reasons = []
    if page_targets != tabs:
        reasons.append(f"Chrome had {page_targets} page targets, tabs-static has {tabs}")
    want = {str(n): "visible" if n == 0 else "hidden" for n in range(tabs)}
    wrong = [f"{n}={visibility.get(n)}" for n in want if visibility.get(n) != want[n]]
    if wrong:
        reasons.append(f"Chrome's tab visibility is not 1 shown, {tabs - 1} hidden: " + ", ".join(wrong))
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
            if name != CHROME_SESSION:
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


# Both keep-awake settings off (D11): their shipping default is pluggedIn, and a session that asks for keep-awake
# names them in its budget `settings`.
KEEP_AWAKE_OFF = {"sessions": {"keepAwake": "off"}, "phone": {"keepAwake": "off"}}
BASE_CONFIG = {"appearance": {"backgroundOpacity": 1}, **KEEP_AWAKE_OFF}  # BenchApp's default, keep-awake off
# The sessions: light (the launch window: one terminal, Home's pages in Chromium by default), light-webkit (the
# same with `browser.defaultEngine: webkit`, so no Chromium runs at all), light-hidden (the app hidden: no window
# can be seen), stress (STRESS, its busy terminals stopped), chrome-static (the reference, run_chrome_static).
# `config` adds to BASE_CONFIG; `settle_min` (seconds) is the shortest settle the session takes (settle_seconds).
# Hidden Chromium tabs freeze FREEZE_HIDDEN_TABS_S after they hide (p14-energy-003's tabs-static sets it), and the
# tab sessions settle FREEZE_GRACE_S past it; chrome-static settles as long, so both windows start after the
# same settle (Chrome's own background throttling starts within that time).
FREEZE_HIDDEN_TABS_S = 30
FREEZE_GRACE_S = 15
SESSIONS = {
    "light": {},
    "light-webkit": {"config": {"browser": {"defaultEngine": "webkit"}}},
    "light-hidden": {"hide": True},
    "stress": {},
    "stress-static": {},
    CHROME_SESSION: {"chrome": True, "settle_min": FREEZE_HIDDEN_TABS_S + FREEZE_GRACE_S},
}


def session_config(session):
    """The cmux-next.json of `session`: BASE_CONFIG with the session's own keys on top."""
    return {**BASE_CONFIG, **(SESSIONS[session].get("config") or {})}


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


def run_chrome_static(opts, out):
    """The chrome-static entry: the --chrome-app browser through xbench's launcher (an APFS clone of a template
    profile keyed on the browser build and uBlock Origin, --user-data-dir, xbench's switches, tabs over CDP
    /json/new) with tabs-static's static pages from the shared page server, every page loaded, the first shown,
    and the uBlock Origin the cmux app bundles; settled and measured as the cmux sessions are, its processes
    classified by chrome_kind. Raises before launch when the browser cannot run that uBlock Origin."""
    import xbench  # scripts/perf-bench (on sys.path): the Chrome launcher the cross-browser bench uses
    bundle = os.path.abspath(opts.chrome_app)
    if not os.path.isdir(bundle):
        raise RuntimeError(f"{CHROME_SESSION}: no {bundle}")
    if procs.main_pid(bundle):
        raise RuntimeError(f"{CHROME_SESSION}: {bundle} is already running; its processes would be measured too")
    with open(os.path.join(bundle, "Contents/Info.plist"), "rb") as handle:
        info = plistlib.load(handle)
    bundle_id, version = info.get("CFBundleIdentifier"), xbench.bundle_version(bundle)
    cmux_ublock = os.path.join(os.path.realpath(opts.app), UBLOCK_IN_APP)
    ublock = None if opts.chrome_ublock == "none" else opts.chrome_ublock or cmux_ublock
    manifest = read_manifest(ublock) if ublock else None
    if manifest:
        refusal = reference_refusal(bundle_id, version, manifest)
        if refusal:
            raise RuntimeError(f"{CHROME_SESSION}: {refusal}; pass --chrome-app a Chromium that runs MV2 "
                               "(ungoogled-chromium of cmux's Chromium major)")
    chrome_version = (manifest or {}).get("version")
    work = os.path.join(out, CHROME_SESSION)
    helper = xbench.Helper(opts.chrome_helper_cache)
    pages = tab_pages.TabPages()
    browser = xbench.ChromiumBrowser("chrome", bundle, helper, None, extensions=[ublock] if manifest else [])
    profile = os.path.join(work, "run")
    try:
        template = os.path.join(work, "template-" + template_key(bundle, version, ublock if manifest else None,
                                                                 chrome_version))
        built = build_template(browser, template, opts.chrome_template_settle)
        xbench.clone(template, profile)
        browser.launch(profile, None)
        browser.ready()
        # DevTools answers before the startup browser opens its first tab (the handler starts in
        # PreMainMessageLoopRun, StartupBrowserCreator opens the window after it): wait for that tab, then every
        # page that is not one of tabs-static's closes, as xbench's adopt_first does.
        wait_for(lambda: browser.pages(), 30, "no startup page target")
        urls = [pages.url("static", index) for index in range(TABS_STATIC_PAGES)]
        for index, url in enumerate(urls):
            browser.new_tab(url, str(index))
            wait_for(lambda: str(index) in pages.loaded, 90, f"tab {url} did not load")
        for target in browser.pages():
            if target.get("url") not in urls:
                browser.close(target["id"])
        browser.activate(browser.tabs[0])
        settle = settle_seconds(CHROME_SESSION, opts.settle)
        time.sleep(settle)  # bench: the pages settle and hidden tabs pass Chrome's background throttling
        first = snapshot(browser.instance.pids())
        gpu0 = procs.gpu_ns_by_pid()
        began = time.monotonic()
        time.sleep(opts.measure)  # bench: the idle window itself (nothing is sent to Chrome in it)
        elapsed = time.monotonic() - began
        gpu1 = procs.gpu_ns_by_pid()
        last = snapshot(browser.instance.pids())
        targets = browser.extension_targets()
        page_targets = len(browser.pages())
        result = {"seconds": round(elapsed, 1), "processes": process_rows(first, last, elapsed, gpu0, gpu1, chrome_kind)}
        visibility = dict(pages.visibility)
        running = any(t.get("url", "").startswith(f"chrome-extension://{UBLOCK_ID}/") for t in targets)
        chrome = {"app": bundle, "bundle_id": bundle_id, "version": version, "build": info.get("CFBundleVersion"),
                  "switches": browser.switches(), "settle_s": settle, "template_built": built,
                  "pages": {"tabs": len(urls), "page_targets": page_targets, "shown": 1, "set": "tabs-static",
                            "loaded": len(pages.loaded), "visibility": visibility},
                  "ublock": {"cmux_version": manifest_version(cmux_ublock), "chrome_version": chrome_version,
                             "running": running},
                  "unequal": chrome_shape_unequal(page_targets, visibility),
                  "extension_targets": [target.get("url", "")[:120] for target in targets]}
        return {"chrome": chrome, "result": result}
    finally:
        browser.quit()
        pages.close()
        shutil.rmtree(profile, ignore_errors=True)  # the keyed template stays for a rerun into `out`


def chrome_static_entry(opts, out, session, markdown):
    """Runs chrome-static and prints its rows; a failure is recorded as a cmux session's failure is."""
    try:
        entry = run_chrome_static(opts, out)
        entry["kinds"] = aggregate(entry["result"])
        entry["over"] = []
        entry["exit"] = 0
        for name, values in entry["kinds"].items():
            print("IDLE-BUDGET-ROW " + json.dumps({"session": session, "kind": name, **values}), flush=True)
        print("IDLE-BUDGET-CHROME " + json.dumps({k: v for k, v in entry["chrome"].items() if k != "switches"}), flush=True)
        markdown.append(table(session, entry["kinds"], []))
    except Exception as error:  # noqa: BLE001 - as a cmux session's failure: recorded, the others still run
        entry = {"exit": 1, "error": f"{type(error).__name__}: {error}"[:500]}
        print(f"IDLE-BUDGET-SESSION-FAILED {session} exit=1 {entry['error'][:300]}", flush=True)
        markdown.append(f"\n### {session}\n\nnot measured: {entry['error'][:300]}")
    return entry


def chrome_reference(report):
    """The chrome-static block with its kinds, or None when it was not measured."""
    entry = report["sessions"].get(CHROME_SESSION) or {}
    return {**entry["chrome"], "kinds": entry["kinds"]} if entry.get("kinds") and entry.get("chrome") else None


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


def table(session, kinds, overs):
    over_keys = {(k, f) for k, f, _, _ in overs}
    lines = [f"\n### {session}\n", "| process | n | threads (max) | wakeups/s (max) | pkg-idle wakeups/s | main wakes/s | "
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


def main():
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
    parser.add_argument("--gate", action="store_true", help="exit 1 when a value is over its budget")
    parser.add_argument("--sample", type=float, default=10,
                        help="seconds of /usr/bin/sample of the app after the window, to name the threads that woke (0: none)")
    parser.add_argument("--chrome-app", default=CHROME_APP,
                        help="the chrome-static browser: a Chromium that runs Manifest V2 (ungoogled-chromium of "
                        "cmux's Chromium major); branded Chrome 137+ and Chrome for Testing 139+ are refused")
    parser.add_argument("--chrome-ublock", default=None,
                        help="the unpacked uBlock Origin Chrome loads in chrome-static (default: the copy in --app; "
                        "`none`: without it, which marks the Chrome ratios unequal)")
    parser.add_argument("--chrome-template-settle", type=float, default=45,
                        help="seconds Chrome's template profile runs before its first clone")
    parser.add_argument("--chrome-helper-cache", default=os.path.expanduser("~/Library/Caches/cmux-perf-bench"),
                        help="xbench's benchhelper cache")
    opts, _unknown = parser.parse_known_args()
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
    from bench_launch import BenchApp
    out = opts.out or os.path.join(os.getcwd(), "artifacts", "idle-budget")
    os.makedirs(out, exist_ok=True)
    machine = host_facts()
    print("IDLE-BUDGET-MACHINE " + json.dumps(machine), flush=True)
    report = {"machine": machine, "app": opts.app, "settle_s": opts.settle, "measure_s": opts.measure, "sessions": {}}
    all_overs = []
    markdown = []
    for session in [s for s in opts.sessions.split(",") if s]:
        if session not in SESSIONS:
            raise SystemExit(f"idle-budget: unknown session {session} (one of {', '.join(SESSIONS)})")
        if SESSIONS[session].get("chrome"):
            report["sessions"][session] = chrome_static_entry(opts, out, session, markdown)
            continue
        app = BenchApp(opts.app, out=os.path.join(out, session), config=session_config(session))
        try:
            entry = {"fresh_session": fresh_session(app)}
            app.launch()
            if session in ("stress", "stress-static"):
                entry["stress"] = build_stress(app, static=session == "stress-static")
            if SESSIONS[session].get("hide"):
                entry["hide"] = app.rpc("action.run", {"action": "showHideAllWindows", "args": {"hidden": True},
                                                       "focus": False, "origin": "script"}, timeout=30)
            time.sleep(opts.settle)  # bench: the session settles (page loads, Chromium's post-load work) before the window
            instance = procs.Instance(app.app, app.process.pid)
            window_before = window_state(app)
            result = measure(app, instance, opts.measure)
            result["window_state"] = {"start": window_before, "end": window_state(app)}
            print(f"IDLE-BUDGET-WINDOW {session} " + json.dumps(result["window_state"]), flush=True)
            if opts.sample:
                result["sample"] = sample_threads(app.process.pid, opts.sample, os.path.join(out, session, "sample-app.txt"))
            kinds = aggregate(result)
            overs = over_budget(session, kinds, budget)
            notes = sum_notes(session, kinds, budget)
            entry.update({"result": result, "kinds": kinds, "over": [list(o) for o in overs], "not_judged": notes})
            report["sessions"][session] = entry
            for name, values in kinds.items():
                print("IDLE-BUDGET-ROW " + json.dumps({"session": session, "kind": name, **values}), flush=True)
            for row in result["processes"]:
                if row["kind"] in ("app", "daemon", "holder", "acpmux") and row["ran"]:
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
            all_overs += [(session, *o) for o in overs]
            markdown.append(table(session, kinds, overs) + "\n\n" + coalition_line(result.get("coalition")))
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
            app.stop()
    cross, cross_notes, refused = judge_across(report, budget, CHROME_SESSION in opts.sessions.split(","))
    for note in cross_notes:
        print(f"IDLE-BUDGET-NOT-JUDGED {note}", flush=True)
    for session, over in cross:
        print(over_line(session, over), flush=True)
    for reason in refused:
        print(f"IDLE-BUDGET-REFUSED {reason}", flush=True)
    all_overs += [(session, *over) for session, over in cross]
    if cross or cross_notes:
        markdown.append("\n### across sessions\n\n" + "\n".join(
            [f"- {over_line(session, over)}" for session, over in cross] + [f"- {note}" for note in cross_notes]))
    if report.get("ratio_to_chrome"):
        markdown.append(ratio_table(report["ratio_to_chrome"]))
    report["over"] = [list(o) for o in all_overs]
    report["session_exits"] = {name: entry.get("exit") for name, entry in report["sessions"].items()}
    text = f"# cmux idle budget, {machine['host']} (macOS {machine['macos']}), settle {opts.settle:g} s, window {opts.measure:g} s\n" + "\n".join(markdown)
    print(text, flush=True)
    with open(os.path.join(out, "idle-budget.md"), "w") as handle:
        handle.write(text + "\n")
    path = opts.json or os.path.join(out, "idle-budget.json")
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w") as handle:
        json.dump(report, handle, indent=1)
    print(f"IDLE-BUDGET over={len(all_overs)} refused={len(refused)} sessions={json.dumps(report['session_exits'])} "
          f"json={path}", flush=True)
    sys.exit(1 if opts.gate and (all_overs or refused) else 0)


if __name__ == "__main__":
    main()
