#!/usr/bin/env python3
"""Child process crashes on a cmux-next app (bd cx-d0d.2; crash-elimination.md section 3, classes 13 and 14), and
the crash survival story (p12-perf-process-036): the app stays up, the page that lost its process says so and comes
back, and a terminal next to it keeps answering keys while it happens.

Cases (each `--only` name, its engine):

  renderer      chromium  SIGKILL the renderer of a Chromium tab: the sad tab shows with Reload; Reload brings the
                          page back.
  crash_url     chromium  chrome://crash typed into the tab's omnibar (the person's path: Chromium handles debug
                          URLs only from the address bar, content/browser/renderer_host/debug_urls.cc): as renderer.
  gpu           chromium  SIGKILL the GPU process: Chromium starts a new one and the page still answers (a sad tab,
                          if one shows, reloads).
  gpucrash_url  chromium  chrome://gpucrash typed into the omnibar: as gpu.
  network       chromium  SIGKILL the network service utility (--utility-sub-type=network.mojom.NetworkService):
                          Chromium starts a new one and a navigation of the tab loads over it.
  host          chromium  with cefHelperHost on: SIGKILL the Chromium browser host that serves the tab (the one
                          parent of the tab's renderers, a process of the app's tree that is not the app): the tab
                          shows the crash page with Reload, and Reload starts a new host under which the same tab
                          answers. No such host: NOT-MEASURABLE.
  browser_check chromium  chrome://inducebrowsercrashforrealz, run only on proof that Chromium's browser process is
                          not the app (cefHelperHost on and the tab's renderers all under one host). Without that
                          proof (in process until F2, or no renderer to read) a browser CHECK would end cmux, so the
                          case is EXPECTED-FAIL and the URL is never typed.
  webkit        webkit    SIGKILL the WebContent process of a WebKit tab (`page_status` page_pid): as renderer.
  agent         webkit    SIGKILL the WebContent process of an agent page (`debug.agent_pane` pid): the page reloads
                          in a new process by itself; one that keeps crashing shows the crash notice with Reload.

Every kill names an exact pid that belongs to this app: a process of the app's own process tree (a Chromium child
found by its --type, or the host), or a WebKit WebContent process that the app reports for its page and whose
responsible process is the app (or the app's own responsible process: a launch from a shell leaves the launcher
responsible for the app and so for its XPC services). A pid it cannot prove is the app's is never signalled: that
case is NOT-MEASURABLE (in check mode a pid the app reported and the proof refuses is a FAIL). A case whose debug
method the build lacks is NOT-MEASURABLE too. A NOT-MEASURABLE case counts as not survived, so only a run that
measured every case can reach the target; `.measured` says how many were.

Two modes:

  Bench (the story, scripts/perf-lab/stories.d/crash-survival*.json): `--app APP --tag TAG --out DIR` launches the
  app through bench_launch.BenchApp once per run (a fresh browser per run: Chromium falls back from hardware GPU
  after kGpuFallbackCrashCount GPU crashes, content/browser/gpu/gpu_process_host.cc, so runs never share one), with
  the typing probe on, and per `--host-arms` arm (cefHelperHost off, on: each run's own tunables file sets the
  feature's local override `browserHost.helper` to the arm). It types one key at a time into a terminal beside the
  page through each kill window and writes cmux-perf-result/v1 through BenchApp.record:
    crash_survival.<engine>                  ratio  survived/cases of the run, EXPECTED-FAIL left out (target
                                                    crash-survival.<engine>: 1.0)
    crash_survival.<engine>.measured         ratio  measured (survived or died)/cases of the run
    crash_survival.<engine>.<case>.recover   ms     the kill to the page answering again
    crash_survival.<engine>.<case>.key_to_frame  ms  each terminal key drawn after the kill, to its frame
  A case survives when the app still runs, the page comes back, and (typing on) the terminal drew at least one key
  after the kill. An arm whose app's features.list does not report cefHelperHost in the arm's state within
  HOST_SETTLE_SECONDS is NOT-MEASURABLE (nothing recorded). Exit 1 only when nothing could be measured; a case that
  died is a FAIL line and a ratio under 1.

  Check (the capture slot: `capture-host launch` runs the app with its debug socket): `--socket PATH [--app-pid PID]`
  drives the running app once, never launches or quits it, writes no result, and exits 1 on any failure.

  child-crash-e2e.py --app "cmux DEV <tag>.app" --tag TAG --out DIR [--engine chromium|webkit|all]
      [--host-arms off,on] [--runs 3] [--only ...] [--build-config bench] [--session light]
  child-crash-e2e.py --socket PATH [--app-pid PID] [--only renderer,gpu,webkit,agent]  (that set is the default)
"""
import argparse, dataclasses, functools, http.server, json, os, signal, socket, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench_launch  # noqa: E402

perf_stats = bench_launch.load_by_path("perf_stats", os.path.join(bench_launch.PERF_LAB, "perf_stats.py"))

