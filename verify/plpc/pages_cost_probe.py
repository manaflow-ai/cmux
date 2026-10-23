#!/usr/bin/env python3
"""pages-cost probe (PL-pages-cost testing, not product code).

Launches a tagged Debug cmux NEXT app (NX_APP), then:
  1. validity: debug.cef, ~/.config/cmux/web-dev.json, host macOS + refresh rate;
  2. Home idle sample (per-process: renderers, WebContent, main) with full command lines;
  3. behaviors (light): (d) new tab spare adoption, (a) Settings hide 45 s / show with a frame
     recording, (e) a debug-socket page call into a hidden (frozen) Settings page;
  4. STRESS (perf-stress-session.py), 45 s past the freeze grace, then a 30 s sample;
     chat engine check, (b-lite) hide a chat 120 s and show it again;
  5. `log show` for "reopens in WebKit".
Writes $NX_ARTIFACTS/probe.json and prints PROBE lines.
"""
import importlib.util, json, os, re, subprocess, sys, time

SRC = os.environ.get("NX_SRC") or os.getcwd()
OUT = os.environ.get("NX_ARTIFACTS") or "/tmp/plpc-probe"
os.makedirs(OUT, exist_ok=True)
sys.path.insert(0, os.path.join(SRC, "scripts/perf-bench"))
sys.path.insert(0, os.path.join(SRC, "scripts/cmux-next"))
import procs  # noqa: E402

STRESS_PATH = sys.argv[1] if len(sys.argv) > 1 else os.path.join(SRC, "scripts/cmux-next/perf-stress-session.py")
SKIP_STRESS = os.environ.get("PROBE_SKIP_STRESS") == "1"
result = {"t0": time.time()}


def log(line):
    print("PROBE " + line, flush=True)


def save():
    with open(os.path.join(OUT, "probe.json"), "w") as f:
        json.dump(result, f, indent=1, default=str)


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


activation = load(os.path.join(SRC, "scripts/cmux-next/activation-perf.py"), "activation_perf")
stress_mod = load(STRESS_PATH, "perf_stress_session")


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout.strip()


result["host"] = sh("scutil --get ComputerName") or sh("hostname")
result["macos"] = sh("sw_vers -productVersion")
result["refresh"] = re.findall(r"(?:Refresh Rate|Resolution).*", sh("system_profiler SPDisplaysDataType 2>/dev/null"))
result["web_dev_json"] = os.path.exists(os.path.expanduser("~/.config/cmux/web-dev.json"))
result["sha"] = sh(f"git -C '{SRC}' rev-parse HEAD")
log(json.dumps({k: result[k] for k in ("host", "macos", "refresh", "web_dev_json", "sha")}))

app = activation.App(os.environ["NX_APP"], OUT, 50)
app.launch()
rpc = app.rpc
pid = procs.main_pid(os.environ["NX_APP"]) or app.process.pid
inst = procs.Instance(os.environ["NX_APP"], pid)
result["launched_at"] = time.time()


def cef():
    got = rpc("debug.cef") or {}
    keep = {k: got.get(k) for k in ("state", "preloaded", "trigger", "default_engine", "unavailable", "fallback",
                                     "spare_window", "footprint_mb")}
    keep["runtime"] = got.get("runtime")
    return keep


def full_commands():
    table = {p: c for p, _pp, c in procs.process_table()}
    return {p: table.get(p, "") for p in inst.pids()}


