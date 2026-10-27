#!/usr/bin/env python3
"""New Chromium tab: input to the tab on screen and to its page's first pixels (perf-lead issue 1, PL-cef-tab).

Launches the tagged app through bench_launch.BenchApp (no activation, the bench env, scratch config: Chromium is the
default engine), then
per round, in a fresh terminal workspace, runs `debug.new_tab {action: bench_create, command: new_browser}` for each case:

  cold_pane    Cmd-Shift-L (New Browser Tab) in a pane with no Chromium window (round 0: the
               process's first Chromium tab)
  warm_pane    Cmd-Shift-L again in that pane (it has a Chromium window)
  second_pane  Cmd-D, then Cmd-Shift-L in the new pane (the second pane with Chromium in the process)
  third_pane   Cmd-D, then Cmd-Shift-L in the new pane
  url_warm     openBrowser with a file:// page in a pane with a Chromium window (a link opened in a tab)
  url_cold     Cmd-D, then openBrowser with a file:// page in the new pane
  webkit_new   New WebKit Tab (openBrowser.webkit) in that pane
  webkit_url   New WebKit Tab with a file:// page

The app reports per run `key_ms` (the input's synchronous main-thread time), `visible_ms` (the new tab selected on its themed pane; `chrome_ms` once its toolbar and page view are in it) (the
first display frame at which the pane shows the new tab, selected, with its browser view in the
pane), `page_ms` (the first frame after the page's first contentful paint or load end), the
main-thread spans (cef.create_window, cef.tab_add, ...) and the frame intervals with the display's
refresh period. The summary gives p50/p95/p99/max per case and the refresh rate: judge in frames. Percentiles come
from scripts/perf-lab/perf_stats.py (linear interpolation).

Every series is also written as one cmux-perf-result/v1 file into `--out` through BenchApp.record,
`new_browser_tab.<session>.<case>.<metric>` (visible, visible_frame, chrome, page, key_ms) with its `.missed_runs`
(new_tab_bench_report.py); the JSON lists them under `results_v1`. The Chromium cases are the story
new-browser-tab, the WebKit ones new-browser-tab-webkit (scripts/perf-lab/stories.d).

`--host` runs Chromium in the Chromium Host (debug tunable `browserHost.helper`), where the warm start builds no spare
window and the new tab's renderer is content's spare RenderProcessHost (p01-process-086); `--host-spare-window` adds
the bench-only feature `chromiumHostSpareWindow` (a Labs local choice), the spare window arm: run both and write the
cold_pane and second_pane visible p95 of each in the PR, to show whether the spare renderer alone meets 100 ms.

`--sessions light,stress`: after the light rounds, builds STRESS (scripts/cmux-next/perf-stress-session.py:
60 workspaces, the measured one 14 panes x 6 tabs, 10 others with Chromium pages, 10 printing
terminals) and runs the cases that need no split in the measured workspace's focused pane.

Not a CI gate (Lawrence 2026-10-23): run it yourself on a fleet GUI host, before and after a change:
  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \\
    python3 scripts/cmux-next/cef-tab-bench.py --tag "$NX_APP_TAG" --app "$NX_APP" --out "$NX_ARTIFACTS" --sessions light,stress
or, building the app in the step:
  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh --ref SHA \\
    --arg=--suite=cef-tab --artifact artifacts/split-spring/report.json [--arg=--rounds=6] [--arg=--sessions=light,stress]
Local, on a built app (never on a laptop in use):
  cef-tab-bench.py --tag T --app "<...>/cmux DEV T.app" [--rounds 6] [--sessions light,stress] [--json F]
"""
import argparse, json, os, signal, socket, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import BenchApp, socket_candidates  # noqa: E402
from new_surfaces_report import frame_of  # noqa: E402
import new_tab_bench_report as results  # noqa: E402