ENGINES = ("chromium", "webkit")
CASES = {
    "renderer": "chromium", "crash_url": "chromium", "gpu": "chromium", "gpucrash_url": "chromium",
    "network": "chromium", "host": "chromium", "browser_check": "chromium",
    "webkit": "webkit", "agent": "webkit",
}
STORIES = {"chromium": "crash-survival", "webkit": "crash-survival-webkit"}
# Check mode's cases unless --only names others: the capture slot's set from before the story.
CHECK_CASES = ("renderer", "gpu", "webkit", "agent")
# The feature that moves Chromium's browser process into the Chromium Host app and its
# local override, the Debug toggle a bench sets through its tunables file (CMUX_NEXT_DEBUG_TUNABLES_FILE, as
# chromium-host-bench.py does): a launched app strips an inherited CMUX_ENABLE_FEATURES (LaunchIdentity), and
# features.list reports the toggle's value with source `local`. The file loads off the main thread after launch.
HOST_FEATURE = "cefHelperHost"
HOST_TOGGLE = "browserHost.helper"
# chromiumHostTabs' local override: with the host on, the arm's Chromium tabs run in it.
HOST_TABS_TOGGLE = "browserHost.tabs"
TUNABLES_FILE = "CMUX_NEXT_DEBUG_TUNABLES_FILE"
HOST_SETTLE_SECONDS = 15
NETWORK_SERVICE = "network.mojom.NetworkService"
WEBCONTENT = "com.apple.WebKit.WebContent"
PAGE_TITLE = "crash-e2e"

SURVIVED, DIED, NOT_MEASURABLE, EXPECTED_FAIL = "survived", "died", "not-measurable", "expected-fail"


# ---------------------------------------------------------------- processes (pure; tests feed `ps` text)
@dataclasses.dataclass(frozen=True)
class Proc:
    pid: int
    ppid: int
    command: str


def parse_ps(text):
    """{pid: Proc} from `ps -Ao pid=,ppid=,command=` output."""
    table = {}
    for line in text.splitlines():
        parts = line.split(None, 2)
        if len(parts) >= 2 and parts[0].isdigit() and parts[1].isdigit():
            table[int(parts[0])] = Proc(int(parts[0]), int(parts[1]), parts[2] if len(parts) == 3 else "")
    return table


def read_ps():
    return parse_ps(subprocess.run(["ps", "-Ao", "pid=,ppid=,command="], capture_output=True, text=True).stdout)


def descendants(table, root):
    """The processes of `root`'s tree below it (children, their children, ...)."""
    kids = {}
    for proc in table.values():
        kids.setdefault(proc.ppid, []).append(proc)
    found, todo = {}, [root]
    while todo:
        for proc in kids.get(todo.pop(), []):
            if proc.pid not in found and proc.pid != root:
                found[proc.pid] = proc
                todo.append(proc.pid)
    return found


def switch_value(command, name):
    """The value of `--name=value` in a Chromium child's command line, or None."""
    prefix = f"--{name}="
    for word in command.split():
        if word.startswith(prefix):
            return word[len(prefix):]
    return None


def chromium_children(table, app_pid, kind, sub_type=None):
    """Pids in the app's process tree started with --type=<kind> (and --utility-sub-type=<sub_type>), sorted. With
    Chromium in process they are the app's children; under the host (F2) its grandchildren."""
    return sorted(p.pid for p in descendants(table, app_pid).values()
                  if switch_value(p.command, "type") == kind
                  and (sub_type is None or switch_value(p.command, "utility-sub-type") == sub_type))


def serving_host(table, app_pid, renderers):
    """The Chromium browser host that runs `renderers`: their one parent, a process of the app's tree that is not the
    app. None without that proof: no renderer runs, one is the app's own child (Chromium in process), or they run
    under different parents."""
    parents = {table[pid].ppid for pid in renderers if pid in table}
    if len(parents) != 1:
        return None
    (parent,) = parents
    return parent if parent != app_pid and parent in descendants(table, app_pid) else None


def responsible_pid(pid):
    """The process responsible for `pid` (libquarantine's responsibility_get_pid_responsible_for_pid, macOS): an XPC
    service such as WebKit's WebContent is launchd's child, but the app that asked for it is responsible. None when
    the call is not available."""
    try:
        import ctypes
        call = ctypes.CDLL("/usr/lib/libSystem.B.dylib").responsibility_get_pid_responsible_for_pid
    except (OSError, AttributeError):
        return None
    call.restype, call.argtypes = ctypes.c_int, [ctypes.c_int]
    value = call(int(pid))
    return value if value > 0 else None


class Ownership:
    """Proves a pid is this app's before anything signals it. `read_table` and `responsible` are seams (tests).

    A WebContent's responsible process is the app's own: the app when it owns its responsibility (launched by
    launchd), else the launcher it inherited it from (a BenchApp Popen from a shell), since launchd gives an XPC
    service its client's responsible pid."""

    def __init__(self, app_pid, read_table=read_ps, responsible=responsible_pid):
        self.app_pid, self.read_table, self.responsible = app_pid, read_table, responsible

    def proof(self, pid, reported_by_app=False):
        """(True, how) when `pid` is the app's, else (False, why)."""
        if not pid or int(pid) == self.app_pid or int(pid) == os.getpid():
            return False, f"pid {pid} is not a child process"
        pid = int(pid)
        table = self.read_table()
        if pid in descendants(table, self.app_pid):
            return True, "in the app's process tree"
        proc = table.get(pid)
        if proc is None:
            return False, f"pid {pid} does not run"
        if not reported_by_app or WEBCONTENT not in proc.command:
            return False, f"pid {pid} ({proc.command[:80]}) is not in the app's process tree"
        owner = self.responsible(pid)
        if owner is None:
            return False, f"pid {pid}: its responsible process cannot be read"
        apps = {self.app_pid} | {p for p in (self.responsible(self.app_pid),) if p is not None and p > 1}
        if owner not in apps:
            return False, f"pid {pid}'s responsible process is {owner}, not the app's ({', '.join(map(str, sorted(apps)))})"
        return True, "WebContent the app reports, responsible process the app's"


