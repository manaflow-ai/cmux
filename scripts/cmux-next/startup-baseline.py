#!/usr/bin/env python3
"""The p08-startup launch battery (chrome-parity/p08-startup.md, tasks 069 and 070) on one fleet GUI mini.

Runs, against one staged bench build, each part as its own tool (the tool's own refusals and output are kept):

  warm      bench-startup.py --mode warm --profile realistic --runs WARM --hangs HANGS
  cold      bench-startup.py --mode cold --profile realistic --runs COLD --hangs HANGS, with --temperature cold
            (sudo -n purge, daemon stopped) when the host has the purge right, else the daemon is stopped and the
            file cache is not purged, and the row says so
  trace     startup-queue.py profile --app: TRACES `trace.py record --scenario launch-warm` (Q6)
  queues    startup-queue.py blocking, mainjobs, globaljobs and arms live (Q5, Q11, Q12, Q13), QUEUE_RUNS launches
            each; a build without their report (a bench build has no blocking detector; an older build has no
            debug.startup) is a refusal, kept as such
  applaunch APP_LAUNCHES `xctrace record --template 'App Launch' --launch`: the life-cycle periods
  stress  the standard STRESS session (perf-stress-session.py Stress.build) in one launch, then
            bench-startup.py --mode warm --runs STRESS: each launch restores the STRESS session (last but gaps:
            the parts before it launch the realistic session)
  gaps      startup-queue.py gaps over the warm, cold and STRESS files (Q7); reads files, launches nothing

Writes --json (every part's command, exit, seconds, output tail and parsed numbers) and --rows (perf-lead.md
section 5 rows, one per number). Every row names the host, macOS, the display and its refresh, the measured
commit and the build config, so rows of different hosts or builds are never compared as one series.

Fleet entry: scripts/measure/split-spring.sh --config=bench --vdisplay=120 --vdisplay-hold=5400 --suite=startup-baseline
  [--measured-sha=SHA] [--build-config=bench] [--parts=warm,cold,...]. To measure an older commit, put this script and
the tip's tools on a scratch ref of that commit (task 069 did so at 772cdfc45ac) and pass its sha as --measured-sha.
"""
import argparse
import datetime
import functools
import importlib.util
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PARTS = ("warm", "cold", "trace", "queues", "applaunch", "stress", "gaps")
LIVE_QUEUES = ("blocking", "mainjobs", "globaljobs", "arms")
# The marks a row is printed for, in launch order (bench-startup.py's names); a mark the build never sent gets a
# "not sent by this build" row, so a missing milestone is visible in the baseline.
ROW_MARKS = ("main_start", "window_display", "first_window_frame_committed", "first_content", "first_terminal_frame",
             "agent_pane.handshake_end", "first_idle", "startup_complete", "cef.initialize_started")
INTERRUPTED = "launch.interrupted"
TEMPERATURE = "launch.temperature"
TAIL = 4000


@functools.cache
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.path.insert(0, os.path.dirname(path))
    spec.loader.exec_module(module)
    return module


def perf_stats():
    return load("perf_stats", os.path.join(ROOT, "scripts", "perf-lab", "perf_stats.py"))


# ---- pure: numbers and rows (tests/test_startup_baseline.py) -----------------------------------------------


def flagged(run, mark):
    return mark in run and run[mark] not in (False, None)


def mark_rows(bench, summary):
    """{mark: {n, p50, p95, p99, max}} over a bench-startup.py --json file's runs, interrupted runs left out, plus
    the run counts. `summary` is perf_stats.summary (the lab's one percentile definition)."""
    runs = [run for modes in bench.values() for mode_runs in modes.values() for run in mode_runs]
    kept = [run for run in runs if not flagged(run, INTERRUPTED)]
    marks = {}
    for name in ROW_MARKS:
        values = [run[name] for run in kept
                  if isinstance(run.get(name), (int, float)) and not isinstance(run.get(name), bool)]
        marks[name] = summary(values)
    temperatures = {}
    for run in kept:
        value = run.get(TEMPERATURE)
        if value is not None:
            temperatures[str(value)] = temperatures.get(str(value), 0) + 1
    return {"runs": len(runs), "kept": len(kept), "marks": marks, "temperatures": temperatures}