def parse(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--app", required=True)
    parser.add_argument("--rounds", type=int, default=6)
    parser.add_argument("--cases", default="cold_pane,warm_pane,second_pane,third_pane,url_warm,url_cold,webkit_new,webkit_url")
    parser.add_argument("--sessions", default="light", help="light, stress, or both (comma list, in that order)")
    parser.add_argument("--profile", type=int, default=0, help="after the light rounds: N profiled new tabs per engine under a Time Profiler (main-thread top frames)")
    parser.add_argument("--spare-cost", action="store_true", help="after the light rounds: the spare Chromium window's resident memory")
    parser.add_argument("--host", action="store_true", help="Chromium in the Chromium Host (debug tunable browserHost.helper)")
    parser.add_argument("--host-spare-window", action="store_true",
                        help="with --host: the bench-only feature chromiumHostSpareWindow, a spare window as in process")
    parser.add_argument("--budget-ms", type=float, default=10.0, help="visible p95 target (reported, not enforced)")
    parser.add_argument("--out", default="/tmp")
    parser.add_argument("--json")
    parser.add_argument("--story", default=results.NEW_BROWSER_TAB_STORY,
                        help="result-v1 story of the Chromium cases (the WebKit cases: <story>-webkit)")
    parser.add_argument("--build-config", choices=["bench", "bench-checks", "release", "debug"],
                        help="result-v1 build config of a bench-hooks bundle that does not stamp it (BenchApp.record)")
    return parser.parse_args(argv)


launcher = None
app = None
if __name__ == "__main__":
    opts = parse()
    TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
    SOCKET = socket_candidates(TAG)[0]  # the launch sets the one the app answered on
    SCRATCH = tempfile.mkdtemp(prefix=f"cef-tab-{TAG}-")
    PAGE = os.path.join(SCRATCH, "page.html")
    open(PAGE, "w").write("<!doctype html><title>cef-tab</title><body style='background:#fff'>"
                          + "".join(f"<p>line {i} of a plain page</p>" for i in range(60)) + "</body>")
    CASES = [c for c in opts.cases.split(",") if c]


def rpc(method, params=None, timeout=30):
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
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def action(name, args=None, timeout=60, focus=True):
    return rpc("action.run", {"action": name, "args": args or {}, "focus": focus, "origin": "script"}, timeout=timeout)


def wait(check, seconds, step=0.2):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            value = check()
        except Exception:
            value = None
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def panes():
    return [p for w in (rpc("debug.surfaces").get("windows") or []) for p in w.get("panes", [])]


def focused():
    return next((p for p in panes() if p.get("focused")), None)


def window_key():
    return ((rpc("debug.windows") or {}).get("windows") or [{}])[0].get("id")


def key(k, modifiers, window):
    return rpc("debug.key", {"key": k, "modifiers": modifiers, "window": window})


def terminal_workspace(name):
    reply = action("newTab", {"name": name}, focus=True)
    if isinstance(reply, dict) and reply.get("error"):
        print("newTab:", json.dumps(reply)[:300], flush=True)
    ok = wait(lambda: (focused() or {}).get("kind") == "terminal", 30)
    time.sleep(0.8)  # test harness: shell prompt
    return ok


def split(window):
    """Cmd-D: a new pane (it may show a New Tab page or a terminal), focused."""
    before = {p.get("pane") for p in panes()}
    key("d", ["command"], window)
    ok = wait(lambda: (focused() or {}).get("pane") not in before and len(panes()) > len(before), 15)
    time.sleep(0.6)  # test harness: shell prompt in the new pane
    return ok


def settle():
    time.sleep(1.2)  # test harness: the page loads and Chromium goes idle before the next input


def bench_case(case, window, session, rnd):
    if case in ("second_pane", "third_pane", "url_cold"):
        if not split(window):
            return {"case": case, "session": session, "round": rnd, "error": "split failed: " + json.dumps(focused())[:200]}
    params = {"action": "bench_create", "command": "new_browser"}
    if case.startswith("url_"):
        params.update({"run": "openBrowser", "url": "file://" + PAGE})
    elif case == "webkit_new":
        params.update({"run": "openBrowser.webkit"})
    elif case == "webkit_url":
        params.update({"run": "openBrowser.webkit", "url": "file://" + PAGE})
    result = rpc("debug.new_tab", params, timeout=30) or {}
    result.update({"case": case, "session": session, "round": rnd})
    result["visible_frame"] = frame_of(result, "visible_ms")
    result["page_frame"] = frame_of(result, "page_ms")
    spans = [s for s in result.get("spans") or [] if s.get("name", "").startswith("cef.") or s.get("ms", 0) >= 2]
    print(f"{session} r{rnd} {case}: engine={result.get('engine')} key={result.get('key_ms')} "
          f"visible={result.get('visible_ms')} (frame {result['visible_frame']}) chrome={result.get('chrome_ms')} page={result.get('page_ms')} "
          f"spare_after={result.get('spare_window')} confirmed={result.get('confirmed_ms')} "
          f"refresh={(result.get('frames') or {}).get('refresh_ms')} "
          f"spans={[(s['name'], round(s['at'], 1), round(s['ms'], 1)) for s in spans][:12]} err={result.get('error')}", flush=True)
    settle()
    return result


def bench_session(session, window):
    rows = []
    for rnd in range(opts.rounds):
        if not terminal_workspace(f"cef-tab-{session}-{rnd}"):
            sys.exit("no focused terminal: " + json.dumps(panes())[:800])
        for case in CASES:
            rows.append(bench_case(case, window, session, rnd))
        action("closeWorkspace", {"confirm": True})
        time.sleep(0.8)  # test harness: the workspace's pages close
    return rows


def build_stress():
    """STRESS (scripts/cmux-next/perf-stress-session.py): 60 workspaces, the measured one 4x3 panes
    (14 with nested splits) of 6 tabs each, 10 others with Chromium pages, 10 printing terminals."""
    import importlib.util
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "perf-stress-session.py")
    spec = importlib.util.spec_from_file_location("perf_stress_session", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    stress = module.Stress(rpc)
    # STRESS has 60 workspaces in all: the tag's daemon may keep workspaces from an earlier run on this host,
    # and a light round's workspace may outlive its close. Close every one but the focused one first.
    for _ in range(3):
        others = [w["id"] for w in stress.workspaces() if w["id"] != stress.focused_workspace()]
        if not others:
            break
        print(f"STRESS: closing {len(others)} workspaces the app already had", flush=True)
        for workspace in others:
            action("goToWorkspace", {"workspace": workspace}, focus=True)
            action("closeWorkspace", {"confirm": True}, focus=True)  # destructive: a script caller confirms
    summary = stress.build()
    print("STRESS-SESSION " + json.dumps(summary), flush=True)
    return summary


def bench_stress(window):
    """In the STRESS measured workspace's focused pane (a terminal): every case that needs no split,
    the new tab closed again (Cmd-W) after each run so the pane stays as built."""
    rows = []
    cases = [c for c in CASES if c not in ("second_pane", "third_pane", "url_cold")]
    for rnd in range(opts.rounds):
        for case in cases:
            row = bench_case(case, window, "stress", rnd)
            rows.append(row)
            if row.get("visible_ms") is not None:
                key("w", ["command"], window)
                time.sleep(0.6)  # test harness: the closed tab's page goes before the next run
    return rows


def app_rss_mb():
    """(MB, processes): resident memory of the app and its helpers (Chromium's included)."""
    ps = subprocess.run(["ps", "-axo", "rss=,command="], capture_output=True, text=True).stdout
    total, count = 0, 0
    for line in ps.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1].startswith(APP + "/"):
            total += int(parts[0])
            count += 1
    return round(total / 1024, 1), count