# ---------------------------------------------------------------- results (pure)
@dataclasses.dataclass
class CaseResult:
    name: str
    engine: str
    outcome: str
    detail: str = ""
    recover_ms: float = None
    key_to_frame: list = dataclasses.field(default_factory=list)

    def report(self):
        out = dataclasses.asdict(self)
        out["key_to_frame"] = perf_stats.summary(self.key_to_frame)
        return out


def counted(results, engine):
    """`engine`'s cases of one run that count: every one but EXPECTED-FAIL."""
    return [r for r in results if r.engine == engine and r.outcome != EXPECTED_FAIL]


def survival(results, engine):
    """survived/cases of `engine` (a NOT-MEASURABLE case counts as not survived, so a partial run never reaches the
    target); None when the run has no case of `engine`."""
    cases = counted(results, engine)
    return sum(r.outcome == SURVIVED for r in cases) / len(cases) if cases else None


def measured(results, engine):
    """measured (survived or died)/cases of `engine`; None when the run has no case of `engine`."""
    cases = counted(results, engine)
    return sum(r.outcome in (SURVIVED, DIED) for r in cases) / len(cases) if cases else None


@dataclasses.dataclass(frozen=True)
class Series:
    story: str
    metric: str
    unit: str
    samples: tuple
    better: str
    engine: str
    target_ref: str = None


def series(runs, engines):
    """The result-v1 series of `runs` (one list of CaseResult per launch) for each engine: one survival and one
    measured sample per run, the recover times and the key->frame samples of the measured cases."""
    out = []
    for engine in engines:
        story = STORIES[engine]
        ratios = [ratio for ratio in (survival(results, engine) for results in runs) if ratio is not None]
        if ratios:
            out.append(Series(story, f"crash_survival.{engine}", "ratio", tuple(ratios), "higher", engine,
                              f"crash-survival.{engine}"))
            covered = tuple(measured(results, engine) for results in runs if counted(results, engine))
            out.append(Series(story, f"crash_survival.{engine}.measured", "ratio", covered, "higher", engine))
        for case in (c for c, e in CASES.items() if e == engine):
            done = [r for results in runs for r in results if r.name == case and r.engine == engine]
            recover = tuple(r.recover_ms for r in done if r.outcome == SURVIVED and r.recover_ms is not None)
            if recover:
                out.append(Series(story, f"crash_survival.{engine}.{case}.recover", "ms", recover, "lower", engine))
            keys = tuple(v for r in done if r.outcome in (SURVIVED, DIED) for v in r.key_to_frame)
            if keys:
                out.append(Series(story, f"crash_survival.{engine}.{case}.key_to_frame", "ms", keys, "lower", engine))
    return out


def window_samples(rows, start, column="contents_ms"):
    """The key->frame samples of the probe rows written since row `start`: complete rows that drew (`column`)."""
    samples = []
    for row in rows[start:]:
        try:
            if row.get("complete") == "1" and row.get(column):
                samples.append(float(row[column]))
        except ValueError:
            continue
    return samples


def probe_rows(path):
    import csv
    try:
        with open(path) as handle:
            return list(csv.DictReader(handle))
    except OSError:
        return []


def missing_method(reply):
    """True when the app answered that it has no such method (a build without the debug method)."""
    error = (reply or {}).get("error") if isinstance(reply, dict) else None
    return isinstance(error, dict) and error.get("code") == "method_not_found"


# ---------------------------------------------------------------- the live app
def wait(check, seconds, step=0.25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            value = check()
        except Exception:
            value = None
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def uptime():
    """Seconds since boot on the clock NSEvent timestamps use (CLOCK_UPTIME_RAW on macOS)."""
    clock = getattr(time, "CLOCK_UPTIME_RAW", None)
    return time.clock_gettime(clock) if clock is not None else time.monotonic()


def serve():
    root = tempfile.mkdtemp(prefix="child-crash-e2e-")
    with open(os.path.join(root, "index.html"), "w") as page:
        page.write(f"<!doctype html><title>{PAGE_TITLE}</title><p id=alive>alive</p>")

    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=root))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://localhost:{server.server_address[1]}/"


class Typist:
    """One key at a time into the focused terminal (`debug.key`, timestamped when sent, so the wait for the main
    thread counts as a real key's wait in the event queue), on a thread, for one kill window."""

    KEYS = "abcdefghijklmnopqrstuvwxyz"

    def __init__(self, rpc, interval):
        self.rpc, self.interval = rpc, interval
        self.stop_event, self.thread, self.sent = threading.Event(), None, 0

    def __enter__(self):
        self.stop_event.clear()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()
        return self

    def _run(self):
        while not self.stop_event.is_set():
            self.rpc("debug.key", {"key": self.KEYS[self.sent % len(self.KEYS)], "timestamp": uptime()}, timeout=10)
            self.sent += 1
            self.stop_event.wait(self.interval)  # one key in flight at a time

    def __exit__(self, *exc):
        self.stop_event.set()
        self.thread.join(15)