def display_from(line):
    """split-spring.sh's display.txt line: `ready ID P50_MS main=ID` for the virtual display, else the reason."""
    match = re.match(r"ready (\d+) ([\d.]+) main=(\d+)", line or "")
    if match and match.group(1) == match.group(3):
        ms = float(match.group(2))
        return {"kind": "virtual (CGVirtualDisplay, main)", "refresh_ms": ms, "hz": round(1000 / ms)}
    return {"kind": f"real main display ({(line or 'no virtual display asked').strip()[:120]})", "refresh_ms": None,
            "hz": None}


def env_label(env):
    hz = f"{env['display']['hz']} Hz" if env["display"].get("hz") else "refresh not measured"
    return (f"host {env['host']}, macOS {env['macos']}, {hz}, display {env['display']['kind']} {env.get('size', '')}, "
            f"sha {env['sha'][:11]}, config {env['config']}").replace("  ", " ").replace(" ,", ",")


def ms(value):
    return "-" if value is None else f"{value:.1f}"


def spread_text(row):
    if not row or not row.get("n"):
        return None
    return (f"p50 {ms(row['p50'])} / p95 {ms(row['p95'])} / p99 {ms(row['p99'])} / max {ms(row['max'])} ms "
            f"(n {row['n']})")


def cell(text):
    """A markdown table cell: a `|` in a hit (an --order term A|B) would split the row."""
    return str(text).replace("|", "\\|")


def bench_rows(name, part):
    if part.get("numbers") is None:
        return [(f"{name}: every mark", f"not measured: {part_failure(part)}")]
    numbers = part["numbers"]
    left = numbers["runs"] - numbers["kept"]
    temps = ", ".join(f"{k} {v}" for k, v in sorted(numbers["temperatures"].items())) or "not sent by this build"
    failed = part.get("failed_runs") or 0
    refused = f", {failed} invocations wrote no run (last: {last_line(part)})" if failed else ""
    rows = [(f"{name}: runs", f"{numbers['kept']} kept of {numbers['runs']} ({left} interrupted, left out{refused}); "
             f"launch.temperature: {temps}{'; ' + part['note'] if part.get('note') else ''}")]
    for mark in ROW_MARKS:
        rows.append((f"{name}: {mark}", spread_text(numbers["marks"].get(mark)) or "not sent by this build"))
    return rows


def last_line(part):
    lines = [line for line in (part.get("tail") or "").splitlines() if line.strip()]
    return lines[-1][:300] if lines else "no output"


def part_failure(part):
    if not part:
        return "part not run"
    if part.get("skipped"):
        return part["skipped"]
    last = [line for line in (part.get("tail") or "").splitlines() if line.strip()]
    return f"exit {part.get('exit')}" + (f": {last[-1][:300]}" if last else "")


def queue_rows(queue_parts):
    rows = []
    for key, part in queue_parts.items():
        doc = part.get("numbers")
        if doc is None:
            rows.append((f"queue {key}", f"no report: {part_failure(part)}"))
            continue
        top = "; ".join(hit["summary"] for hit in doc["hits"][:5]) or "no hit"
        rows.append((f"queue {doc['queue']} {key}", f"{len(doc['hits'])} hits over {doc['runs']} runs; top: {top}"))
    return rows


def applaunch_rows(part):
    launches = (part or {}).get("numbers") or []
    if not launches:
        return [("App Launch: life-cycle periods", f"not measured: {part_failure(part)}")]
    periods = {}
    for launch in launches:
        for label, value in launch.get("periods", []):
            periods.setdefault(label, []).append(value)
    if not periods:
        return [("App Launch: life-cycle periods", f"{len(launches)} traces, no life-cycle period table read "
                 "(table names in the JSON's applaunch toc)")]
    stats = perf_stats()
    return [(f"App Launch: {label}", spread_text(stats.summary(values))) for label, values in periods.items()]