def sample(label, seconds=30):
    win = inst.window(seconds, per_pid=True)
    cmds = full_commands()
    mem = inst.memory(per_pid=True)
    mem_by_pid = {row["pid"]: row["footprint_mb"] for row in mem.get("pids", [])}
    rows = []
    for row in win.get("pids", []):
        rows.append({**row, "footprint_mb": mem_by_pid.get(row["pid"]), "command": cmds.get(row["pid"], "")})
    kinds = win["kinds"]
    summary = {
        "label": label, "seconds": win["seconds"], "cpu_pct": win["cpu_pct"], "wakeups_per_s": win["wakeups_per_s"],
        "mb": mem["mb"],
        "renderer": {"n": kinds.get("renderer", {}).get("n", 0),
                     "cpu_pct": round(kinds.get("renderer", {}).get("cpu_pct", 0), 3),
                     "mb": round(mem["kinds"].get("renderer", 0), 1)},
        "webcontent": {"n": kinds.get("webkit-webcontent", {}).get("n", 0),
                       "cpu_pct": round(kinds.get("webkit-webcontent", {}).get("cpu_pct", 0), 3),
                       "mb": round(mem["kinds"].get("webkit-webcontent", 0), 1)},
        "main": {"cpu_pct": round(kinds.get("main", {}).get("cpu_pct", 0), 3),
                 "wakeups_per_s": round(kinds.get("main", {}).get("wakeups_per_s", 0), 2)},
        "kinds": kinds, "mem_kinds": mem["kinds"], "pids": rows,
    }
    log(f"sample {label}: " + json.dumps({k: summary[k] for k in ("cpu_pct", "wakeups_per_s", "mb", "renderer", "webcontent", "main")}))
    for row in rows:
        if row["kind"] in ("renderer", "webkit-webcontent", "gpu"):
            log(f"  {label} {row['kind']} pid={row['pid']} cpu={row['cpu_pct']} wk={row['wakeups_per_s']} mb={row['footprint_mb']} cmd={row['command'][:900]}")
    return summary


def pages_list():
    got = rpc("debug.page", {"action": "list"}) or {}
    return got.get("pages") if isinstance(got, dict) else got


def topology():
    return (rpc("snapshot.get") or {}).get("topology") or {}


def all_tabs():
    out = []
    for w in topology().get("workspaces") or []:
        for s in w.get("screens") or []:
            for p in s.get("panes") or []:
                for t in p.get("tabs") or []:
                    out.append({**t, "_pane": p.get("id"), "_workspace": w.get("id")})
    return out


def action(name, args=None, target=None, focus=True):
    params = {"action": name, "args": args or {}, "focus": focus, "origin": "script"}
    if target:
        params["target"] = target
    t = time.monotonic()
    got = rpc("action.run", params, timeout=60)
    return got, round((time.monotonic() - t) * 1000, 1)


def timed(method, params=None, timeout=30):
    t = time.monotonic()
    got = rpc(method, params or {}, timeout=timeout)
    return got, round((time.monotonic() - t) * 1000, 1)