class Driver:
    """Runs the cases on one running app. `rpc(method, params, timeout)` is the app's socket; `probe` its typing
    probe CSV (None: no typing); `check` prints and counts PASS/FAIL lines. `strict` (check mode): a pid the app
    reports that the ownership proof refuses is a FAIL, not only NOT-MEASURABLE."""

    def __init__(self, rpc, app_pid, url, probe=None, cli=None, socket_path=None, key_interval=0.1,
                 ownership=None, host_on=False, strict=False):
        self.rpc, self.app_pid, self.url, self.probe = rpc, app_pid, url, probe
        self.cli, self.socket_path, self.key_interval = cli, socket_path, key_interval
        self.ownership = ownership or Ownership(app_pid)
        self.host_on, self.strict = host_on, strict
        self.kill_row = None  # the probe row count when the case's crash was sent (None: not sent, or no probe)
        self.failures, self.checks = [], 0
        self.layout = None  # {"terminal_pane", "terminal_tab", "browser_pane", "tab"} of the engine under test
        self.navigations = 0
        self.baseline_renderers = set()  # renderers that ran before the tab opened: never the tab's

    # -- plumbing
    def check(self, name, ok, detail=""):
        self.checks += 1
        print(f"{'PASS' if ok else 'FAIL'} {name}{': ' + str(detail)[:400] if detail else ''}", flush=True)
        if not ok:
            self.failures.append(name)
        return ok

    def call(self, method, params=None, timeout=40):
        return self.rpc(method, params or {}, timeout=timeout) or {}

    def action(self, name, args=None, target=None, focus=True):
        params = {"action": name, "args": args or {}, "focus": focus, "confirm": True, "origin": "script"}
        if target:
            params["target"] = target
        return self.call("action.run", params, timeout=60)

    def js(self, tab, script):
        reply = self.call("browser.page.eval", {"tab": tab, "script": script})
        return reply.get("value") if "error" not in reply else None

    def status(self, tab, press=None):
        return self.call("debug.browser.page_status", {"tab": tab, **({"press": press} if press else {})})

    def answers(self, tab):
        return self.js(tab, "document.getElementById('alive')?.textContent") == "alive"

    def crash_sent(self):
        """Marks the crash of the running case: the probe rows written from now on are the terminal after it."""
        self.kill_row = len(probe_rows(self.probe)) if self.probe else None

    def kill(self, name, pid, reported_by_app=False):
        """SIGKILL `pid` once Ownership proves it is the app's; the monotonic kill time, or None (not signalled)."""
        owned, why = self.ownership.proof(pid, reported_by_app)
        if not owned:
            if self.strict and reported_by_app:
                self.check(f"{name}: the pid the app reports is proved the app's", False, f"{pid}: {why}")
            else:
                print(f"NOT-MEASURABLE {name}: refused to signal {pid}: {why}", flush=True)
            return None
        self.crash_sent()
        os.kill(int(pid), signal.SIGKILL)
        print(f"killed {name} {pid} ({why})", flush=True)
        return time.monotonic()

    # -- layout: a typed terminal beside the page under test
    def workspaces(self):
        snap = self.call("snapshot.get")
        return ((snap.get("topology") or snap).get("workspaces")) or []

    @staticmethod
    def panes(workspace):
        return [p for s in (workspace or {}).get("screens") or [] for p in s.get("panes") or [] if not p.get("dock")]

    def workspace_named(self, name):
        return next((w for w in self.workspaces() if (w.get("name") or w.get("title")) == name), None)

    def pane_tabs(self, pane_id):
        for workspace in self.workspaces():
            for pane in self.panes(workspace):
                if pane.get("id") == pane_id:
                    return pane.get("tabs") or []
        return []

    def run_cli(self, *args):
        env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
        try:
            return subprocess.run([self.cli, "--app-socket", self.socket_path, *args], env=env, capture_output=True,
                                  text=True, timeout=60, stdin=subprocess.DEVNULL)
        except (OSError, subprocess.TimeoutExpired) as error:
            return subprocess.CompletedProcess(args, 124, "", str(error))

    def focus_terminal(self):
        if self.layout:
            self.action("pane.focus", target=f"pane:{self.layout['terminal_pane']}")

    def open_layout(self, engine):
        """A workspace with a zsh terminal on the left (typed) and a tab of `engine` on our page on the right.
        Without a CLI (no typing) only the tab opens, in the focused pane. Returns the tab id or None."""
        if self.probe and self.cli:
            name = "crash-survival"
            if not self.workspace_named(name):
                done = self.run_cli("workspace", "create", "--name", name, "--focus", "--shell", "exec /bin/zsh -f")
                if not self.check("layout: the terminal workspace opens", done.returncode == 0, done.stderr.strip()):
                    return None
            panes = wait(lambda: self.panes(self.workspace_named(name)), 20) or []
            if not self.check("layout: the workspace has a pane", bool(panes)):
                return None
            left = panes[0]["id"]
            before = {p["id"] for p in panes}
            self.action("splitRight", target=f"pane:{left}")
            right = wait(lambda: next((p["id"] for p in self.panes(self.workspace_named(name)) if p["id"] not in before), None), 15)
            if not self.check("layout: the split opens a pane for the page", bool(right)):
                return None
            beside = wait(lambda: self.pane_tabs(right), 10) or []
            opened = self.action(f"openBrowser.{engine}", {"url": self.url}, target=f"tab:{beside[0]['id']}" if beside else f"pane:{right}")
        else:
            left = right = None
            opened = wait(lambda: (lambda r: r if r.get("created") else None)(self.action("openBrowser", {"url": self.url, "engine": engine})), 90, 3) or {}
        created = opened.get("created") or []
        tab = created[0] if created else None
        loaded = bool(tab) and wait(lambda: self.js(tab, "document.title") == PAGE_TITLE, 60, 0.5)
        self.check(f"{engine} tab loads {self.url}", bool(loaded), opened)
        if not loaded:
            return None
        terminal = next((t.get("id") for t in self.pane_tabs(left) if t.get("kind") == "terminal"), None) if left else None
        self.layout = {"terminal_pane": left, "terminal_tab": terminal, "browser_pane": right, "tab": tab} if left else None
        if left:
            time.sleep(1.0)  # test harness wait: the shell prompt draws
            self.focus_terminal()
        return tab

    # -- one case through its kill window
    def window(self, name, engine, run):
        """Runs `run()` (the crash and its recovery: (outcome, detail, recover_ms)) while the terminal is typed into,
        and makes the CaseResult. A died case also needs the app running and the terminal drawing after the kill."""
        typing = bool(self.probe and self.layout)
        self.kill_row = None
        if typing:
            with Typist(self.rpc, self.key_interval):
                time.sleep(0.5)  # test harness: keys before the crash, the window's baseline
                outcome, detail, recover = run()
                time.sleep(0.5)  # test harness: keys after the recovery
            time.sleep(0.5)  # test harness: the last key's frame lands
            terminal = self.layout.get("terminal_tab")
            self.action("terminal.sendText", {"text": "\x15"}, target=f"tab:{terminal}" if terminal else None, focus=False)  # Ctrl-U
        else:
            outcome, detail, recover = run()
        # Only the keys drawn after the crash, and only for a case that crashed something: the keys before it, and a
        # case that returned before any crash, measure a quiet terminal.
        sent = typing and self.kill_row is not None and outcome in (SURVIVED, DIED)
        keys = window_samples(probe_rows(self.probe), self.kill_row) if sent else []
        if outcome == SURVIVED and not alive(self.app_pid):
            outcome, detail = DIED, "the app ended"
        if outcome == SURVIVED and typing and not keys:
            outcome, detail = DIED, "the terminal drew no key after the kill"
        result = CaseResult(name, engine, outcome, detail, recover, keys)
        if outcome in (SURVIVED, DIED):
            self.check(f"{name}: survived", outcome == SURVIVED, detail or f"recover {recover} ms, {len(keys)} keys")
        else:
            print(f"{outcome.upper()} {name}: {detail}", flush=True)
        return result

    def sad_tab_reloads(self, name, tab, killed_at):
        """The tab shows the sad tab with Reload, and Reload brings the page back."""
        gone = wait(lambda: (lambda s: s if s.get("gone") == "1" else None)(self.status(tab)), 20)
        lines = ((gone or {}).get("gone_text") or "").split("\n")
        self.check(f"{name}: the tab shows the crashed page with Reload", bool(gone) and len(lines) == 3 and lines[2] != "", lines)
        if not gone:
            return DIED, "no sad tab", None
        pressed = self.status(tab, press="reload").get("pressed") == "1"
        back = pressed and wait(lambda: self.status(tab).get("gone") == "0" and self.answers(tab), 30, 0.25)
        recover = round((time.monotonic() - killed_at) * 1000, 1)
        return (SURVIVED, "", recover) if back else (DIED, f"Reload did not bring the page back (pressed={pressed})", None)

    def page_answers_after(self, name, tab, killed_at):
        """The page answers again; a sad tab, if one shows, reloads."""
        def back():
            if self.status(tab).get("gone") == "1":
                self.status(tab, press="reload")
            return self.answers(tab)
        ok = wait(back, 30, 0.25)
        recover = round((time.monotonic() - killed_at) * 1000, 1)
        return (SURVIVED, "", recover) if ok else (DIED, f"{name}: the page does not answer", None)

    def omnibar(self, name, text):
        """Types `text` into the browser pane's omnibar and commits it (the person's address bar path); the time,
        or None with the case's NOT-MEASURABLE reason printed."""
        params = {"text": text, "commit": True}
        if self.layout:
            params["pane"] = self.layout["browser_pane"]
        self.crash_sent()
        reply = self.call("debug.omnibar_type", params)
        at = time.monotonic()
        self.focus_terminal()  # the omnibar took the keyboard; the typed keys go back to the terminal
        if missing_method(reply):
            return None, "this build has no debug.omnibar_type"
        if not reply.get("typed"):
            return None, f"the omnibar did not take {text}: {reply}"
        return at, ""

    # -- the cases
    def chromium_cases(self, tab, only):
        results = []
        renderers = lambda: chromium_children(self.ownership.read_table(), self.app_pid, "renderer")

        def tab_host():
            """The host that runs the tab's renderers (those that did not run before the tab opened), or None."""
            table = self.ownership.read_table()
            tab_renderers = set(chromium_children(table, self.app_pid, "renderer")) - self.baseline_renderers
            return serving_host(table, self.app_pid, tab_renderers)

        def renderer_run(name):
            def run():
                if name == "renderer":
                    pids = sorted(set(renderers()) - self.baseline_renderers)
                    if not pids:
                        return NOT_MEASURABLE, "the tab has no renderer process of its own", None
                    killed = [at for at in (self.kill("renderer", pid) for pid in pids) if at]
                    if not killed:
                        return NOT_MEASURABLE, "no renderer pid proved the app's", None
                    at = killed[0]
                else:
                    at, why = self.omnibar("crash_url", "chrome://crash")
                    if at is None:
                        return NOT_MEASURABLE, why, None
                return self.sad_tab_reloads(name, tab, at)
            return run

        def gpu_run(name):
            def run():
                gpus = chromium_children(self.ownership.read_table(), self.app_pid, "gpu-process")
                if not gpus:
                    return DIED, "Chromium runs no GPU process", None
                if name == "gpu":
                    killed = [at for at in (self.kill("gpu", pid) for pid in gpus) if at]
                    if not killed:
                        return NOT_MEASURABLE, "no GPU pid proved the app's", None
                    at = killed[0]
                else:
                    at, why = self.omnibar("gpucrash_url", "chrome://gpucrash")
                    if at is None:
                        return NOT_MEASURABLE, why, None
                restarted = wait(lambda: set(chromium_children(self.ownership.read_table(), self.app_pid, "gpu-process")) - set(gpus), 20)
                if not restarted:
                    return DIED, "Chromium started no new GPU process", None
                return self.page_answers_after(name, tab, at)
            return run

        def network_run():
            nets = chromium_children(self.ownership.read_table(), self.app_pid, "utility", NETWORK_SERVICE)
            if not nets:
                return NOT_MEASURABLE, "no out-of-process network service", None
            killed = [at for at in (self.kill("network", pid) for pid in nets) if at]
            if not killed:
                return NOT_MEASURABLE, "no network service pid proved the app's", None
            restarted = wait(lambda: set(chromium_children(self.ownership.read_table(), self.app_pid, "utility", NETWORK_SERVICE)) - set(nets), 20)
            if not restarted:
                return DIED, "Chromium started no new network service", None
            # A navigation, so the page's bytes come over the new network service.
            self.navigations += 1
            query = f"?n={self.navigations}"
            self.call("browser.page.navigate", {"tab": tab, "url": self.url + query})
            ok = wait(lambda: self.js(tab, "location.search") == query and self.answers(tab), 30, 0.25)
            recover = round((time.monotonic() - killed[0]) * 1000, 1)
            return (SURVIVED, "", recover) if ok else (DIED, "the page does not load after the network service crash", None)

        def host_run():
            host = tab_host()
            if host is None:
                return NOT_MEASURABLE, "no Chromium host runs the tab's renderers (in process, or none runs)", None
            at = self.kill("host", host)
            if at is None:
                return NOT_MEASURABLE, f"host pid {host} not proved the app's", None
            # The host's end shows the crash page with Reload, and Reload starts a new host.
            outcome, detail, recover = self.sad_tab_reloads("host", tab, at)
            if outcome != SURVIVED:
                return outcome, detail, recover
            fresh = tab_host()
            if fresh is None or fresh == host:
                return DIED, f"the tab answers, but not from a new Chromium host (host {fresh})", None
            print(f"host: the tab runs under a new host {fresh}", flush=True)
            return outcome, detail, recover

        def browser_check_run():
            if not self.host_on or tab_host() is None:
                return EXPECTED_FAIL, ("no proof Chromium's browser process runs outside the app (in process until F2, "
                                       "or no renderer of the tab to read): a browser CHECK would end cmux"), None
            at, why = self.omnibar("browser_check", "chrome://inducebrowsercrashforrealz")
            if at is None:
                return NOT_MEASURABLE, why, None
            return self.page_answers_after("browser_check", tab, at)

        runs = {"renderer": renderer_run("renderer"), "crash_url": renderer_run("crash_url"), "gpu": gpu_run("gpu"),
                "gpucrash_url": gpu_run("gpucrash_url"), "network": network_run, "host": host_run,
                "browser_check": browser_check_run}
        for name in self.chromium_plan(only):
            results.append(self.window(name, "chromium", runs[name]))
        return results

    def chromium_plan(self, only):
        """The Chromium cases this app runs, in order: the host case only with cefHelperHost on (the off arm has no
        host to kill)."""
        if "host" in only and not self.host_on:
            print(f"NOT-MEASURABLE host: {HOST_FEATURE} is off in this app", flush=True)
        return [c for c, e in CASES.items() if e == "chromium" and c in only and (c != "host" or self.host_on)]

    def unopened(self, engine, names):
        """The cases of a tab that did not open: NOT-MEASURABLE, so they count against the run's survival (the
        browser CHECK stays EXPECTED-FAIL without its proof, as it would with the tab)."""
        return [CaseResult(n, engine, EXPECTED_FAIL if n == "browser_check" and not self.host_on else NOT_MEASURABLE,
                           f"the {engine} tab did not open") for n in names]

    def webkit_case(self, tab):
        def run():
            page = wait(lambda: self.status(tab).get("page_pid"), 20)
            if not page:
                return DIED, f"the WebKit tab reports no WebContent process: {self.status(tab)}", None
            at = self.kill("webkit WebContent", page, reported_by_app=True)
            if at is None:
                return NOT_MEASURABLE, f"WebContent {page} not proved the app's", None
            outcome, detail, recover = self.sad_tab_reloads("webkit", tab, at)
            fresh = self.status(tab).get("page_pid")
            self.check("webkit: the page runs in a new WebContent process", bool(fresh) and fresh != page, fresh)
            return outcome, detail, recover
        return self.window("webkit", "webkit", run)

    def agent_case(self):
        """An agent page's WebContent: it reloads in a new process by itself. Then the keep-crashing notice
        (PageCrashReloads: 3 reloads in 10 minutes) and its Reload, as checks."""
        state = {}

        def pid_of(pane):
            return self.call("debug.agent_pane", {"action": "pid", "pane": pane}).get("pid")

        def run():
            probe = self.call("debug.agent_pane", {"action": "pid"})
            if missing_method(probe):
                return NOT_MEASURABLE, "this build has no debug.agent_pane", None
            pane = probe.get("pane") or ((probe.get("agent_panes") or [None])[0])
            if not pane:
                self.action("newTab")  # a new workspace opens on the New Tab page, an agent page
                probe = wait(lambda: (lambda r: r if r.get("pid") else None)(self.call("debug.agent_pane", {"action": "pid"})), 30) or {}
                pane = probe.get("pane")
            page = pid_of(pane) if pane else None
            if not page:
                return DIED, f"no agent page reports its WebContent process: {probe}", None
            at = self.kill("agent WebContent", page, reported_by_app=True)
            if at is None:
                return NOT_MEASURABLE, f"WebContent {page} not proved the app's", None
            fresh = wait(lambda: (lambda p: p if p and p != page else None)(pid_of(pane)), 30)
            state.update(pane=pane, fresh=fresh)
            recover = round((time.monotonic() - at) * 1000, 1)
            return (SURVIVED, "", recover) if fresh else (DIED, "the agent page did not reload in a new process", None)

        result = self.window("agent", "webkit", run)
        if result.outcome == SURVIVED:
            self.keep_crashing_notice(state["pane"], state["fresh"], pid_of)
        return result

    def keep_crashing_notice(self, pane, current, pid_of):
        notice = None
        for crash in range(2, 6):
            if not current or not self.kill("agent WebContent", current, reported_by_app=True):
                break
            notice = wait(lambda: (lambda r: r if r.get("shown") else None)(self.call("debug.agent_pane", {"action": "crash_notice", "pane": pane})), 3)
            if notice:
                print(f"agent: notice after crash {crash}", flush=True)
                break
            previous = current
            current = wait(lambda: (lambda p: p if p and p != previous else None)(pid_of(pane)), 30)
        texts = (notice or {}).get("texts") or []
        self.check("agent: a page that keeps crashing shows the crashed page with Reload", len(texts) == 2 and all(texts), texts)
        self.check("agent: app still runs after repeated crashes", alive(self.app_pid))
        if notice:
            pressed = self.call("debug.agent_pane", {"action": "crash_notice", "pane": pane, "press": "reload"}).get("pressed")
            back = pressed and wait(lambda: (lambda p: p if p and p != current else None)(pid_of(pane)), 30)
            gone = not self.call("debug.agent_pane", {"action": "crash_notice", "pane": pane}).get("shown")
            self.check("agent: Reload starts the page again", bool(back) and gone, f"pressed={pressed} pid={back}")

    def run_cases(self, engines, only):
        """Every selected case once: the agent page first (while a fresh window still shows its New Tab page), then
        each engine's tab beside the typed terminal."""
        results = []
        if "webkit" in engines and "agent" in only:
            results.append(self.agent_case())
        if "chromium" in engines and only & {c for c, e in CASES.items() if e == "chromium"}:
            self.baseline_renderers = set(chromium_children(self.ownership.read_table(), self.app_pid, "renderer"))
            tab = self.open_layout("chromium")
            results.extend(self.chromium_cases(tab, only) if tab else self.unopened("chromium", self.chromium_plan(only)))
        if "webkit" in engines and "webkit" in only:
            self.layout = None
            tab = self.open_layout("webkit")
            results.extend([self.webkit_case(tab)] if tab else self.unopened("webkit", ["webkit"]))
        self.check("app still runs at the end", alive(self.app_pid))
        return results


