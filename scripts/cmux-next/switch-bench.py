#!/usr/bin/env python3
"""Switch bench (PL-switch, perf-lead.md issues 4, 7, 12): every switch, input to its committed frame,
in a light session and in STRESS (perf-stress-session.py). Budget: < 10 ms p95 (perf-lead-brief).

Launches a tagged Debug app (no activation, scratch config; activation-perf.py's launcher). Per session:

  ws.terminal.next_prev   Ctrl-Cmd-] / [ between two terminal workspaces   debug.workspace_switch
  ws.chromium.next_prev   the same between two workspaces showing a Chromium page
  ws.chromium_hidden      two terminal workspaces while other workspaces hold Chromium pages (shown before)
  ws.cmd_digit            Cmd-1 / Cmd-2
  tab.terminal / tab.chromium   Ctrl-Tab in a pane of 4 tabs of that kind      debug.tab_switch
  space.next_prev         Opt-Cmd-] / [ between two spaces                    debug.workspace_switch (+ input_commit: shown in the key's turn)
  group.toggle            Ctrl-Cmd-. (collapse / expand the shown workspace's group)  debug.input_commit

Per row: input_to_commit p50/p95 (the event's age at the intent plus intent to the Core Animation commit),
late frames, and `work_before_commit`: main-thread follow-up work (window record saves, trail encodes) that
ran between a switch and its commit. Checks (exit 1 when one fails, --no-gate to report only):

  record_saves_before_commit  0 per switch (a save builds every window's records on the main actor)
  space_switch_in_turn        a space switch shows its workspace in the key's own turn (workspace_shown 1)

Fleet (an owned console mini; the step builds the app):
  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh \\
    --ref SHA --artifact artifacts/split-spring/report.json --arg=--suite=switch-bench [--arg=--sample=ROW]
Usage (a GUI fleet host, never a laptop):
  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \\
    python3 scripts/cmux-next/switch-bench.py --app "$NX_APP" --out "$NX_ARTIFACTS" [--sessions light,stress]
Older builds without `debug.input_commit` or `work_before_commit` leave those columns n/a.
"""
import argparse, importlib.util, json, os, statistics, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="switch-bench-"))
parser.add_argument("--sessions", default="light,stress")
parser.add_argument("--switches", type=int, default=24)
parser.add_argument("--interval", type=float, default=0.25)
parser.add_argument("--budget-ms", type=float, default=10.0)
parser.add_argument("--no-gate", action="store_true")
parser.add_argument("--json", help="also write the report here (the fleet measure step's artifact)")
parser.add_argument("--sample", default="", help="ROW[,...]: also `sample` the app's main thread during those rows (OUT/sample-<session>-<row>.txt)")
opts, _unknown = parser.parse_known_args()  # the fleet entry also passes --tag
os.makedirs(opts.out, exist_ok=True)
activation = load("activation_perf", "activation-perf.py")
stress_mod = load("perf_stress_session", "perf-stress-session.py")
anim = None
if opts.sample:
    import types
    # main_thread_hot only: anim-perf-terminal.py parses its own argv at import, so load the one function.
    source = open(os.path.join(HERE, "anim-perf-terminal.py")).read()
    start = source.index("IDLE = (")
    end = source.index("def budgets():")
    anim = types.ModuleType("anim_hot")
    exec(compile(source[start:end], "anim-perf-terminal.py", "exec"), anim.__dict__)
REPORT = {"app": opts.app, "host": os.uname().nodename, "sessions": {}, "checks": []}


def pct(values, q):
    vals = sorted(v for v in values if isinstance(v, (int, float)))
    if not vals:
        return None
    k = (len(vals) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(vals) - 1)
    return round(vals[lo] + (vals[hi] - vals[lo]) * (k - lo), 2)


