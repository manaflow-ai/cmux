#!/usr/bin/env python3
"""pl-o-all bench + behavior driver (test harness only, run inside an nx-remote --needs gui job).

Uses the tree's own scripts/cmux-next/activation-perf.py and perf-stress-session.py, unchanged.
Phase A: LIGHT (default session) then STRESS (Stress(rpc).build()) in one app.
Phase B: activation-perf heavy session with --workspaces 400, plus a sidebar hover proxy.
Writes $NX_ARTIFACTS/plo-bench.json and prints one PLO-RESULT line per section.
"""
import importlib.util, json, os, socket as so, subprocess, sys, tempfile, time

SRC = os.environ.get("NX_SRC") or os.getcwd()
HERE = os.path.join(SRC, "scripts/cmux-next")
OUT = os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp()
APP = os.environ["NX_APP"]
sys.path.insert(0, HERE)
RESULT = {}


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


act = load("activation_perf", "activation-perf.py")
stress_mod = load("perf_stress_session", "perf-stress-session.py")


def emit(key, value):
    RESULT[key] = value
    print(f"PLO-RESULT {key} {json.dumps(value)}", flush=True)
    with open(os.path.join(OUT, "plo-bench.json"), "w") as f:
        json.dump(RESULT, f, indent=1)


def sh(*cmd, timeout=60):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout.strip()
    except Exception as error:  # noqa: BLE001 - harness: record and go on
        return f"error: {error}"


def meta():
    rate = sh("osascript", "-l", "JavaScript", "-e",
              'ObjC.import("AppKit"); var s=$.NSScreen.screens; var r=[]; for (var i=0;i<s.count;i++){var x=s.objectAtIndex(i); r.push(x.maximumFramesPerSecond+"Hz "+x.frame.size.width+"x"+x.frame.size.height)}; r.join(", ")')
    return {"host": sh("hostname"), "macos": sh("sw_vers", "-productVersion"), "build": sh("sw_vers", "-buildVersion"),
            "sha": sh("git", "-C", SRC, "rev-parse", "HEAD"), "refresh": rate, "load": sh("sysctl", "-n", "vm.loadavg"),
            "web_dev_json": os.path.exists(os.path.expanduser("~/.config/cmux/web-dev.json")),
            "chip": sh("sysctl", "-n", "machdep.cpu.brand_string")}


def topo(app):
    return (app.rpc("snapshot.get") or {}).get("topology") or {}


def tab_counts(app):
    counts = {}
    for w in topo(app).get("workspaces") or []:
        kinds = {}
        for s in w.get("screens") or []:
            for p in s.get("panes") or []:
                for t in p.get("tabs") or []:
                    k = t.get("kind") or "?"
                    if k == "page":
                        k = f"page:{t.get('page')}"
                    kinds[k] = kinds.get(k, 0) + 1
        counts[w.get("id")] = kinds
    return counts


def cef_check(app):
    cef = app.rpc("debug.cef") or {}
    text = json.dumps(cef)
    return {"unavailable_or_fallback": ("unavailable" in text) or ("fallback" in text.lower()),
            "excerpt": text[:600]}


def control_publishes(app, pairs=5):
    rows = []
    for _ in range(pairs):
        app.rpc("debug.app_activation", {"active": False, "window_notices": True})
        time.sleep(0.4)  # harness: the app sits in the background between Cmd-Tabs
        app.rpc("debug.timings", {"clear": True})
        app.rpc("debug.app_activation", {"active": True, "window_notices": True})
        time.sleep(0.6)  # harness: let the after-frame and held publishes land
        t = app.rpc("debug.timings") or {}
        pubs = t.get("control_publishes") or []
        rows.append({"count": len(pubs), "ms": [p.get("ms") for p in pubs], "tabs": [p.get("tabs") for p in pubs]})
    return rows


