"""SCRATCH (RESIZE MAIN BUDGET, never merge): main-thread time profile of one bench round, the bench app's pid only.

`start(pid, label, out)` runs `xctrace record --template 'Time Profiler' --attach PID` (falls back to --all-processes
filtered to PID when attaching is refused); `stop(handle)` ends it, exports the time-profile table and keeps the main
thread's samples of that pid: time (ns from the trace start), weight (ns) and the stack (leaf first, symbol and binary).

`summarize(samples)` splits the main thread's on-CPU time into bursts (consecutive samples; a gap of more than
GAP_NS ends a burst). A burst is one stretch of main-thread work: a 120 Hz motion frame's work is one burst or a few
close ones. Per burst: its ms and its heaviest app frames. Over the round: ms per symbol (self and inclusive) in all
bursts and in the heavy bursts (>= HEAVY_MS), so the frames that make the p99 are named.

Background noise (cmux-ad m6, STATUS 13205): `background_cpu()` / `background_delta()` read the CPU seconds of
mediaanalysisd and the Spotlight daemons over a round; a round over BACKGROUND_LIMIT_S is marked and dropped by the
reader.
"""
import collections, glob, os, signal, subprocess, time

GAP_NS = 1_600_000
HEAVY_MS = 6.0
BACKGROUND_DAEMONS = ("mediaanalysisd", "mds", "mds_stores", "mdworker", "mdworker_shared", "mdbulkimport",
                      "photoanalysisd", "corespotlightd", "mediaanalysisd-access")
BACKGROUND_LIMIT_S = 1.0
# Frames that are the run loop's plumbing, never the work itself (skipped when naming a burst's app frames).
PLUMBING = ("CFRunLoop", "__CFRunLoop", "_DPSNextEvent", "NSApplication run", "-[NSApplication run]", "NSApplicationMain",
            "main", "start", "dyld", "_NSHandleCarbonMenuEvent", "RunCurrentEventLoopInMode", "ReceiveNextEventCommon",
            "BlockUntilNextEventMatchingListInMode", "_BlockUntilNextEventMatchingListInModeWithFilter",
            "-[NSApplication(NSEventRouting) _nextEventMatchingEventMask:untilDate:inMode:dequeue:]",
            "__CFRUNLOOP_IS_CALLING_OUT_TO_AN_OBSERVER_CALLBACK_FUNCTION__",
            "__CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE0_PERFORM_FUNCTION__",
            "__CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__", "_dispatch_main_queue_drain",
            "_dispatch_main_queue_callback_4CF", "_dispatch_client_callout", "_dispatch_call_block_and_release")


