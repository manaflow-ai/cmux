#!/usr/bin/env python3
"""p08-startup-072 hour-0 launch seed: warm launches of a tagged app with a seeded terminal session.

Measurement scaffolding on a scratch ref (cp/p08-startup-072-m*), never landed. Run through
scripts/measure/split-spring.sh --suite=launch-seed. In order:

  seed      one launch on an empty state; makes WORKSPACES workspaces of three terminal tabs and a split
            through the daemon socket, selects project-01's first terminal, quits the app (the daemon stays:
            warm).
  bench     RUNS warm launches: every launch mark (CMUX_NEXT_LAUNCH_MARKS_FD), main-thread stalls >= HANGS ms
            (debug.hangs) over the first SETTLE s.
  profile   PROFILES warm launches under `xctrace record --template 'Time Profiler' --all-processes`: the app's
            main-thread samples from its first sample to first_window_frame_committed (self, inclusive, the
            first cmux frame, the chain of cmux frames), and the main-thread samples to +3 s.
  probe     PROBES warm launches with scripts/measure/blocking-probe/probe.c inserted and
            CMUX_BLOCKING_PROBE_UNTIL_MS = the bench's first_window_frame_committed p50: the main-thread file,
            socket, process, lock and sleep waits before the first frame, ranked by
            scripts/measure/blocking-probe-report.py.

Everything goes to --json (one file, the step's artifact) and a summary to stdout.
"""
import argparse
import collections
import glob
import importlib.util
import json
import os
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
_spec = importlib.util.spec_from_file_location("bench_startup", os.path.join(HERE, "bench-startup.py"))
bs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bs)

FIRST = "first_window_frame_committed"
TERM = bs.FINAL_MARK
NEVER = "launch-seed-072.never"
RAW_ROWS = []
PARSE_NOTES = []
CMUX_IMAGE = re.compile(r"^(cmux|CmuxNext|libcmux)", re.I)


def log(text):
    print(text, flush=True)


def pct(values, q):
    values = sorted(values)
    if not values:
        return None
    index = min(len(values) - 1, max(0, int(round(q * (len(values) - 1)))))
    return values[index]


def clean(tag):
    left = bs.app_pids(tag)
    if left:
        bs.stop(left)


def seed(tag, scratch, timeout, workspaces):
    from bench_cli_storm import Client  # noqa: E402
    bs.reset_state(tag)
    prime = bs.Launch(tag, scratch)
    info = {}
    try:
        if not prime.wait_for([FIRST], timeout):
            raise SystemExit("launch-seed: the seeding launch never committed a window frame")
        daemon = Client(bs.daemon_socket(tag), timeout=10)

        def listed():
            return {w["id"]: w for w in daemon.call("list-workspaces", cmd_key="cmd")["data"]["workspaces"]}

        for index in range(workspaces):
            before = listed()
            created = daemon.call("new-workspace", {"name": f"project-{index + 1:02d}"}, cmd_key="cmd")
            if not created.get("ok"):
                raise SystemExit(f"launch-seed: new-workspace failed: {created.get('error')}")
            workspace = next(w for key, w in listed().items() if key not in before)
            pane = workspace["screens"][0]["panes"][0]
            for _ in range(2):
                daemon.call("new-tab", {"pane": pane["id"]}, cmd_key="cmd")
            daemon.call("split", {"pane": pane["id"], "dir": "right"}, cmd_key="cmd")
        daemon.close()
        app = bs.app_client(tag)
        tab = bs.app_tab_id(app, "project-01", timeout)
        reply = app.call("action.run", {"action": "palette.goToTab", "target": {"kind": "tab", "id": tab}}) if tab else {}
        app.close()
        info["selected"] = bool(reply.get("ok"))
        info["seed_terminal_frame"] = prime.wait_for([TERM], timeout)
        prime.wait_for([NEVER], 3)  # the selection reaches the saved state
    finally:
        prime.quit()
        clean(tag)
    log(f"launch-seed: seeded {workspaces} workspaces; project-01 selected {info.get('selected')}; "
        f"terminal frame in the seeding launch {info.get('seed_terminal_frame')}")
    return info


