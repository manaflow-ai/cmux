#!/usr/bin/env python3
"""SCRATCH MEASUREMENT (cp/lag-measure, never lands): terminal key to frame in a NEW terminal tab and in the same
terminal after it sat idle, per feature configuration of the chrome-parity dogfood builds (dogfood-3 typing lag).

For each configuration (an app and its feature inputs), interleaved over --rounds launches (fresh saved state each):
  1. the app opens (bench_launch.BenchApp), a terminal workspace is made (newTab) and the app idles --settle s;
  2. per trial (--trials per launch): Ctrl-` (New Terminal Tab, the person's key) makes a terminal; its login shell
     reads $ZDOTDIR/.zshrc (ZDOTDIR given to the app), whose first precmd writes a ready file: the prompt is about to
     show. Typing starts at once: --keys letters, one in flight, every --interval s (`new`);
  3. Ctrl-U, --idle s with no input, then --keys more letters in the same terminal (`warm`); Ctrl-U; Cmd-W.
Key to frame is the typing probe's contents_ms (CMUX_NEXT_TYPING_PROBE): the key's event timestamp (the client's send
time, CLOCK_UPTIME_RAW) to the frame Ghostty hands the layer after the echo is parsed. Keys are debug.key (the
control socket's injected lane, labelled automation) unless --input real (HID tap; needs the input grant).

Feature inputs: the app strips every inherited CMUX_* variable at launch (LaunchIdentity.inheritedKeys), so
CMUX_ENABLE_FEATURES / CMUX_DISABLE_FEATURES in the launch environment reach nothing. A configuration passes them
anyway (to show it) and, on builds with Labs local choices (v2.1), also writes them as local choices
(BenchApp(local_features=...)), which do reach the feature list. Each launch records features.list where the build
has it, and the app log's `ignored inherited` line.

  newterm-typing-bench.py --app APP(v2.1) --tag TAG --out DIR --json FILE --v11-sha256 HEX
      [--configs v11-env,v21-default,v21-off] [--rounds 2] [--trials 5] [--keys 50] [--interval 0.06] [--idle 5]
      [--settle 5] [--stress] [--input debug|real] [--check-env-off]
"""
import argparse, json, os, re, subprocess, sys, tempfile, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hid_input  # noqa: E402
import typing_report  # noqa: E402
from bench_launch import ISOLATED_LAUNCH_KEY, BenchApp, LaunchError  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))

# v1.1's switch set: the launch line of /work/wt/chrome-parity-design/dogfood/features-v1-1.md (53 names).
V11_NAMES = ("agentPageRendererSharing,automationBurstSnap,cefLayerHosting,cefPrefetchBehindFence,cefPumpInputPolicy,"
             "cefTimerSlack,chromiumHostIdleExit,chromiumHostWidgets,chromiumSpareAfterFirstTab,cmuxPageRendererSharing,"
             "coldScrollbackCompression,controlSocketEarlyBind,daemonRequestQos,energySaver,frameRateClasses,"
             "frozenGrowthDiscard,intentPrewarmHover,memoryAgentAndControlCaches,memoryAppCaches,memoryBrowserCaches,"
             "memoryDiscardAgentPagesOverBudget,memoryDiscardConversations,memoryDiscardInternalPages,"
             "memoryDiscardPageTabs,memoryDiscardParkedIdleTimeout,memoryDiscardParkedWorkspaces,memoryDiscardRemoteTabs,"
             "memoryFileHomeCaches,memoryHiddenFrameLRU,memoryImageCaches,memorySaverBackgroundActivity,"
             "memoryTerminalLastFrames,newTabParksHidden,occludedWindowDiscard,overlayTopLayer,pageLifecycle,"
             "pageProcessGroups,pageRendererAtFirstShow,pagesSpareWindow,pointerFrameDrags,pointerFrameHover,"
             "pointerFrameRemoteInput,recentlyAudibleProtection,renderStarvationGuard,rendererlessSpareWindow,"
             "sentryHandlersFirst,sidebarRowsNearViewport,stripPanResampling,taskManagerMemorySaved,terminalGPURelease,"
             "terminalPointerFrames,topPageDiscard,vsyncHub").split(",")