def render_rows(report, date=None):
    """perf-lead.md section 5 rows: | date | workstream | sha | row | before | after |, the env in each row."""
    env = report["env"]
    date = date or datetime.date.today().isoformat()
    parts = report["parts"]
    rows = []
    for name, label in (("warm", f"launch warm x{report['args']['warm']} (realistic)"),
                        ("cold", f"launch cold x{report['args']['cold']} (realistic)"),
                        ("stress", f"launch warm x{report['args']['stress']} (STRESS)")):
        if name in parts:
            rows += bench_rows(label, parts[name])
    if "trace" in parts:
        rows += queue_rows({f"profile (trace.py launch-warm x{report['args']['traces']})": parts["trace"]})
    rows += queue_rows(parts.get("queues", {}))
    rows += queue_rows(parts.get("gaps", {}))
    if "applaunch" in parts:
        count = report["args"]["app_launches"]
        rows += [(f"{row} x{count}", value) for row, value in applaunch_rows(parts["applaunch"])]
    workstream = report["args"]["workstream"]
    label = env_label(env)
    return [f"| {date} | {workstream} | {env['sha'][:11]} | {cell(row)} | {cell(value)}; {label} | - |"
            for row, value in rows]


# ---- fleet: the parts ---------------------------------------------------------------------------------------


def run(command, log_path, timeout):
    began = time.monotonic()
    try:
        with open(log_path, "w") as log:
            done = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
        code = done.returncode
    except subprocess.TimeoutExpired:
        code = "timeout"
    with open(log_path, errors="replace") as log:
        text = log.read()
    sys.stdout.write(text[-TAIL:])
    sys.stdout.flush()
    return {"command": command, "exit": code, "seconds": round(time.monotonic() - began, 1), "tail": text[-TAIL:]}


def read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def tool(name):
    return [sys.executable, os.path.join(HERE, name)]


def build_check(app):
    """(bench-startup flags, what the build is). A stamped bundle is checked by bench-startup --require-optimized; an
    unstamped one (reload.sh before task 006's stamp) by its executable: Xcode's .debug.dylib means Debug, which is
    refused, and the bench-hooks marker means a Release-optimized bench build."""
    launch = load("bench_launch", os.path.join(HERE, "bench_launch.py"))
    bs = load("bench_startup", os.path.join(HERE, "bench-startup.py"))
    stamped = launch.info_plist(app).get(launch.BUILD_CONFIG_KEY)
    if stamped:
        return ["--require-optimized"], f"Info.plist {launch.BUILD_CONFIG_KEY}={stamped}"
    kind = launch.bundle_kind(app, bs.executable(app))
    if kind == "debug":
        raise SystemExit(f"startup-baseline: {app} is a Debug build: launch numbers need --config=bench")
    return [], f"an unstamped {kind} bundle (its reload.sh predates the stamp; the executable says optimized)"


def merge_bench(files):
    """One bench-startup.py --json document ({tag: {mode: [runs]}}) from several, runs kept in order."""
    merged = {}
    for data in files:
        for tag, modes in (data or {}).items():
            for mode, runs in modes.items():
                merged.setdefault(tag, {}).setdefault(mode, []).extend(runs)
    return merged


def bench_part(opts, out, name, mode, runs, extra):
    """RUNS bench-startup.py invocations of one run each, the tag's app processes stopped between them: at
    772cdfc45ac a quit app's Chromium helpers outlive it for a moment, and bench-startup refuses a launch while
    any process of the bundle runs (so its own run 2 never started). The runs merge into OUT/NAME.json."""
    path = os.path.join(out, f"{name}.json")
    files, parts = [], []
    for index in range(1, runs + 1):
        one = os.path.join(out, f"{name}-{index}.json")
        command = tool("bench-startup.py") + ["--app", opts.app, "--mode", mode, "--runs", "1", "--hangs",
                                              str(opts.hangs), "--timeout", str(opts.timeout), "--json", one,
                                              "--build-config", opts.build_config] + opts.optimized_flags + extra
        stop_apps(opts)
        parts.append(run(command, os.path.join(out, f"{name}-{index}.log"), opts.part_timeout))
        data = read_json(one)
        if isinstance(data, dict):
            files.append(data)
        elif index == 1:
            break  # the first run refused (a profile that never seeds, say): the rest would refuse the same way
    with open(path, "w") as f:
        json.dump(merge_bench(files), f, indent=1)
    failed = [p for p in parts if p["exit"] != 0]
    part = {"command": parts[0]["command"] if parts else [], "runs_invoked": len(parts),
            "exit": failed[-1]["exit"] if failed and not files else 0,
            "failed_runs": len(failed), "seconds": round(sum(p["seconds"] for p in parts), 1),
            "tail": (failed[-1] if failed else parts[-1])["tail"] if parts else "", "json": path}
    part["numbers"] = mark_rows(merge_bench(files), perf_stats().summary) if files else None
    return part


