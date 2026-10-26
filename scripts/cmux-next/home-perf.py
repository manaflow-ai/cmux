#!/usr/bin/env python3
"""Swift Home performance baseline for the React Home switch decision (cx-59n8).

Launches the tagged app through bench_launch.BenchApp (the bench env, classic Home, no activation, a fresh saved
session, the tag's teardown at the end), seeds a local channel through `debug.home.api` (the same data path the
React Home uses), shows it with `home.openConversation`, and measures through the debug socket only:
  - frame pacing (`debug.frames`) while the transcript scrolls
    (`debug.home.drive scroll`), during sends, and while keys are typed;
  - key dispatch latency: the `debug.key` round trip per key (the key event
    goes through the window's responder chain into the field and the text is
    in the field when the call returns; the glyph is on screen at the next
    presented frame, so key-to-glyph is about this plus one frame interval);
    p50/p95/p99 from scripts/perf-lab/perf_stats.py (agent_bench_report.py);
  - memory: resident size and phys_footprint (`footprint`) at each stage.
Runs on cmux-lawrence-2 (GUI host), never on the laptop. Writes one JSON report, and every raw sample as
cmux-perf-result/v1 (story home-perf, engine none: the native classic Home transcript) next to it: each stage's
frame intervals and main-thread ms, each key's round trip, and the memory at each stage.

Usage: home-perf.py --tag <tag> --out results.json [--messages 300]
       home-perf.py --app BUNDLE --out DIR [--messages 300]     (the lab story; DIR/home-perf-<tag>.json)

--out is the report file when it ends in .json, else the folder that gets home-perf-<tag>.json; result-v1 goes
into the report's folder. A run that writes no result-v1 series (no build sha, no features snapshot) still writes
its report, then exits non-zero, so the lab sees a failed story and not an empty one.
"""
import argparse, json, os, re, socket, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # the bench modules, also under `python3 -I`
import agent_bench_report as report  # noqa: E402
import home_classic  # noqa: E402
from bench_launch import BenchApp, rpc_at, tag_of  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", help="the tag of a DerivedData Debug app (default: read from --app)")
parser.add_argument("--app", help="the app bundle (default: the DerivedData Debug app of --tag)")
parser.add_argument("--out", required=True, help="the report (.json), or the folder that gets home-perf-<tag>.json")
parser.add_argument("--messages", type=int, default=300)
parser.add_argument("--session", choices=["light"], default="light", help="result-v1 session (the story runner's)")
parser.add_argument("--build-config", choices=["bench", "bench-checks"],
                    help="result-v1 build config of a bench-hooks bundle that does not stamp it")
opts = parser.parse_args()
if not opts.app and not opts.tag:
    parser.error("name the app with --app, or the tag of a DerivedData Debug app with --tag")
home = os.environ["HOME"]
app = os.path.realpath(opts.app.rstrip("/")) if opts.app else \
    f"{home}/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/cmux DEV {opts.tag}.app"
tag = opts.tag or tag_of(app)
out_path = opts.out if opts.out.endswith(".json") else os.path.join(opts.out, f"home-perf-{tag}.json")
work = os.path.dirname(os.path.abspath(out_path))
os.makedirs(work, exist_ok=True)
results = {"tag": tag, "host": socket.gethostname(), "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
raw_frames = {}  # stage -> the per-frame arrays of its debug.frames answer (result-v1 only)
key_trips = []  # each key's debug.key round trip, ms
bench = BenchApp(app, out=work, env={"CMUX_DEV_BACKEND_MODE": "local", **home_classic.ENV}, window=None,
                 screen="last", log_name="perf-app.log", build_config=opts.build_config)


def rpc(method, params=None, timeout=35):
    reply = rpc_at(bench.socket, method, params, timeout)
    return reply if reply is not None else {}


def poll(predicate, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.5)  # harness wait, not app code
    return None


def memory(pid):
    rss = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    out = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True).stdout
    match = re.search(r"Footprint:\s*([\d.]+)\s*([KMG]B)", out)
    footprint_mb = None
    if match:
        value, unit = float(match.group(1)), match.group(2)
        footprint_mb = value / 1024 if unit == "KB" else value * 1024 if unit == "GB" else value
    return {"rss_mb": round(int(rss) / 1024, 1) if rss.isdigit() else None, "footprint_mb": footprint_mb}