def start(tag, scratch, extra_env=None):
    """bs.Launch, timed: Popen returns once the child has exec'd, so this is fork to exec (plus the limits)."""
    began = time.monotonic()
    launch = bs.Launch(tag, scratch, extra_env)
    launch.popen_ms = (time.monotonic() - began) * 1000
    return launch


def one_launch(tag, scratch, timeout, settle, extra_env=None, hangs=True):
    clean(tag)
    launch = start(tag, scratch, extra_env)
    stalls = None
    try:
        reached = launch.wait_for([TERM], timeout)
        launch.wait_for([NEVER], settle)
        if hangs and bs.HANG_THRESHOLD_MS:
            try:
                stalls = bs.launch_stalls(tag)
            except (OSError, SystemExit) as error:
                log(f"  debug.hangs failed: {error}")
    finally:
        launch.quit()
        clean(tag)
    return launch, reached, stalls


def bench(tag, scratch, runs, timeout, settle):
    results = []
    for index in range(runs):
        launch, reached, stalls = one_launch(tag, scratch, timeout, settle)
        marks = dict(launch.marks)
        results.append({"marks": marks, "terminal": reached, "stalls": stalls or [], "popen_ms": launch.popen_ms})
        log(f"  bench run {index + 1}: popen {launch.popen_ms:.0f} ms, {FIRST} {marks.get(FIRST, 'missing')} ms, {TERM} {marks.get(TERM, 'missing')} ms, "
            f"stalls {len(stalls or [])} ({sum(s['ms'] for s in stalls or []):.0f} ms)")
        for stall in (stalls or [])[:4]:
            log(f"    stall {stall['ms']:.0f} ms (cpu {stall['cpu_ms']:.0f}): " + " < ".join(stall["frames"][:5]))
    return results


def mark_table(results):
    names = collections.OrderedDict()
    for run in results:
        for name in run["marks"]:
            names.setdefault(name, None)
    table = {}
    for name in names:
        values = [run["marks"][name] for run in results if name in run["marks"]]
        table[name] = {"p50": statistics.median(values), "p95": pct(values, 0.95), "min": min(values), "max": max(values),
                       "n": len(values)}
    return dict(sorted(table.items(), key=lambda item: item[1]["p50"]))


def stall_sites(results):
    sites = collections.defaultdict(list)
    for run in results:
        for stall in run["stalls"]:
            sites[bs.stall_site(stall)].append(stall["ms"])
    rows = [{"site": site, "runs": len(values), "p50": statistics.median(values), "max": max(values), "total": sum(values)}
            for site, values in sites.items()]
    return sorted(rows, key=lambda row: -row["total"])


class Symbolicator:
    """atos for frames xctrace left as addresses (a stripped bench build), against the build's dSYM."""

    def __init__(self, app):
        self.dsyms = {}
        for path in glob.glob(os.path.join(os.path.dirname(app), "*.dSYM/Contents/Resources/DWARF/*")):
            self.dsyms[os.path.basename(path)] = path
        self.cache = {}

    def resolve(self, wanted):
        """wanted: {(binary_path, load_addr): {addr, ...}} -> {(binary_path, addr): name}."""
        out = {}
        for (path, load), addrs in wanted.items():
            target = self.dsyms.get(os.path.basename(path)) or path
            if not target or not os.path.exists(target):
                continue
            addrs = sorted(addrs)
            for start in range(0, len(addrs), 400):
                chunk = addrs[start:start + 400]
                done = subprocess.run(["xcrun", "atos", "-o", target, "-l", load, *chunk], capture_output=True, text=True)
                for addr, line in zip(chunk, done.stdout.splitlines()):
                    out[(path, addr)] = line.strip()
        return out


def export_samples(trace, xml_path):
    with open(xml_path, "w") as out:
        subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                        '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'], stdout=out, check=False)


