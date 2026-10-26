#!/usr/bin/env python3
"""Live check: what idle Chromium tabs cost, and that page console output stays off disk (perf100 browser lane).

  scripts/cmux-next/browser-idle-cost-live.py --app PATH --tabs 5 [--out DIR] [--budget FILE]

The shared page server (tab_pages.py) serves the pages. The tagged app opens --tabs Chromium tabs of a
static page and a static front tab that stays shown (until the chatty phase), then runs these phases,
each one adding a tab:

  static   only the static tabs;
  loading  one more tab whose load never ends (an image request the server keeps open);
  chatty   one more tab, shown, that calls console.log 4 times a second, as the 1Password extension's
           background page does (a background page never freezes; a hidden tab would after 30 s).

Each phase waits --settle-s (past the 30 s hidden-tab freeze), then measures --idle-s: CPU seconds,
idle wakeups and bytes written per Chromium process class (app/browser, gpu, renderer, utility),
footprint per renderer, and how many bytes cef.log grew. The chatty tab's lines carry a run marker;
the run counts the marker lines in cef.log (and cef.previous.log) at the end, and the page counts its
calls to the server, so "0 lines" cannot mean "never logged". CPU limits are reported, and gated only
where the budget file names them.

With --budget, a breach of any limit in the file (see browser-idle-cost-budget.json) is a FAIL.
`sample` output of the GPU process and the app for 3 s per phase goes to the artifacts.

The app launches and stops through bench_launch.BenchApp (the bench env, a fresh saved session, debug.quit of its
own PID, then the tag's daemons). A run that measured every phase also writes cmux-perf-result/v1 into --out
(story browser-idle-cost, idle_burst_bench_report.browser_idle_series): per phase and class its idle CPU %,
wakeups/s, footprint and disk bytes; per phase the total CPU % and cef.log bytes/s; the console lines on disk and
the FAIL count.
"""
import argparse, importlib.util, json, os, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import BenchApp, bundle_id  # noqa: E402
import idle_burst_bench_report as results_v1  # noqa: E402
from tab_pages import PERF100_CLASSES, TabPages, chromium_children, process_table, process_type_kind  # noqa: E402

_spec = importlib.util.spec_from_file_location("browser_engine_bench", os.path.join(HERE, "..", "perf", "browser_engine_bench.py"))
bench = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bench)


