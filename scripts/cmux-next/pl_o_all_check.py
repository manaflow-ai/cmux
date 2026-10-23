#!/usr/bin/env python3
"""pl-o-all test driver (testing harness only, scratch commit, not for landing).

Launches a tagged Debug app (activation-perf.py's App), then per session (LIGHT, STRESS):
control publishes per debug.app_activation pair, activation cycles (heavy = window_notices,
heavy_app_only), STRESS tab-list changes under perf-signposts (20 newTab.default, 20 closeTab,
one 12-pane workspace close), and behavior spot checks. Prints one line per result: `PLO {json}`.
  python3 scripts/cmux-next/pl_o_all_check.py --app "$NX_APP" --out "$NX_ARTIFACTS" [--phase main|act400]
"""
import argparse, importlib.util, json, os, platform, socket, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


act = load("activation_perf", "activation-perf.py")
stress_mod = load("perf_stress_session", "perf-stress-session.py")
RESULTS = {}


def emit(key, value):
    RESULTS[key] = value
    print("PLO " + json.dumps({key: value}, default=str), flush=True)


def guarded(key, fn):
    try:
        return fn()
    except Exception as error:  # a broken phase is reported, the next phase still runs
        emit(key + "_error", repr(error)[:400])
        return None


def host_facts():
    disp = subprocess.run(["system_profiler", "SPDisplaysDataType"], capture_output=True, text=True).stdout
    lines = [l.strip() for l in disp.splitlines() if any(k in l for k in ("Resolution", "Refresh", "UI Looks like", "Display Type", "Hz"))]
    return {"host": socket.gethostname(), "macos": platform.mac_ver()[0], "display": lines[:8],
            "web_dev_json": os.path.exists(os.path.expanduser("~/.config/cmux/web-dev.json"))}


def cef_facts(app):
    report = app.rpc("debug.cef") or {}
    text = json.dumps(report)
    return {"unavailable_or_fallback": ("unavailable" in text) or ("fallback" in text.lower()), "excerpt": text[:600]}


def publishes_per_pair(app, pairs=6):
    rows = []
    for _ in range(pairs):
        app.rpc("debug.timings", {"clear": True})
        app.rpc("debug.app_activation", {"active": False, "window_notices": True})
        app.rpc("debug.app_activation", {"active": True, "window_notices": True})
        time.sleep(0.5)  # test script: the after-frame publishes land before the read
        app.rpc("debug.layout_counters")  # one more socket round trip through the main actor
        report = app.rpc("debug.timings", {"clear": True}) or {}
        pubs = report.get("control_publishes") or []
        rows.append({"count": len(pubs), "ms": [p.get("ms") for p in pubs], "tabs": [p.get("tabs") for p in pubs]})
    counts = [r["count"] for r in rows]
    return {"counts": counts, "rows": rows[:3]}


def activation(app, cycles=20):
    out = {}
    for mode, notices in (("heavy", True), ("heavy_app_only", False)):
        rows, hangs = act.cycles(app, cycles, window_notices=notices)
        s = act.summarize(rows, hangs)
        out[mode] = {"observers_ms": s.get("observers_ms"), "drain_ms": s.get("drain_ms"),
                     "resyncs": s.get("resyncs"), "hangs": s.get("hangs")}
    return out


def topology(app):
    return ((app.rpc("snapshot.get") or {}).get("topology")) or {}


def all_tabs(topo, skip=None):
    return {t.get("id") for w in topo.get("workspaces") or [] if w.get("id") != skip
            for s in w.get("screens") or [] for p in s.get("panes") or [] for t in p.get("tabs") or [] if t.get("id")}