def background_cpu():
    """CPU seconds so far per pid of the background daemons ({pid: (name, seconds)}); {} when ps fails."""
    try:
        out = subprocess.run(["ps", "-A", "-o", "pid=,time=,comm="], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    found = {}
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        name = os.path.basename(parts[2].strip())
        if name not in BACKGROUND_DAEMONS:
            continue
        seconds = 0.0
        for field in parts[1].replace("-", ":").split(":"):
            try:
                seconds = seconds * 60 + float(field)
            except ValueError:
                seconds = 0.0
        found[parts[0]] = (name, seconds)
    return found


def background_delta(before):
    by_name = {}
    for pid, (name, seconds) in background_cpu().items():
        used = seconds - before.get(pid, (name, 0.0))[1]
        if used > 0:
            by_name[name] = round(by_name.get(name, 0.0) + used, 2)
    total = round(sum(by_name.values()), 2)
    return {"by_name": by_name, "total_s": total, "limit_s": BACKGROUND_LIMIT_S, "over_limit": total > BACKGROUND_LIMIT_S}


def _env():
    xcodes = sorted(glob.glob("/Applications/Xcode*.app"))
    env = dict(os.environ)
    if xcodes and not env.get("DEVELOPER_DIR"):
        env["DEVELOPER_DIR"] = xcodes[-1] + "/Contents/Developer"
    return env


def start(pid, label, out, seconds=60):
    """Starts recording; returns a handle for stop(), or None when xctrace cannot start."""
    env = _env()
    trace = os.path.join(out, f"xct-{label}.trace")
    for mode in (["--attach", str(pid)], ["--all-processes"]):
        proc = subprocess.Popen(["xcrun", "xctrace", "record", "--template", "Time Profiler", *mode, "--time-limit",
                                 f"{seconds}s", "--output", trace, "--no-prompt"], env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT)
        time.sleep(4)  # bench script: the recorder starts before the round
        if proc.poll() is None:
            return {"proc": proc, "trace": trace, "env": env, "mode": mode[0], "pid": pid, "label": label}
        tail = (proc.communicate()[0] or b"").decode(errors="replace")[-600:]
        print(f"MAIN-PROFILE {label}: xctrace {mode[0]} exited at once: {tail}", flush=True)
    return None


def stop(handle):
    """Ends the recording; returns {mode, samples: [(t_ns, weight_ns, stack_index)], stacks: [[frame_index...]],
    frames: [[name, binary]]} of the pid's main thread, or {error}."""
    if not handle:
        return None
    proc = handle["proc"]
    proc.send_signal(signal.SIGINT)
    try:
        tail = proc.communicate(timeout=240)[0].decode(errors="replace")[-600:]
    except subprocess.TimeoutExpired:
        proc.kill()
        tail = "timeout"
    xml = handle["trace"] + ".xml"
    exported = subprocess.run(["xcrun", "xctrace", "export", "--input", handle["trace"], "--xpath",
                               '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]', "--output", xml],
                              env=handle["env"], capture_output=True, text=True, timeout=900)
    if exported.returncode != 0 or not os.path.exists(xml):
        return {"mode": handle["mode"], "error": f"export rc {exported.returncode}: {exported.stderr[-600:]}", "record_tail": tail}
    result = parse(xml, handle["pid"])
    result["mode"] = handle["mode"]
    try:
        os.unlink(xml)
        subprocess.run(["rm", "-rf", handle["trace"]], timeout=120)
    except OSError:
        pass
    return result


def parse(xml, pid):
    import xml.etree.ElementTree as ET
    byid = {}

    def resolve(e):
        if e is None:
            return None
        r = e.get("ref")
        return byid.get(r, e) if r else e

    frame_index, frames = {}, []
    stack_index, stacks = {}, []
    samples = []
    threads_ms = collections.Counter()
    pid_text = f"pid: {pid})"
    for _, e in ET.iterparse(xml, events=("end",)):
        if e.get("id"):
            byid[e.get("id")] = e
        if e.tag != "row":
            continue
        th = resolve(e.find("thread"))
        tfmt = th.get("fmt", "") if th is not None else ""
        pr = resolve(e.find("process"))
        pfmt = pr.get("fmt", "") if pr is not None else tfmt
        if pid_text not in pfmt and pid_text not in tfmt:
            continue
        w = resolve(e.find("weight"))
        weight = int(w.text) if w is not None and w.text and w.text.isdigit() else 1_000_000
        threads_ms[tfmt.split(" (")[0][:60]] += weight
        if "Main Thread" not in tfmt:
            continue
        st = resolve(e.find("sample-time"))
        t = int(st.text) if st is not None and st.text and st.text.isdigit() else 0
        bt = resolve(e.find("tagged-backtrace"))
        if bt is not None and bt.tag == "tagged-backtrace":
            bt = resolve(bt.find("backtrace"))
        elif bt is None:
            bt = resolve(e.find("backtrace"))
        names = []
        if bt is not None:
            for f in bt.findall("frame"):
                f = resolve(f)
                b = resolve(f.find("binary"))
                key = (f.get("name", "?"), b.get("name", "?") if b is not None else "?")
                if key not in frame_index:
                    frame_index[key] = len(frames)
                    frames.append(list(key))
                names.append(frame_index[key])
        tup = tuple(names[:120])
        if tup not in stack_index:
            stack_index[tup] = len(stacks)
            stacks.append(list(tup))
        samples.append([t, weight, stack_index[tup]])
    samples.sort()
    return {"samples": samples, "stacks": stacks, "frames": frames,
            "threads_ms": {k: round(v / 1e6, 1) for k, v in threads_ms.most_common(12)}}


def app_frame(stack, frames, app_binaries):
    """The leaf-most frame of the app's own code in a stack (its name), else the leaf."""
    for index in stack:
        name, binary = frames[index]
        if binary in app_binaries and not any(name.startswith(p) for p in PLUMBING):
            return name
    return frames[stack[0]][0] if stack else "?"


def summarize(profile, app_binaries, heavy_ms=HEAVY_MS):
    """Bursts and per-symbol ms of a stop() result (see the module docstring)."""
    if not profile or profile.get("error") or not profile.get("samples"):
        return {"error": (profile or {}).get("error", "no main-thread samples")}
    samples, stacks, frames = profile["samples"], profile["stacks"], profile["frames"]
    bursts, current = [], []
    for sample in samples:
        if current and sample[0] - current[-1][0] > GAP_NS:
            bursts.append(current)
            current = []
        current.append(sample)
    if current:
        bursts.append(current)
    t0 = samples[0][0]
    incl_all, incl_heavy, self_all, app_heavy = (collections.Counter() for _ in range(4))
    rows = []
    heavy = 0
    for burst in bursts:
        ms = sum(s[1] for s in burst) / 1e6
        is_heavy = ms >= heavy_ms
        heavy += is_heavy
        per = collections.Counter()
        for _, weight, si in burst:
            stack = stacks[si]
            names = set(frames[i][0] for i in stack)
            for n in names:
                incl_all[n] += weight
                if is_heavy:
                    incl_heavy[n] += weight
            if stack:
                self_all[frames[stack[0]][0]] += weight
            leaf_app = app_frame(stack, frames, app_binaries)
            per[leaf_app] += weight
            if is_heavy:
                app_heavy[leaf_app] += weight
        if is_heavy:
            rows.append({"at_ms": round((burst[0][0] - t0) / 1e6, 1), "ms": round(ms, 1),
                         "top": [[n[:110], round(w / 1e6, 1)] for n, w in per.most_common(6)]})
    total = sum(s[1] for s in samples) / 1e6
    top = lambda c, n: [[k[:140], round(v / 1e6, 1)] for k, v in c.most_common(n)]
    return {"main_sampled_ms": round(total, 1), "bursts": len(bursts), "heavy_bursts": heavy, "heavy_ms": heavy_ms,
            "burst_ms": sorted(round(sum(s[1] for s in b) / 1e6, 1) for b in bursts)[-12:],
            "heavy": rows[:40], "self_ms": top(self_all, 30), "incl_ms": top(incl_all, 60),
            "heavy_incl_ms": top(incl_heavy, 60), "heavy_app_leaf_ms": top(app_heavy, 30)}
