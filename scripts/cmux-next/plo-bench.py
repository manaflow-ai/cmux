#!/usr/bin/env python3
"""pl-o-all batch bench (test harness only; not part of the branch).

Runs on a fleet GUI host inside an nx-remote --app-from-fleet job:
  python3 plo_bench.py --app "$NX_APP" --out "$NX_ARTIFACTS" --src "$NX_SRC" [--sections ...]
LIGHT then STRESS (scripts/cmux-next/perf-stress-session.py Stress(rpc).build()):
  cmdtab      activation cycles heavy (window_notices) and app-only: observers_ms, drain_ms
  publishes   debug.timings control_publishes per Cmd-Tab pair (and a no-activation control)
  tablist     20 Cmd-T + 20 Cmd-W (debug.key) under a signpost stream: action.perform/commit
  hover       debug.pointer_hover round trips over the sidebar
  spot        daemon restart, settings tab in a closed pane, two windows key/focus, close measured workspace
"""
import argparse, importlib.util, json, os, signal, socket, subprocess, sys, time, traceback


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def pct(values, q):
    values = sorted(v for v in values if isinstance(v, (int, float)))
    return round(values[min(len(values) - 1, int(len(values) * q))], 3) if values else None


def stat(values):
    return {"n": len([v for v in values if isinstance(v, (int, float))]), "p50": pct(values, 0.5), "p95": pct(values, 0.95),
            "max": round(max([v for v in values if isinstance(v, (int, float))]), 3) if values else None}