def parse_samples(xml_path, pid, symbolicator):
    """The pid's main-thread samples: [(t_ns, weight_ns, [(name, binary), ...] leaf first)], and the pid's first sample."""
    byid = {}
    rows = []
    first = None
    first_any = None
    marker = f"pid: {pid})"
    unresolved = collections.defaultdict(set)

    def resolve(element):
        ref = element.get("ref")
        return byid.get(ref, element) if ref else element

    for _event, element in ET.iterparse(xml_path, events=("end",)):
        if element.get("id"):
            byid[element.get("id")] = element
        if element.tag != "row":
            continue
        thread = element.find("thread")
        thread = resolve(thread) if thread is not None else None
        fmt = thread.get("fmt", "") if thread is not None else ""
        if marker not in fmt:
            continue
        stamp = element.find("sample-time")
        stamp = resolve(stamp) if stamp is not None else None
        t_ns = int(stamp.text) if stamp is not None and stamp.text and stamp.text.isdigit() else None
        if t_ns is None:
            continue
        first_any = t_ns if first_any is None else min(first_any, t_ns)
        # Between fork and exec the pid is still the Python launcher: the app starts at its first own sample.
        if "python" not in fmt.lower():
            first = t_ns if first is None else min(first, t_ns)
        if not fmt.startswith("Main Thread") or "python" in fmt.lower():
            continue
        weight = element.find("weight")
        weight = resolve(weight) if weight is not None else None
        w_ns = int(weight.text) if weight is not None and weight.text and weight.text.isdigit() else 1000000
        backtrace = next((child for child in element.iter() if child.tag.endswith("backtrace")), None)
        backtrace = resolve(backtrace) if backtrace is not None else None
        if backtrace is not None and backtrace.tag == "tagged-backtrace":
            inner = next((child for child in backtrace.iter() if child.tag == "backtrace"), None)
            backtrace = resolve(inner) if inner is not None else backtrace
        if len(RAW_ROWS) < 4:
            RAW_ROWS.append(ET.tostring(element, encoding="unicode")[:3000])
        frames = []
        if backtrace is not None:
            for frame in backtrace.iter("frame"):
                frame = resolve(frame)
                binary = frame.find("binary")
                binary = resolve(binary) if binary is not None else None
                name = frame.get("name", "?")
                bname = binary.get("name", "") if binary is not None else ""
                if re.fullmatch(r"0x[0-9a-fA-F]+", name) and binary is not None and binary.get("path"):
                    unresolved[(binary.get("path"), binary.get("load-addr", "0x0"))].add(frame.get("addr", name))
                    name = ("@", binary.get("path"), frame.get("addr", name))
                frames.append((name, bname))
        rows.append((t_ns, w_ns, frames))
    names = symbolicator.resolve(unresolved) if unresolved else {}
    fixed = []
    for t_ns, w_ns, frames in rows:
        fixed.append((t_ns, w_ns, [((names.get((n[1], n[2]), n[2]) if isinstance(n, tuple) else n), b) for n, b in frames]))
    PARSE_NOTES.append({"first_any": first_any, "first_exec": first,
                        "fork_to_exec_ms": round((first - first_any) / 1e6, 1) if first and first_any else None})
    return fixed, first


def short(name):
    name = re.sub(r"\s*\(in [^)]*\)", "", name)
    return name[:140]


def aggregate(samples, start_ns, end_ns):
    window = [(t, w, f) for t, w, f in samples if start_ns <= t <= end_ns]
    total = sum(w for _, w, _ in window)
    self_sym, incl_sym, first_cmux, chains, images = (collections.Counter() for _ in range(5))
    for _t, w, frames in window:
        if not frames:
            continue
        self_sym[short(frames[0][0])] += w
        images[frames[0][1] or "?"] += w
        for name in {short(n) for n, _ in frames}:
            incl_sym[name] += w
        cmux = [short(n) for n, b in frames if CMUX_IMAGE.match(b or "")]
        first_cmux[cmux[0] if cmux else f"(no cmux frame) {short(frames[-1][0])[:60]}"] += w
        root_first = list(reversed(cmux))
        chains[" > ".join(root_first[:4]) if root_first else "(no cmux frame)"] += w

    def top(counter, limit, floor_ms=0.0):
        return [{"ms": round(v / 1e6, 2), "name": k} for k, v in counter.most_common(limit) if v / 1e6 >= floor_ms]

    return {"total_ms": round(total / 1e6, 2), "samples": len(window),
            "self": top(self_sym, 60), "inclusive": top(incl_sym, 150, 1.0), "first_cmux": top(first_cmux, 80),
            "chains": top(chains, 120, 0.5), "images": top(images, 30)}


