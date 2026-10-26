#!/usr/bin/env python3
"""Time daemon new-tab replies and check whether each tab adopted the spare host (R81).

Usage: new-tab-daemon-bench.py CMUX_BINARY [RUNS] [login|sh] [--app APP --out DIR]
       new-tab-daemon-bench.py --app APP --out DIR [--runs N] [--shell login|sh]
Runs a headless daemon on a private socket and state dir, sends new-tab with a
caller-chosen terminal_id (as the app does) and reports reply time and whether
the tab's host pid was the spare. With --app and no CMUX_BINARY the daemon is the
app's bundled CLI (Contents/Resources/bin/cmux). Env: GAP (seconds between tabs, default 0.6),
SAMPLE=SECONDS with SAMPLE_OUT=PATH runs `sample` on the daemon meanwhile,
SPANS=1 turns on the daemon's debug timing marks (CMUX_TUI_DEBUG_SPANS) and
prints the mean, p95 and p99 gap before each mark, then the p50, p95 and p99 time from
request arrival to each first-output mark of the tab (`new-tab.follow` lines:
host.first_output, first_printable_output, first_prompt_mark,
attach.first_output_sent; the last needs
an attached client, which this bench does not have).
Percentiles come from scripts/perf-lab/perf_stats.py (linear interpolation).
With --out, the replies are written as cmux-perf-result/v1 (story new-tab-daemon,
`new_tab_daemon.<shell>.reply` with its `.missed_runs`, and `new_tab_daemon.<shell>.not_adopted`;
new_tab_bench_report.py), the build named by --app (or CMUX_CI_SHA) and this Mac's host block.
Run it on a fleet Mac, never on the laptop.
"""
import argparse, glob, json, os, shutil, socket, subprocess, sys, tempfile, time, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench_launch  # noqa: E402
import new_tab_bench_report as results  # noqa: E402

pct = results.pct