class Bench:
    def __init__(self, opts):
        self.opts = opts
        here = os.path.join(opts.src, "scripts/cmux-next")
        sys.path.insert(0, here)
        self.act = load(os.path.join(here, "activation-perf.py"), "activation_perf")
        self.stress_mod = load(os.path.join(here, "perf-stress-session.py"), "perf_stress_session")
        self.sp = load(os.path.join(here, "perf-signposts.py"), "perf_signposts")
        self.report = {"sections": {}}

    def log(self, *parts):
        print("plo-bench:", *parts, flush=True)

    def section(self, phase, name, fn):
        key = f"{phase}.{name}"
        try:
            t0 = time.monotonic()
            value = fn()
            if isinstance(value, dict):
                value["secs"] = round(time.monotonic() - t0, 1)
            self.report["sections"][key] = value
            self.log(key, json.dumps(value)[:1500])
        except Exception as error:  # a broken section must not hide the others
            self.report["sections"][key] = {"error": f"{type(error).__name__}: {error}", "trace": traceback.format_exc()[-1500:]}
            self.log(key, "ERROR", error)
        self.save()

    def save(self):
        with open(os.path.join(self.opts.out, "plo-bench.json"), "w") as f:
            json.dump(self.report, f, indent=1)

    # --- environment -------------------------------------------------------------------------
    def host_facts(self):
        def sh(*argv):
            try:
                return subprocess.run(argv, capture_output=True, text=True, timeout=60).stdout.strip()
            except Exception as error:
                return f"error {error}"
        displays = sh("system_profiler", "SPDisplaysDataType")
        refresh = [line.strip() for line in displays.splitlines() if "Resolution" in line or "Refresh" in line or "UI Looks like" in line]
        sha = sh("git", "-C", self.opts.src, "rev-parse", "HEAD")
        return {"host": sh("hostname"), "macos": sh("sw_vers", "-productVersion"), "build": sh("sw_vers", "-buildVersion"),
                "displays": refresh, "src_sha": sha, "app": self.opts.app,
                "web_dev_json": os.path.exists(os.path.expanduser("~/.config/cmux/web-dev.json"))}

    def validity(self):
        cef = self.rpc("debug.cef") or {}
        text = json.dumps(cef)
        topo = self.topology()
        kinds = {}
        for w in topo.get("workspaces") or []:
            for s in w.get("screens") or []:
                for p in s.get("panes") or []:
                    for t in p.get("tabs") or []:
                        k = t.get("kind") or "?"
                        if k == "page":
                            k = f"page:{t.get('page')}"
                        kinds[k] = kinds.get(k, 0) + 1
        config = {}
        try:
            with open(self.app.config) as f:
                config = json.load(f)
        except Exception:
            pass
        return {"cef_unavailable": "unavailable" in text, "cef_fallback": "fallback" in text,
                "cef_report": text[:1200], "tab_kinds": kinds,
                "web_dev_json": os.path.exists(os.path.expanduser("~/.config/cmux/web-dev.json")),
                "site_engines_in_config": "siteEngines" in json.dumps(config)}

    # --- helpers -------------------------------------------------------------------------------
    def rpc(self, method, params=None, timeout=60):
        return self.app.rpc(method, params or {}, timeout=timeout)

    def topology(self):
        return (self.rpc("snapshot.get") or {}).get("topology") or {}

    def tab_ids(self, workspace=None):
        ids = set()
        for w in self.topology().get("workspaces") or []:
            if workspace and w.get("id") != workspace:
                continue
            for s in w.get("screens") or []:
                for p in s.get("panes") or []:
                    for t in p.get("tabs") or []:
                        if t.get("id"):
                            ids.add(t["id"])
        return ids

    def rss_kb(self):
        try:
            return int(subprocess.run(["ps", "-o", "rss=", "-p", str(self.app.process.pid)], capture_output=True, text=True).stdout.strip())
        except Exception:
            return None

    def signposts(self, scenario, category=("action",)):
        predicate = f'subsystem == "{self.sp.SUBSYSTEM}" AND category IN {{' + ", ".join(f'"{c}"' for c in category) + "}"
        log = subprocess.Popen(["/usr/bin/log", "stream", "--signpost", "--style", "ndjson", "--predicate", predicate,
                                "--process", str(self.app.process.pid)], stdout=subprocess.PIPE, text=True)
        lines = [log.stdout.readline()]
        try:
            extra = scenario()
        finally:
            time.sleep(1.0)  # test script: the last commit's end event reaches the log stream
            log.send_signal(signal.SIGINT)
            rest, _ = log.communicate(timeout=20)
            lines.extend(rest.splitlines())
        intervals = self.sp.pair(lines)
        rows = self.sp.summarize(intervals)
        return {"rows": [r for r in rows if r["detail"] != "*" or r["name"].startswith("action")], "intervals": len(intervals),
                "scenario": extra}

    # --- sections ------------------------------------------------------------------------------
    def cmdtab(self, cycles=20, sample=False):
        out = {}
        rows, hangs = self.act.cycles(self.app, cycles, window_notices=False)
        out["heavy_app_only"] = self.act.summarize(rows, hangs)
        sample_out = os.path.join(self.opts.out, f"sample-{self.phase}.txt") if sample else None
        rows, hangs = self.act.cycles(self.app, cycles, pid=self.app.process.pid, sample_out=sample_out, window_notices=True)
        out["heavy"] = self.act.summarize(rows, hangs)
        return out

    def publishes(self, pairs=10):
        def run(activate):
            counts, ms = [], []
            for _ in range(pairs):
                if activate:
                    self.rpc("debug.app_activation", {"active": False, "window_notices": True})
                    time.sleep(0.4)  # test script: the app sits in the background between Cmd-Tabs
                self.rpc("debug.timings", {"clear": True})
                if activate:
                    self.rpc("debug.app_activation", {"active": True, "window_notices": True})
                time.sleep(0.6)  # test script: after-frame and held publishes land before the read
                pubs = (self.rpc("debug.timings") or {}).get("control_publishes") or []
                counts.append(len(pubs))
                ms.extend(p.get("ms") for p in pubs)
            return {"publishes_per_window": counts, "publish_ms": stat(ms)}
        return {"become_with_window_notices": run(True), "no_activation_control": run(False)}

    def tablist(self, n=20):
        def scenario():
            before = len(self.tab_ids())
            replies = []
            for _ in range(n):
                replies.append(self.rpc("debug.key", {"key": "t", "modifiers": ["command"]}))
                time.sleep(0.3)  # test script: one Cmd-T per 300 ms, as a person types it
            mid = len(self.tab_ids())
            for _ in range(n):
                replies.append(self.rpc("debug.key", {"key": "w", "modifiers": ["command"]}))
                time.sleep(0.3)  # test script: one Cmd-W per 300 ms
            after = len(self.tab_ids())
            errors = sorted({json.dumps(r)[:200] for r in replies if isinstance(r, dict) and r.get("error")})
            return {"tabs_before": before, "tabs_after_new": mid, "tabs_after_close": after, "errors": errors[:5],
                    "sample_reply": json.dumps(replies[0])[:300] if replies else None}
        return self.signposts(scenario)

    def hover(self, moves=20):
        times = []
        replies = []
        for i in range(moves):
            point = [120, 200 + (i % 2) * 120]
            t0 = time.monotonic()
            reply = self.rpc("debug.pointer_hover", {"point": point})
            times.append((time.monotonic() - t0) * 1000)
            replies.append(reply)
            time.sleep(0.2)  # test script: one pointer move per 200 ms
        self.rpc("debug.pointer_hover", {"point": None})
        return {"round_trip_ms": stat(times), "sample_reply": json.dumps(replies[-1])[:400]}

    def spot_daemon(self):
        before_tabs = self.tab_ids()
        before = self.rpc("debug.daemon") or {}
        self.rpc("debug.daemon", {"action": "restart"})
        seen, min_tabs, states = [], len(before_tabs), []
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:  # bounded poll of the app's daemon state in a test script
            state = self.rpc("debug.daemon") or {}
            ids = self.tab_ids()
            min_tabs = min(min_tabs, len(ids))
            states.append(state.get("connection"))
            if state.get("pid") and state.get("pid") != before.get("pid") and state.get("connection") == "connected":
                break
            time.sleep(0.25)  # test script: the poll interval
        time.sleep(2.0)  # test script: the reconnected daemon's first topology lands
        after_tabs = self.tab_ids()
        return {"pid_before": before.get("pid"), "pid_after": (self.rpc("debug.daemon") or {}).get("pid"),
                "states_seen": sorted({s for s in states if s}), "tabs_before": len(before_tabs),
                "min_tabs_while_away": min_tabs, "tabs_after": len(after_tabs),
                "tabs_lost": sorted(before_tabs - after_tabs)[:10]}

    def action(self, name, args=None, target=None, timeout=120):
        params = {"action": name, "args": args or {}, "focus": True, "origin": "script"}
        if target:
            params["target"] = target
        return self.rpc("action.run", params, timeout=timeout)

    def spot_settings_pane(self):
        topo = self.topology()
        focus = topo.get("focus") or {}
        ws = (focus.get("workspace") if isinstance(focus.get("workspace"), str) else None)
        before = self.tab_ids()
        r_split = self.action("splitRight")
        time.sleep(1.0)  # test script: the split lands
        r_open = self.action("openSettings")
        time.sleep(1.5)  # test script: the settings tab opens
        mid = self.tab_ids()
        new = mid - before
        topo = self.topology()
        pane = (topo.get("focus") or {}).get("pane")
        settings_tabs = []
        for w in topo.get("workspaces") or []:
            for s in w.get("screens") or []:
                for p in s.get("panes") or []:
                    for t in p.get("tabs") or []:
                        if t.get("id") in new:
                            settings_tabs.append({"id": t.get("id"), "kind": t.get("kind"), "page": t.get("page"), "pane": p.get("id")})
        r_close = self.action("closePane", target={"kind": "pane", "id": pane} if pane else None)
        time.sleep(1.5)  # test script: the pane closes
        after = self.tab_ids()
        return {"split": json.dumps(r_split)[:200], "open": json.dumps(r_open)[:200], "close": json.dumps(r_close)[:200],
                "new_tabs": settings_tabs, "closed_pane": pane, "new_tabs_left_after_close": sorted(new & after),
                "other_tabs_lost": sorted((before - after))[:10]}

    def spot_windows(self):
        r_new = self.action("newWindow")
        time.sleep(2.0)  # test script: the second window opens
        topo = self.topology()
        windows = [w.get("key") for w in topo.get("windows") or []]
        rows = []
        for i in range(6):
            target = windows[i % len(windows)] if windows else None
            if not target:
                break
            t0 = time.monotonic()
            reply = self.rpc("debug.window.focus", {"window": target}) or {}
            topo = self.topology()
            dt = (time.monotonic() - t0) * 1000
            key_windows = [w.get("key") for w in topo.get("windows") or [] if w.get("key_window")]
            focus_window = (topo.get("focus") or {}).get("window")
            ids = {w.get("key"): w.get("id") for w in topo.get("windows") or []}
            rows.append({"asked": target, "app_key": reply.get("key"), "snapshot_key_windows": key_windows,
                         "focus_window": focus_window, "focus_matches": focus_window == ids.get(reply.get("key")) if reply.get("key") else None,
                         "ms": round(dt, 1)})
        cli = None
        try:
            cli = self.app.cli("list-windows").stdout[:600]
        except Exception as error:
            cli = f"error {error}"
        # close the second window again (Cmd-Shift-W is not universal: the closeWindow action on it)
        second = windows[-1] if len(windows) > 1 else None
        r_close = self.action("closeWindow", target={"kind": "window", "id": second}) if second else None
        time.sleep(1.0)  # test script: the window closes
        topo = self.topology()
        return {"new": json.dumps(r_new)[:200], "windows": windows, "rows": rows, "cli_list_windows": cli,
                "close": json.dumps(r_close)[:200], "windows_after_close": len(topo.get("windows") or []),
                "focus_after_close": topo.get("focus")}

    def spot_close_workspace(self, workspace):
        before_all = self.tab_ids()
        mine = self.tab_ids(workspace)
        counters_before = self.rpc("debug.layout_counters") or {}
        rss_before = self.rss_kb()
        reply_box = {}

        def scenario():
            t0 = time.monotonic()
            reply_box["reply"] = self.action("closeWorkspace", target={"kind": "workspace", "id": workspace})
            reply_box["rtt_ms"] = round((time.monotonic() - t0) * 1000, 1)
            time.sleep(3.0)  # test script: terminals and pages release
            return {}
        sig = self.signposts(scenario)
        after_all = self.tab_ids()
        counters_after = self.rpc("debug.layout_counters") or {}
        return {"reply": json.dumps(reply_box.get("reply"))[:300], "rtt_ms": reply_box.get("rtt_ms"),
                "tabs_in_workspace": len(mine), "tabs_before": len(before_all), "tabs_after": len(after_all),
                "workspace_tabs_left": len(mine & after_all), "other_tabs_lost": len((before_all - mine) - after_all),
                "rss_kb_before": rss_before, "rss_kb_after": self.rss_kb(),
                "counters_before": json.dumps(counters_before)[:600], "counters_after": json.dumps(counters_after)[:600],
                "signposts": sig}

    # --- run -----------------------------------------------------------------------------------
    def run(self):
        opts = self.opts
        self.report["host"] = self.host_facts()
        self.log("host", json.dumps(self.report["host"]))
        self.app = self.act.App(os.path.abspath(opts.app), opts.out, opts.hang_ms)
        try:
            self.app.launch()
            time.sleep(3.0)  # test script: the first workspace's terminal settles before LIGHT
            self.phase = "light"
            self.section("light", "validity", self.validity)
            self.section("light", "cmdtab", lambda: self.cmdtab(opts.cycles))
            self.section("light", "publishes", self.publishes)
            self.section("light", "tablist", self.tablist)
            self.section("light", "hover", self.hover)
            # STRESS
            self.phase = "stress"
            stress = self.stress_mod.Stress(self.app.rpc)
            summary = stress.build()
            self.report["stress_session"] = summary
            print("STRESS-SESSION " + json.dumps(summary), flush=True)
            self.save()
            self.section("stress", "validity", self.validity)
            self.section("stress", "cmdtab", lambda: self.cmdtab(opts.cycles, sample=True))
            self.section("stress", "publishes", self.publishes)
            self.section("stress", "tablist", self.tablist)
            self.section("stress", "hover", self.hover)
            self.section("stress", "spot_daemon", self.spot_daemon)
            self.section("stress", "spot_settings_pane", self.spot_settings_pane)
            self.section("stress", "spot_windows", self.spot_windows)
            measured = summary.get("measured")
            if measured:
                self.section("stress", "spot_close_workspace", lambda: self.spot_close_workspace(measured))
        finally:
            self.save()
            self.app.stop()
            self.save()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--src", required=True)
    parser.add_argument("--cycles", type=int, default=20)
    parser.add_argument("--hang-ms", type=int, default=30)
    opts = parser.parse_args()
    os.makedirs(opts.out, exist_ok=True)
    Bench(opts).run()


if __name__ == "__main__":
    main()