class Bench:
    def __init__(self, app):
        self.app, self.rpc = app, app.rpc
        self.stress = stress_mod.Stress(app.rpc, log=lambda line: print(line, flush=True))

    def action(self, name, args=None, target=None, settle=0.0):
        return self.stress.action(name, args, target=target, settle=settle)

    def key(self, key, mods):
        return self.rpc("debug.key", {"key": key, "modifiers": mods})

    def focused(self):
        return self.stress.focused_workspace()

    def new_workspace(self, kind="terminal", pages=1):
        ws = self.stress.new_workspace()
        if ws and kind != "terminal":
            pane = (self.stress.panes(self.stress.workspace(ws)) or [{}])[0].get("id")
            for _ in range(pages):
                self.stress.add_tab(ws, pane, kind)
        return ws

    def time(self, method, step, count, label, also=None):
        """`count` inputs (`step(i)`), timed by `method`'s timer; the row's numbers. `also`: a second timer
        recorded over the same inputs, its rows under `also_rows` (a space switch: debug.input_commit)."""
        hot = self.sampled(step, count, label) if label in opts.sample.split(",") else None
        self.rpc("debug.frames", {"action": "start"})  # the display link ticks, so commits map to vsyncs
        if also:
            self.rpc(also, {"action": "start"})
        probe = self.rpc(method, {"action": "start"})
        if not isinstance(probe, dict) or "recording" not in probe:
            self.rpc("debug.frames", {"action": "stop"})
            return {"label": label, "error": f"{method} unavailable"}
        for index in range(count):
            step(index)
            time.sleep(opts.interval)  # bench pacing: one input per interval, its commit lands meanwhile
        time.sleep(0.5)  # bench: the last commit lands
        reply = self.rpc(method, {"action": "stop"}) or {}
        also_rows = ((self.rpc(also, {"action": "stop"}) or {}).get("inputs") or []) if also else []
        self.rpc("debug.frames", {"action": "stop"})
        rows = reply.get("switches") or reply.get("inputs") or reply.get("moves") or []
        e2e = [r.get("input_ms", 0) + r["commit_ms"] for r in rows if isinstance(r.get("commit_ms"), (int, float))]
        apply = [r.get("apply_ms") for r in rows]
        late = [r.get("late_vsyncs", 0) for r in rows]
        out = {"label": label, "n": len(rows), "asked": count, "input_to_commit_p50": pct(e2e, 0.5),
               "input_to_commit_p95": pct(e2e, 0.95), "input_to_commit_max": max(e2e) if e2e else None,
               "apply_p50": pct(apply, 0.5), "apply_p95": pct(apply, 0.95), "late_switches": sum(1 for v in late if v),
               "refresh_ms": rows[0].get("refresh_ms") if rows else None,
               "work_before_commit": reply.get("work_before_commit"),
               "workspace_shown": [r.get("workspace_shown") for r in rows + also_rows if "workspace_shown" in r] or None}
        stages = {}
        for stage in ("input", "park", "content", "sidebar", "root", "theme", "did_show", "focus", "strip", "withdraw", "reveal",
                      "stripSync", "view", "present", "record"):
            vals = [r[stage + "_ms"] for r in rows if isinstance(r.get(stage + "_ms"), (int, float))]
            if vals:
                stages[stage] = pct(vals, 0.95)
        out["stages_p95"] = stages
        if hot:
            out["sample_hot"] = hot
        print(f"  {label:<22} n={out['n']:<3} commit p50/p95 {out['input_to_commit_p50']}/{out['input_to_commit_p95']} ms "
              f"apply p95 {out['apply_p95']} late {out['late_switches']} refresh {out['refresh_ms']} "
              f"work {out['work_before_commit']} stages {stages}", flush=True)
        return out

    def sampled(self, step, count, label):
        """A separate pass of the row under /usr/bin/sample (1 ms), so the sampler stays out of the timed numbers."""
        path = os.path.join(opts.out, f"sample-{self.session}-{label}.txt")
        seconds = max(3, int(count * opts.interval) + 2)
        sampler = subprocess.Popen(["/usr/bin/sample", str(self.app.process.pid), str(seconds), "1", "-mayDie", "-file", path],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.8)  # bench: the sampler attaches
        for index in range(count):
            step(index)
            time.sleep(opts.interval)  # bench pacing, as the timed pass
        try:
            sampler.wait(timeout=seconds + 90)
        except subprocess.TimeoutExpired:
            sampler.terminate()
        try:
            text = open(path, errors="replace").read()
            hot = anim.main_thread_hot(text, limit=60) + ["-- main-thread call tree, nodes of >= 3 samples (WindowServer waits included) --"]
            hot += main_tree(text)
        except OSError:
            hot = ["(no sample)"]
        print(f"== sample {self.session} {label}: {path}", *hot, sep="\n", flush=True)
        return hot

    def pair_switch(self, a, b, label, how="next_prev"):
        """Alternates a <-> b; `a` and `b` must be adjacent in the sidebar (b right after a) for next/prev."""
        self.action("goToWorkspace", {"workspace": a}, settle=0.6)
        if how == "next_prev":
            step = lambda i: self.key("]" if i % 2 == 0 else "[", ["control", "command"])  # noqa: E731
        else:
            step = lambda i: self.key("2" if i % 2 == 0 else "1", ["command"])  # noqa: E731
        return self.time("debug.workspace_switch", step, opts.switches, label)

    def to_top(self, ids):
        """Moves `ids` to the top of the sidebar in this order (Cmd-1 is ids[0])."""
        for ws in reversed(ids):
            self.action("palette.moveWorkspaceToTop", target={"kind": "workspace", "id": ws}, settle=0.3)

    def tabs_pane(self, kind, count=4):
        ws = self.stress.new_workspace()
        pane = (self.stress.panes(self.stress.workspace(ws)) or [{}])[0].get("id")
        for _ in range(count - 1):
            self.stress.add_tab(ws, pane, "terminal" if kind == "terminal" else kind)
        time.sleep(1.0)  # bench: pages load
        for _ in range(count):  # warm: every tab once
            self.key("tab", ["control"])
            time.sleep(0.3)  # bench pacing: warm visit
        return ws

    def run(self, session):
        self.session = session
        rows = {}
        term_a, term_b = self.new_workspace(), self.new_workspace()
        chrome_a, chrome_b = self.new_workspace("chromium"), self.new_workspace("chromium")
        time.sleep(2.0)  # bench: pages load
        self.to_top([term_a, term_b])
        rows["ws.terminal.next_prev"] = self.pair_switch(term_a, term_b, "ws.terminal.next_prev")
        rows["ws.cmd_digit"] = self.pair_switch(term_a, term_b, "ws.cmd_digit", how="digit")
        # Chromium pages present in other workspaces, shown once (mounted, parked), not in the switched pair.
        rows["ws.chromium_hidden"] = self.pair_switch(term_a, term_b, "ws.chromium_hidden")
        self.to_top([chrome_a, chrome_b])
        rows["ws.chromium.next_prev"] = self.pair_switch(chrome_a, chrome_b, "ws.chromium.next_prev")
        for kind in ("terminal", "chromium"):
            self.tabs_pane(kind)
            rows[f"tab.{kind}"] = self.time("debug.tab_switch", lambda i: self.key("tab", ["control"]), opts.switches, f"tab.{kind}")
        rows["space.next_prev"] = self.spaces()
        rows["group.toggle"] = self.group()
        return rows

    def spaces(self):
        """Two spaces, each with a workspace; Opt-Cmd-] / [ between them, timed per key."""
        before = len((self.rpc("snapshot.get") or {}).get("profiles") or [])
        self.action("space.new", {"name": "bench space"}, settle=2.5)
        if not self.focused():
            return {"label": "space.next_prev", "error": "no workspace after space.new"}
        self.action("space.previous", settle=1.0)
        step = lambda i: self.key("]" if i % 2 == 0 else "[", ["option", "command"])  # noqa: E731
        row = self.time("debug.workspace_switch", step, opts.switches, "space.next_prev", also="debug.input_commit")
        row["spaces_before"] = before
        return row

    def group(self):
        ws = self.focused()
        self.action("workspace.newInNewGroup", settle=1.2)
        self.action("workspace.newBelow", settle=1.0)
        step = lambda i: self.key(".", ["control", "command"])  # noqa: E731
        row = self.time("debug.input_commit", step, opts.switches, "group.toggle")
        if ws:
            self.action("goToWorkspace", {"workspace": ws}, settle=0.5)
        return row


