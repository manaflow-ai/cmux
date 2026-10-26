#!/usr/bin/env python3
"""Main-thread time of a structural sidebar rebuild in the sidebar-document mode (bead cx-x5jpp).

  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA \
    -- python3 -I scripts/cmux-next/sidebar-mirror-rebuild-perf.py --label before --out "$NX_ARTIFACTS"
  scripts/cmux-next/sidebar-mirror-rebuild-perf.py --app <cmux DEV tag.app> [--count 1000] [--rebuilds 20]
  scripts/cmux-next/sidebar-mirror-rebuild-perf.py --tag <tag> [--count 1000] [--rebuilds 20]   (a running tagged app)

With --app (default $NX_APP, the app of an nx-remote GUI job) it launches that app through
bench_launch.BenchApp (the bench env, an empty config, a fresh saved session) and quits it and its
daemons at the end; with --tag alone it attaches to a running tagged app and quits nothing. Never on
the laptop. It makes `--count` empty workspaces (`perf-NNNN`, the names
sidebar-rows-perf-live.py uses, so either script reuses the other's), then `--rebuilds` times
creates one workspace and closes it again. Each create and each close changes the live workspace
set, so the sidebar asks the Rust mirror for its rows again (one `view` FFI call) and lays out the
list again. Measured from `debug.sidebar_perf` (reset before the phase):

  mirror_ns   main-thread time in SidebarMirror.rows / .acceptance (request encode, Rust call, reply read)
  main_ns     main-thread time of the list layout paths
  rebuilds, list_reloads, and the mirror `view` calls (`debug.sidebar_rows` doc.ffi_calls)

It reports the time per `view` call and per rebuild, the p50/p95/p99 of each create-and-close
cycle, and, with --app, writes each cycle's mirror and layout time as result-v1 (story
sidebar-mirror-rebuild, sidebar_bench_report.py). It fails when the build has no `mirror_ns` counter, when the sidebar
document mode is not active, or when no `view` call happened.
"""

import argparse, json, os, socket, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor

parser = argparse.ArgumentParser()
parser.add_argument("--app", default=os.environ.get("NX_APP"), help="launch this app (default $NX_APP)")
parser.add_argument("--tag", default=os.environ.get("NX_APP_TAG"))
parser.add_argument("--count", type=int, default=1000)
parser.add_argument("--rebuilds", type=int, default=20)
parser.add_argument("--label", default="run")
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
opts = parser.parse_args()
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # the bench modules, also under `python3 -I`
import sidebar_bench_report as report  # noqa: E402
from bench_launch import BenchApp, tag_of  # noqa: E402

if opts.app:
    opts.tag = tag_of(os.path.realpath(opts.app))
if not opts.tag:
    sys.exit("--app or --tag is required outside an nx-remote --app-from-fleet job")
SOCKET = os.environ.get("NX_APP_SOCKET") or f"/tmp/cmux-debug-{opts.tag}.sock"
CLI = os.environ.get("NX_APP_CLI") or os.path.join(HERE, "..", "cmux-debug-cli.sh")
BENCH = None  # the BenchApp of the app this script launched (--app)


def rpc(method, params=None, timeout=60):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def cli(*args, timeout=60):
    env = dict(os.environ, CMUX_TAG=opts.tag, CMUX_QUIET="1")
    return subprocess.run([CLI, "--app-socket", SOCKET, *args], env=env, capture_output=True, text=True, timeout=timeout)


def rows():
    return rpc("debug.sidebar_rows", timeout=120) or {}


def titles():
    return {str(r.get("title")) for w in (rows().get("windows") or []) for r in (w.get("rows") or [])}


def view_calls():
    return int(((rows().get("doc") or {}).get("ffi_calls") or {}).get("view", 0))