def frames(label, body):
    rpc("debug.frames", {"action": "start"})
    started = time.time()
    extra = body()
    stats, raw_frames[label] = report.split_raw_frames(rpc("debug.frames", {"action": "stop", "raw": True}))
    stats["seconds"] = round(time.time() - started, 2)
    if extra:
        stats.update(extra)
    results[label] = stats
    print(label, json.dumps(stats), flush=True)


try:
    bench.launch(timeout=180)
    pid = bench.process.pid
    if not home_classic.require(rpc):  # classic Home: these checks drive the native transcript
        sys.exit(2)
    if not poll(lambda: "conversations" in (rpc("debug.home.api", {"call": "inbox"}) or {}), timeout=180):
        sys.exit("FAIL the local owner never answered")
    results["memory_launch"] = memory(pid)
    created = rpc("debug.home.api", {"call": "submit", "op": {"kind": "create_group", "title": f"perf-{int(time.time())}", "participants": []}})
    channel = created.get("conversation")
    if not channel:
        sys.exit(f"FAIL no channel: {created}")
    seed_started = time.time()
    for index in range(opts.messages):
        text = f"perf message {index}: " + ("lorem ipsum dolor sit amet " * (1 + index % 6))
        rpc("debug.home.api", {"call": "submit", "op": {"kind": "send", "conversation": channel, "text": text}})
    results["seed"] = {"messages": opts.messages, "seconds": round(time.time() - seed_started, 2)}
    opened = rpc("action.run", {"id": "home.openConversation", "arguments": {"conversation": channel}, "focus": True})
    shown = poll(lambda: (g := rpc("debug.home.drive", {"action": "geometry"})) and g.get("ok") and g, timeout=60)
    results["open"] = {"action": opened, "geometry": shown}
    if not shown:
        sys.exit(f"FAIL the channel is not shown: {opened}")
    time.sleep(2)  # let the first layout and pictures settle before measuring
    results["memory_open"] = memory(pid)

    def scroll():
        for _ in range(60):
            rpc("debug.home.drive", {"action": "scroll", "dy": -120})
            time.sleep(1 / 30)
        for _ in range(60):
            rpc("debug.home.drive", {"action": "scroll", "dy": 120})
            time.sleep(1 / 30)
    frames("scroll", scroll)

    def send():
        for index in range(20):
            rpc("debug.home.drive", {"action": "type", "text": f"send during measure {index}"})
            rpc("debug.home.drive", {"action": "send"})
            time.sleep(0.5)
    frames("send", send)

    def typing():
        rpc("debug.home.drive", {"action": "focus"})
        for char in "the quick brown fox jumps over the lazy dog " * 2:
            started = time.perf_counter()
            rpc("debug.key", {"key": char})
            key_trips.append((time.perf_counter() - started) * 1000)
            time.sleep(0.08)
        return {"key_dispatch_ms": report.key_dispatch(key_trips)}
    frames("typing", typing)
    results["memory_end"] = memory(pid)
    results["result_v1"] = report.record_all(bench, report.home_series(raw_frames, key_trips, results), engine="none",
                                             session=opts.session)
finally:
    bench.stop()  # the in-app quit, then the tag's daemons (acpmux included: tag_teardown.py)
    with open(out_path, "w") as handle:
        json.dump(results, handle, indent=1)
    print("wrote", out_path, flush=True)
if not report.any_written(results.get("result_v1")):
    sys.exit("RESULT-V1 FAIL: no series written")