def main_tree(text, minimum=3, limit=700):
    """The sample's main-thread call tree, nodes of at least `minimum` samples (1 ms each), idle
    run-loop waits left out but synchronous WindowServer round trips (mach_msg under AppKit) kept:
    window ordering on a switch is a wait for WindowServer, which main_thread_hot counts as idle."""
    import re
    graph = text.split("Call graph:", 1)
    if len(graph) < 2:
        return ["(no call graph)"]
    lines = graph[1].splitlines()
    start = next((i for i, l in enumerate(lines) if "com.apple.main-thread" in l), None)
    if start is None:
        return ["(no main thread)"]
    node = re.compile(r"^([ +!:|]*)(\d+) (.*)$")
    base = len(node.match(lines[start]).group(1))
    out, skip = [], None
    for line in lines[start + 1:]:
        m = node.match(line)
        if not m:
            continue
        depth = len(m.group(1))
        if depth <= base:
            break
        if skip is not None and depth > skip:
            continue  # inside an idle run-loop wait
        skip = depth if "__CFRunLoopServiceMachPort" in m.group(3) else None
        if skip is not None or int(m.group(2)) < minimum:
            continue
        out.append(line.rstrip()[:220])
        if len(out) >= limit:
            break
    return out


def check(name, ok, detail):
    REPORT["checks"].append({"check": name, "ok": ok, "detail": detail})
    print(f"{'PASS' if ok else 'FAIL'} | {name} | {detail}", flush=True)