def tag_of(opts):
    bs = load("bench_startup", os.path.join(HERE, "bench-startup.py"))
    tag = bs.app_tag(opts.app)
    bs.APPS[tag] = opts.app
    return bs, tag


def stop_apps(opts):
    """Quits the tag's app (a part that timed out can leave it running, and the next bench then refuses); the
    daemon keeps running, so the state stays warm."""
    bs, tag = tag_of(opts)
    bs.stop(bs.app_pids(tag))


def seed_terminals(opts, workspaces):
    """The terminal session task 072 measured at 772cdfc45ac: WORKSPACES workspaces of 3 terminal tabs and a split
    (daemon socket), project-01's first terminal selected, then the app quits and the daemon keeps it (warm)."""
    bs, tag = tag_of(opts)
    from bench_cli_storm import Client  # noqa: E402  (bench-startup's own control client)
    scratch = tempfile.mkdtemp(prefix="startup-baseline-seed-")
    with open(os.path.join(scratch, "cmux.json"), "w") as f:
        f.write("{}\n")
    bs.reset_state(tag)
    launch = bs.Launch(tag, scratch)
    try:
        if not launch.wait_for([bs.FIRST_CONTENT, bs.FINAL_MARK, "first_window_frame_committed"], opts.timeout,
                               any_of=True):
            raise RuntimeError("the seeding launch never committed a window frame")
        daemon = Client(bs.daemon_socket(tag), timeout=10)
        try:
            def listed():
                reply = daemon.call("list-workspaces", cmd_key="cmd")
                return {w["id"]: w for w in reply["data"]["workspaces"]}

            for index in range(workspaces):
                before = listed()
                made = daemon.call("new-workspace", {"name": f"project-{index + 1:02d}"}, cmd_key="cmd")
                if not made.get("ok"):
                    raise RuntimeError(f"new-workspace failed: {made.get('error')}")
                workspace = next(w for key, w in listed().items() if key not in before)
                pane = workspace["screens"][0]["panes"][0]
                for _ in range(2):
                    daemon.call("new-tab", {"pane": pane["id"]}, cmd_key="cmd")
                daemon.call("split", {"pane": pane["id"], "dir": "right"}, cmd_key="cmd")
        finally:
            daemon.close()
        app = bs.app_client(tag)
        try:
            tab = bs.app_tab_id(app, "project-01", opts.timeout)
            if tab:
                app.call("action.run", {"action": "palette.goToTab", "target": {"kind": "tab", "id": tab}})
        finally:
            app.close()
        launch.wait_for([bs.FINAL_MARK], opts.timeout)
        launch.wait_for(["startup-baseline.never"], 3)  # the selection reaches the saved state
    finally:
        launch.quit()
        bs.stop(bs.app_pids(tag))
        shutil.rmtree(scratch, ignore_errors=True)
    return f"{workspaces} workspaces of 3 terminal tabs and a split (task 072's seed), no agent chat"


def realistic_part(opts, out, name, mode, runs, extra):
    """bench_part with --profile realistic (done checks 1 and 2). When that gives no kept run (at 772cdfc45ac the
    realistic seed's launch never draws a terminal), task 072's terminal session is seeded once and this part and
    every later one restore it; the note says so."""
    if not opts.seeded:
        part = bench_part(opts, out, name, mode, runs, ["--profile", "realistic"] + extra)
        if part["numbers"] and part["numbers"]["kept"]:
            return part
        opts.realistic_failure = part_failure(part)
        stop_apps(opts)
        opts.seeded = seed_terminals(opts, opts.workspaces)
    part = bench_part(opts, out, name, mode, runs, extra)
    part["note"] = (f"NOT the realistic profile, which gave no run ({opts.realistic_failure}); state: "
                    f"{opts.seeded}")
    return part