# ---------------------------------------------------------------- modes
def selected(opts):
    engines = ENGINES if opts.engine == "all" else (opts.engine,)
    default = CHECK_CASES if opts.socket else CASES  # check mode keeps the capture slot's cases
    only = set(opts.only.split(",")) if opts.only else {c for c in default if CASES[c] in engines}
    unknown = only - set(CASES)
    if unknown:
        raise SystemExit(f"unknown case {', '.join(sorted(unknown))}; cases: {', '.join(CASES)}")
    return engines, only


def socket_app_pid(path):
    # lsof lists a unix socket by the path it is bound to, under the process that holds it.
    out = subprocess.run(["lsof", "-U", "-Fpn"], capture_output=True, text=True).stdout
    pid = None
    for line in out.splitlines():
        if line.startswith("p"):
            pid = int(line[1:])
        elif line.startswith("n") and line[1:] == path:
            return pid
    return None


def check_mode(opts):
    """The capture slot's check: drive the running app once, write the report, exit 1 on any failure."""
    rpc = functools.partial(bench_launch.rpc_at, opts.socket)
    pid = opts.app_pid or socket_app_pid(opts.socket)
    if not pid or not alive(pid):
        sys.exit(f"FAIL no app process for {opts.socket}")
    if not wait(lambda: "error" not in (rpc("debug.crashes", None, timeout=5) or {"error": "no reply"}), 60):
        sys.exit("FAIL the app does not answer on its socket")
    features = bench_launch.features_snapshot(rpc("features.list", None, timeout=10))
    server, url = serve()
    print(f"app pid {pid}, page {url}", flush=True)
    engines, only = selected(opts)
    driver = Driver(rpc, pid, url, socket_path=opts.socket, strict=True,
                    host_on=host_state(features) == "on")
    results = driver.run_cases(engines, only)
    server.shutdown()
    write_report(opts.out, {"mode": "check", "runs": [[r.report() for r in results]]})
    if driver.failures:
        sys.exit(f"FAIL {len(driver.failures)}: {', '.join(driver.failures)}")
    print("PASS every child process crash is contained")