def spare_cost():
    """What the always-ready spare Chromium window costs: the app's resident memory with the spare
    up, then again once `debug.cef drop_spare` closed it."""
    live = wait(lambda: (rpc("debug.cef") or {}).get("spare_window") == "live", 60, step=0.5)
    if not live:
        return {"spare": (rpc("debug.cef") or {}).get("spare_window"), "note": "no live spare"}
    time.sleep(3)  # test harness: the spare's renderer settles
    with_spare = app_rss_mb()
    rpc("debug.cef", {"drop_spare": True})
    time.sleep(5)  # test harness: the spare's renderer exits
    without = app_rss_mb()
    cost = {"with_spare_mb": with_spare[0], "with_spare_processes": with_spare[1], "without_mb": without[0],
            "without_processes": without[1], "spare_mb": round(with_spare[0] - without[0], 1)}
    print("SPARE-COST " + json.dumps(cost), flush=True)
    return cost


def profile_summary(trace, label):
    """Heaviest main-thread frames of the app in `trace` (self and inclusive ms)."""
    import collections, xml.etree.ElementTree as ET
    xml = trace + ".xml"
    with open(xml, "w") as handle:
        subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                        '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'], stdout=handle, timeout=600)
    byid, selfw, incl, total = {}, collections.Counter(), collections.Counter(), 0
    def resolve(e):
        r = e.get("ref")
        return byid.get(r, e) if r else e
    for _, e in ET.iterparse(xml, events=("end",)):
        if e.get("id"):
            byid[e.get("id")] = e
        if e.tag != "row":
            continue
        thread = resolve(e.find("thread")) if e.find("thread") is not None else None
        if thread is None or "Main Thread" not in thread.get("fmt", ""):
            continue
        w = e.find("weight"); w = resolve(w) if w is not None else None
        weight = int(w.text) if w is not None and w.text and w.text.isdigit() else 1000000
        bt = e.find("backtrace"); bt = resolve(bt) if bt is not None else None
        if bt is None:
            continue
        names = [resolve(f).get("name", "?") for f in bt.findall("frame")]
        if not names:
            continue
        total += weight
        selfw[names[0]] += weight
        for n in set(names):
            incl[n] += weight
    lines = [f"PROFILE {label} main-thread total_ms={total / 1e6:.1f}"]
    lines += [f"PROFILE {label} self {w / 1e6:8.1f} ms  {n[:170]}" for n, w in selfw.most_common(30)]
    lines += [f"PROFILE {label} incl {w / 1e6:8.1f} ms  {n[:170]}" for n, w in incl.most_common(90)]
    print("\n".join(lines), flush=True)
    return {"total_ms": round(total / 1e6, 1), "self": [[n, round(w / 1e6, 1)] for n, w in selfw.most_common(30)],
            "incl": [[n, round(w / 1e6, 1)] for n, w in incl.most_common(90)]}