def has_purge_right():
    return subprocess.run(["sudo", "-n", "/usr/sbin/purge"], capture_output=True).returncode == 0


def queue_part(opts, out, mode, args, label=None):
    name = f"queue-{mode}" + (f"-{label}" if label else "")
    path = os.path.join(out, f"{name}.json")
    part = run(tool("startup-queue.py") + [mode] + args + ["--json", path], os.path.join(out, f"{name}.log"),
               opts.part_timeout)
    part["numbers"] = read_json(path)
    return part


def stress_part(opts, out):
    """One launch builds STRESS (the daemon keeps it: warm), then bench-startup restores it STRESS times."""
    bs = load("bench_startup", os.path.join(HERE, "bench-startup.py"))
    stress = load("perf_stress_session", os.path.join(HERE, "perf-stress-session.py"))
    tag = bs.app_tag(opts.app)
    bs.APPS[tag] = os.path.abspath(opts.app)
    scratch = tempfile.mkdtemp(prefix="startup-baseline-stress-")
    with open(os.path.join(scratch, "cmux.json"), "w") as f:
        f.write("{}\n")
    bs.reset_state(tag)
    launch = bs.Launch(tag, scratch, {"CMUX_NEXT_NO_ACTIVATE": "0"})  # the builder needs a key window
    built = {}
    try:
        # An empty state's first launch shows the agent page; a build before first_content sends only these.
        shown = [bs.FIRST_CONTENT, bs.FINAL_MARK, bs.AGENT_MARK, "first_window_frame_committed"]
        if not launch.wait_for(shown, opts.timeout, any_of=True):
            raise RuntimeError(f"the STRESS build launch sent none of {', '.join(shown)}")
        client = bs.app_client(tag)

        def rpc(method, params=None, timeout=30):
            client.sock.settimeout(timeout)
            reply = client.call(method, params or {})
            return reply["result"] if "result" in reply else {"error": reply.get("error")}

        builder = stress.Stress(rpc)
        try:
            built = builder.build()
        finally:
            client.close()
        print("STRESS-SESSION " + json.dumps(built), flush=True)
    finally:
        launch.quit()
        bs.stop(bs.app_pids(tag))
        shutil.rmtree(scratch, ignore_errors=True)
    part = bench_part(opts, out, "stress", "warm", opts.stress, [])
    part["session"] = built
    part["note"] = "restores the STRESS session built once (perf-stress-session.py, daemon kept)"
    return part


def applaunch_periods(trace, out, index):
    """The App Launch template's life-cycle periods: (label, ms) per row of each table whose schema names one."""
    toc = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--toc"], capture_output=True,
                         text=True).stdout
    periods, samples = [], {}
    for schema in sorted(set(re.findall(r'<table [^>]*schema="([^"]*life-cycle[^"]*)"', toc))):
        xml = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                              f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'], capture_output=True,
                             text=True).stdout
        with open(os.path.join(out, f"applaunch-{index}-{schema}.xml"), "w") as f:
            f.write(xml)
        periods += life_cycle_rows(xml)
        samples[schema] = life_cycle_sample(xml)
    return toc, periods, samples


# Cells that are not a period's name: times, ids, processes and threads.
NOT_NAMES = ("start-time", "duration", "event-time", "process", "thread", "pid", "tid", "uint64", "uint32", "sentinel",
             "boolean", "core", "weight")
# xctrace's duration of a period still open when the recording stopped (UINT64_MAX ns): not a measured length.
OPEN_PERIOD_NS = 1 << 62


def row_cells(row, byid):
    """A row's cells, refs resolved: xctrace writes a repeated value once with an id and later as a ref."""
    return [byid.get(cell.get("ref"), cell) if cell.get("ref") else cell for cell in row]