def parse(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", required=True, help="tagged .app")
    parser.add_argument("--tag")  # the story runner passes it; the bundle carries the tag
    parser.add_argument("--tabs", type=int, default=5)
    parser.add_argument("--settle-s", type=float, default=40)
    parser.add_argument("--idle-s", type=float, default=60)
    parser.add_argument("--phases", default="static,loading,chatty")
    parser.add_argument("--budget", help="JSON limits; a breach is a FAIL")
    parser.add_argument("--no-sample", action="store_true")
    parser.add_argument("--env", action="append", default=[],
                        help="KEY=VALUE for the app, e.g. CMUX_NEXT_CEF_EXTRA_SWITCHES=process-per-site")
    parser.add_argument("--story", default=results_v1.BROWSER_IDLE_STORY, help="result-v1 story")
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS"), help="artifacts and result-v1 (default: a new "
                        "temporary folder)")
    opts = parser.parse_args(argv)
    if not set(opts.phases.split(",")) <= {"static", "loading", "chatty"}:
        parser.error(f"unknown phase in {opts.phases}")
    if any("=" not in item for item in opts.env):
        parser.error("--env takes KEY=VALUE")
    return opts


def bench_app(opts):
    """The tagged app as this lane launches it (bench_launch.BenchApp: the bench env, a fresh saved session, the tag
    teardown), on the last screen, with --env on top."""
    return BenchApp(opts.app, out=opts.out, env=dict(item.split("=", 1) for item in opts.env), config={},
                    screen="last", log_name="app.log")


opts = LAUNCHER = pages = CEF_LOG = MARKER = ORIGIN = None
failures = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def rpc(method, params=None, timeout=30):
    """One request on the launched app's socket (BenchApp.rpc): its result, or {"error": ...}."""
    reply = LAUNCHER.rpc(method, params, timeout)
    return reply if isinstance(reply, dict) else {}


def wait_for(predicate, what, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.2)
    check(False, f"timed out: {what}")
    return None


def processes(app_pid):
    """{pid: class} for the app and every child of it with a --type (tab_pages.process_type_kind); its other
    children (daemons, the Chromium Host) are not this lane's."""
    return {**chromium_children(app_pid, process_table(), PERF100_CLASSES, process_type_kind), app_pid: "app"}


def snapshot(pids):
    snap = {}
    for pid in pids:
        info = bench.rusage(pid)
        if info is not None:
            snap[pid] = (bench.cpu_ns(info), info.ri_pkg_idle_wkups + info.ri_interrupt_wkups,
                         info.ri_diskio_byteswritten, info.ri_phys_footprint, info.ri_resident_size)
    return snap


def log_size():
    try:
        return os.path.getsize(CEF_LOG)
    except OSError:
        return 0


def measure(app_pid, phase):
    rows = processes(app_pid)
    before, log_before, t0, ticks_before = snapshot(rows), log_size(), time.monotonic(), pages.ticks
    time.sleep(opts.idle_s)  # the measured idle window itself
    after, log_after, seconds = snapshot(rows), log_size(), time.monotonic() - t0
    classes = {}
    for pid, kind in rows.items():
        if pid not in before or pid not in after:
            continue
        c = classes.setdefault(kind, {"count": 0, "cpu_s": 0.0, "wakeups": 0, "bytes_written": 0, "footprint": [], "rss": []})
        c["count"] += 1
        c["cpu_s"] += (after[pid][0] - before[pid][0]) / 1e9
        c["wakeups"] += after[pid][1] - before[pid][1]
        c["bytes_written"] += after[pid][2] - before[pid][2]
        c["footprint"].append(after[pid][3])
        c["rss"].append(after[pid][4])
    for c in classes.values():
        c["cpu_percent"] = round(100 * c["cpu_s"] / seconds, 3)
        c["wakeups_per_s"] = round(c["wakeups"] / seconds, 1)
        c["footprint_total"] = sum(c["footprint"])
        c["rss_total"] = sum(c["rss"])
    dropped = sorted(set(rows) - (set(before) & set(after)))
    check("gpu" in classes and classes.get("renderer", {}).get("count", 0) >= 1
          and not any(rows[pid] in ("gpu", "renderer") for pid in dropped),
          f"{phase}: the GPU process and renderers are measured ({sorted(classes)}, unmeasured pids {dropped})")
    result = {"phase": phase, "seconds": round(seconds, 1), "classes": classes, "unmeasured_pids": dropped,
              "console_calls": pages.ticks - ticks_before,
              "pages_visible": sorted(n for n, state in pages.visibility.items() if state == "visible"),
              "cef_log_bytes_per_min": round((log_after - log_before) * 60 / seconds),
              "total_cpu_percent": round(sum(c["cpu_percent"] for c in classes.values()), 3)}
    for name in ("debug.cef", "debug.wakeups"):
        result[name] = rpc(name)
    if not opts.no_sample:
        for pid, kind in rows.items():
            if kind in ("gpu", "app"):
                subprocess.run(["sample", str(pid), "3", "-file", os.path.join(opts.out, f"sample-{phase}-{kind}-{pid}.txt")],
                               capture_output=True, timeout=60)
    summary = ", ".join(f"{k} x{c['count']}: {c['cpu_percent']}% cpu, {c['wakeups_per_s']} wk/s, "
                        f"{c['footprint_total'] // 1048576} MB" for k, c in sorted(classes.items()))
    print(f"phase {phase} ({opts.tabs} tabs): {summary}; cef.log {result['cef_log_bytes_per_min']} B/min; "
          f"static pages that report visible: {result['pages_visible']}", flush=True)
    return result


def open_tab(url, key):
    rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True})
    wait_for(lambda: key in pages.loaded, f"page {key} loads", 60)


def show(url):
    tabs = rpc("browser.page.tabs", {"all": True}).get("tabs") or []
    tab = next((t for t in tabs if (t.get("url") or "").startswith(url)), None)
    check(tab is not None, f"tab {url} is listed ({len(tabs)} tabs)")
    if tab:
        rpc("action.run", {"action": "tab.focus", "target": f"tab:{tab['id']}", "focus": True})