def v21_names():
    """The 104 names of FeatureDogfoodSet.chromeParity at this checkout (699620cc350a)."""
    src = open(os.path.join(ROOT, "Packages/macOS/CmuxNext/Sources/CmuxNextFeatures/FeatureDogfoodSet.swift")).read()
    body = src.split("names: [", 1)[1].split("]", 1)[0]
    return re.findall(r'"([A-Za-z0-9]+)"', body)


parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True, help="the v2.1 app (split-spring.sh's fetched build)")
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--json")
parser.add_argument("--v11-sha256", help="the v1.1 build's app zip (sha256 of the fleet artifact)")
parser.add_argument("--configs", default="v11-env,v21-default,v21-off")
parser.add_argument("--only", help="comma list of feature names for a `v21-only` config: these on, every other "
                    "dogfood switch off (the bisect's arm)")
parser.add_argument("--rounds", type=int, default=2)
parser.add_argument("--trials", type=int, default=5)
parser.add_argument("--keys", type=int, default=50)
parser.add_argument("--interval", type=float, default=0.06)
parser.add_argument("--idle", type=float, default=5.0)
parser.add_argument("--settle", type=float, default=5.0)
parser.add_argument("--stress", action="store_true", help="build the STRESS session (perf-stress-session.py) first")
parser.add_argument("--input", choices=("debug", "real"), default="debug")
parser.add_argument("--check-env-off", action="store_true",
                    help="also launch v2.1 with CMUX_DISABLE_FEATURES only (no local choices) and record features.list")
opts = parser.parse_args()
OUT = os.path.abspath(opts.out)
os.makedirs(OUT, exist_ok=True)
NAMES21 = v21_names()
results = {"opts": vars(opts), "host": os.uname().nodename, "log": [], "launches": [], "v21_names": len(NAMES21),
           "v11_names": len(V11_NAMES), "input": opts.input}
WINDOW = (40, 40, 1400, 900)


def note(text):
    print(text, flush=True)
    results["log"].append(text)


def save():
    if opts.json:
        with open(opts.json, "w") as handle:
            json.dump(results, handle, indent=1)


def fetch_v11():
    if not opts.v11_sha256:
        return None
    run = subprocess.run([sys.executable, os.path.join(HERE, "fleet-app-fetch.py"), "--sha256", opts.v11_sha256,
                          "--dest", os.path.join(OUT, "fleet-apps")], capture_output=True, text=True, timeout=1800)
    note(f"v1.1 fetch: rc={run.returncode} {run.stderr.strip()[-300:]}")
    return run.stdout.strip().splitlines()[-1] if run.returncode == 0 and run.stdout.strip() else None


def configs(v11_app):
    v21 = os.path.abspath(opts.app.rstrip("/"))
    all_off = ",".join(NAMES21)
    table = {
        # As Lawrence launched v1.1 (open --env CMUX_ENABLE_FEATURES=...): v1.1 has no Labs local choices.
        "v11-env": {"app": v11_app, "env": {"CMUX_ENABLE_FEATURES": ",".join(V11_NAMES)}, "local": None},
        # v2.1 double-clicked: the compiled-in dogfood set (tag chrome-parity-*).
        "v21-default": {"app": v21, "env": {}, "local": None},
        # v2.1 with every dogfood switch off: the env (stripped) and the Labs local choices (effective).
        "v21-off": {"app": v21, "env": {"CMUX_DISABLE_FEATURES": all_off}, "local": {n: False for n in NAMES21}},
    }
    if opts.only:
        on = set(opts.only.split(","))
        table["v21-only"] = {"app": v21, "env": {}, "local": {n: (n in on) for n in NAMES21}}
    if opts.check_env_off:
        table["v21-envoff"] = {"app": v21, "env": {"CMUX_DISABLE_FEATURES": all_off}, "local": None, "check_only": True}
    return table