def life_cycle_rows(xml):
    """(label, ms) of each exported row with a closed duration: the label joins its distinct named cells (the
    table's category, such as `States`, and the period itself)."""
    import xml.etree.ElementTree as ET
    try:
        tree = ET.fromstring(xml)
    except ET.ParseError:
        return []
    byid = {node.get("id"): node for node in tree.iter() if node.get("id")}
    rows = []
    for row in tree.iter("row"):
        cells = row_cells(row, byid)
        duration = next((cell for cell in cells if cell.tag == "duration"), None)
        names = []
        for cell in cells:
            name = (cell.get("fmt") or "").strip()
            if cell.tag not in NOT_NAMES and name and name not in names:
                names.append(name)
        text = (duration.text or "").strip() if duration is not None else ""
        if names and text.isdigit() and int(text) < OPEN_PERIOD_NS:
            rows.append((" / ".join(names), int(text) / 1e6))
    return rows


def life_cycle_sample(xml, limit=40):
    """The first rows as `tag=fmt` cells, kept in the report so a parser change can be checked against the export."""
    import xml.etree.ElementTree as ET
    try:
        tree = ET.fromstring(xml)
    except ET.ParseError as error:
        return [f"parse error: {error}"]
    byid = {node.get("id"): node for node in tree.iter() if node.get("id")}
    return [" | ".join(f"{c.tag}={(c.get('fmt') or c.text or '').strip()[:80]}" for c in row_cells(row, byid))
            for row in list(tree.iter("row"))[:limit]]


def applaunch_part(opts, out):
    bs = load("bench_startup", os.path.join(HERE, "bench-startup.py"))
    tag = bs.app_tag(opts.app)
    bs.APPS[tag] = os.path.abspath(opts.app)
    scratch = tempfile.mkdtemp(prefix="startup-baseline-applaunch-")
    with open(os.path.join(scratch, "cmux.json"), "w") as f:
        f.write("{}\n")
    launches, failures = [], []
    for index in range(1, opts.app_launches + 1):
        trace = os.path.join(out, f"applaunch-{index}.trace")
        shutil.rmtree(trace, ignore_errors=True)
        bs.stop(bs.app_pids(tag))
        command = ["xcrun", "xctrace", "record", "--template", "App Launch", "--time-limit", "10s", "--output", trace,
                   "--no-prompt", "--env", "CMUX_NEXT_NO_ACTIVATE=0", "--env", "CMUX_NEXT_SOCKET_MODE=automation",
                   "--env", f"CMUX_NEXT_CONFIG_FILE={os.path.join(scratch, 'cmux.json')}", "--launch", "--",
                   bs.app_binary(tag)]
        done = run(command, os.path.join(out, f"applaunch-{index}.log"), 240)
        bs.stop(bs.app_pids(tag))
        if done["exit"] != 0 and not os.path.isdir(trace):
            failures.append(done)
            continue
        toc, periods, samples = applaunch_periods(trace, out, index)
        launches.append({"index": index, "periods": periods, "samples": samples, "toc": toc[:20000]})
    shutil.rmtree(scratch, ignore_errors=True)
    return {"command": "xctrace record --template 'App Launch' --launch", "exit": 0 if launches else 1,
            "numbers": launches, "tail": failures[-1]["tail"] if failures else ""}