def profile_new_tabs(window, count):
    """`count` new tabs per engine (Cmd-Shift-L, New WebKit Tab with a page), each closed again,
    under a Time Profiler attached to the app."""
    out = {}
    for label, params in (("chromium", {}), ("webkit", {"run": "openBrowser.webkit", "url": "file://" + PAGE})):
        if not terminal_workspace(f"cef-tab-profile-{label}"):
            continue
        trace = os.path.join(opts.out, f"new-tab-{label}.trace")
        recorder = subprocess.Popen(["xcrun", "xctrace", "record", "--template", "Time Profiler", "--attach", str(app.pid),
                                     "--output", trace, "--no-prompt"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(4)  # test harness: the recorder attaches
        for _ in range(count):
            rpc("debug.new_tab", {"action": "bench_create", "command": "new_browser", **params}, timeout=30)
            time.sleep(0.6)  # test harness: the page loads
            key("w", ["command"], window)
            time.sleep(0.4)  # test harness: the tab closes
        recorder.send_signal(signal.SIGINT)
        try:
            recorder.wait(timeout=120)
        except subprocess.TimeoutExpired:
            recorder.kill()
        try:
            out[label] = profile_summary(trace, f"new-tab-{label}")
        except Exception as error:  # a failed export must not lose the timings
            print(f"profile export failed: {error!r}", flush=True)
        action("closeWorkspace", {"confirm": True})
        time.sleep(0.8)  # test harness: the workspace's pages close
    return out


def summary(rows):
    pct = results.pct
    out = {}
    for session in sorted({r.get("session") for r in rows if r.get("session")}):
        for case in CASES:
            sel = [r for r in rows if r.get("session") == session and r.get("case") == case]
            refresh = [(r.get("frames") or {}).get("refresh_ms") for r in sel]
            out[f"{session}/{case}"] = {
                "n": len(sel), "missed": sum(r.get("visible_ms") is None for r in sel),
                "engines": sorted({r.get("engine") or "none" for r in sel}),
                "key_p50": pct([r.get("key_ms") for r in sel], .5), "key_max": pct([r.get("key_ms") for r in sel], 1),
                "visible_p50": pct([r.get("visible_ms") for r in sel], .5),
                "visible_p95": pct([r.get("visible_ms") for r in sel], .95),
                "visible_p99": pct([r.get("visible_ms") for r in sel], .99),
                "visible_max": pct([r.get("visible_ms") for r in sel], 1),
                "visible_frame_p95": pct([r.get("visible_frame") for r in sel], .95),
                "visible_frame_p99": pct([r.get("visible_frame") for r in sel], .99),
                "chrome_p50": pct([r.get("chrome_ms") for r in sel], .5),
                "chrome_p95": pct([r.get("chrome_ms") for r in sel], .95),
                "chrome_p99": pct([r.get("chrome_ms") for r in sel], .99),
                "page_p50": pct([r.get("page_ms") for r in sel], .5),
                "page_p95": pct([r.get("page_ms") for r in sel], .95),
                "page_p99": pct([r.get("page_ms") for r in sel], .99),
                "create_window_ms_p95": pct([sum(s["ms"] for s in r.get("spans") or [] if s.get("name") == "cef.create_window") or None
                                             for r in sel], .95),
                "tab_add_ms_p95": pct([sum(s["ms"] for s in r.get("spans") or [] if s.get("name") == "cef.tab_add") or None
                                       for r in sel], .95),
                "main_spans_ms_p95": pct([r.get("main_thread_spans_ms") for r in sel], .95),
                "main_spans_ms_p99": pct([r.get("main_thread_spans_ms") for r in sel], .99),
                "refresh_ms": pct(refresh, .5),
            }
    return out


def host_launch(options, scratch):
    """The launch env and Labs local features of the arm: `--host` writes a debug tunables file with
    `browserHost.helper`, `--host-spare-window` adds `chromiumHostSpareWindow` (bench-only, a local choice since the app
    strips an inherited CMUX_ENABLE_FEATURES). Neither: the in-process engine, no change."""
    if options.host_spare_window and not options.host:
        raise SystemExit("--host-spare-window needs --host")
    if not options.host:
        return {}, {}
    tunables = os.path.join(scratch, "debug-tunables.json")
    with open(tunables, "w") as handle:
        json.dump({"version": 1, "values": {"browserHost.helper": True}}, handle)
    features = {"chromiumHostSpareWindow": True} if options.host_spare_window else {}
    return {"CMUX_NEXT_DEBUG_TUNABLES_FILE": tunables}, features


def cleanup():
    """Quits the app this run launched and ends its tag's daemons (BenchApp.stop); nothing when the launch refused."""
    if launcher:
        launcher.stop()


def main():
    global app, launcher, SOCKET
    # One launch path (bench_launch.py): it refuses a live app of this tag, unlinks only a socket nothing accepts on,
    # starts the app with the bench env and an empty cmux.json (Chromium is the default engine), and says why when
    # it does not come up.
    env, local_features = host_launch(opts, SCRATCH)
    launcher = BenchApp(APP, out=opts.out, log_name=f"app-{TAG}.log", config={}, window=(40, 40, 1400, 900),
                        screen="last", build_config=opts.build_config, env=env, local_features=local_features)
    try:
        launcher.launch(timeout=120)
    finally:
        app = launcher.process
    SOCKET = launcher.socket
    time.sleep(2)  # test harness: first workspace
    window = window_key()
    rows, stress, spare, profiles = [], None, None, None
    for session in [s for s in opts.sessions.split(",") if s]:
        if session == "stress":
            stress = build_stress()
            rows += bench_stress(window)
        else:
            rows += bench_session(session, window)
            if session == "light" and opts.profile:
                profiles = profile_new_tabs(window, opts.profile)
            if session == "light" and opts.spare_cost:
                spare = spare_cost()
    cef = rpc("debug.cef") or {}
    result = {"tag": TAG, "host": os.uname().nodename, "cpus": os.cpu_count(), "stress_session": stress, "spare_cost": spare, "profiles": profiles,
              "budget_visible_ms": opts.budget_ms, "summary": summary(rows), "runs": rows,
              "host_arm": {"host": opts.host, "spare_window": opts.host_spare_window},
              "cef": {k: cef.get(k) for k in ("backend", "spare_window", "start_steps", "likely", "state") if k in cef},
              "results_v1": results.record_all(launcher, results.new_browser_tab_series(rows, CASES, opts.story))}
    print("\nSUMMARY", json.dumps(result["summary"], indent=1), flush=True)
    print(f"\n| session/case | n | visible p50 | visible p95 | frame p95 | chrome p95 | page p50 | page p95 | create_window p95 | "
          f"tab_add p95 | refresh |\n|---|---|---|---|---|---|---|---|---|---|---|")
    for name, s in result["summary"].items():
        print(f"| {name} | {s['n']} | {s['visible_p50']} | {s['visible_p95']} | {s['visible_frame_p95']} | {s['chrome_p95']} | {s['page_p50']} | "
              f"{s['page_p95']} | {s['create_window_ms_p95']} | {s['tab_add_ms_p95']} | {s['refresh_ms']} |")
    over = [k for k, v in result["summary"].items() if v["missed"] or (v["visible_p95"] or 1e9) > opts.budget_ms]
    print("CEF-TAB", f"OVER {opts.budget_ms} ms: " + ", ".join(over) if over else "WITHIN", flush=True)
    if opts.json:
        os.makedirs(os.path.dirname(os.path.abspath(opts.json)), exist_ok=True)
        open(opts.json, "w").write(json.dumps(result, indent=1))
    return True


if __name__ == "__main__":
    ok = False
    try:
        ok = main()
    finally:
        cleanup()
    sys.exit(0 if ok else 1)