def judge(results, lines):
    """The --budget file's limits on this run's results (each breach a FAIL)."""
    with open(opts.budget) as f:
        budget = json.load(f)
    limit = budget.get("console_marker_lines_on_disk")
    if limit is not None and "chatty" in opts.phases.split(","):
        check(lines <= limit, f"page console lines in cef.log: {lines} <= {limit}")
    for phase in results["phases"]:
        limits = budget.get("phases", {}).get(phase["phase"], {})
        for kind, cap in limits.get("cpu_percent", {}).items():
            got = phase["classes"].get(kind, {}).get("cpu_percent", 0)
            check(got <= cap, f"{phase['phase']}: {kind} idle CPU {got}% <= {cap}%")
        cap = limits.get("cef_log_bytes_per_min")
        if cap is not None:
            check(phase["cef_log_bytes_per_min"] <= cap, f"{phase['phase']}: cef.log {phase['cef_log_bytes_per_min']} B/min <= {cap}")


def run(results):
    phases = opts.phases.split(",")
    LAUNCHER.launch(timeout=120)
    app_pid = LAUNCHER.process.pid
    print(f"app pid {app_pid}, origin {ORIGIN}, out {opts.out}, cef.log {CEF_LOG}", flush=True)
    rpc("action.run", {"action": "workspace.selectFirst"})
    rpc("action.run", {"action": "newTab", "origin": "script", "focus": True})
    for n in range(opts.tabs):
        open_tab(f"{ORIGIN}/static-{n}", str(n))
    front = f"{ORIGIN}/static-front"
    open_tab(front, "front")
    for phase in phases:
        if phase in ("loading", "chatty"):
            open_tab(f"{ORIGIN}/{phase}-x", phase)
            # The chatty page stays shown, as an extension's background page never freezes;
            # the loading page is hidden behind the front tab.
            show(f"{ORIGIN}/chatty-x" if phase == "chatty" else front)
        time.sleep(opts.settle_s)  # past the hidden-tab freeze, so the window is steady idle
        results["phases"].append(measure(app_pid, phase))
    lines = 0
    check(os.path.exists(CEF_LOG), f"cef.log exists at {CEF_LOG}")
    for path in (CEF_LOG, CEF_LOG.replace("cef.log", "cef.previous.log")):
        if os.path.exists(path):
            with open(path, errors="replace") as f:
                lines += sum(1 for line in f if MARKER in line)
    if "chatty" in phases:
        chatty = next(p for p in results["phases"] if p["phase"] == "chatty")
        check(chatty["console_calls"] >= 3 * opts.idle_s, f"the chatty page logs while measured ({chatty['console_calls']} calls)")
    results["console_marker_lines_on_disk"] = lines
    print(f"cef.log lines with the page's console marker: {lines}", flush=True)
    if opts.budget:
        judge(results, lines)


def record(results):
    """The run's series as cmux-perf-result/v1 in --out (BenchApp.record), once every phase measured. A run cut short
    (the launch or a phase raised) writes none: a missing run, never a partial one that reads as a pass."""
    written = results_v1.record_all(LAUNCHER, results_v1.browser_idle_series(results, failures, story=opts.story))
    kept = sum(1 for v in written.values() if not v.startswith("not recorded"))
    print(f"result-v1: {kept} of {len(written)} series written to {opts.out}", flush=True)


def main(argv=None):
    global opts, LAUNCHER, pages, CEF_LOG, MARKER, ORIGIN
    opts = parse(argv)
    opts.out = opts.out or tempfile.mkdtemp(prefix="browser-idle-cost-")
    os.makedirs(opts.out, exist_ok=True)
    LAUNCHER = bench_app(opts)
    CEF_LOG = os.path.expanduser(f"~/Library/Application Support/{bundle_id(LAUNCHER.app)}/Chromium/cef.log")
    MARKER = f"cmux-idle-cost-{os.urandom(4).hex()}"
    pages = TabPages(marker=MARKER)  # the static, loading and chatty pages, and what they report
    ORIGIN = pages.origin
    results = {"tabs": opts.tabs, "app": LAUNCHER.app, "env": opts.env, "phases": []}
    try:
        run(results)
        record(results)
    finally:
        with open(os.path.join(opts.out, f"browser-idle-cost-{opts.tabs}.json"), "w") as f:
            json.dump(results, f, indent=1, default=str)
        LAUNCHER.stop()  # debug.quit of the PID it started, then the tag's daemons (TagTeardown)
        pages.close()
    print(f"{len(failures)} failure(s); artifacts in {opts.out}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