def host_env(opts, out):
    def sw(key):
        return subprocess.run(["sw_vers", key], capture_output=True, text=True).stdout.strip()

    display_line = ""
    path = os.path.join(out, "display.txt")
    if os.path.exists(path):
        with open(path) as f:
            display_line = f.read().strip()
    display = display_from(display_line)
    size = re.search(r"\bsize=(\d+x\d+)", display_line)  # the display's pixels (`visible=` can read 0x0)
    head = subprocess.run(["git", "-C", ROOT, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    return {"host": os.uname().nodename.split(".")[0], "macos": f"{sw('-productVersion')} ({sw('-buildVersion')})",
            "machine": platform.machine(), "display": display, "display_line": display_line,
            "size": size.group(1) if size else "", "sha": opts.measured_sha or head, "tools_ref": head,
            "config": opts.build_config, "build_evidence": opts.build_evidence, "load_before": os.getloadavg()}


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", required=True, help="a staged `cmux DEV <tag>.app` (bench config)")
    parser.add_argument("--tag", help="split-spring.sh passes it; the tag comes from --app")
    parser.add_argument("--out", required=True)
    parser.add_argument("--json", required=True)
    parser.add_argument("--rows", help="perf-lead.md rows (default OUT/rows.md)")
    parser.add_argument("--parts", default=",".join(PARTS))
    parser.add_argument("--measured-sha", help="the commit the app was built from (a scratch tools ref of it: its sha)")
    parser.add_argument("--build-config", default="bench", choices=["bench", "release"])
    parser.add_argument("--workstream", default="p08-startup-069 baseline")
    parser.add_argument("--warm", type=int, default=20)
    parser.add_argument("--cold", type=int, default=10)
    parser.add_argument("--stress", type=int, default=10)
    parser.add_argument("--traces", type=int, default=5)
    parser.add_argument("--app-launches", type=int, default=5)
    parser.add_argument("--queue-runs", type=int, default=1)
    parser.add_argument("--hangs", type=int, default=16)
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--until-mark", default="first_window_frame_committed",
                        help="the queues' last mark (default: one every build sends, whatever pane it restores); "
                             "startup_complete once the build sends it (task 070 at the tip)")
    parser.add_argument("--part-timeout", type=float, default=1800)
    parser.add_argument("--workspaces", type=int, default=24, help="the terminal seed's workspaces (task 072: 24)")
    opts, _ = parser.parse_known_args()
    opts.app = os.path.abspath(opts.app)
    opts.seeded, opts.realistic_failure = None, None
    parts = [part for part in opts.parts.split(",") if part]
    unknown = sorted(set(parts) - set(PARTS))
    if unknown:
        parser.error(f"unknown parts {unknown}; known: {', '.join(PARTS)}")
    os.makedirs(opts.out, exist_ok=True)
    opts.optimized_flags, opts.build_evidence = build_check(opts.app)
    report = {"args": {**vars(opts)}, "env": host_env(opts, opts.out), "parts": {}}

    def save():
        with open(opts.json, "w") as f:
            json.dump(report, f, indent=1)

    out, done = opts.out, report["parts"]
    save()
    for name in parts:
        print(f"startup-baseline: {name}", flush=True)
        try:
            if name != "gaps":
                stop_apps(opts)
            if name == "warm":
                done[name] = realistic_part(opts, out, "warm", "warm", opts.warm, [])
            elif name == "cold":
                purge = has_purge_right()
                cold = ["--temperature", "cold"] if purge else []
                done[name] = realistic_part(opts, out, "cold", "cold", opts.cold, cold)
                done[name]["note"] = "; ".join(filter(None, [
                    "file cache purged (sudo -n purge), daemon stopped" if purge else
                    "daemon stopped, file cache NOT purged: the host has no purge right", done[name].get("note")]))
            elif name == "trace":
                done[name] = queue_part(opts, out, "profile", ["--app", opts.app, "--runs", str(opts.traces),
                                                               "--temperature", "warm", "--out",
                                                               os.path.join(out, "traces"),
                                                               "--until-mark", opts.until_mark])
            elif name == "gaps":
                gaps = done.setdefault("gaps", {})
                for key in ("warm", "cold", "stress"):
                    path = done.get(key, {}).get("json", "")
                    if os.path.exists(path):
                        gaps[f"gaps {key}"] = queue_part(opts, out, "gaps", [path, "--min-ms", "5"], key)
            elif name == "queues":
                queues = done.setdefault("queues", {})
                for mode in LIVE_QUEUES:
                    queues[mode] = queue_part(opts, out, mode, ["--app", opts.app, "--runs", str(opts.queue_runs),
                                                                "--until-mark", opts.until_mark])
            elif name == "applaunch":
                done[name] = applaunch_part(opts, out)
            elif name == "stress":
                done[name] = stress_part(opts, out)
        except Exception as error:  # noqa: BLE001 measurement: one part's failure keeps the others
            done[name] = {"exit": "error", "tail": f"{type(error).__name__}: {error}", "numbers": None}
            print(f"startup-baseline: {name} failed: {error!r}", flush=True)
        save()
    report["env"]["load_after"] = os.getloadavg()
    rows = render_rows(report)
    with open(opts.rows or os.path.join(out, "rows.md"), "w") as f:
        f.write("\n".join(rows) + "\n")
    report["rows"] = rows
    save()
    print("ROWS-BEGIN\n" + "\n".join(rows) + "\nROWS-END", flush=True)


if __name__ == "__main__":
    main()