def signposts(app, label, actions):
    save = os.path.join(app.out, f"signposts-{label}.ndjson")
    proc = subprocess.Popen([sys.executable, os.path.join(HERE, "perf-signposts.py"), "--pid", str(app.process.pid),
                             "--category", "action", "--save", save, "--seconds", "600", "--json"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    time.sleep(3)  # test script: the log stream attaches before the first action
    started = time.monotonic()
    actions()
    took = round(time.monotonic() - started, 1)
    time.sleep(2)  # test script: the last intervals reach the stream
    proc.terminate()
    out, _ = proc.communicate(timeout=60)
    summary = subprocess.run([sys.executable, os.path.join(HERE, "perf-signposts.py"), "--from", save, "--json"],
                             capture_output=True, text=True).stdout
    try:
        parsed = json.loads(summary)
    except ValueError:
        parsed = summary[-1500:]
    return {"wall_s": took, "summary": parsed, "stream_tail": (out or "")[-300:]}


def tab_list_changes(app, st):
    measured = st.measured
    ws = st.workspace(measured)
    panes = st.panes(ws)
    pane = panes[0]["id"]
    st.focus_pane(pane)

    def run():
        for _ in range(20):
            n = len(st.tabs(measured, pane))
            st.action("newTab.default")
            stress_mod.wait(lambda: len(st.tabs(measured, pane)) > n, 10, step=0.05)
        for _ in range(20):
            n = len(st.tabs(measured, pane))
            st.action("closeTab", {"confirm": True})
            stress_mod.wait(lambda: len(st.tabs(measured, pane)) < n, 10, step=0.05)
    return signposts(app, "tabs", run)


def spot_close_workspace(app, st):
    victim = (getattr(st, "background", None) or [None])[0]
    before = topology(app)
    others_before = all_tabs(before, skip=victim)
    victim_tabs = all_tabs({"workspaces": [w for w in before.get("workspaces") or [] if w.get("id") == victim]})
    surf_before = app.rpc("debug.layout_counters") or {}
    st.action("closeWorkspace", {"confirm": True}, target=f"workspace:{victim}")
    stress_mod.wait(lambda: victim not in {w.get("id") for w in topology(app).get("workspaces") or []}, 20)
    time.sleep(2)  # test script: page and terminal hosts release
    after = topology(app)
    others_after = all_tabs(after, skip=victim)
    pool = app.rpc("debug.page_host_pool") or {}
    return {"victim": victim, "victim_tabs": len(victim_tabs), "victim_gone": victim not in {w.get("id") for w in after.get("workspaces") or []},
            "victim_tabs_left": len(victim_tabs & all_tabs(after)), "other_tabs_before": len(others_before),
            "other_tabs_lost": len(others_before - others_after),
            "counters_before": {k: v for k, v in surf_before.items() if isinstance(v, (int, float))},
            "counters_after": {k: v for k, v in (app.rpc("debug.layout_counters") or {}).items() if isinstance(v, (int, float))},
            "page_host_pool": json.dumps(pool)[:400]}


def spot_settings_tab(app, st):
    measured = st.measured
    pane = st.panes(st.workspace(measured))[-1]["id"]
    st.focus_pane(pane)
    before = {t.get("id") for t in st.tabs(measured, pane)}
    reply = st.action("openSettings")
    time.sleep(1.5)  # test script: the settings page opens
    tabs = st.tabs(measured, pane)
    new = [t for t in tabs if t.get("id") not in before]
    result = {"open_reply": json.dumps(reply)[:200], "new_tabs": [{k: t.get(k) for k in ("id", "kind", "page", "title")} for t in new]}
    if not new:
        result["note"] = "openSettings made no tab in the focused pane (a Settings window instead?)"
        return result
    st.action("closePane", {"confirm": True}, target=f"pane:{pane}")
    stress_mod.wait(lambda: not any(p.get("id") == pane for p in st.panes(st.workspace(measured))), 10)
    left = all_tabs(topology(app)) & {t.get("id") for t in new}
    result.update({"pane_gone": not any(p.get("id") == pane for p in st.panes(st.workspace(measured))),
                   "settings_tab_left": len(left)})
    return result


def spot_daemon(app, st):
    before = all_tabs(topology(app))
    first = app.rpc("debug.daemon") or {}
    app.rpc("debug.daemon", {"action": "restart"})
    samples = []
    deadline = time.monotonic() + 40
    while time.monotonic() < deadline:  # bounded poll of the app's socket state in a test script
        samples.append(len(all_tabs(topology(app))))
        time.sleep(0.5)  # test script: the poll interval
    after = all_tabs(topology(app))
    return {"daemon_before": json.dumps(first)[:300], "tabs_before": len(before), "min_tabs_while_away": min(samples) if samples else None,
            "tabs_after": len(after), "lost_after": len(before - after), "daemon_after": json.dumps(app.rpc("debug.daemon") or {})[:300]}


def spot_windows(app, st):
    st.action("newWindow")
    time.sleep(2)  # test script: the window opens
    wins = (app.rpc("debug.windows") or {}).get("windows") or []
    ids = [w.get("id") for w in wins if w.get("id")]
    out = {"windows": len(ids)}
    checks = []
    for target in (ids[:2] * 2)[:4]:
        app.rpc("debug.window.focus", {"window": target})
        app.rpc("debug.app_activation", {"active": False, "window_notices": True})
        app.rpc("debug.app_activation", {"active": True, "window_notices": True})
        time.sleep(0.3)  # test script: one frame for the after-frame publish
        cli = app.cli("list-windows", "--json")
        topo = topology(app)
        checks.append({"target": target, "focus": (topo.get("focus") or {}).get("window"),
                       "key_windows": [w.get("id") for w in topo.get("windows") or [] if w.get("isKey") or w.get("key")],
                       "cli": (cli.stdout or cli.stderr)[:300]})
    out["switches"] = checks
    if len(ids) > 1:
        st.action("closeWindow", {"confirm": True}, target=f"window:{ids[-1]}")
        time.sleep(1.5)  # test script: the window closes
        cli = app.cli("list-windows", "--json")
        out["after_close"] = {"windows": len((app.rpc("debug.windows") or {}).get("windows") or []), "cli": (cli.stdout or cli.stderr)[:300]}
    return out


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--app", required=True)
    p.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or "/tmp/plo")
    p.add_argument("--phase", choices=["main", "act400"], default="main")
    o = p.parse_args()
    os.makedirs(o.out, exist_ok=True)
    emit("host", host_facts())
    app = act.App(os.path.abspath(o.app), o.out, 50)
    try:
        app.launch()
        emit("app", {"tag": app.tag, "pid": app.process.pid})
        if o.phase == "act400":
            opts = argparse.Namespace(workspaces=400, browser=100, hibernate=50, chats=100, cycles=20, max_resyncs=act.MAX_RESYNCS,
                                      sample=False, out=o.out)
            r = act.run(app, opts)
            emit("act400", {k: r.get(k) for k in ("light", "session", "heavy_app_only", "heavy", "failures")})
            emit("act400_cef", guarded("act400_cef", lambda: cef_facts(app)))
            return
        emit("light_cef", guarded("light_cef", lambda: cef_facts(app)))
        emit("light_publishes", guarded("light_publishes", lambda: publishes_per_pair(app)))
        emit("light_activation", guarded("light_activation", lambda: activation(app)))
        st = stress_mod.Stress(app.rpc, log=lambda m: print(m, flush=True))
        summary = st.build()
        print("STRESS-SESSION " + json.dumps(summary), flush=True)
        emit("stress_session", summary)
        emit("stress_cef", guarded("stress_cef", lambda: cef_facts(app)))
        emit("stress_publishes", guarded("stress_publishes", lambda: publishes_per_pair(app)))
        emit("stress_activation", guarded("stress_activation", lambda: activation(app)))
        emit("stress_tabs_signposts", guarded("stress_tabs_signposts", lambda: tab_list_changes(app, st)))
        emit("spot_close_workspace", guarded("spot_close_workspace", lambda: spot_close_workspace(app, st)))
        emit("spot_settings_tab", guarded("spot_settings_tab", lambda: spot_settings_tab(app, st)))
        emit("spot_windows", guarded("spot_windows", lambda: spot_windows(app, st)))
        emit("stress_close_12pane", guarded("stress_close_12pane", lambda: signposts(
            app, "close12", lambda: (st.action("closeWorkspace", {"confirm": True}, target=f"workspace:{st.measured}"),
                                     stress_mod.wait(lambda: st.workspace(st.measured) is None, 30)))))
        emit("spot_daemon", guarded("spot_daemon", lambda: spot_daemon(app, st)))
    finally:
        app.stop()
        with open(os.path.join(o.out, f"plo-{o.phase}.json"), "w") as f:
            json.dump(RESULTS, f, indent=1, default=str)


if __name__ == "__main__":
    main()