def host_state(snapshot):
    """cefHelperHost's `state` in a features.list snapshot (bench_launch.features_snapshot), or None."""
    return ((snapshot or ({}, None, None))[0].get(HOST_FEATURE) or {}).get("state")


def arm_env(arm, probe, tunables_path):
    """The launch environment of one run of `arm`: the typing probe, and a tunables file of its own that sets the
    host toggle to the arm (off too, so a developer's own Debug Settings never pick the off arm's value)."""
    with open(tunables_path, "w") as handle:
        json.dump({"version": 1, "values": {HOST_TOGGLE: arm == "on", HOST_TABS_TOGGLE: arm == "on"}}, handle)
    return {"CMUX_NEXT_TYPING_PROBE": probe, TUNABLES_FILE: tunables_path}


def settle_host_state(app, arm, seconds=HOST_SETTLE_SECONDS):
    """cefHelperHost's state once the arm's toggle applies: the tunables file loads after the launch's first
    features.list read, so an arm whose snapshot does not show it yet reads features.list again (``app.features``
    becomes that answer, the one its results record) until it does or `seconds` pass."""
    want = "on" if arm == "on" else "off"
    if host_state(app.features) != want:
        def settled():
            snapshot = app.read_features()
            if snapshot is not None:
                app.features = snapshot
            return host_state(snapshot) == want
        wait(settled, seconds, step=0.5)
    return host_state(app.features)