def wait(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the sidebar to follow a CLI change
        value = predicate()
        if value:
            return value
        time.sleep(0.1)
    return predicate()


def launch():
    """Launches --app through BenchApp (an empty config, the window at 40,40 1100x720 on the last screen) and waits
    for the sidebar document; SOCKET and CLI then name that app."""
    global BENCH, SOCKET, CLI
    BENCH = BenchApp(opts.app, out=opts.out, config={}, window=(40, 40, 1100, 720), screen="last")
    BENCH.launch()
    SOCKET = BENCH.socket
    if not os.environ.get("NX_APP_CLI"):
        CLI = BENCH.cli
    if not wait(lambda: (rows().get("doc") or {}).get("active"), 120):
        sys.exit(f"FAIL the tagged app did not come up with the sidebar document active ({rows().get('doc')})")


def counter_ms(counters, key):
    return (counters.get(key) or 0) / 1e6


def write_summary(summary):
    os.makedirs(opts.out, exist_ok=True)
    with open(os.path.join(opts.out, f"mirror-rebuild-{opts.label}.json"), "w") as out:
        json.dump(summary, out, indent=2)


def measure():
    doc = rows().get("doc") or {}
    if "error" in rows() or not doc.get("active"):
        sys.exit(f"no tagged app with the sidebar document active on {SOCKET} ({doc})")
    have = titles()
    missing = [f"perf-{i:04d}" for i in range(opts.count) if f"perf-{i:04d}" not in have]
    with ThreadPoolExecutor(max_workers=8) as pool:
        bad = [r for r in pool.map(lambda n: cli("workspace", "create", "--empty", "--name", n), missing) if r.returncode]
    if bad:
        sys.exit(f"workspace create failed: {bad[0].stderr[-300:]}")
    listed = wait(lambda: sum(t.startswith("perf-") for t in titles()) >= opts.count, 300)
    if not listed:
        sys.exit("the sidebar does not list the perf workspaces")
    rpc("debug.sidebar_perf", {"reset": True})
    views_before = view_calls()
    close_errors, cycles = [], []
    last = rpc("debug.sidebar_perf") or {}
    for index in range(opts.rebuilds):
        name = f"rebuild-{index:03d}"
        made = cli("workspace", "create", "--empty", "--name", name, "--json")
        if made.returncode:
            sys.exit(f"create failed: {made.stderr[-300:]}")
        reply = json.loads(made.stdout or "{}")
        value = reply.get("value") or {}
        ws_id = value.get("workspace_id") or reply.get("workspace_id") or reply.get("id")
        wait(lambda: name in titles(), 15)
        if not ws_id:
            sys.exit(f"no workspace id in the create reply: {made.stdout[:300]}")
        # The close is a second rebuild when it lands; a refused close only leaves one more row.
        closed = cli("workspace", ws_id, "close")
        if closed.returncode == 0:
            wait(lambda: name not in titles(), 15)
        else:
            close_errors.append((closed.stdout + closed.stderr).strip()[-200:])
        # This cycle's share of the counters (they only grow after the reset): result-v1's raw samples.
        now = rpc("debug.sidebar_perf") or {}
        if "mirror_ns" in now and "mirror_ns" in last:
            cycles.append({"mirror_ms": counter_ms(now, "mirror_ns") - counter_ms(last, "mirror_ns"),
                           "main_ms": counter_ms(now, "main_ns") - counter_ms(last, "main_ns")})
        last = now
    counters = rpc("debug.sidebar_perf") or {}
    if "mirror_ns" not in counters:
        sys.exit(f"this build has no mirror_ns counter: {counters}")
    views = view_calls() - views_before
    summary = {
        "label": opts.label, "tag": opts.tag, "count": opts.count, "rebuild_cycles": opts.rebuilds,
        "view_calls": views, "rebuilds": counters.get("rebuilds"), "list_reloads": counters.get("list_reloads"),
        "mirror_ms_per_view": round(counters["mirror_ns"] / 1e6 / max(views, 1), 3),
        "main_ms_per_rebuild": round(counters.get("main_ns", 0) / 1e6 / max(counters.get("rebuilds") or 1, 1), 3),
        "close_errors": close_errors[:3],
        "mirror_ms_total": round(counters["mirror_ns"] / 1e6, 2), "main_ms_total": round(counters.get("main_ns", 0) / 1e6, 2),
    }
    for key in ("mirror_ms", "main_ms"):
        values = [c[key] for c in cycles]
        summary[f"cycle_{key}"] = {f"p{p}": report.pct(values, p, 3) for p in (50, 95, 99)}
    write_summary(summary)
    # result-v1 only from an app this script launched (its launch env is BenchApp's), and after the summary is on
    # disk, so a failure here cannot lose it.
    if BENCH is None:
        summary["result_v1"] = "not recorded: attached to an app this bench did not launch (--tag)"
    else:
        summary["result_v1"] = report.record_all(BENCH, report.mirror_series(opts.count, cycles))
    write_summary(summary)
    print(json.dumps(summary), flush=True)
    if views == 0:
        sys.exit("FAIL no mirror view call during the rebuilds")
    print("ok", flush=True)


def main():
    try:
        if opts.app:
            launch()
        measure()
    finally:
        if BENCH is not None:
            BENCH.stop()


main()