def parse(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("binary", nargs="?", help="the cmux-tui daemon binary (default: the --app bundle's CLI)")
    parser.add_argument("runs_word", nargs="?", type=int, metavar="RUNS")
    parser.add_argument("shell_word", nargs="?", choices=["login", "sh"], metavar="SHELL")
    parser.add_argument("--runs", type=int)
    parser.add_argument("--shell", choices=["login", "sh"])
    parser.add_argument("--app", help="the measured app bundle: its CLI is the daemon, and it names the result's build")
    parser.add_argument("--out", help="write cmux-perf-result/v1 here")
    parser.add_argument("--tag")  # the story runner passes it; the bundle carries the tag
    parser.add_argument("--story", default=results.NEW_TAB_DAEMON_STORY, help="result-v1 story")
    parser.add_argument("--build-config", choices=["bench", "bench-checks", "release", "debug"],
                        help="result-v1 build config of a bench-hooks bundle that does not stamp it")
    opts = parser.parse_args(argv)
    opts.runs = opts.runs or opts.runs_word or 20
    opts.shell = opts.shell or opts.shell_word or "login"
    if not opts.binary:
        if not opts.app:
            parser.error("name the daemon binary, or --app")
        opts.binary = os.path.join(os.path.realpath(opts.app), "Contents/Resources/bin/cmux")
    if opts.out and not opts.app:
        parser.error("--out needs --app: a result names the build it measured")
    return opts


def measured_build(app, stated):
    """(result-v1 build, host) of the app on this Mac. Raises RecordError when the build cannot be named."""
    binary = bench_launch.main_binary(app)
    build = results.perf_result.Build(sha=bench_launch.build_sha(app),
                                      config=bench_launch.build_config(app, binary, stated),
                                      measure_version=bench_launch.PERF_LAB_MEASURE_VERSION)
    return build, results.perf_result.Host.from_dict(bench_launch.read_host())


def span_report(spans_path):
    gaps = {}
    order = []
    totals = []
    follow = {}
    for line in open(spans_path):
        trace = json.loads(line)
        if trace.get("label") == "new-tab.follow":
            for name, at in trace["marks"]:
                follow.setdefault(name, []).append(at / 1000)
            continue
        if trace.get("label") not in ("new-tab", "host"):
            continue
        if trace["label"] == "host":
            trace["marks"] = [["host-process " + name, at] for name, at in trace["marks"]]
        if trace["label"] == "new-tab":
            totals.append(trace["total_us"] / 1000)
        last = 0
        for name, at in trace["marks"]:
            key = " ".join(name.split(" ")[:2]) if name.startswith(("lock.wait", "host-process")) else name
            if key not in gaps:
                gaps[key] = []
                order.append(key)
            gaps[key].append((at - last) / 1000)
            last = at
        gaps.setdefault("(after last mark)", []).append((trace["total_us"] - last) / 1000)
    order.append("(after last mark)")
    n = len(totals)
    if os.environ.get("SPANS_DUMP"):
        shutil.copy(spans_path, os.environ["SPANS_DUMP"])
    print(f"spans over {n} new-tab traces; daemon total p50 {pct(totals, .5)} ms p99 {pct(totals, .99)} ms")
    print(f"{'gap before mark':58s} {'count':>5s} {'sum/tab':>8s} {'mean':>7s} {'p95':>7s} {'p99':>7s}")
    for key in order:
        values = gaps[key]
        print(f"{key[:58]:58s} {len(values):5d} {sum(values) / n:8.2f} {sum(values) / len(values):7.2f} "
              f"{pct(values, .95):7.2f} {pct(values, .99):7.2f}")
    print(f"{'request arrival to first-output mark':58s} {'count':>5s} {'p50':>8s} {'p95':>7s} {'p99':>7s}")
    for name in ("host.first_output", "first_printable_output", "first_prompt_mark", "attach.first_output_sent"):
        values = follow.get(name, [])
        if not values:
            print(f"{name:58s} {0:5d} {'-':>8s} {'-':>7s} {'-':>7s}")
            continue
        print(f"{name:58s} {len(values):5d} {pct(values, .5):8.2f} {pct(values, .95):7.2f} {pct(values, .99):7.2f}")


def main(argv=None):
    opts = parse(argv)
    measured = measured_build(opts.app, opts.build_config) if opts.out else None  # refuse before any run
    d = tempfile.mkdtemp(prefix="r81b-", dir="/tmp")
    sock = os.path.join(d, "s.sock")
    env = dict(os.environ)
    spans_path = os.path.join(d, "spans.jsonl")
    if os.environ.get("SPANS"):
        env["CMUX_TUI_DEBUG_SPANS"] = spans_path
    daemon = subprocess.Popen([opts.binary, "--headless", "--session", "r81b", "--socket", sock,
                               "--state", os.path.join(d, "state")],
                              stdout=subprocess.DEVNULL, stderr=open(os.path.join(d, "err.log"), "w"), env=env)
    for _ in range(200):
        if os.path.exists(sock):
            break
        time.sleep(0.05)  # bench: the daemon binds its socket

    def req(obj):
        s = socket.socket(socket.AF_UNIX)
        s.connect(sock)
        s.sendall((json.dumps(obj) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            c = s.recv(65536)
            if not c:
                break
            buf += c
        s.close()
        return json.loads(buf)

    def hosts():
        out = subprocess.run(["pgrep", "-P", str(daemon.pid), "-f", "__terminal-host"], capture_output=True, text=True).stdout
        return set(int(x) for x in out.split())

    def records():
        out = {}
        for f in glob.glob(os.path.join(d, "state", "terminal-hosts-*", "*.json")):
            try:
                r = json.load(open(f))
                out[r.get("terminal_id")] = r.get("host_pid")
            except Exception:
                pass
        return out

    times = []
    adopted = 0
    try:
        time.sleep(1.0)  # bench: the daemon parks its first spare
        sampler = None
        if os.environ.get("SAMPLE"):
            sampler = subprocess.Popen(["sample", str(daemon.pid), os.environ["SAMPLE"], "1", "-mayDie", "-file",
                                        os.environ.get("SAMPLE_OUT", "/tmp/r81b-sample.txt")],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(0.5)  # bench: the sampler attaches
        for i in range(opts.runs):
            before = hosts()
            spare = before - set(records().values())
            cmd = {"id": i + 1, "cmd": "new-tab", "terminal_id": uuid.uuid4().hex}
            if opts.shell == "sh":
                cmd["env"] = {"SHELL": "/bin/sh"}
            t0 = time.perf_counter()
            r = req(cmd)
            dt = (time.perf_counter() - t0) * 1000
            if not r.get("ok"):
                print("fail", r)
                break
            tpid = records().get(r["data"].get("terminal_id"))
            time.sleep(float(os.environ.get("GAP", "0.6")))  # let refill finish
            hit = tpid in spare
            adopted += hit
            times.append(dt)
            print(f"run {i:2d}: {dt:7.1f} ms  spare={sorted(spare)} host={tpid} adopted={hit}", flush=True)
        if times:
            print(f"adopted {adopted}/{len(times)} p50={pct(times, .5):.1f} p95={pct(times, .95):.1f} "
                  f"p99={pct(times, .99):.1f} min={min(times):.1f}")
        if measured:
            path = results.write_all(opts.out, results.new_tab_daemon_series(times + [None] * (opts.runs - len(times)),
                                                                             adopted, opts.shell, story=opts.story),
                                     *measured, root=bench_launch.ROOT)
            print(f"result-v1: {path}")
        if sampler:
            sampler.wait()
        if os.environ.get("SPANS") and os.path.exists(spans_path):
            span_report(spans_path)
    finally:
        daemon.terminate()
        try:
            daemon.wait(5)
        except Exception:
            daemon.kill()
        print(open(os.path.join(d, "err.log")).read()[-2000:])
        shutil.rmtree(d, ignore_errors=True)
    return 0 if len(times) == opts.runs else 1


if __name__ == "__main__":
    sys.exit(main())