def profile(tag, scratch, timeout, out, index, app, symbolicator):
    trace = os.path.join(out, f"launch-{index}.trace")
    shutil.rmtree(trace, ignore_errors=True)
    recorder = subprocess.Popen(["xcrun", "xctrace", "record", "--template", "Time Profiler", "--all-processes",
                                 "--time-limit", "90s", "--output", trace, "--no-prompt"],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    time.sleep(6)  # measurement script: the recorder starts sampling
    clean(tag)
    launch = start(tag, scratch)
    try:
        launch.wait_for([TERM], timeout)
        launch.wait_for([NEVER], 3)
    finally:
        pid = launch.process.pid
        launch.quit()
        clean(tag)
    recorder.send_signal(signal.SIGINT)
    try:
        recorder_out, _ = recorder.communicate(timeout=240)
    except subprocess.TimeoutExpired:
        recorder.kill()
        recorder_out, _ = recorder.communicate()
    xml_path = os.path.join(out, f"launch-{index}.xml")
    export_samples(trace, xml_path)
    samples, first = parse_samples(xml_path, pid, symbolicator)
    marks = dict(launch.marks)
    result = {"pid": pid, "marks": marks, "recorder": (recorder_out or "")[-600:], "main_samples": len(samples),
              "popen_ms": launch.popen_ms, "raw_rows": list(RAW_ROWS)}
    RAW_ROWS.clear()
    if first is None or FIRST not in marks:
        log(f"  profile {index}: no samples of pid {pid} or no {FIRST} ({len(samples)} main samples); recorder: {(recorder_out or '')[-300:]}")
        return result
    shift = launch.popen_ms  # marks count from fork; `first` is exec
    result["parse"] = PARSE_NOTES[-1] if PARSE_NOTES else None

    def at(mark_ms):
        return first + int(max(0.0, mark_ms - shift) * 1e6)

    cut = at(marks[FIRST])
    result["to_first_frame"] = aggregate(samples, first, cut)
    if "main_start" in marks:
        result["pre_main"] = aggregate(samples, first, at(marks["main_start"]))
    if "did_finish_launching_start" in marks:
        result["main_to_dfl"] = aggregate(samples, at(marks.get("main_start", 0)), at(marks["did_finish_launching_start"]))
    if "did_finish_launching_end" in marks:
        result["dfl"] = aggregate(samples, at(marks.get("did_finish_launching_start", 0)), at(marks["did_finish_launching_end"]))
        result["dfl_end_to_first_frame"] = aggregate(samples, at(marks["did_finish_launching_end"]), cut)
    result["first_frame_to_3s"] = aggregate(samples, cut, cut + 3_000_000_000)
    # Main turns: runs of main-thread samples with gaps under 2 ms, 16 ms or longer, in the first 3 s after the frame.
    turns, run = [], []
    for t, w, frames in sorted((s for s in samples if first <= s[0] <= cut + 3_000_000_000), key=lambda s: s[0]):
        if run and t - run[-1][0] > 2_000_000:
            turns.append(run)
            run = []
        run.append((t, w, frames))
    if run:
        turns.append(run)
    long_turns = []
    for turn in turns:
        ms = sum(w for _, w, _ in turn) / 1e6
        if ms >= 16:
            top = aggregate(turn, turn[0][0], turn[-1][0])
            long_turns.append({"start_ms": round((turn[0][0] - first) / 1e6, 1), "cpu_ms": round(ms, 1),
                               "chains": top["chains"][:6], "first_cmux": top["first_cmux"][:6]})
    result["turns_16ms"] = long_turns
    tf = result["to_first_frame"]
    log(f"  profile {index}: pid {pid}, {FIRST} {marks[FIRST]:.0f} ms, main CPU to first frame {tf['total_ms']:.0f} ms "
        f"({tf['samples']} samples), {len(long_turns)} turns >= 16 ms")
    for row in tf["first_cmux"][:15]:
        log(f"    {row['ms']:7.1f} ms  {row['name']}")
    return result


def row_text(element, byid):
    """One exported row as `fmt` cells (refs resolved), for tables this script does not parse."""
    cells = []
    for child in element:
        child = byid.get(child.get("ref"), child) if child.get("ref") else child
        cells.append(f"{child.tag}={(child.get('fmt') or child.text or '').strip()[:160]}")
    return " | ".join(cells)


def app_launch(tag, scratch, out, index, symbolicator):
    """xctrace's App Launch template (`--launch`): the toc, each table's first rows, and the main-thread profile."""
    trace = os.path.join(out, f"applaunch-{index}.trace")
    shutil.rmtree(trace, ignore_errors=True)
    clean(tag)
    env = {"CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
           "CMUX_NEXT_CONFIG_FILE": os.path.join(scratch, "cmux.json")}
    cmd = ["xcrun", "xctrace", "record", "--template", "App Launch", "--time-limit", "8s", "--output", trace, "--no-prompt"]
    for key, value in env.items():
        cmd += ["--env", f"{key}={value}"]
    cmd += ["--launch", "--", bs.app_binary(tag)]
    done = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    clean(tag)
    result = {"recorder": (done.stdout + done.stderr)[-800:], "tables": {}}
    toc = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--toc"], capture_output=True, text=True).stdout
    result["toc"] = toc[:20000]
    match = re.search(r'<process[^>]*pid="(\d+)"', toc)
    pid = int(match.group(1)) if match else None
    result["pid"] = pid
    for schema in sorted(set(re.findall(r'<table [^>]*schema="([^"]+)"', toc))):
        xml_path = os.path.join(out, f"applaunch-{index}-{schema}.xml")
        with open(xml_path, "w") as f:
            subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                            f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'], stdout=f, check=False)
        if schema == "time-profile" and pid:
            samples, first = parse_samples(xml_path, pid, symbolicator)
            result["main_samples"] = len(samples)
            result["raw_rows"] = list(RAW_ROWS)
            RAW_ROWS.clear()
            if first is not None:
                result["first_2s"] = aggregate(samples, first, first + 2_000_000_000)
                result["first_600ms"] = aggregate(samples, first, first + 600_000_000)
            continue
        byid, rows, count = {}, [], 0
        try:
            for _event, element in ET.iterparse(xml_path, events=("end",)):
                if element.get("id"):
                    byid[element.get("id")] = element
                if element.tag == "row":
                    count += 1
                    if len(rows) < 120:
                        rows.append(row_text(element, byid))
        except ET.ParseError as error:
            rows.append(f"parse error: {error}")
        result["tables"][schema] = {"rows": count, "first": rows}
    names = ", ".join(f"{name}({table['rows']})" for name, table in result["tables"].items())
    log(f"  app launch {index}: pid {pid}, main samples {result.get('main_samples')}, tables {names}")
    for schema, table in result["tables"].items():
        if any(word in schema for word in ("life-cycle", "dyld", "static", "launch", "initializer")):
            for line in table["first"][:40]:
                log(f"    {schema}: {line[:300]}")
    return result


def probe(tag, scratch, timeout, out, index, until_ms):
    lib = os.path.join(out, "blocking-probe.dylib")
    if not os.path.exists(lib):
        subprocess.run(["clang", "-dynamiclib", "-O2", "-Wall", "-framework", "CoreFoundation", "-o", lib,
                        os.path.join(ROOT, "scripts/measure/blocking-probe/probe.c")], check=True)
    dumps = os.path.join(out, "probe-dumps")
    os.makedirs(dumps, exist_ok=True)
    env = {"DYLD_INSERT_LIBRARIES": lib, "CMUX_BLOCKING_PROBE_OUT": os.path.join(dumps, "probe-%p.tsv"),
           "CMUX_BLOCKING_PROBE_UNTIL_MS": str(int(until_ms))}
    clean(tag)
    launch = start(tag, scratch, env)
    try:
        launch.wait_for([TERM], timeout)
        launch.wait_for([NEVER], 12)  # the probe's periodic dump (every 10 s) has the window
    finally:
        pid = launch.process.pid
        launch.quit()
        clean(tag)
    path = os.path.join(dumps, f"probe-{pid}.tsv")
    log(f"  probe {index}: pid {pid}, dump {'present' if os.path.exists(path) else 'missing'}, until {until_ms:.0f} ms, "
        f"{FIRST} {launch.marks.get(FIRST, 'missing')}")
    return path if os.path.exists(path) else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag")
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--json", required=True)
    parser.add_argument("--runs", type=int, default=10)
    parser.add_argument("--profiles", type=int, default=3)
    parser.add_argument("--probes", type=int, default=3)
    parser.add_argument("--app-launches", type=int, default=3)
    parser.add_argument("--hangs", type=int, default=16)
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--settle", type=float, default=3)
    parser.add_argument("--workspaces", type=int, default=24)
    opts, _ = parser.parse_known_args()
    from bench_launch import require_gui_session  # noqa: E402
    require_gui_session("launch-seed")
    app = os.path.abspath(opts.app)
    tag = bs.app_tag(app)
    bs.APPS[tag] = app
    bs.RUN_TAGS.append(tag)
    bs.HANG_THRESHOLD_MS = opts.hangs
    out = opts.out
    os.makedirs(out, exist_ok=True)
    scratch = tempfile.mkdtemp(prefix="launch-seed-")
    with open(os.path.join(scratch, "cmux.json"), "w") as f:
        f.write("{}\n")
    sha = subprocess.run(["git", "-C", ROOT, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    report = {"sha": sha, "app": os.path.basename(app), "load_before": os.getloadavg(),
              "args": vars(opts), "host": os.uname().nodename}

    def save():
        with open(opts.json, "w") as f:
            json.dump(report, f, indent=1)

    try:
        report["seed"] = seed(tag, scratch, opts.timeout, opts.workspaces)
        save()
        runs = bench(tag, scratch, opts.runs, opts.timeout, opts.settle)
        report["bench"] = {"runs": runs, "marks": mark_table(runs), "stall_sites": stall_sites(runs)}
        save()
        log("marks (p50 / p95 / n):")
        for name, row in report["bench"]["marks"].items():
            log(f"  {name:<46} {row['p50']:8.1f} {row['p95']:8.1f} {row['n']:3d}")
        log("stall sites (runs, p50, max):")
        for row in report["bench"]["stall_sites"][:20]:
            log(f"  {row['runs']:2d} {row['p50']:6.0f} {row['max']:6.0f}  {row['site']}")
        symbolicator = Symbolicator(app)
        report["profiles"] = []
        for index in range(1, opts.profiles + 1):
            try:
                report["profiles"].append(profile(tag, scratch, opts.timeout, out, index, app, symbolicator))
            except Exception as error:  # noqa: BLE001 measurement: keep the other parts
                log(f"  profile {index} failed: {error!r}")
            save()
        report["app_launch"] = []
        for index in range(1, opts.app_launches + 1):
            try:
                report["app_launch"].append(app_launch(tag, scratch, out, index, symbolicator))
            except Exception as error:  # noqa: BLE001 measurement: keep the other parts
                log(f"  app launch {index} failed: {error!r}")
            save()
        first = (report["bench"]["marks"].get(FIRST) or {}).get("p50")
        popens = [run["popen_ms"] for run in runs if run.get("popen_ms") is not None]
        if first and popens:
            first = first - statistics.median(popens)
        if first and opts.probes:
            paths = [p for p in (probe(tag, scratch, opts.timeout, out, i, first) for i in range(1, opts.probes + 1)) if p]
            if paths:
                probe_out = os.path.join(out, "probe-report")
                subprocess.run([sys.executable, os.path.join(ROOT, "scripts/measure/blocking-probe-report.py"),
                                "--app", app, "--launches", str(len(paths)), "--out", probe_out, *paths])
                md = os.path.join(probe_out, "blocking-probe.md")
                if os.path.exists(md):
                    with open(md) as f:
                        report["probe_md"] = f.read()
                    log(report["probe_md"][:6000])
                jsn = os.path.join(probe_out, "blocking-probe.json")
                if os.path.exists(jsn):
                    with open(jsn) as f:
                        report["probe"] = json.load(f)
            report["probe_until_ms"] = first
    finally:
        report["load_after"] = os.getloadavg()
        save()
        bs.stop(bs.tag_pids(tag))


if __name__ == "__main__":
    main()