def bench_mode(opts):
    """The story: per arm and run, a BenchApp launch, the cases, then one result-v1 file per series."""
    engines, only = selected(opts)
    arms = [a for a in opts.host_arms.split(",") if a]
    if set(arms) - {"off", "on"}:
        raise SystemExit("--host-arms takes off, on or off,on")
    if "chromium" not in engines:
        arms = ["off"]  # the host arm changes only Chromium
    report, recorded, failures = {"mode": "bench", "arms": {}}, 0, []
    os.makedirs(opts.out, exist_ok=True)
    for arm in arms:
        runs, last = [], None  # `last`: the arm's last launch; it records the arm's series (its build, host, features)
        for run in range(opts.runs):
            probe = os.path.join(opts.out, f"typing-host-{arm}-{run}.csv")
            env = arm_env(arm, probe, os.path.join(opts.out, f"debug-tunables-host-{arm}-{run}.json"))
            app = bench_launch.BenchApp(opts.app, out=opts.out, env=env, log_name=f"app-host-{arm}-{run}.log",
                                        perf_session=opts.session, build_config=opts.build_config)
            server = None
            try:
                app.launch()
                state = settle_host_state(app, arm)
                if (arm == "on") != (state == "on"):
                    print(f"NOT-MEASURABLE host arm {arm}: the app reports {HOST_FEATURE} {state or 'undeclared'}",
                          flush=True)
                    report["arms"][arm] = {"not_measurable": f"{HOST_FEATURE} {state or 'undeclared'}"}
                    break
                last = app
                server, url = serve()
                driver = Driver(app.rpc, app.process.pid, url, probe=probe, cli=app.cli, socket_path=app.socket,
                                key_interval=opts.key_interval, host_on=state == "on")
                print(f"arm {HOST_FEATURE}={arm} run {run + 1}/{opts.runs}: app pid {app.process.pid}, page {url}", flush=True)
                runs.append(driver.run_cases(engines, only))
                failures.extend(f"{arm}/{run}/{name}" for name in driver.failures)
            finally:
                if server:
                    server.shutdown()
                app.stop()
        for s in series(runs, engines):
            path = last.record(s.story, s.metric, s.unit, list(s.samples), better=s.better, engine=s.engine,
                               target_ref=s.target_ref)
            recorded += 1
            print(f"RESULT {s.metric} {perf_stats.summary(s.samples)} -> {path}", flush=True)
        if runs:
            report["arms"][arm] = {"runs": [[r.report() for r in results] for results in runs],
                                   "survival": {e: [survival(results, e) for results in runs] for e in engines}}
    write_report(opts.out, report)
    if failures:
        print(f"FAIL {len(failures)}: {', '.join(failures)}", flush=True)
    if not recorded:
        sys.exit("FAIL nothing was measured")