try:
    time.sleep(30)  # probe: Home settles after launch (as budget.py's home_settle_s)
    result["cef_home"] = cef()
    log("cef home: " + json.dumps(result["cef_home"]))
    result["pages_home"] = pages_list()
    log("pages home: " + json.dumps(result["pages_home"])[:3000])
    result["tabs_home"] = [{k: t.get(k) for k in ("id", "kind", "page", "selected", "title")} for t in all_tabs()]
    log("tabs home: " + json.dumps(result["tabs_home"])[:2000])
    result["home"] = sample("home", 30)
    save()

    # (d) New tab spare adoption right after launch.
    result["new_tab_state_before"], _ = timed("debug.new_tab", {"action": "state"})
    got, ms = timed("debug.new_tab", {"action": "open_and_type", "text": ""})
    result["new_tab_open"] = {"reply": got, "rpc_ms": ms}
    log("new_tab open: " + json.dumps(result["new_tab_open"])[:1500])
    time.sleep(2)  # probe: the opened tab settles

    # (a) Settings: open, hide 45 s (past the 30 s freeze grace), show with a recording.
    got, ms = timed("settings.open", {"focus": True})
    log(f"settings.open {got} {ms} ms")
    time.sleep(5)  # probe: Settings loads and paints
    settings = next((t for t in all_tabs() if "settings" in json.dumps(t).lower() and t.get("kind") == "page"), None)
    result["settings_tab"] = settings
    st, ms = timed("debug.page", {"page": "settings", "action": "state"})
    result["settings_state_shown"] = {"rpc_ms": ms, **({k: st.get(k) for k in ("painted", "in_window", "view_hidden", "url", "instance")} if isinstance(st, dict) else {"raw": st})}
    log("settings shown: " + json.dumps(result["settings_state_shown"]))
    other = next((t for t in all_tabs() if settings and t.get("_pane") == settings.get("_pane") and t.get("id") != settings.get("id")), None)
    if settings and other:
        _, ms_hide = action("tab.focus", target=f"tab:{other['id']}")
        time.sleep(45)  # probe: past browser.freezeHiddenTabs (30 s) so the hidden page is frozen
        result["settings_hidden_sample"] = sample("settings-hidden", 10)
        rec_dir = os.path.join(OUT, "settings-show-frames")
        rpc("debug.window_record", {"dir": rec_dir, "seconds": 2})
        time.sleep(0.25)  # probe: the recorder's first frames land before the switch
        _, ms_show = action("tab.focus", target=f"tab:{settings['id']}")
        t = time.monotonic()
        st, ms = timed("debug.page", {"page": "settings", "action": "state"})
        result["settings_show"] = {"tab_focus_ms": ms_show, "state_rpc_ms": ms, "since_focus_ms": round((time.monotonic() - t) * 1000, 1),
                                   **({k: st.get(k) for k in ("painted", "in_window", "view_hidden", "in_flight")} if isinstance(st, dict) else {"raw": st})}
        log("settings show: " + json.dumps(result["settings_show"]))
        time.sleep(3)  # probe: the recording ends
        try:
            frames = json.load(open(os.path.join(rec_dir, "frames.json")))
            result["settings_frames"] = frames if isinstance(frames, dict) else {"frames": frames}
        except Exception as error:  # the recorder may not have written yet
            result["settings_frames"] = {"error": str(error)}
        # (e) a debug-socket page call into the hidden (frozen) Settings page.
        action("tab.focus", target=f"tab:{other['id']}")
        time.sleep(45)  # probe: frozen again
        st, ms = timed("debug.page", {"page": "settings", "action": "state"})
        result["settings_call_while_hidden"] = {"rpc_ms": ms, **({k: st.get(k) for k in ("painted", "view_hidden", "in_flight", "error")} if isinstance(st, dict) else {"raw": st})}
        log("settings call hidden: " + json.dumps(result["settings_call_while_hidden"]))
        action("tab.focus", target=f"tab:{settings['id']}")
    else:
        result["settings_skip"] = "no Settings tab or no other tab in its pane"
        log("settings: " + result["settings_skip"])
    save()

    if not SKIP_STRESS:
        stress = stress_mod.Stress(rpc, log=lambda line: print(line, flush=True))
        summary = stress.build()
        result["stress_session"] = summary
        print("STRESS-SESSION " + json.dumps(summary), flush=True)
        time.sleep(45)  # probe: past the 30 s freeze grace for every hidden page
        result["cef_stress"] = cef()
        log("cef stress: " + json.dumps(result["cef_stress"]))
        result["stress"] = sample("stress", 30)
        wk, _ = timed("debug.wakeups", {})
        result["stress_wakeups_ledger"] = wk
        save()
        # Chat engine and (b-lite): show one chat, check its engine, hide 120 s, show again.
        chats = [t for t in all_tabs() if t.get("_workspace") == summary.get("measured") and t.get("kind") in ("agent", "chat", "agentChat") or "chat" in str(t.get("kind"))]
        result["chat_tabs"] = len(chats)
        if chats:
            chat = chats[0]
            action("tab.focus", target=f"tab:{chat['id']}")
            time.sleep(3)  # probe: the chat page starts and paints
            eng, ms = timed("debug.agent_pane", {"action": "engine", "pane": chat["_pane"]})
            result["chat_engine"] = {"reply": eng, "rpc_ms": ms}
            log("chat engine: " + json.dumps(result["chat_engine"]))
            others = [w for w in (topology().get("workspaces") or []) if w.get("id") != summary.get("measured")]
            if others:
                action("goToWorkspace", {"workspace": others[0]["id"]})
                time.sleep(120)  # probe: the chat stays hidden for 2 min
                result["chat_hidden_sample"] = sample("chat-hidden", 10)
                t = time.monotonic()
                action("goToWorkspace", {"workspace": summary.get("measured")})
                rd, ms = timed("debug.agent_pane", {"action": "readiness", "pane": chat["_pane"]})
                result["chat_show"] = {"readiness_rpc_ms": ms, "since_switch_ms": round((time.monotonic() - t) * 1000, 1), "reply": rd}
                log("chat show: " + json.dumps(result["chat_show"])[:1500])
        save()
finally:
    try:
        result["reopens_in_webkit"] = sh(f"log show --style compact --start '@{int(result['launched_at'])}' "
                                         "--predicate 'eventMessage CONTAINS \"reopens in WebKit\"' 2>/dev/null | tail -20")
    except Exception as error:
        result["reopens_in_webkit"] = str(error)
    log("reopens in WebKit lines: " + json.dumps(result.get("reopens_in_webkit"))[:1500])
    save()
    app.stop()