dist = typing_report.distribution


class Session:
    def __init__(self, bench, probe, zdot):
        self.bench, self.probe, self.zdot = bench, probe, zdot
        cli = os.path.join(bench.app, "Contents/Resources/bin/cmux")
        self.control = hid_input.Control(bench.socket, cli, os.path.join(bench.scratch, "cmux.json"))
        self.poster = hid_input.poster_for(opts.input, control=self.control)

    def rpc(self, method, params=None, timeout=30):
        return self.control.rpc(method, params, timeout=timeout)

    def key(self, name, modifiers=()):
        return hid_input.poster_for("debug", control=self.control).key(name, modifiers)

    def rows(self):
        return hid_input.probe_rows(self.probe)

    def focused_kind(self):
        snap = self.rpc("snapshot.get") or {}
        topo = snap.get("topology") or snap
        for w in topo.get("workspaces") or []:
            for sc in w.get("screens") or []:
                for p in sc.get("panes") or []:
                    if p.get("focused"):
                        return p.get("kind"), len(p.get("tabs") or [])
        return None, 0

    def ensure_terminal(self):
        kind, _ = self.focused_kind()
        if kind == "terminal":
            return True
        reply = self.rpc("action.run", {"action": "newTab", "args": {"focus": True, "name": "nt-bench"}, "wait": True},
                         timeout=60)
        note(f"newTab: {json.dumps(reply)[:200]}")
        return bool(hid_input.wait(lambda: self.focused_kind()[0] == "terminal", 30))

    def type_batch(self, count):
        """`count` letters, one in flight; the complete probe rows they made, in key order, and the rpc times."""
        before = self.rows()
        last = max((int(r["index"]) for r in before if r.get("index", "").isdigit()), default=-1)
        trips = []
        for index in range(count):
            t0 = time.perf_counter()
            reply = self.poster.key(hid_input.LETTERS[index % 26])
            trips.append((time.perf_counter() - t0) * 1000)
            if isinstance(reply, dict) and reply.get("error"):
                note(f"key {index}: {str(reply.get('error'))[:160]}")
            rest = opts.interval - (time.perf_counter() - t0)
            if rest > 0:
                time.sleep(rest)  # bench pacing: one key in flight at a time
        time.sleep(0.5)  # bench: the last echo's frame lands before the CSV is read
        new = [r for r in self.rows() if r.get("index", "").isdigit() and int(r["index"]) > last]
        new.sort(key=lambda r: int(r["index"]))
        done = [r for r in new if r.get("complete") == "1" and r.get("contents_ms")]
        return done, new, trips

    def ready_files(self):
        return {f for f in os.listdir(self.zdot) if f.startswith("ready.")}

    def trial(self, number):
        """One new terminal: its first --keys keys, then --keys keys after --idle s idle."""
        seen = self.ready_files()
        self.rpc("debug.hangs", {"clear": True})
        t0 = time.monotonic()
        reply = self.key("`", ("control",))
        created = None
        ready = hid_input.wait(lambda: (self.ready_files() - seen) or None, 10, step=0.002)
        prompt_s = time.monotonic() - t0 if ready else None
        if not ready:
            note(f"trial {number}: no ready file in 10 s (ZDOTDIR not reaching the shell?); typing anyway "
                 f"(debug.key reply {json.dumps(reply)[:160]})")
        kind, tabs = self.focused_kind()
        created = {"kind": kind, "tabs": tabs}
        done_new, all_new, trips_new = self.type_batch(opts.keys)
        hangs_new = self.rpc("debug.hangs", {"limit": 8}, timeout=20)
        self.rpc("action.run", {"action": "terminal.sendText", "args": {"text": "\x15"}, "focus": True, "origin": "script"})
        time.sleep(opts.idle)  # the measured idle: the terminal sits still before the warm keys
        self.rpc("debug.hangs", {"clear": True})
        done_warm, all_warm, trips_warm = self.type_batch(opts.keys)
        hangs_warm = self.rpc("debug.hangs", {"limit": 8}, timeout=20)
        self.rpc("action.run", {"action": "terminal.sendText", "args": {"text": "\x15"}, "focus": True, "origin": "script"})
        self.key("w", ("command",))
        hid_input.wait(lambda: self.focused_kind()[1] < tabs or None, 5)
        time.sleep(0.5)  # bench: the closed tab's pane settles before the next trial
        col = lambda rows, key: [float(r[key]) for r in rows if r.get(key)]
        hang = lambda h: {k: h.get(k) for k in ("count", "max_ms", "total_ms")} if isinstance(h, dict) else h
        return {
            "trial": number, "prompt_s": round(prompt_s, 3) if prompt_s else None, "created": created,
            "new": {"ms": col(done_new, "contents_ms"), "rows": len(all_new), "complete": len(done_new),
                    "dispatch_start_ms": col(done_new, "dispatch_start_ms"), "rpc_ms": [round(t, 2) for t in trips_new],
                    "hangs": hang(hangs_new)},
            "warm": {"ms": col(done_warm, "contents_ms"), "rows": len(all_warm), "complete": len(done_warm),
                     "dispatch_start_ms": col(done_warm, "dispatch_start_ms"), "rpc_ms": [round(t, 2) for t in trips_warm],
                     "hangs": hang(hangs_warm)},
        }