def main():
    app = activation.App(os.path.abspath(opts.app.rstrip("/")), opts.out, 50)
    app.launch()
    try:
        bench = Bench(app)
        cef = app.rpc("debug.cef") or {}
        REPORT["cef"] = {k: cef.get(k) for k in ("state", "unavailable", "fallback", "available") if k in cef}
        for session in [s for s in opts.sessions.split(",") if s]:
            print(f"== session {session}", flush=True)
            if session == "stress":
                summary = bench.stress.build()
                print("STRESS-SESSION " + json.dumps(summary), flush=True)
                REPORT["stress_session"] = summary
            REPORT["sessions"][session] = bench.run(session)
            with open(os.path.join(opts.out, "switch-bench.json"), "w") as f:
                json.dump(REPORT, f, indent=1)
    finally:
        app.stop()
    for session, rows in REPORT["sessions"].items():
        for name, row in rows.items():
            work = (row or {}).get("work_before_commit")
            if isinstance(work, dict) and name.startswith(("ws.", "tab.", "space.")):
                saves = int(work.get("record_saves", 0))
                check(f"{session} {name} record_saves_before_commit", saves == 0, f"{saves} saves over {row.get('n')} switches")
        shown = (rows.get("space.next_prev") or {}).get("workspace_shown")
        if shown is not None:
            check(f"{session} space_switch_in_turn", bool(shown) and min(shown) >= 1, f"workspace_shown per key {shown}")
        print(f"\n# {session}: input to commit (ms, p50/p95; budget p95 {opts.budget_ms})")
        for name, row in rows.items():
            print(f"| {name} | {row.get('input_to_commit_p50')} | {row.get('input_to_commit_p95')} | late {row.get('late_switches')} "
                  f"| refresh {row.get('refresh_ms')} | {row.get('error') or ''} |")
    for path in [os.path.join(opts.out, "switch-bench.json")] + ([opts.json] if opts.json else []):
        with open(path, "w") as f:
            json.dump(REPORT, f, indent=1)
    failed = [c for c in REPORT["checks"] if not c["ok"]]
    print(f"\nSWITCH-BENCH checks {len(REPORT['checks']) - len(failed)}/{len(REPORT['checks'])} pass")
    sys.exit(1 if failed and not opts.no_gate else 0)


if __name__ == "__main__":
    main()
