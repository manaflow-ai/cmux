#!/usr/bin/env python3
"""App activation (Cmd-Tab back to cmux) in a heavy session: work and time (user msg 9674/9682).

Builds a session like a person's long-running app: --workspaces workspaces, --browser Chromium
tabs (--hibernate of them hibernated), --chats chat tabs (New Tab page / agent pane), spread over
the workspaces, then the first workspace shown. Then --cycles times: the app resigns and becomes
active again through `debug.app_activation` (the app's real activation observers run; the window
never takes the display), with `window_notices` (the main window's resign/become key and main, as a
real Cmd-Tab posts). Per activation:

  observers_ms   main-thread time the become notices took to deliver (the app times it)
  drain_ms       the next socket round trip through the main actor (work the observers queued)
  resyncs        status indicators the activation touched (`indicator_resyncs`); budget: the
                 indicators a window can show (--max-resyncs), never every row and tab of the session
  hangs          main-thread stalls over --hang-ms during the cycles (debug.hangs)

With --sample the script also samples the app's main thread during the cycles (`sample`, the
call graph lands in OUT/activation-sample.txt).

Run on a GUI fleet host, never a laptop:
  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \\
    python3 scripts/cmux-next/activation-perf.py --app "$NX_APP" --out "$NX_ARTIFACTS" --sample
perf-gate.py runs it as its `activation` scenario. Exit 1 when a blocking budget breaks (--gate).
Older builds without the counter or the reply timing still report the round-trip times.
"""
import argparse, json, os, socket, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

MAX_RESYNCS = 64  # a 1440x900 window shows at most ~40 sidebar rows and ~20 strip tabs


def pct(values, q):
    values = sorted(values)
    return values[min(len(values) - 1, int(len(values) * q))] if values else None


