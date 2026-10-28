"""bench-webui.py priority-roles: the scheduling role, QoS and footprint of every cmux process while cmux's own pages
(Settings, History, ...) are shown, hidden and parked (plans/cmux-next/chrome-parity/p13-webui.md, task 083, done
check D12).

Chrome backgrounds a renderer whose widgets are all hidden: RenderProcessHostImpl::UpdateProcessPriority picks
kBestEffort, and ChildProcessLauncherHelper::ApplyProcessPriorityOnLauncherThread
(content/browser/child_process_launcher_helper_mac.cc) applies it through the child's task port
(ChildProcessTaskPortProvider, MachPortRendezvous). On macOS kBestEffort is TASK_BACKGROUND_APPLICATION with the
task suppression policy (base/process/process_mac.cc SetPriority): low-priority CPU, LATENCY_QOS_TIER_5 timers,
disk throttling. WebKit's ProcessThrottler does the same for a hidden WebContent process. This mode measures
whether cmux's page renderers get there, and how fast.

States, one launch per engine (browser.defaultEngine, which cmux's pages follow):
  parked      after --settle with no page opened: only the New Tab preload is parked
  one-shown   --pages opened in a pages workspace, the last one shown
  all-hidden  a terminal workspace shown: every page hidden (and frozen once the lifecycle planner runs)
Then --runs hide and show cycles time each page renderer from the switch to backgrounded (and back).

Each state prints one PERF-WEBUI-PRIORITY row per process kind: processes, roles, how many are backgrounded,
the QoS class that ran most of their CPU, footprint, CPU and wakeups. A row per cycle phase prints the
percentiles of the time to background (and to foreground). PERF-WEBUI-PRIORITY-OVER names each D12 breach:
in all-hidden a page renderer not backgrounded within --background-ms; in one-shown more page renderers above
background than pages shown.

--purge-arm launches again with Blink's MemoryPurgeOnFreeze (third_party/blink/common/features.cc, off on
desktop; MemoryPurgeManager::OnPageFrozen purges a backgrounded renderer once every page in it is frozen) and
prints PERF-WEBUI-PURGE with the page renderers' footprint in all-hidden for both arms. cmux turns purge on only
with a gain recorded from this row. The switch goes through CMUX_NEXT_CEF_EXTRA_SWITCHES, so the purge arm needs
a DEBUG dev build.
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "perf-bench"))
import procs  # noqa: E402  (process set of one app, counters, thread roles, QoS split)

# Page name -> the action that shows it.
PAGES = {"settings": "openSettings", "history": "history.show", "apps": "appStore.show", "stats": "stats.show"}
PAGE_RENDERER_KINDS = ("renderer", "webkit-webcontent")
PURGE_SWITCH = "enable-features=MemoryPurgeOnFreeze"


def kind_of(cmd: str) -> str:
    """procs.kind_of, with the extension renderer apart: it holds no page and Chrome prioritizes it by its own
    rules (extensions::ProcessManager), so it is reported but never judged."""
    kind = procs.kind_of(cmd)
    if kind == "renderer" and "--extension-process" in cmd:
        return "renderer:extension"
    return kind


def percentile(values, q: float):
    ordered = sorted(v for v in values if v is not None)
    if not ordered:
        return None
    return ordered[min(len(ordered) - 1, int(len(ordered) * q))]


def spread(values) -> dict:
    landed = [v for v in values if v is not None]
    return {"n": len(values), "landed": len(landed), "p50": percentile(landed, 0.5), "p95": percentile(landed, 0.95),
            "p99": percentile(landed, 0.99), "max": max(landed) if landed else None}


def top_qos(before: dict | None, after: dict | None) -> tuple[str | None, float | None]:
    """The QoS class that ran most of the CPU between two `procs.qos_cpu_ns` reads, and its share; (None, None)
    when there was none."""
    if not after:
        return None, None
    deltas = {name: after[name] - (before or {}).get(name, 0) for name in after}
    total = sum(max(v, 0) for v in deltas.values())
    if total <= 0:
        return None, None
    name = max(deltas, key=deltas.get)
    return name, round(deltas[name] / total, 3)


def kind_rows(processes: list[dict]) -> dict[str, dict]:
    """Per kind: n, backgrounded, roles {role: n}, top QoS {class: n}, summed footprint, CPU and wakeups."""
    rows: dict[str, dict] = {}
    for proc in processes:
        row = rows.setdefault(proc["kind"], {"n": 0, "backgrounded": 0, "roles": {}, "qos": {}, "footprint_mb": 0.0,
                                             "cpu_pct": 0.0, "wakeups_per_s": 0.0})
        row["n"] += 1
        row["backgrounded"] += proc["role"] in procs.BACKGROUNDED_ROLES
        row["roles"][proc["role"]] = row["roles"].get(proc["role"], 0) + 1
        if proc.get("qos"):
            row["qos"][proc["qos"]] = row["qos"].get(proc["qos"], 0) + 1
        for key in ("footprint_mb", "cpu_pct", "wakeups_per_s"):
            row[key] = round(row[key] + (proc.get(key) or 0.0), 3)
    return rows


def breaches(state: str, rows: dict[str, dict], shown_pages: int) -> list[str]:
    """D12 for one state. all-hidden: every page renderer backgrounded. one-shown: at most `shown_pages` page
    renderers above background (which renderer holds which page is not reported yet). parked: the preload's
    renderer is hidden, so it is backgrounded too."""
    found = []
    for kind in PAGE_RENDERER_KINDS:
        row = rows.get(kind)
        if not row:
            continue
        above = row["n"] - row["backgrounded"]
        allowed = shown_pages if state == "one-shown" else 0
        if above > allowed:
            found.append(f"state={state} kind={kind} above_background={above} allowed={allowed} "
                         f"roles={','.join(f'{r}:{n}' for r, n in sorted(row['roles'].items()))}")
    return found


def page_renderers(instance) -> dict[int, str]:
    return {pid: kind for pid, cmd in instance.pids().items() if (kind := kind_of(cmd)) in PAGE_RENDERER_KINDS}


def backgrounded_or_gone(pid: int) -> bool:
    """A renderer that ended (a discard, a crash) holds no shown page either."""
    return procs.counters(pid) is None or procs.role_of(procs.thread_priorities(pid)) in procs.BACKGROUNDED_ROLES


def time_to(predicate, timeout_s: float, step_s: float = 0.02):
    """Milliseconds until `predicate()` holds, or None after `timeout_s` (bench poll, not app code)."""
    started = time.monotonic()
    while time.monotonic() - started < timeout_s:
        if predicate():
            return round((time.monotonic() - started) * 1000, 1)
        time.sleep(step_s)  # bench poll of the kernel's thread priorities
    return None


def measure_state(instance, state: str, window_s: float) -> dict:
    """Every process of the app in one state: role (read at the end of the window), QoS split, footprint, CPU
    and wakeups over `window_s`."""
    qos: dict[str, dict] = {}

    def during(seconds: float):
        qos["before"] = {pid: procs.qos_cpu_ns(pid) for pid in instance.pids()}
        time.sleep(seconds)  # bench: the measured window
        qos["after"] = {pid: procs.qos_cpu_ns(pid) for pid in instance.pids()}

    window = instance.window(window_s, during=during, per_pid=True)
    commands = instance.pids()
    processes = []
    for row in window.get("pids", []):
        pid = row["pid"]
        got = procs.counters(pid)
        name, share = top_qos(qos["before"].get(pid), qos["after"].get(pid))
        processes.append({"pid": pid, "kind": kind_of(commands.get(pid, "")) if pid in commands else row["kind"],
                          "role": procs.role_of(procs.thread_priorities(pid)), "qos": name, "qos_share": share,
                          "footprint_mb": round(got[3] / procs.MB, 1) if got else None,
                          "cpu_pct": row["cpu_pct"], "wakeups_per_s": row["wakeups_per_s"]})
    return {"state": state, "processes": processes, "kinds": kind_rows(processes)}


def print_state(engine: str, arm: str, result: dict, shown_pages: int) -> list[str]:
    for kind, row in sorted(result["kinds"].items()):
        roles = ",".join(f"{r}:{n}" for r, n in sorted(row["roles"].items()))
        qos = ",".join(f"{q}:{n}" for q, n in sorted(row["qos"].items())) or "-"
        print(f"PERF-WEBUI-PRIORITY engine={engine} arm={arm} state={result['state']} kind={kind} n={row['n']} "
              f"backgrounded={row['backgrounded']} roles={roles} qos={qos} footprint_mb={round(row['footprint_mb'], 1)} "
              f"cpu_pct={row['cpu_pct']} wakeups_per_s={row['wakeups_per_s']}", flush=True)
    found = breaches(result["state"], result["kinds"], shown_pages)
    for line in found:
        print(f"PERF-WEBUI-PRIORITY-OVER engine={engine} arm={arm} {line}", flush=True)
    return found


def purge_gain(base: dict, purge: dict) -> dict:
    """Page renderer footprint in all-hidden, base arm against the MemoryPurgeOnFreeze arm."""
    def footprint(result):
        kinds = result["kinds"]
        return round(sum(kinds[k]["footprint_mb"] for k in PAGE_RENDERER_KINDS if k in kinds), 1)
    before, after = footprint(base), footprint(purge)
    return {"base_mb": before, "purge_mb": after, "gain_mb": round(before - after, 1)}


class SessionShapeError(Exception):
    """The run cannot measure what it was asked to: a page did not open, or the engine is not there."""


def show(app, workspace: str):
    reply = app.action("goToWorkspace", workspace=workspace)
    if reply.get("error"):
        raise SessionShapeError(f"goToWorkspace {workspace}: {reply['error']}")


def new_workspace(app) -> str:
    made = app.run("workspace.newAtBottom")
    created = [item for item in made.get("created", []) if str(item).startswith("ws_")]
    if not created:
        raise SessionShapeError(f"workspace.newAtBottom: {made.get('error') or made}")
    return created[0]


def all_backgrounded(instance) -> bool:
    return all(backgrounded_or_gone(pid) for pid in page_renderers(instance))


def cycles(app, instance, pages_ws: str, terminal_ws: str, runs: int, timeout_s: float, gap_s: float) -> dict:
    """`runs` hide and show cycles: per page renderer the ms from the hide to backgrounded, and per show the ms
    until a page renderer leaves background (None when it did not within `timeout_s`)."""
    to_background, to_foreground = [], []
    for _ in range(runs):
        renderers = list(page_renderers(instance))
        show(app, terminal_ws)
        started = time.monotonic()
        for pid in renderers:
            waited = time.monotonic() - started
            rest = time_to(lambda pid=pid: backgrounded_or_gone(pid), max(timeout_s - waited, 0.0))
            to_background.append(None if rest is None else round(waited * 1000 + rest, 1))
        time.sleep(gap_s)  # bench: hidden long enough to freeze
        show(app, pages_ws)
        to_foreground.append(time_to(lambda: not all_backgrounded(instance), timeout_s))
        time.sleep(gap_s)  # bench: shown long enough to load and paint
    return {"to_background_ms": spread(to_background), "to_foreground_ms": spread(to_foreground)}


def run_arm(args, engine: str, arm: str, bm, bp) -> dict:
    """One launch: the three states, then the cycles. Raises SessionShapeError."""
    bundle = os.path.realpath(args.app)
    switches = [s for s in args.cef_switches.split(":") if s] + ([PURGE_SWITCH] if arm == "purge" else [])
    extra = {"CMUX_NEXT_CEF_EXTRA_SWITCHES": ":".join(switches)} if switches else {}
    if os.environ.get("CI_JOB_DIR"):  # the fleet worker finds the step's processes by this marker
        extra["CI_JOB_DIR"] = os.environ["CI_JOB_DIR"]
    bp.wipe_state(bundle)
    pid, sock, scratch = bm.launch(bundle, {"browser": {"defaultEngine": engine}}, extra)
    report = {"engine": engine, "arm": arm, "switches": switches, "states": {}, "over": []}
    states = report["states"]
    try:
        app = bm.App(bundle, sock)
        instance = procs.Instance(bundle, pid)
        if engine == "chromium":
            cef = bp.rpc(sock, "debug.cef") or {}
            if cef.get("error") or cef.get("unavailable") or cef.get("fallback"):
                raise SessionShapeError(f"Chromium is not available: {json.dumps(cef)[:300]}")
        time.sleep(args.settle)  # bench: launch work and the preload settle
        states["parked"] = measure_state(instance, "parked", args.window)
        report["over"] += print_state(engine, arm, states["parked"], 0)
        pages_ws, terminal_ws = new_workspace(app), new_workspace(app)
        show(app, pages_ws)
        for name in args.pages:
            action = PAGES[name]
            reply = app.action(action, focus=True)
            if reply.get("error"):
                raise SessionShapeError(f"{action}: {reply['error']}")
        time.sleep(args.settle)  # bench: the pages load and paint
        expected = "renderer" if engine == "chromium" else "webkit-webcontent"
        if expected not in page_renderers(instance).values():
            raise SessionShapeError(f"{len(args.pages)} pages opened with browser.defaultEngine={engine} "
                                    f"but no {expected} process runs")
        states["one-shown"] = measure_state(instance, "one-shown", args.window)
        report["over"] += print_state(engine, arm, states["one-shown"], 1)
        show(app, terminal_ws)
        hidden_at = time.monotonic()
        report["first_background_ms"] = time_to(lambda: all_backgrounded(instance), args.background_ms / 1000)
        if report["first_background_ms"] is None:
            line = f"state=all-hidden page renderers not backgrounded within {args.background_ms} ms"
            print(f"PERF-WEBUI-PRIORITY-OVER engine={engine} arm={arm} {line}", flush=True)
            report["over"].append(line)
        time.sleep(max(args.settle - (time.monotonic() - hidden_at), 0))  # bench: hidden long enough to freeze
        states["all-hidden"] = measure_state(instance, "all-hidden", args.window)
        report["over"] += print_state(engine, arm, states["all-hidden"], 0)
        if args.runs:
            show(app, pages_ws)
            time.sleep(args.cycle_gap)  # bench: the pages show again before the first cycle
            report["cycles"] = cycles(app, instance, pages_ws, terminal_ws, args.runs, args.cycle_timeout, args.cycle_gap)
            for phase, values in report["cycles"].items():
                print(f"PERF-WEBUI-PRIORITY-CYCLE engine={engine} arm={arm} phase={phase} n={values['n']} "
                      f"landed={values['landed']} p50={values['p50']} p95={values['p95']} p99={values['p99']} "
                      f"max={values['max']}", flush=True)
    finally:
        try:
            bm.App(bundle, sock).run("quit")
            bm.wait_gone(pid, 20)
        except Exception as error:  # noqa: BLE001  the quit failed; end_bundle ends the processes
            print(f"   quit: {error}", file=sys.stderr)
        bm.end_bundle(bundle)
        shutil.rmtree(scratch, ignore_errors=True)
        bp.wipe_state(bundle)
    return report


def main(args) -> int:
    """Every engine, then the purge arm on Chromium. Exit 1 on a bad session shape; breaches are printed and
    written to --out, not an exit status (agents read them; no CI gate)."""
    unknown = [name for name in args.pages if name not in PAGES]
    if unknown or not args.pages:
        raise SystemExit(f"bench-webui priority-roles: --pages takes {','.join(PAGES)} (got {unknown or 'none'})")
    if sys.platform != "darwin":
        raise SystemExit("bench-webui priority-roles: macOS only (a fleet GUI mini, never a laptop)")
    import bench_memory as bm  # macOS only: loads libproc at import
    import bench_power as bp
    engines = ["chromium", "webkit"] if args.engine == "both" else [args.engine]
    report = {"mode": "priority-roles", "app": os.path.realpath(args.app), "pages": args.pages, "arms": []}
    status = 0
    try:
        for engine in engines:
            report["arms"].append(run_arm(args, engine, "base", bm, bp))
        if args.purge_arm and "chromium" in engines:
            report["arms"].append(run_arm(args, "chromium", "purge", bm, bp))
            base = next(arm for arm in report["arms"] if arm["engine"] == "chromium" and arm["arm"] == "base")
            gain = purge_gain(base["states"]["all-hidden"], report["arms"][-1]["states"]["all-hidden"])
            report["purge"] = gain
            print(f"PERF-WEBUI-PURGE state=all-hidden page_renderer_footprint_base_mb={gain['base_mb']} "
                  f"purge_mb={gain['purge_mb']} gain_mb={gain['gain_mb']}", flush=True)
    except SessionShapeError as error:
        print(f"bench-webui priority-roles: {error}", file=sys.stderr)
        status = 1
    finally:
        if args.out:
            with open(args.out, "w") as handle:
                json.dump(report, handle, indent=1)
    return status


def add_arguments(parser):
    parser.add_argument("--app", required=True, help="a tagged DEV build (its state is wiped before and after)")
    parser.add_argument("--engine", choices=("chromium", "webkit", "both"), default="both")
    parser.add_argument("--pages", type=lambda text: [p for p in text.split(",") if p], default=["settings", "history"],
                        help=f"comma list of {','.join(PAGES)}; the last one stays shown")
    parser.add_argument("--settle", type=float, default=30, help="seconds before each state is measured")
    parser.add_argument("--window", type=float, default=10, help="seconds of CPU, wakeups and QoS per state")
    parser.add_argument("--background-ms", type=float, default=1000, help="D12: hidden page renderers backgrounded within")
    parser.add_argument("--runs", type=int, default=5, help="hide and show cycles for the percentiles")
    parser.add_argument("--cycle-gap", type=float, default=12, help="seconds hidden and shown in each cycle")
    parser.add_argument("--cycle-timeout", type=float, default=5, help="seconds a cycle waits for a role change")
    parser.add_argument("--purge-arm", action="store_true", help="launch again with MemoryPurgeOnFreeze (DEBUG build)")
    parser.add_argument("--cef-switches", default="", help="more Chromium switches, colon-separated (DEBUG build)")
    parser.add_argument("--out", help="JSON report")