def build_stress(session):
    import importlib.util
    spec = importlib.util.spec_from_file_location("perf_stress_session", os.path.join(HERE, "perf-stress-session.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    stress = module.Stress(session.rpc, log=note)
    summary = stress.build()
    note("STRESS-SESSION " + json.dumps(summary)[:400])
    return summary


def feature_states(snapshot, names):
    if not snapshot:
        return None
    features = snapshot[0] or {}
    states = {}
    for name in names:
        f = features.get(name) or {}
        key = f"{f.get('state')}/{f.get('source')}"
        states[key] = states.get(key, 0) + 1
    return states


def launch(name, cfg, round_index):
    tag_dir = os.path.join(OUT, f"{name}-r{round_index}")
    os.makedirs(tag_dir, exist_ok=True)
    probe = os.path.join(tag_dir, "typing.csv")
    zdot = tempfile.mkdtemp(prefix="nt-zdot-")
    with open(os.path.join(zdot, ".zshrc"), "w") as handle:
        handle.write("PS1='nt%# '\nprecmd() { if [[ -z $NT_READY ]]; then NT_READY=1; : >| \"$ZDOTDIR/ready.$$\"; fi }\n")
    env = {"CMUX_NEXT_TYPING_PROBE": probe, "CMUX_NEXT_HANG_THRESHOLD_MS": "8", "ZDOTDIR": zdot}
    env.update(cfg["env"])
    if opts.input == "real":
        env["CMUX_NEXT_NO_ACTIVATE"] = None
        env[ISOLATED_LAUNCH_KEY] = "1"
    entry = {"config": name, "round": round_index, "app": os.path.basename(cfg["app"]), "env_keys": sorted(cfg["env"]),
             "local_choices": len(cfg["local"] or {}), "trials": []}
    results["launches"].append(entry)
    bench = BenchApp(cfg["app"], out=tag_dir, window=WINDOW, log_name="app.log", env=env,
                     local_features=cfg["local"], perf_session="stress" if opts.stress else "light")
    try:
        try:
            bench.launch(timeout=180)
        except LaunchError as error:
            entry["launch_error"] = error.reason
            note(f"{name} r{round_index}: the app did not come up: {error.reason}")
            return
        snapshot = bench.read_features()
        entry["features_v21"] = feature_states(snapshot, NAMES21)
        entry["features_v11"] = feature_states(snapshot, V11_NAMES)
        try:
            log = open(os.path.join(tag_dir, "app.log"), errors="replace").read()
            entry["ignored_inherited"] = re.findall(r"cmux: ignored inherited ([^\n]*)", log)[:2]
        except OSError:
            entry["ignored_inherited"] = None
        note(f"{name} r{round_index}: features v21 {entry['features_v21']} v11 {entry['features_v11']}; "
             f"ignored inherited {entry['ignored_inherited']}")
        if cfg.get("check_only"):
            return
        session = Session(bench, probe, zdot)
        if opts.stress:
            try:
                entry["stress"] = build_stress(session)
            except Exception as error:  # a STRESS failure is a result, not a crash of the other configs
                entry["stress_error"] = repr(error)[:400]
                note(f"{name} r{round_index}: STRESS build failed: {error!r}")
                return
        if not session.ensure_terminal():
            entry["error"] = "no focused terminal"
            note(f"{name} r{round_index}: no focused terminal")
            return
        if opts.input == "real":
            hid_input.bring_front(bench.process.pid)
        time.sleep(opts.settle)  # the app idles as a person's would before they open a terminal
        for number in range(opts.trials):
            try:
                t = session.trial(number)
            except Exception as error:
                note(f"{name} r{round_index} trial {number}: failed: {error!r}")
                continue
            entry["trials"].append(t)
            n, w = dist(t["new"]["ms"]) or {}, dist(t["warm"]["ms"]) or {}
            note(f"{name} r{round_index} t{number}: prompt {t['prompt_s']} s {t['created']}; new p50 {n.get('p50')} "
                 f"p95 {n.get('p95')} max {n.get('max')} ({t['new']['complete']}/{opts.keys}); warm p50 {w.get('p50')} "
                 f"p95 {w.get('p95')} max {w.get('max')} ({t['warm']['complete']}/{opts.keys})")
            save()
    finally:
        bench.stop()
        save()


def summarize():
    summary = {}
    for name in {e["config"] for e in results["launches"]}:
        launches = [e for e in results["launches"] if e["config"] == name]
        trials = [t for e in launches for t in e.get("trials", [])]
        if not trials:
            continue
        new = [v for t in trials for v in t["new"]["ms"]]
        warm = [v for t in trials for v in t["warm"]["ms"]]
        first10 = [v for t in trials for v in t["new"]["ms"][:10]]
        send = [v for t in trials for v in t["new"]["dispatch_start_ms"]]
        summary[name] = {
            "new": dist(new), "warm": dist(warm), "new_first10": dist(first10),
            "new_send_to_dispatch": dist(send),
            "warm_send_to_dispatch": dist([v for t in trials for v in t["warm"]["dispatch_start_ms"]]),
            "prompt_s": dist([t["prompt_s"] for t in trials if t["prompt_s"]], digits=3),
            "keys_sent": {"new": len(trials) * opts.keys, "warm": len(trials) * opts.keys},
            "hangs_new": sum((t["new"]["hangs"] or {}).get("count") or 0 for t in trials if isinstance(t["new"]["hangs"], dict)),
            "hangs_warm": sum((t["warm"]["hangs"] or {}).get("count") or 0 for t in trials if isinstance(t["warm"]["hangs"], dict)),
            "launches": len(launches),
            "features_v21": [e.get("features_v21") for e in launches],
        }
    results["summary"] = summary
    for name, s in sorted(summary.items()):
        note(f"SUMMARY {name}: new {s['new']} | warm {s['warm']} | first10 {s['new_first10']} | prompt {s['prompt_s']}")


def main():
    results["refresh_hz"] = hid_input.display_refresh()
    results["macos"] = hid_input.macos_version()
    table = configs(fetch_v11() if "v11-env" in opts.configs else None)
    order = [c for c in opts.configs.split(",") if c]
    for c in order:
        if c not in table or not table[c]["app"]:
            sys.exit(f"newterm-typing: config {c} has no app")
    try:
        if opts.check_env_off:
            launch("v21-envoff", table["v21-envoff"], 0)
        for round_index in range(opts.rounds):
            # Interleaved, the order reversed every other round, so host drift weighs on every config alike.
            for name in (order if round_index % 2 == 0 else list(reversed(order))):
                launch(name, table[name], round_index)
    finally:
        summarize()
        save()


if __name__ == "__main__":
    main()