def write_report(out, report):
    os.makedirs(out, exist_ok=True)
    path = os.path.join(out, "child-crash-e2e.json")
    with open(path, "w") as handle:
        json.dump(report, handle, indent=1)
    print(f"report: {path}", flush=True)


def parse(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--socket", help="check mode: the running app's debug socket")
    parser.add_argument("--app-pid", type=int, help="check mode: the app's pid (default: the process listening on --socket)")
    parser.add_argument("--app", help="bench mode: the tagged app bundle to launch")
    parser.add_argument("--tag", help="bench mode: the app's tag (the runner passes it; the bundle names it too)")
    parser.add_argument("--engine", choices=("chromium", "webkit", "all"), default="all")
    parser.add_argument("--only", help=f"comma list of cases (default: every case of --engine; with --socket "
                                       f"{','.join(CHECK_CASES)}): {', '.join(CASES)}")
    parser.add_argument("--host-arms", default="off", help=f"bench mode: {HOST_FEATURE} arms, off, on or off,on")
    parser.add_argument("--runs", type=int, default=1, help="bench mode: launches per arm (the capture slot passes it too)")
    parser.add_argument("--key-interval", type=float, default=0.1, help="seconds between typed keys")
    parser.add_argument("--session", choices=("light",), default="light", help="result-v1 session")
    parser.add_argument("--build-config", choices=("bench", "bench-checks", "release", "debug"),
                        help="result-v1 build config of a bench-hooks bundle that does not stamp it (BenchApp.record)")
    parser.add_argument("--out", default="/tmp/child-crash-e2e")
    opts = parser.parse_args(argv)
    if bool(opts.socket) == bool(opts.app):
        parser.error("pass --socket (check a running app) or --app (launch and measure), not both")
    if opts.runs < 1:
        parser.error("--runs is at least 1")
    return opts


def main(argv=None):
    opts = parse(argv)
    (check_mode if opts.socket else bench_mode)(opts)


if __name__ == "__main__":
    main()