def wait(predicate, seconds, step=0.25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded poll of the app's socket state in a test script
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test script: the poll interval
    return None


class Session:
    """Builds the heavy session through any app object with rpc(method, params, timeout) and cli(*args)."""

    def __init__(self, app, scratch):
        self.app, self.scratch = app, scratch

    def action(self, name, args=None, target=None, timeout=120):
        params = {"action": name, "args": args or {}, "focus": True, "origin": "script"}
        if target:
            params["target"] = target
        return self.app.rpc("action.run", params, timeout=timeout)

    def topology(self):
        return (self.app.rpc("snapshot.get") or {}).get("topology") or {}

    def workspace_ids(self):
        return [w.get("id") for w in self.topology().get("workspaces") or [] if w.get("id")]

    def shown(self):
        return (self.topology().get("focus") or {}).get("workspace")

    def tabs_of(self, workspace):
        for w in self.topology().get("workspaces") or []:
            if w.get("id") == workspace:
                return [t.get("id") for s in w.get("screens") or [] for p in s.get("panes") or []
                        for t in p.get("tabs") or [] if t.get("id")]
        return []

    def page(self, index):
        path = os.path.join(self.scratch, f"page-{index}.html")
        with open(path, "w") as f:
            f.write(f"<!doctype html><title>page {index}</title><body style='font:20px -apple-system'>"
                    + f"<p>activation page {index}</p>" * 30)
        return "file://" + path

    def build(self, workspaces, browser, chats, hibernate):
        start = time.monotonic()
        have = len(self.workspace_ids())
        for i in range(max(0, workspaces - have)):
            self.app.cli("workspace", "create", "--name", f"act {i}")
        ids = wait(lambda: (lambda w: w if len(w) >= workspaces else None)(self.workspace_ids()), 120) or self.workspace_ids()
        first = ids[0]
        # Tabs go into the workspaces after the first, two per workspace: the first stays the shown one.
        hosts = ids[1:] or ids
        plan = ["chromium"] * browser + ["chat"] * chats
        made = {"chromium": [], "chat": []}
        for index, kind in enumerate(plan):
            workspace = hosts[(index // 2) % len(hosts)]
            if self.shown() != workspace:
                self.action("goToWorkspace", {"workspace": workspace})
            before = set(self.tabs_of(workspace))
            if kind == "chromium":
                self.action("openBrowser.chromium", {"url": self.page(index)})
            else:
                self.action("newTab.page")
            new = wait(lambda: [t for t in self.tabs_of(workspace) if t not in before], 20) or []
            made[kind] += new[:1]
        hibernated, refused = 0, None
        for tab in made["chromium"][:hibernate]:
            reply = self.action("hibernateTab", target={"kind": "tab", "id": tab})
            if isinstance(reply, dict) and reply.get("error"):
                refused = refused or reply.get("error")
            else:
                hibernated += 1
        if refused:
            print(f"activation-perf: hibernateTab refused: {str(refused)[:200]}", flush=True)
        self.action("goToWorkspace", {"workspace": first})
        wait(lambda: self.shown() == first, 20)
        time.sleep(3.0)  # test script: pages finish their first loads before the measured cycles
        return {"workspaces": len(self.workspace_ids()), "chromium_tabs": len(made["chromium"]),
                "chat_tabs": len(made["chat"]), "hibernated": hibernated, "build_s": round(time.monotonic() - start, 1)}


def cycles(app, count, pid=None, sample_out=None, settle=0.4, window_notices=True):
    """`count` resign/become pairs; per become: observers_ms, drain_ms, round trip and resyncs."""
    app.rpc("debug.hangs", {"clear": True})
    app.rpc("debug.layout_counters", {"reset": True})
    sampler = None
    if pid and sample_out:
        seconds = max(3, int(count * (settle * 2 + 0.3)) + 2)
        sampler = subprocess.Popen(["/usr/bin/sample", str(pid), str(seconds), "-mayDie", "-file", sample_out],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.5)  # test script: sample attaches before the first cycle
    rows = []
    for _ in range(count):
        app.rpc("debug.app_activation", {"active": False, "window_notices": window_notices})
        time.sleep(settle)  # test script: the app sits in the background between Cmd-Tabs
        app.rpc("debug.layout_counters", {"reset": True})
        t0 = time.monotonic()
        reply = app.rpc("debug.app_activation", {"active": True, "window_notices": window_notices}) or {}
        t1 = time.monotonic()
        counters = app.rpc("debug.layout_counters", {"reset": False}) or {}
        t2 = time.monotonic()
        rows.append({"round_trip_ms": round((t1 - t0) * 1000, 2), "drain_ms": round((t2 - t1) * 1000, 2),
                     "observers_ms": reply.get("observers_ms"), "resyncs": counters.get("indicator_resyncs"),
                     "error": reply.get("error")})
        time.sleep(settle)  # test script: trailing work of this activation ends before the next one
    if sampler:
        sampler.wait()
    hangs = app.rpc("debug.hangs", {"limit": 5}) or {}
    return rows, hangs


def summarize(rows, hangs):
    def stat(key):
        values = [r[key] for r in rows if isinstance(r.get(key), (int, float))]
        return {"p50": pct(values, 0.5), "p95": pct(values, 0.95), "max": max(values) if values else None}
    total = [r["round_trip_ms"] + r["drain_ms"] for r in rows]
    return {"cycles": len(rows), "observers_ms": stat("observers_ms"), "round_trip_ms": stat("round_trip_ms"),
            "drain_ms": stat("drain_ms"), "total_ms": {"p50": pct(total, 0.5), "p95": pct(total, 0.95)},
            "resyncs": stat("resyncs"), "hangs": hangs.get("count", hangs.get("total")),
            "worst_hangs": (hangs.get("hangs") or hangs.get("items") or [])[:3],
            "errors": sorted({r["error"] if isinstance(r["error"], str) else json.dumps(r["error"]) for r in rows if r.get("error")})}


class App:
    """A tagged Debug app launched without activation (as perf-gate.py launches it)."""

    def __init__(self, bundle, out, hang_ms):
        name = os.path.basename(bundle.rstrip("/"))
        self.bundle, self.tag, self.out = bundle, name[len("cmux DEV "):-len(".app")], out
        self.socket = f"/tmp/cmux-debug-{self.tag}.sock"
        self.cli_path = os.path.join(bundle, "Contents/Resources/bin/cmux")
        self.scratch = tempfile.mkdtemp(prefix=f"activation-{self.tag}-")
        self.config = os.path.join(self.scratch, "cmux.json")
        self.hang_ms, self.process, self.teardown = hang_ms, None, None

    def launch(self):
        with open(self.config, "w") as f:
            json.dump({"appearance": {"backgroundOpacity": 1}}, f)
        ghostty = os.path.join(self.scratch, "ghostty")
        open(ghostty, "w").close()
        if os.path.exists(self.socket):
            os.unlink(self.socket)
        env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
               "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
               "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1440,900",
               "CMUX_NEXT_CONFIG_FILE": self.config, "CMUX_NEXT_GHOSTTY_CONFIG": ghostty,
               "CMUX_NEXT_CHIEF_ISOLATED": "1", "CMUX_NEXT_CHIEF_HOME": os.path.join(self.scratch, "chief"),
               "CMUX_NEXT_HANG_THRESHOLD_MS": str(self.hang_ms), "ACPMUX_AGENT_LAUNCH": "deny"}
        try:
            from tag_teardown import TagTeardown
            self.teardown = TagTeardown(self.bundle)
            self.teardown.install()
        except ImportError:
            self.teardown = None
        log = open(os.path.join(self.out, "app.log"), "a")
        self.process = subprocess.Popen([os.path.join(self.bundle, "Contents/MacOS/cmux DEV")], env=env,
                                        stdout=log, stderr=log, stdin=subprocess.DEVNULL)
        print(f"activation-perf: launched {self.tag} pid {self.process.pid}", flush=True)
        if not wait(lambda: os.path.exists(self.socket) and "error" not in (self.rpc("debug.layout_counters") or {"error": 1}), 180):
            raise SystemExit("activation-perf: the app's debug socket never answered (a Debug build is required)")
        wait(lambda: Session(self, self.scratch).workspace_ids(), 60)

    def stop(self):
        try:
            if self.process and self.process.poll() is None:
                self.rpc("debug.quit", {"fixture_quit": "end-sessions"}, timeout=10)
                try:
                    self.process.wait(30)
                except subprocess.TimeoutExpired:
                    self.process.terminate()
                    try:
                        self.process.wait(15)
                    except subprocess.TimeoutExpired:
                        self.process.kill()
        finally:
            if self.teardown:
                self.teardown.end()

    def rpc(self, method, params=None, timeout=60):
        try:
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(timeout)
            conn.connect(self.socket)
            conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(1 << 22)
                if not chunk:
                    break
                buf += chunk
            conn.close()
            reply = json.loads(buf)
        except (OSError, ValueError) as error:
            return {"error": str(error)}
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}

    def cli(self, *args):
        env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
        env["CMUX_NEXT_CONFIG_FILE"] = self.config
        return subprocess.run([self.cli_path, "--app-socket", self.socket, *args], env=env, capture_output=True,
                              text=True, timeout=120, stdin=subprocess.DEVNULL)


def run(app, opts, pid=None):
    """Light cycles, then the heavy session and its cycles; returns the report."""
    session = Session(app, getattr(app, "scratch", tempfile.mkdtemp()))
    light_rows, light_hangs = cycles(app, opts.cycles)
    light = summarize(light_rows, light_hangs)
    print(f"activation-perf: light {json.dumps(light)}", flush=True)
    sizes = session.build(opts.workspaces, opts.browser, opts.chats, opts.hibernate)
    print(f"activation-perf: session {json.dumps(sizes)}", flush=True)
    # App notices only (builds before the window_notices parameter post only these): the mode that
    # compares with older builds. Then with the main window's key and main notices, as Cmd-Tab posts.
    app_rows, app_hangs = cycles(app, opts.cycles, window_notices=False)
    heavy_app = summarize(app_rows, app_hangs)
    print(f"activation-perf: heavy_app_only {json.dumps(heavy_app)}", flush=True)
    sample_out = os.path.join(opts.out, "activation-sample.txt") if opts.sample and pid else None
    heavy_rows, heavy_hangs = cycles(app, opts.cycles, pid=pid, sample_out=sample_out)
    heavy = summarize(heavy_rows, heavy_hangs)
    print(f"activation-perf: heavy {json.dumps(heavy)}", flush=True)
    failures = []
    worst = heavy["resyncs"]["max"]
    if worst is not None and worst > opts.max_resyncs:
        failures.append(f"an activation resynced {worst} status indicators in the heavy session (budget {opts.max_resyncs}: "
                        f"the indicators on screen, not every row and tab)")
    return {"light": light, "session": sizes, "heavy_app_only": heavy_app, "heavy": heavy, "rows": heavy_rows,
            "failures": failures}


def add_arguments(parser):
    parser.add_argument("--workspaces", type=int, default=150)
    parser.add_argument("--browser", type=int, default=100, help="Chromium tabs")
    parser.add_argument("--hibernate", type=int, default=50, help="of the Chromium tabs, how many hibernate")
    parser.add_argument("--chats", type=int, default=100, help="chat tabs (New Tab page / agent pane)")
    parser.add_argument("--cycles", type=int, default=20)
    parser.add_argument("--max-resyncs", type=int, default=MAX_RESYNCS)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", required=True, help="a Debug `cmux DEV <tag>.app` (not running)")
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or "/tmp/cmux-activation-perf")
    parser.add_argument("--hang-ms", type=int, default=30)
    parser.add_argument("--sample", action="store_true", help="sample the main thread during the heavy cycles")
    parser.add_argument("--gate", action="store_true", help="exit 1 when a blocking budget breaks")
    add_arguments(parser)
    opts = parser.parse_args()
    os.makedirs(opts.out, exist_ok=True)
    app = App(os.path.abspath(opts.app), opts.out, opts.hang_ms)
    report = {}
    try:
        app.launch()
        report = run(app, opts, pid=app.process.pid)
    finally:
        app.stop()
        with open(os.path.join(opts.out, "activation-perf.json"), "w") as f:
            json.dump(report, f, indent=1)
    for failure in report.get("failures") or []:
        print(f"FAIL {failure}", flush=True)
    sys.exit(1 if opts.gate and report.get("failures") else 0)


if __name__ == "__main__":
    main()
