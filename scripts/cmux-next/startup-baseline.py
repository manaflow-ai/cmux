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
    rows = [(f"{name}: runs", f"{numbers['kept']} kept of {numbers['runs']} ({left} interrupted, left out); "
             f"launch.temperature: {temps}{'; ' + part['note'] if part.get('note') else ''}")]
    for mark in ROW_MARKS:
        rows.append((f"{name}: {mark}", spread_text(numbers["marks"].get(mark)) or "not sent by this build"))
    return rows


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


def bench_part(opts, out, name, mode, runs, extra):
    path = os.path.join(out, f"{name}.json")
    command = tool("bench-startup.py") + ["--app", opts.app, "--mode", mode, "--runs", str(runs), "--hangs",
                                          str(opts.hangs), "--timeout", str(opts.timeout), "--json", path,
                                          "--build-config", opts.build_config] + opts.optimized_flags + extra
    part = run(command, os.path.join(out, f"{name}.log"), opts.part_timeout)
    data = read_json(path)
    part["json"] = path
    part["numbers"] = mark_rows(data, perf_stats().summary) if isinstance(data, dict) else None
    return part


def realistic_part(opts, out, name, mode, runs, extra):
    """bench_part with --profile realistic (done checks 1 and 2); when that gives no kept run (the seed's agent pane
    never answered, say), the same runs on the state the tag has, and the note says why."""
    part = bench_part(opts, out, name, mode, runs, ["--profile", "realistic"] + extra)
    if part["numbers"] and part["numbers"]["kept"]:
        return part
    failed = part_failure(part)
    part = bench_part(opts, out, name, mode, runs, extra)
    part["note"] = f"NOT the realistic profile, which gave no run ({failed}): the state the tag had"
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
        if not launch.wait_for([bs.FIRST_CONTENT, bs.FINAL_MARK], opts.timeout, any_of=True):
            raise RuntimeError("the STRESS build launch never showed its first content")
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
    periods = []
    for schema in sorted(set(re.findall(r'<table [^>]*schema="([^"]*life-cycle[^"]*)"', toc))):
        xml = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                              f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'], capture_output=True,
                             text=True).stdout
        with open(os.path.join(out, f"applaunch-{index}-{schema}.xml"), "w") as f:
            f.write(xml)
        periods += life_cycle_rows(xml)
    return toc, periods


def life_cycle_rows(xml):
    """(label, ms) of each exported row: its duration cell (ns) and its first named text cell. xctrace writes a
    repeated value once with an id and later as a ref, so refs are resolved."""
    import xml.etree.ElementTree as ET
    try:
        tree = ET.fromstring(xml)
    except ET.ParseError:
        return []
    byid = {node.get("id"): node for node in tree.iter() if node.get("id")}
    rows = []
    for row in tree.iter("row"):
        cells = [byid.get(cell.get("ref"), cell) if cell.get("ref") else cell for cell in row]
        duration = next((cell for cell in cells if cell.tag == "duration"), None)
        label = next((cell.get("fmt") for cell in cells
                      if cell.tag in ("string", "narrative", "app-period", "event-concept") and cell.get("fmt")), None)
        if duration is not None and label and (duration.text or "").strip().isdigit():
            rows.append((label, int(duration.text) / 1e6))
    return rows


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
        toc, periods = applaunch_periods(trace, out, index)
        launches.append({"index": index, "periods": periods, "toc": toc[:20000]})
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
    size = re.search(r"visible=(\d+x\d+)", display_line)
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
    parser.add_argument("--until-mark", default="first_terminal_frame",
                        help="the queues' last mark: startup_complete once the build sends it")
    parser.add_argument("--part-timeout", type=float, default=1800)
    opts, _ = parser.parse_known_args()
    opts.app = os.path.abspath(opts.app)
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