def signposts(app, pid, label, body, seconds):
    save = os.path.join(OUT, f"signposts-{label}.ndjson")
    proc = subprocess.Popen([sys.executable, os.path.join(HERE, "perf-signposts.py"), "--pid", str(pid), "--seconds", str(seconds),
                             "--save", save, "--json"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    time.sleep(2.0)  # harness: log stream attaches before the first action
    t0 = time.monotonic()
    extra = body()
    took = time.monotonic() - t0
    stdout, stderr = proc.communicate(timeout=seconds + 60)
    try:
        parsed = json.loads(stdout)
    except ValueError:
        parsed = {"raw": stdout[-1500:], "stderr": stderr[-800:]}
    return {"body_s": round(took, 1), "extra": extra, "signposts": parsed}


def action(app, name, args=None, target=None, focus=True, timeout=60):
    params = {"action": name, "args": args or {}, "focus": focus, "origin": "script"}
    if target:
        params["target"] = target
    return app.rpc("action.run", params, timeout=timeout)


def tab_churn(app, n=20):
    errors = []
    for _ in range(n):
        r = action(app, "newTab.default")
        if isinstance(r, dict) and r.get("error"):
            errors.append(str(r["error"])[:120])
        time.sleep(0.15)  # harness: one Cmd-T per ~frame burst, not a flood
    for _ in range(n):
        r = action(app, "closeTab")
        if isinstance(r, dict) and r.get("error"):
            errors.append(str(r["error"])[:120])
        time.sleep(0.15)  # harness: one Cmd-W per ~frame burst
    return {"errors": errors[:5]}


def surface_summary(app):
    s = app.rpc("debug.surfaces", timeout=60) or {}
    pool = app.rpc("debug.page_host_pool") or {}
    def size(v):
        return len(v) if isinstance(v, (list, dict)) else v
    return {"surfaces": {k: size(v) for k, v in s.items()} if isinstance(s, dict) else str(s)[:200],
            "page_host_pool": {k: size(v) for k, v in pool.items()} if isinstance(pool, dict) else str(pool)[:200]}


def behavior(app, stress):
    out = {}
    # 1. Close a background Chromium workspace: its surfaces release, the other workspaces keep their tabs.
    bg = (getattr(stress, "background", None) or [])
    victim = bg[0] if bg else None
    before_tabs = tab_counts(app)
    before = surface_summary(app)
    if victim:
        r = action(app, "closeWorkspace", target=f"workspace:{victim}", focus=False)
        time.sleep(3.0)  # harness: release work after the close
        after_tabs = tab_counts(app)
        others_same = all(after_tabs.get(w) == k for w, k in before_tabs.items() if w != victim)
        out["close_workspace"] = {"victim": victim, "victim_tabs": before_tabs.get(victim), "reply": str(r)[:200],
                                  "victim_gone": victim not in after_tabs, "other_workspaces_unchanged": others_same,
                                  "before": before, "after": surface_summary(app)}
    # 2. Settings page tab in a pane, then close that pane: the page tab closes.
    try:
        ws = topo(app).get("focus", {}).get("workspace")
        r1 = action(app, "openSettings")
        time.sleep(2.0)  # harness: the page tab mounts
        holder = None
        for w in topo(app).get("workspaces") or []:
            for s in w.get("screens") or []:
                for p in s.get("panes") or []:
                    if any(t.get("kind") == "page" and t.get("page") == "settings" for t in p.get("tabs") or []):
                        holder = (w.get("id"), p.get("id"), len(p.get("tabs") or []))
        r2 = action(app, "closePane", target=f"pane:{holder[1]}") if holder else None
        time.sleep(2.0)  # harness: close settles
        left = [t for c in tab_counts(app).values() for k, t in c.items() if k == "page:settings"]
        out["settings_pane_close"] = {"workspace": ws, "open_reply": str(r1)[:200], "holder": holder,
                                      "close_reply": str(r2)[:200], "settings_tabs_left": sum(left)}
    except Exception as error:  # noqa: BLE001 - harness
        out["settings_pane_close"] = {"error": str(error)}
    # 3. Daemon restart: no tab releases while the daemon is away.
    try:
        before_tabs = tab_counts(app)
        r = app.rpc("debug.daemon", {"action": "restart"}, timeout=30)
        seen = []
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:  # harness: bounded poll of the daemon state
            d = app.rpc("debug.daemon") or {}
            st = d.get("connection") or d.get("startup")
            seen.append(st)
            mid = tab_counts(app)
            if sum(sum(v.values()) for v in mid.values()) < sum(sum(v.values()) for v in before_tabs.values()):
                seen.append("TAB-LOSS")
            if len(seen) > 4 and st == "connected":
                break
            time.sleep(0.5)  # harness: poll interval
        after_tabs = tab_counts(app)
        out["daemon_restart"] = {"reply": str(r)[:300], "states": seen[:40], "tabs_equal": after_tabs == before_tabs,
                                 "tabs_before": sum(sum(v.values()) for v in before_tabs.values()),
                                 "tabs_after": sum(sum(v.values()) for v in after_tabs.values()),
                                 "daemon": str(app.rpc("debug.daemon"))[:400]}
    except Exception as error:  # noqa: BLE001 - harness
        out["daemon_restart"] = {"error": str(error)}
    # 4. Two windows: key and focus follow a window switch at once (snapshot and CLI).
    try:
        app.rpc("debug.app_activation", {"active": True, "window_notices": True})
        r = action(app, "newWindow")
        time.sleep(3.0)  # harness: the new window mounts
        windows = topo(app).get("windows") or []
        ids = [w.get("id") for w in windows]
        trail = []
        for target in (ids * 2)[:4]:
            fr = app.rpc("debug.window.focus", {"window": target})
            t = topo(app)
            trail.append({"asked": target, "reply": str(fr)[:120], "focus": t.get("focus"),
                          "keys": [(w.get("id"), w.get("isKey"), w.get("key")) for w in t.get("windows") or []]})
        cli = app.cli("list-windows")
        cli2 = app.cli("window", "list") if cli.returncode else None
        close = action(app, "closeWindow")
        time.sleep(2.0)  # harness: close settles
        t = topo(app)
        out["two_windows"] = {"new_reply": str(r)[:200], "window_ids": ids, "trail": trail,
                              "cli": (cli.stdout or cli.stderr)[-800:], "cli2": ((cli2.stdout or cli2.stderr)[-800:] if cli2 else None),
                              "close_reply": str(close)[:200], "after_close": {"focus": t.get("focus"),
                                                                             "windows": [(w.get("id"), w.get("isKey"), w.get("key")) for w in t.get("windows") or []]}}
    except Exception as error:  # noqa: BLE001 - harness
        out["two_windows"] = {"error": str(error)}
    return out


def hover_proxy(app, rounds=20):
    """Round trip of debug.pointer_hover between two sidebar rows (same debug walk on base and head)."""
    rows = []
    for i in range(rounds):
        y = 600 if i % 2 else 560
        t0 = time.monotonic()
        r = app.rpc("debug.pointer_hover", {"point": [120, y]})
        rows.append(round((time.monotonic() - t0) * 1000, 2))
        if i == 0:
            first = str(r)[:300]
    app.rpc("debug.pointer_hover", {"point": None})
    return {"ms": {"p50": act.pct(rows, 0.5), "p95": act.pct(rows, 0.95), "max": max(rows)}, "first_reply": first}


def phase_a():
    app = act.App(os.path.abspath(APP), OUT, 30)
    app.launch()
    pid = app.process.pid
    try:
        emit("cef_light", cef_check(app))
        rows, hangs = act.cycles(app, 20, window_notices=True)
        emit("light_heavy", act.summarize(rows, hangs))
        rows, hangs = act.cycles(app, 20, window_notices=False)
        emit("light_heavy_app_only", act.summarize(rows, hangs))
        emit("light_control_publishes", control_publishes(app))
        emit("light_tab_churn", signposts(app, pid, "light", lambda: tab_churn(app), 40))
        stress = stress_mod.Stress(app.rpc)
        summary = stress.build()
        print("STRESS-SESSION " + json.dumps(summary), flush=True)
        emit("stress_session", summary)
        emit("cef_stress", cef_check(app))
        emit("stress_tabs", tab_counts(app).get(summary.get("measured")))
        rows, hangs = act.cycles(app, 20, window_notices=True, pid=pid, sample_out=os.path.join(OUT, "stress-activation-sample.txt"))
        emit("stress_heavy", act.summarize(rows, hangs))
        rows, hangs = act.cycles(app, 20, window_notices=False)
        emit("stress_heavy_app_only", act.summarize(rows, hangs))
        emit("stress_control_publishes", control_publishes(app))
        action(app, "goToWorkspace", {"workspace": summary.get("measured")})
        time.sleep(1.0)  # harness: the measured workspace shows
        emit("stress_tab_churn", signposts(app, pid, "stress", lambda: tab_churn(app), 45))
        emit("stress_hover", hover_proxy(app))
        emit("behavior", behavior(app, stress))
        measured = summary.get("measured")
        def close_measured():
            r = action(app, "closeWorkspace", target=f"workspace:{measured}", focus=False)
            time.sleep(3.0)  # harness: release work after the close
            return str(r)[:200]
        emit("stress_close_12pane", signposts(app, pid, "close12", close_measured, 12))
        emit("hangs_a", app.rpc("debug.hangs", {"limit": 5}))
    finally:
        app.stop()


def phase_b():
    app = act.App(os.path.abspath(APP), OUT, 30)
    app.launch()
    try:
        class Opts:
            workspaces, browser, hibernate, chats, cycles, max_resyncs = 400, 100, 50, 100, 20, act.MAX_RESYNCS
            out, sample = OUT, True
        report = act.run(app, Opts, pid=app.process.pid)
        report.pop("rows", None)
        emit("ws400", report)
        emit("cef_ws400", cef_check(app))
        emit("ws400_hover", hover_proxy(app))
        emit("ws400_control_publishes", control_publishes(app))
    finally:
        app.stop()


if __name__ == "__main__":
    emit("meta", meta())
    which = sys.argv[1:] or ["a", "b"]
    for phase in which:
        try:
            {"a": phase_a, "b": phase_b}[phase]()
        except BaseException as error:  # noqa: BLE001 - harness: record and go on to the next phase
            emit(f"phase_{phase}_error", repr(error)[:500])
    emit("meta_end", {"load": sh("sysctl", "-n", "vm.loadavg")})
