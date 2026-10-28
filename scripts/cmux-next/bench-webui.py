#!/usr/bin/env python3
"""WebUI bench (plans/cmux-next/chrome-parity/p13-webui.md, section 5): the done checks D1-D6 and D12 of cmux's own
web pages, as a thin driver over the benches that already count and time them. It adds no process counting and no
launch of its own:

  launch, socket, teardown   bench_launch.BenchApp (the one launch path of GUI benches)
  processes, CPU, wakeups,   scripts/perf-bench/procs.py Instance: every process of the run (WebKit processes the
  footprint                  app is responsible for too), its rusage counters (the same counters bench-idle.sh
                             reads through bench_idle.py), per kind
  renderers of browser tabs  bench_renderer_sharing.renderer_map (the app's `resources` report)
  a page that answers        bench-pages.py react_view (`debug.page`, controls > 0) and its PAGES tunables
  STRESS                     perf-stress-session.py Stress (--session stress) and its cef_problems
  percentiles                scripts/perf-lab/perf_stats.py summary (p50, p95, p99, max)

Modes (each prints `WEBUI-ROW` lines, one per row, and writes OUT/webui-<mode>.json):

  home      D1/D2. Home (home.show) after --settle s, then a --measure s window: WebKit WebContent and CEF process
            counts, Chromium renderers apart from extension renderers (tab_pages.process_type_kind), whole-tree
            footprint, web helper CPU and wakeups/s (WebContent alone for D2), `debug.wakeups` owners of pages,
            the preload and spares. Each row names its section 5 tier (pinned or train).
  pages10   D3. Opens settings, history, cloud, apps, keybindings, files, diff, markdown, editor and chief-usage (the
            last one shown), then: renderers that hold no browser tab, DevTools on page renderers (`unscored` on
            fork < 29: clicks use DevTools there), frozen pages --hide-settle s after hiding, the delivery window
            (below), discarded pages and footprint at --discard-settle s against the one-page footprint, then
            each discarded page shown again by its action (up to --runs): key to the turn that drew its hide-time
            snapshot and to its restored document's first frame (`debug.page` `restore`, D4's discarded rows).
            With --every-page-hidden (task 037, MQ5): the ten pages open, a terminal tab hides the last one too, and
            after --hide-settle s a --measure s window reads the interrupt wakeups/s of each page renderer (its
            pages and their states in the note) and of the GPU process. The app runs with browser.freezeHiddenTabs
            "off", so the pages stay hidden and running; a renderer whose page froze or ended is unscored, and so is
            the verdict then. A renderer above 0.2/s names the pages whose self-rescheduling requestAnimationFrame
            loops move to usePageAnimationFrame; none above it and none unscored, none moves.
  open      D4, light or STRESS. Cmd-T into the preloaded New Tab (`debug.new_tab bench_open`: key turn, cover
            frame = `visible_ms`) and its Cmd-W; Cmd-, Settings warm (--runs) and cold (the first open and
            --cold-runs opens after its renderer was killed), timed on the app's uptime clock from the key's
            `debug.action_budget` start to the page's `debug.page` painted_uptime, and its Cmd-W (with the engine
            page closes `debug.webui` `retire` stamps in the key's turn); a frozen chat of --chat-turns turns
            shown again --runs times. D4 rows with no app signal yet print `unscored`.
  crash     D5. 5 privileged pages, 1 shown; kill -9 of the shown page's renderer --kills times: cmux survives, the
            shown page paints again (until the group cap, 3 per 600 s), hidden pages do not reload.
  pressure  D6. A browser tab and a chat, then pages; `debug.hibernation.pressure critical` (the memory coordinator's
            override, which every web object follows): the preload slot right after, renderers once discards
            settle. The override is cleared (`none`) at the end.
  priority  D12. Page renderers (or WebContent processes) with every page hidden: backgrounded (`ps` priority <= 4,
            darwinbg) within --priority-wait s.
  priority-roles
            D12 in depth (task 083, bench_webui_priority.py, its own launch and options): per engine, the scheduling
            role (thread base priority and ceiling), the QoS class that ran the CPU, footprint, CPU and wakeups of
            every process kind while pages are parked, one shown and all hidden; the p50 to max time from a switch
            to each page renderer backgrounded and back; with --purge-arm, Blink's MemoryPurgeOnFreeze arm and its
            page renderer footprint gain. Prints PERF-WEBUI-PRIORITY(-OVER) and PERF-WEBUI-PURGE; --out is a file.
  delivery  D3's delivery rows alone: events and native pushes to frozen pages over --measure s while
            `debug.webui publish` drives one stream per page at 10 Hz and the appearance toggles every second.
  push      Task 079's A/B (the page push channel, feature `pagePushChannel`, fork API 43): the ten pages open,
            and over --measure s each gets --push-hz host calls a second (`debug.page ping`, answered
            `unknown_op`). Rows: the call's round trip (p50 to p99, the delivery into the page plus the same reply
            path in both arms), page renderer CPU per 1,000 deliveries, and the deliveries the census counted as
            scripts and as data. Run it with and without `--enable-feature pagePushChannel` on one host and one
            build; the push channel lands only with a gain beyond the off arm's spread. The run turns
            `browser.freezeHiddenTabs` off: a frozen page would thaw at each call.
  park      Spike 090, light or STRESS, one variant per run (--park frozen or rendered, set through the debug
            tunable webui.preloadPark): the census must show the New Tab preload parked as asked (frozen: census
            state `frozen`; rendered: `hidden` with `engine_visible` false), else every row is `unscored`. Then the
            preload's renderer (WebContent with --engine webkit) wakeups/s over --measure 1 s windows, its
            `debug.wakeups` owners, and --runs Cmd-T opens, each from a preload parked as asked: key turn, key to the
            cover frame (`visible_ms`), key to the live frame (`live_ms`: the first frame the page painted after
            its show, when the cover goes) and the display refresh (the targets are 120 Hz frames).

Spike 090's table (plans/cmux-next/webui-DESIGN.md section 5) comes from the park runs' reports, on any machine:
  python3 scripts/cmux-next/bench-webui.py park-table --run JOB_ID OUT/park/webui-park.json [--run JOB_ID FILE ...]
It prints one Markdown row per report (p50/p95/p99/max of cover, live and parked wakeups, sha, host, job id), then
the park state the decision rule picks and the D4 live-frame targets written from it (``park_decision``).

The page census is `debug.webui` (task 001). A build without it (the base of the program) gets `unscored` for the
census rows and still measures the process rows. Keys read, per row of its `rows` list: `row` (page, spare or
process), `page`, `engine`, `group`, `state` (active, hidden, frozen, discarded, crashed), `keep_reasons`,
`renderer_pid`, `webkit_pid`, `hidden_deliveries`, `hidden_pushes`, `devtools`, `spare_kind`, `pid`,
`process_kind` (renderer, extension, utility, gpu), `reloads`. Task 001's report (`pages`, `spares`, `processes`)
is read into the same rows (``Census.from_report``). Change them in ``Census`` only. The `publish` and `pressure`
verbs count only when their reply confirms them; else their rows are `unscored`, never a pass with no load.

--page-code-cache (task 052's A/B, Debug development bundles): the app starts Chromium with the code cache spike's
switches (manaflow-ai/cef cp/p13-webui-052: cmux-page scripts get V8's code cache, in memory for the pages profile,
as Chrome's WebUICodeCache gives chrome: scripts). Run `open` with and without it on one host, one build: the cold
Settings row decides and the warm row is the control (webui-DESIGN.md 5.4). Every Chromium renderer must carry the switch; a
run whose renderers do not (a bench or Release build drops CMUX_NEXT_CEF_EXTRA_SWITCHES, or the fork lacks the spike)
is refused (exit 2): before the mode, once the first Settings open has its renderer (none then is refused too) and
at the end, where `page_code_cache.renderers_with_switch` counts them.

Session shapes (refused, exit 2, never measured as the shape asked): light is one window, no browser tab and no
chat before the mode starts, every page the mode opens live, one page shown when the mode shows one; STRESS is
perf-stress-session.py's check. With --engine chromium, `debug.cef` must show Chromium available with no WebKit
fallback. Timings are measured, never compared to a budget for an exit status: targets print beside the values
(section 5) and the exit is 0 unless the run itself failed.

Run on a GUI fleet host, never a laptop:
  python3 scripts/cmux-next/bench-webui.py home --app BUNDLE --engine chromium --settle 60 [--out DIR]
  scripts/measure/webui-bench.sh (the fleet entry: builds the tag first)
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
MODES = ("home", "pages10", "open", "crash", "pressure", "priority", "delivery", "push", "park")
# Modes with their own module, launch path and options: {mode: module file in HERE}.
MODULE_MODES = {"priority-roles": "bench_webui_priority"}
# Spike 090: the preload's park state, chosen per run through this debug tunable (the preload owner reads it).
PARK_STATES = ("frozen", "rendered")
PARK_TUNABLE = "webui.preloadPark"
FRAME_120HZ_MS = 1000 / 120  # the spike's unit: D4 targets are whole frames of a 120 Hz display
LIVE_CEILING_MS = 50  # D4: the live-frame target is never worse than this p95, whatever the spike measures
# D3's ten pages: (page id, the action that opens it, its arguments; "{md}" and "{txt}" are scratch files).
PAGES10 = [("cmux.settings", "openSettings", {}), ("cmux.history", "history.show", {}),
           ("cmux.cloud", "palette.openCloudPane", {}), ("cmux.apps", "appStore.show", {}),
           ("cmux.keybindings", "keybindings.open", {}), ("cmux.files", "files.open", {}),
           ("cmux.diff", "openDiffViewer", {"path": ROOT}), ("cmux.markdown", "openMarkdownFile", {"path": "{md}"}),
           ("cmux.editor", "file.open", {"path": "{txt}"}), ("cmux.chief-usage", "chief.openUsage", {})]
PRIVILEGED5 = PAGES10[:5]  # one capability group (section 3.B): the crash, pressure and priority sessions
WEB_KINDS = ("renderer", "gpu", "helper")  # procs.kind_of names of CEF processes; utility:* and webkit-* by prefix
GPU_KINDS = ("gpu", "webkit-gpu")  # procs.kind_of names of the CEF and the WebKit GPU process
HIDDEN_WAKEUPS_PER_S = 0.2  # MQ5's bound for a hidden page's renderer and the GPU (D2's WebContent bound)
BACKGROUND_PRI = 4  # `ps -o pri` of a darwinbg task: Chrome backgrounds a hidden renderer so (base/process/process_mac.cc)
GROUP_CAP = 3  # crash budget per group in 600 s (section 3.C)
PUSH_FEATURE = "pagePushChannel"  # task 079's default-off feature
PUSH_FORK_API = 43  # CEFForkFeatures.pagePushForkAPI
LATENCY_STEP = 0.005  # s between polls of a timed wait (bench-pages.py polls at 10 ms); setup waits poll at 50 ms
# s after a Cmd-W's start that count as its turn and frames for engine page closes; PageRetirer.delay (500 ms) is later.
CLOSE_TURN_WINDOW = 0.25
# Task 052's spike switches (CMUX_NEXT_CEF_EXTRA_SWITCHES, colon-separated): the fork copies the first to every renderer.
CODE_CACHE_SWITCHES = ("cmux-code-cache-schemes=cmux-page", "enable-features=WebUICodeCache")
CODE_CACHE_MARK = "--" + CODE_CACHE_SWITCHES[0]


def host_uptime():
    """Seconds on the clock of the app's `painted_uptime` (ProcessInfo.systemUptime) and `start_uptime_ns`
    (CLOCK_UPTIME_RAW): both are mach_absolute_time, so app timestamps and this one subtract."""
    return time.clock_gettime(time.CLOCK_UPTIME_RAW) if hasattr(time, "CLOCK_UPTIME_RAW") else time.monotonic()


def load(name, path):
    """The module at `path` (python3 -I puts no script folder on sys.path), loaded once."""
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    argv, sys.argv = sys.argv, sys.argv[:1]  # bench-pages.py reads sys.argv while it loads bench-stalls.py
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[name]
        raise
    finally:
        sys.argv = argv
    return module


stats = load("perf_stats", os.path.join(ROOT, "scripts/perf-lab/perf_stats.py"))
stress_session = load("perf_stress_session", os.path.join(HERE, "perf-stress-session.py"))


class ShapeError(RuntimeError):
    """The session is not the shape the mode measures."""


# ---------------------------------------------------------------- rows

OPS = {"<=": lambda a, b: a <= b, "==": lambda a, b: a == b, ">=": lambda a, b: a >= b}


def row(name, value, target=None, unit="", note="", tier=""):
    """One result row. `value` is a number, a perf_stats summary, or None (unscored, `note` says why). `target` is
    (op, bound) for a number or (stat, op, bound) for a summary; it is printed and marked, never an exit status.
    `tier` is section 5's `pinned` (must pass on the pinned fork) or `train` (needs the fork train dist), or empty."""
    status = "info"
    if value is None:
        status = "unscored"
    elif target:
        stat, op, bound = target if len(target) == 3 else (None, *target)
        measured = value.get(stat) if isinstance(value, dict) else value
        status = "unscored" if measured is None else ("met" if OPS[op](measured, bound) else "missed")
        if status == "met" and isinstance(value, dict) and value.get("missed"):
            status = "missed"  # a sample that never finished never prints met
    return {"name": name, "value": value, "target": list(target) if target else None, "unit": unit,
            "status": status, "note": note, "tier": tier}


def series(name, values, target=None, unit="ms", note="", tier=""):
    """A latency row: the percentiles of `values`. A None entry is a sample that never finished: it is counted in
    `missed` and makes a scored row `missed`."""
    timed = [v for v in values if isinstance(v, (int, float))]
    summary = stats.summary(timed)
    summary["missed"] = len(values) - len(timed)
    if not timed:
        entry = row(name, None, target, unit, note or ("no sample finished" if values else "no sample"), tier)
        if values and target:
            entry.update(value=summary, status="missed")  # every sample timed out
        return entry
    return row(name, summary, target, unit, note, tier)


def line(mode, entry):
    value = entry["value"]
    if isinstance(value, dict):
        shown = " ".join(f"{k}={_fmt(value.get(k))}" for k in ("n", "p50", "p95", "p99", "max", "missed"))
    else:
        shown = f"value={_fmt(value)}"
    target = "".join(str(part) for part in entry["target"]) if entry["target"] else "-"
    tier = f" tier={entry['tier']}" if entry.get("tier") else ""
    note = f" note={json.dumps(entry['note'])}" if entry["note"] else ""
    return (f"WEBUI-ROW mode={mode} row={entry['name']} {shown} unit={entry['unit'] or '-'} target={target}{tier} "
            f"status={entry['status']}{note}")


def _fmt(value):
    return f"{value:.3f}".rstrip("0").rstrip(".") if isinstance(value, float) else json.dumps(value)


# ---------------------------------------------------------------- the census (debug.webui, task 001)


class Census:
    def __init__(self, rows):
        self.rows = rows

    @classmethod
    def read(cls, rpc):
        """The census now, or None when the build has no `debug.webui`."""
        reply = rpc("debug.webui")
        if not isinstance(reply, dict) or reply.get("error"):
            return None
        if isinstance(reply.get("rows"), list):
            return cls([r for r in reply["rows"] if isinstance(r, dict)])
        if isinstance(reply.get("pages"), list):
            return cls(cls.from_report(reply))
        return None

    @staticmethod
    def from_report(reply):
        """Task 001's report (`pages`, `spares`, `processes`; keys in CmuxNextPages/WebUI/WebUICensus.swift) as rows:
        a `visible` page is `active`, its first renderer pid is `renderer_pid`, a parked page is a spare row."""
        rows = []
        for page in (p for p in reply.get("pages") or [] if isinstance(p, dict)):
            pid = next(iter(page.get("renderer_pids") or []), None)
            if page.get("spare"):
                rows.append({"row": "spare", "spare_kind": "preload" if page["spare"] == "new_tab" else page["spare"],
                             "state": page.get("state"), "engine_visible": page.get("engine_visible"),
                             "renderer_pid": pid, "webkit_pid": page.get("webkit_pid")})
                continue
            rows.append({"row": "page", "page": page.get("page"), "engine": page.get("engine"), "group": page.get("group"),
                         "state": "active" if page.get("state") == "visible" else page.get("state"),
                         "keep_reasons": [r for r in page.get("keep_reasons") or [] if r != "visible"],
                         "renderer_pid": pid, "webkit_pid": page.get("webkit_pid"),
                         "hidden_deliveries": page.get("deliveries_while_hidden"),
                         "hidden_pushes": page.get("pushes_while_hidden"),
                         "script_deliveries": page.get("script_deliveries"),
                         "data_deliveries": page.get("data_deliveries")})
        for spare in (s for s in reply.get("spares") or [] if isinstance(s, dict)):
            rows.append({"row": "spare", "spare_kind": "preload" if spare.get("spare") == "new_tab" else spare.get("spare"),
                         "state": spare.get("state"), "renderer_pid": next(iter(spare.get("renderer_pids") or []), None),
                         "webkit_pid": spare.get("webkit_pid")})
        for process in (p for p in reply.get("processes") or [] if isinstance(p, dict)):
            kind = process.get("kind")
            rows.append({"row": "process", "pid": process.get("pid"),
                         "process_kind": "extension" if kind == "extension_renderer" else kind})
        return rows

    def pages(self, *states):
        return [r for r in self.rows if r.get("row") == "page" and (not states or r.get("state") in states)]

    def page(self, page_id):
        return next((r for r in self.pages() if r.get("page") == page_id), None)

    def processes(self, kind):
        return [r for r in self.rows if r.get("row") == "process" and r.get("process_kind") == kind]

    def spares(self, kind=None):
        return [r for r in self.rows if r.get("row") == "spare" and (kind is None or r.get("spare_kind") == kind)]

    @staticmethod
    def pid(page):
        return page.get("renderer_pid") or page.get("webkit_pid")

    def renderers(self):
        """{renderer or WebContent pid: [page ids]} of the live pages."""
        owners = {}
        for page in self.pages("active", "hidden", "frozen"):
            if self.pid(page):
                owners.setdefault(self.pid(page), []).append(page.get("page"))
        return owners

    def hidden_traffic(self):
        """{page id: events delivered + native pushes while hidden} of the frozen pages."""
        return {p.get("page"): int(p.get("hidden_deliveries") or 0) + int(p.get("hidden_pushes") or 0)
                for p in self.pages("frozen")}


def park_state(spare):
    """How a preload row is parked: `frozen` (frozen-hidden), `rendered` (rendered-parked: the engine was told it is
    hidden, so its JS sees `visibilitychange` and pauses, and it keeps its rendered frame), `visible` (its engine
    still thinks it is shown, as NewTabSparePool's spare at the program's base), or None when the row does not say."""
    if spare.get("state") == "frozen":
        return "frozen"
    if spare.get("engine_visible") is True:
        return "visible"
    if spare.get("engine_visible") is False and spare.get("state") == "hidden":
        return "rendered"
    return None


# ---------------------------------------------------------------- shapes


def light_problems(topology):
    """Why `snapshot.get`'s topology is not the light session's start: one window, no browser tab, no chat."""
    problems = []
    windows = topology.get("windows") or []
    if len(windows) != 1:
        problems.append(f"{len(windows)} windows, not 1")
    tabs = [t for w in topology.get("workspaces") or [] for p in stress_session.Stress.panes(w) for t in p.get("tabs") or []]
    for kind in ("browser", "conversation"):
        count = sum(1 for t in tabs if t.get("kind") == kind)
        if count:
            problems.append(f"{count} {kind} tabs before the bench (a restored session)")
    return problems


def engine_problems(cef, engine, mode):
    """With --engine chromium: perf-stress-session.py's cef_problems. Home may not have started Chromium yet."""
    if engine != "chromium":
        return []
    problems = stress_session.cef_problems(cef)
    return [p for p in problems if not (mode == "home" and p.startswith("Chromium state"))]


def read_priorities(pids):
    """{pid: scheduling priority} from one `ps` call (not a process count: the pids come from the census or procs)."""
    if not pids:
        return {}
    out = subprocess.run(["ps", "-o", "pid=,pri=", "-p", ",".join(str(p) for p in pids)],
                         capture_output=True, text=True).stdout
    found = {}
    for text in out.splitlines():
        parts = text.split()
        if len(parts) == 2 and parts[0].isdigit() and parts[1].lstrip("-").isdigit():
            found[int(parts[0])] = int(parts[1])
    return found


# ---------------------------------------------------------------- the bench


class Bench:
    """One mode against a running app. Every seam is injected: `rpc(method, params, timeout)` (a result or
    {"error": ...}), `instance` (procs.Instance: pids, memory, window), `browser_renderers()` (pids that hold a
    browser tab), `kind_of(cmd)` (procs.kind_of), `type_kind(cmd)` (tab_pages.process_type_kind: cef-renderer apart
    from cef-extension), `kill(pid, signal)`, `alive()`, `priorities(pids)`, `react_view` (bench-pages.py), `clock`
    (sleep, monotonic) and `uptime()` (seconds on the app's uptime clock; defaults to `clock.uptime`, else
    host_uptime)."""

    def __init__(self, opts, rpc, instance, browser_renderers, kind_of, react_view, alive, kill=os.kill,
                 priorities=read_priorities, clock=time, log=None, type_kind=None, uptime=None):
        self.opts, self.rpc, self.instance = opts, rpc, instance
        self.browser_renderers, self.kind_of, self.react_view = browser_renderers, kind_of, react_view
        self.alive, self.kill, self.priorities, self.clock = alive, kill, priorities, clock
        self.type_kind = type_kind or (lambda cmd: None)
        self.uptime = uptime or getattr(clock, "uptime", None) or host_uptime
        self.log = log or (lambda text: print(text, flush=True))
        self.rows, self.facts = [], {}
        scratch = tempfile.mkdtemp(prefix="bench-webui-")
        self.files = {"{md}": os.path.join(scratch, "page.md"), "{txt}": os.path.join(scratch, "page.txt")}
        for path, text in zip(self.files.values(), ("# WebUI bench\n\nA markdown page.\n", "WebUI bench editor page\n")):
            with open(path, "w") as handle:
                handle.write(text)

    # Waits: `settle` is the only sleep that is not a bounded poll of app state.

    def settle(self, seconds, why, quiet=False):
        if seconds > 0:
            if not quiet:
                self.log(f"bench-webui: settle {seconds:g} s ({why})")
            self.clock.sleep(seconds)  # bench: a named settle phase (--settle, --hide-settle, --discard-settle)

    def until(self, predicate, seconds, step=0.05):
        deadline = self.clock.monotonic() + seconds
        while True:
            value = predicate()
            if value or self.clock.monotonic() >= deadline:
                return value
            self.clock.sleep(step)  # bench: a bounded poll of the app's reported state

    def add(self, *entries):
        self.rows.extend(entries)

    # App helpers.

    def action(self, name, args=None, target=None, setup=True):
        params = {"action": name, "args": args or {}, "focus": True, "origin": "script"}
        if target:
            params["target"] = target
        reply = self.rpc("action.run", params, timeout=60)
        if setup and isinstance(reply, dict) and reply.get("error"):
            raise ShapeError(f"{name} was refused: {str(reply['error'])[:200]}")
        return reply

    def census(self):
        return Census.read(self.rpc)

    def live(self, page_id):
        """Whether a page of `page_id` that is not a parked spare is live (`debug.page list`)."""
        reply = self.rpc("debug.page", {"page": page_id, "action": "list"})
        pages = reply.get("pages") if isinstance(reply, dict) else None
        return any(isinstance(p, dict) and not p.get("parked") for p in pages or [])

    def painted(self, page_id):
        state = self.rpc("debug.page", {"page": page_id})
        return isinstance(state, dict) and not state.get("error") and state.get("painted") is True

    def open_pages(self, pages):
        for page_id, name, args in pages:
            self.action(name, {k: self.files.get(v, v) for k, v in args.items()})
            if not self.until(lambda: self.live(page_id), self.opts.open_timeout):
                raise ShapeError(f"{name} opened no {page_id} page in {self.opts.open_timeout:g} s")
        shown = pages[-1][0]
        self.until(lambda: self.painted(shown), self.opts.open_timeout)
        opened = {page_id for page_id, _, _ in pages}

        def shown_only():
            census = self.census()
            return census is None or [p.get("page") for p in census.pages("active") if p.get("page") in opened] == [shown]

        if not self.until(shown_only, self.opts.open_timeout):
            active = [p.get("page") for p in (self.census() or Census([])).pages("active")]
            raise ShapeError(f"shown pages {active}, not [{shown}]")
        return shown

    def hide_pages(self):
        """A terminal tab in the focused pane: no page is shown."""
        self.action("newSurface")
        if not self.until(lambda: not (self.census() or Census([])).pages("active"), self.opts.open_timeout):
            active = [p.get("page") for p in (self.census() or Census([])).pages("active")]
            raise ShapeError(f"pages still shown after the terminal tab: {active}")

    def page_renderers(self, census=None):
        """{pid: [page ids or "?"]}: the census's, else every Chromium renderer that holds no browser tab (with
        --engine webkit, every WebContent process) from procs."""
        if census is not None:
            return census.renderers()
        browser = self.browser_renderers()
        want = "webkit-webcontent" if self.opts.engine == "webkit" else "renderer"
        return {pid: ["?"] for pid, cmd in self.instance.pids().items() if self.kind_of(cmd) == want and pid not in browser}

    def fork_api(self):
        cef = self.rpc("debug.cef")
        return int(cef.get("fork_api") or 0) if isinstance(cef, dict) else 0

    def code_cache_renderers(self):
        """(Chromium renderers apart from extension renderers, how many of them carry task 052's switch)."""
        commands = [cmd for cmd in self.instance.pids().values() if self.type_kind(cmd) == "cef-renderer"]
        return len(commands), sum(CODE_CACHE_MARK in cmd for cmd in commands)

    def check_code_cache_arm(self, when, need_renderer=False):
        """--page-code-cache: refused when a renderer runs without the switch (the A/B would measure the off arm
        twice), and with `need_renderer` when no renderer runs (the switch was never seen)."""
        renderers, switched = self.code_cache_renderers()
        if need_renderer and not renderers:
            raise ShapeError(f"--page-code-cache: no Chromium renderer {when}, so no renderer shows the switch")
        if switched < renderers:
            raise ShapeError(f"--page-code-cache: {renderers - switched} of {renderers} Chromium renderers lack "
                             f"{CODE_CACHE_MARK} {when} (a Debug development bundle reads CMUX_NEXT_CEF_EXTRA_SWITCHES; "
                             "the fork needs manaflow-ai/cef cp/p13-webui-052)")

    def code_cache_row(self):
        """The end of an on-arm run: a renderer that started without the switch during the mode refuses the run."""
        renderers, switched = self.code_cache_renderers()
        self.add(row("page_code_cache.renderers_with_switch", switched if renderers else None, ("==", renderers),
                     note=f"{renderers} Chromium renderers at the end of the run" if renderers
                     else "no Chromium renderer at the end of the run"))
        self.check_code_cache_arm("at the end of the run")

    def check_engine(self, mode):
        problems = engine_problems(self.rpc("debug.cef"), self.opts.engine, mode)
        if problems:
            raise ShapeError("Chromium is not the page engine: " + "; ".join(problems))

    # The modes.

    def home(self):
        self.action("home.show")
        self.settle(self.opts.settle, "Home idle")
        self.check_engine("home")
        window = self.instance.window(self.opts.measure, per_pid=True)
        memory = self.instance.memory()
        types = [self.type_kind(cmd) for cmd in self.instance.pids().values()]
        kinds = window.get("kinds") or {}
        count = lambda test: sum(int(entry.get("n", 0)) for kind, entry in kinds.items() if test(kind))  # noqa: E731
        total = lambda key, test: sum(e.get(key) or 0 for k, e in kinds.items() if test(k))  # noqa: E731
        web = lambda kind: kind in WEB_KINDS or kind.startswith(("utility:", "webkit-"))  # noqa: E731
        cef = lambda kind: kind in WEB_KINDS or kind.startswith("utility:")  # noqa: E731
        webcontent = lambda kind: kind == "webkit-webcontent"  # noqa: E731
        census = self.census()
        chromium = self.opts.engine == "chromium"
        cpu = round(total("cpu_pct", web), 3)
        # D1 (Chromium) mixes pinned and train rows; D2 (WebKit) is pinned throughout.
        d1 = lambda tier: tier if chromium else "pinned"  # noqa: E731
        self.add(row("webcontent_processes", count(webcontent), ("==", 0) if chromium else ("<=", 1), tier="pinned"),
                 row("cef_processes", count(cef), None if chromium else ("==", 0), tier="" if chromium else "pinned"),
                 row("chromium_renderers", types.count("cef-renderer"), ("==", 1) if chromium else ("==", 0), tier=d1("train"),
                     note="--type=renderer without --extension-process (tab_pages.process_type_kind)"),
                 row("extension_renderers", types.count("cef-extension"), ("==", 0), tier="pinned"),
                 row("footprint_mb", memory.get("mb"), ("<=", 250) if chromium else ("<=", 150), "MB", tier=d1("train")),
                 row("web_helper_cpu_pct", cpu, ("<=", 0.3) if chromium else None, "%", tier="pinned" if chromium else ""))
        if chromium:
            self.add(row("web_helper_cpu_pct_train", cpu, ("<=", 0.05), "%", tier="train"),
                     row("web_helper_wakeups_per_s", round(total("wakeups_per_s", web), 2), ("<=", 1.0), "/s", tier="train"))
        else:
            self.add(row("webcontent_wakeups_per_s", round(total("wakeups_per_s", webcontent), 2), ("<=", 0.2), "/s",
                         tier="pinned", note="WebContent processes only"),
                     row("web_helper_wakeups_per_s", round(total("wakeups_per_s", web), 2), unit="/s",
                         note="info: every WebKit and CEF helper"))
        self.add(self.page_wakeups_row("page_preload_spare_wakeups_per_s"))
        preload = census.spares("preload") if census is not None else []
        park = self.opts.park or "frozen"  # the park state the run asked for (spike 090), frozen by default
        self.add(row(f"preload_{park}", int(all(park_state(s) == park for s in preload)) if preload else None, ("==", 1),
                     tier="pinned" if chromium else "",
                     note="" if preload else "no preload row" if census else "no debug.webui in this build"))
        self.facts.update(window=window, memory=memory)

    def page_wakeups_row(self, name):
        """The app's wakeups/s owned by pages, the preload and spares (`debug.wakeups` ledger); unscored, never 0,
        when the ledger cannot be read."""
        reply = self.rpc("debug.wakeups", timeout=30)
        ledger = reply.get("ledger") if isinstance(reply, dict) and not reply.get("error") else None
        if not isinstance(ledger, list):
            return row(name, None, ("==", 0), "/s", tier="train", note=f"debug.wakeups gave no ledger: {json.dumps(reply)[:120]}")
        owners = [e for e in ledger if isinstance(e, dict)
                  and any(word in str(e.get("owner", "")).lower() for word in ("page", "preload", "spare"))]
        return row(name, round(sum(e.get("per_second", 0) for e in owners), 2), ("==", 0), "/s", tier="train",
                   note=", ".join(f"{e.get('owner')}:{e.get('reason')}" for e in owners[:6]))

    def pages10(self, discard=True):
        if self.opts.every_page_hidden:
            return self.hidden_wakeups()
        first = PAGES10[0][0]
        self.open_pages(PAGES10[:1])
        self.settle(self.opts.hide_settle, "one page")
        one_page = self.instance.memory().get("mb")
        self.open_pages(PAGES10[1:])
        self.check_engine("pages10")
        census = self.census()
        renderers = self.page_renderers(census)
        self.add(row("page_renderers", len(renderers), ("<=", 4), tier="pinned" if self.opts.engine == "webkit" else "train",
                     note="" if census else "renderers holding no browser tab (no debug.webui in this build)"))
        api = self.fork_api()
        self.add(row("devtools_on_page_renderers",
                     None if census is None or api < 29 else sum(1 for p in census.pages() if p.get("devtools")), ("==", 0),
                     tier="train",
                     note="" if census and api >= 29 else f"fork api {api} < 29: clicks use DevTools" if census else "no debug.webui"))
        hidden_at = self.clock.monotonic()
        self.settle(self.opts.hide_settle, "pages hide and freeze")
        census = self.census()
        last_hidden = PAGES10[-2][0]
        self.add(row("frozen_pages", None if census is None else len(census.pages("frozen")), ("==", 8), tier="train"),
                 row("last_hidden_not_frozen", None if census is None else
                     int((census.page(last_hidden) or {}).get("state") == "hidden"), ("==", 1), tier="train"))
        self.delivery_window(census)
        if not discard:
            return
        self.settle(self.opts.discard_settle - (self.clock.monotonic() - hidden_at), "discard of hidden pages")
        census = self.census()
        keepless = None if census is None else [p for p in census.pages() if p.get("page") != PAGES10[-1][0] and not p.get("keep_reasons")]
        footprint = self.instance.memory().get("mb")
        self.add(row("discarded_pages", None if census is None else sum(1 for p in keepless if p.get("state") == "discarded"),
                     ("==", len(keepless) if keepless is not None else 9), tier="train"),
                 row("one_page_footprint_mb", one_page, unit="MB", note=f"after {first} only"),
                 row("footprint_at_discard_mb", footprint, ("<=", round((one_page or 0) + 5, 1)), "MB", tier="train"))
        self.discarded_show_rows(census)

    def restore_times(self, page_id, since):
        """The page's last restore after a discard (`debug.page` `restore`: host uptime `started`, `covered`,
        `painted`) once it started at or after `since` and painted, else None."""
        state = self.rpc("debug.page", {"page": page_id})
        times = state.get("restore") if isinstance(state, dict) and not state.get("error") else None
        if not isinstance(times, dict) or not isinstance(times.get("started"), (int, float)) or times["started"] < since:
            return None
        return times if isinstance(times.get("painted"), (int, float)) else None

    def discarded_show_rows(self, census):
        """D4's discarded rows: each discarded page shown again by its action, timed on the app's uptime clock from
        the action's `debug.action_budget` start (else just before it) to the turn the hide-time snapshot went over
        the page (`covered`) and to the restored document's first painted frame (`painted`). A page with no kept
        snapshot gives no snapshot sample."""
        discarded = set() if census is None else {p.get("page") for p in census.pages("discarded")}
        snapshot, live = [], []
        for page_id, name, args in [entry for entry in PAGES10 if entry[0] in discarded][:self.opts.runs]:
            sequence = self.budget_sequence()
            sent = self.uptime()
            self.action(name, {k: self.files.get(v, v) for k, v in args.items()})
            times = self.until(lambda: self.restore_times(page_id, sent), self.opts.open_timeout, step=LATENCY_STEP)
            run = self.budget_run(name, sequence) or {}
            start = run["start_uptime_ns"] / 1e9 if isinstance(run.get("start_uptime_ns"), (int, float)) else sent
            covered = (times or {}).get("covered")
            snapshot.append(round((covered - start) * 1000, 1) if isinstance(covered, (int, float)) else None)
            live.append(round((times["painted"] - start) * 1000, 1) if times else None)
        note = "" if discarded else "no discarded page to show" if census is not None else "no debug.webui in this build"
        self.add(series("discarded_page.snapshot_frame_ms", snapshot, ("p99", "<=", 16.7),
                        note=note or "key to the turn that drew the hide-time snapshot (debug.page restore.covered)"),
                 series("discarded_page.live_ms", live, ("p95", "<=", 150),
                        note=note or "key to the restored document's first frame (debug.page restore.painted)"))

    def hidden_wakeups(self):
        """MQ5 (task 037): wakeups of each page renderer and of the GPU process while all ten pages are hidden and
        still run. `launch_config` turns `browser.freezeHiddenTabs` off (the planner's freeze_off keep reason): a
        frozen page runs no task, so it could hide any loop. A renderer is scored only when the census shows each
        of its pages hidden, not frozen or gone, both before and after the window.

        A hidden page gets no animation frame on either engine: Chromium's scheduler sends no BeginMainFrame to a
        widget that is not visible (cc/scheduler/scheduler_state_machine.cc ShouldSendBeginMainFrame), which is where
        PageAnimator::ServiceScriptedAnimations runs rAF callbacks; WebKit throttles a hidden page's
        ScriptedAnimationController (ThrottlingReason::VisuallyIdle). So a renderer that still wakes names a loop
        that does not wait for frames, or a document the engine thinks is visible (a parked one)."""
        tier = "pinned" if self.opts.engine == "webkit" else "train"
        self.open_pages(PAGES10)
        self.check_engine("pages10")
        self.hide_pages()
        self.settle(self.opts.hide_settle, "every page hidden, none frozen")
        before = self.census()
        renderers = self.page_renderers(before)
        window = self.instance.window(self.opts.measure, per_pid=True)
        after = self.census()
        states = None
        if before is not None and after is not None:
            states = {}
            for census in (before, after):
                for page in census.pages():
                    states.setdefault(page.get("page"), []).append(page.get("state"))
        measured = {e.get("pid"): e for e in window.get("pids") or [] if isinstance(e, dict)}
        over, rates, unmeasured = [], [], []
        for pid, pages in sorted(renderers.items()):
            name = "+".join(str(page) for page in pages) if before is not None else f"pid-{pid}"
            rate, note = self.hidden_rate(pid, pages, measured.get(pid), states)
            self.add(row(f"hidden_renderer_wakeups_per_s:{name}", rate, ("<=", HIDDEN_WAKEUPS_PER_S), "/s", tier=tier,
                         note=note))
            if rate is None:
                unmeasured.append(name)
                continue
            rates.append(rate)
            if rate > HIDDEN_WAKEUPS_PER_S:
                over.append(f"{name} ({rate}/s)")
        notes = ["rAF loops to move are in: " + "; ".join(over)] if over else []
        if unmeasured:
            notes.append("not measured: " + ", ".join(unmeasured))
        elif not over:
            notes.append("no renderer above the bound: no rAF loop moves" if rates else "no renderer measured")
        # A measured renderer above the bound is a finding; otherwise one unmeasured renderer leaves the verdict open.
        verdict = max(rates) if rates and (over or not unmeasured) else None
        kinds = window.get("kinds") or {}
        counts = {kind: int((kinds.get(kind) or {}).get("n") or 0) for kind in GPU_KINDS}
        gpu = sum((kinds.get(kind) or {}).get("wakeups_per_s") or 0 for kind in GPU_KINDS)
        self.add(row("hidden_page_renderers", len(renderers), (">=", 1), tier=tier,
                     note="" if before else "renderers holding no browser tab (no debug.webui in this build)"),
                 row("hidden_page_renderer_wakeups_max_per_s", verdict, ("<=", HIDDEN_WAKEUPS_PER_S), "/s", tier=tier,
                     note="; ".join(notes)),
                 row("hidden_gpu_wakeups_per_s", round(gpu, 2) if sum(counts.values()) else None,
                     ("<=", HIDDEN_WAKEUPS_PER_S), "/s", tier=tier,
                     note=", ".join(f"{kind} processes {n}" for kind, n in counts.items()) if sum(counts.values())
                     else "no GPU process counted in the window"),
                 row("hidden_frozen_pages", None if after is None else len(after.pages("frozen")), ("==", 0), "pages",
                     note="after the window: freezeHiddenTabs is off, so none may freeze" if after else
                     "no debug.webui in this build"))
        self.facts.update(hidden_window=window)

    @staticmethod
    def hidden_rate(pid, pages, entry, states):
        """(wakeups/s or None, note) of one page renderer. `states` is {page: [state before, state after]} from the
        census, None without one. A renderer with no counters, unknown page states or a page that was not hidden
        and running for the whole window is None: it proves nothing about a loop."""
        if entry is None:
            return None, f"pid {pid} gave no counters in the window (it ended, or no per-pid rows)"
        rate = round(entry.get("wakeups_per_s") or 0, 2)
        if states is None:
            return None, f"pid {pid} read {rate}/s, but its page states are unknown (no debug.webui in this build)"
        seen = ", ".join(f"{page}={'>'.join(states.get(page) or ['gone'])}" for page in pages)
        if any(states.get(page) != ["hidden", "hidden"] for page in pages):
            return None, f"pid {pid} read {rate}/s, but not every page stayed hidden and running: {seen}"
        return rate, f"pid {pid}: {seen}"

    @staticmethod
    def acknowledged(reply, keys):
        """Whether a debug verb's reply confirms it ran (one of `keys`), not an error or a reply that ignored the
        verb; else the reason it did not."""
        if not isinstance(reply, dict) or reply.get("error"):
            return False, f"refused: {json.dumps(reply)[:120]}"
        if not any(key in reply for key in keys):
            return False, f"the reply confirms no {' or '.join(keys)} (a build without the verb)"
        return True, ""

    def delivery_window(self, census):
        """Events and pushes to frozen pages over --measure s of publishing and appearance toggles."""
        if census is None:
            self.add(row("frozen_hidden_traffic", None, ("==", 0), tier="train", note="no debug.webui in this build"))
            return
        before = census.hidden_traffic()
        if not before:
            self.add(row("frozen_hidden_traffic", None, ("==", 0), tier="train", note="no frozen page before the window"))
            return
        published, why = self.acknowledged(
            self.rpc("debug.webui", {"action": "publish", "hz": 10, "seconds": self.opts.measure}), ("publishing", "streams"))
        if not published:
            self.add(row("frozen_hidden_traffic", None, ("==", 0), tier="train", note=f"debug.webui publish {why}: no load"))
            return

        def toggles(seconds):
            started, modes = self.clock.monotonic(), ("dark", "light")
            index = 0
            while self.clock.monotonic() - started < seconds:
                self.rpc("debug.appearance", {"mode": modes[index % 2]})
                index += 1
                self.settle(min(1.0, seconds - (self.clock.monotonic() - started)), "appearance toggle", quiet=True)
            self.rpc("debug.appearance", {"mode": "system"})

        self.instance.window(self.opts.measure, during=toggles)
        after = (self.census() or Census([])).hidden_traffic()
        traffic = {page: count - before[page] for page, count in after.items() if page in before}
        self.add(row("frozen_hidden_traffic", sum(traffic.values()), ("==", 0), tier="train",
                     note=", ".join(f"{p}={n}" for p, n in traffic.items() if n)))

    def delivery(self):
        self.open_pages(PAGES10)
        self.settle(self.opts.hide_settle, "pages hide and freeze")
        self.delivery_window(self.census())

    def push(self):
        """Task 079's A/B: --push-hz host calls per page per second to the ten pages over --measure s."""
        channel = PUSH_FEATURE in self.opts.enable_feature
        self.open_pages(PAGES10)
        self.check_engine("push")
        before = self.census()
        renderers = self.page_renderers(before)
        pages = [page_id for page_id, _, _ in PAGES10]
        trips = []

        def load(seconds):
            started = self.clock.monotonic()
            tick = 0
            while True:
                due = started + tick / self.opts.push_hz
                if due - started >= seconds:
                    return
                self.settle(due - self.clock.monotonic(), "push pace", quiet=True)  # bench: the load's own pace
                for page_id in pages:
                    reply = self.rpc("debug.page", {"page": page_id, "action": "ping"}, timeout=10)
                    ok = isinstance(reply, dict) and not reply.get("error") and isinstance(reply.get("ms"), (int, float))
                    trips.append(round(reply["ms"], 3) if ok else None)
                tick += 1

        window = self.instance.window(self.opts.measure, during=load, per_pid=True)
        after = self.census()
        calls = sum(1 for trip in trips if trip is not None)
        cpu_s = sum((entry.get("cpu_pct") or 0) / 100 * (window.get("seconds") or self.opts.measure)
                    for entry in window.get("pids") or [] if isinstance(entry, dict) and entry.get("pid") in renderers)
        arm = "on" if channel else "off"

        def delivered(key):
            if before is None or after is None:
                return None
            total = lambda census: sum(int(p.get(key) or 0) for p in census.pages())  # noqa: E731
            return total(after) - total(before) if any(p.get(key) is not None for p in after.pages()) else None

        scripts, data = delivered("script_deliveries"), delivered("data_deliveries")
        events = (scripts or 0) + (data or 0) if scripts is not None or data is not None else 2 * calls
        api = self.fork_api()
        self.add(series(f"push.round_trip_ms.{arm}", trips, note=f"fork api {api}", tier="train"),
                 row(f"push.renderer_cpu_ms_per_1000.{arm}", round(cpu_s * 1000 / (events / 1000), 3) if events and renderers else None,
                     unit="ms", tier="train",
                     note=f"{len(renderers)} page renderers, {events} deliveries" if renderers else "no page renderer"),
                 row(f"push.script_deliveries.{arm}", scripts, ("==", 0) if channel and api >= PUSH_FORK_API else None,
                     tier="train", note="" if scripts is not None else "no delivery counts in this build's census"),
                 row(f"push.data_deliveries.{arm}", data, tier="train"))
        self.facts.update(push_window=window)

    def budget_runs(self):
        reply = self.rpc("debug.action_budget", {"limit": 64})
        recent = reply.get("recent") if isinstance(reply, dict) else None
        return [r for r in recent or [] if isinstance(r, dict)]

    def budget_sequence(self):
        return max((int(r.get("sequence", 0)) for r in self.budget_runs()), default=0)

    def budget_run(self, action, after):
        """The action's first run newer than sequence `after` (`debug.action_budget`: `commit_ms`, the main-thread
        time to its commit in the key's turn, and `start_uptime_ns`), or None."""
        runs = sorted((r for r in self.budget_runs() if r.get("id") == action and int(r.get("sequence", 0)) > after),
                      key=lambda r: int(r.get("sequence", 0)))
        return runs[0] if runs else None

    def commit_ms(self, action, after):
        return (self.budget_run(action, after) or {}).get("commit_ms")

    def key(self, key, *modifiers):
        return self.rpc("debug.key", {"key": key, "modifiers": list(modifiers)})

    def painted_uptime(self, page_id):
        """The shown page's first painted frame on the uptime clock (`debug.page` `painted_uptime`), or None."""
        state = self.rpc("debug.page", {"page": page_id})
        value = state.get("painted_uptime") if isinstance(state, dict) and not state.get("error") else None
        return value if isinstance(value, (int, float)) else None

    def pid_exists(self, pid):
        try:
            self.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True

    def open(self):
        self.new_tab_rows()
        self.settings_rows()
        cef = self.rpc("debug.cef")
        built = cef.get("window_built_on_key_turn") if isinstance(cef, dict) else None
        # D4 rows with no app signal yet: printed unscored, so the gap shows in every run.
        self.add(row("cef.window_built_on_key_turn", built if isinstance(built, (int, float)) else None, ("==", 0),
                     note="" if isinstance(built, (int, float)) else "debug.cef reports no window_built_on_key_turn"),
                 row("second_page_same_pane_windows", None, ("==", 0), note="no per-open window count in debug.cef or debug.webui"))
        if self.opts.chat_turns > 0:
            self.frozen_chat()

    def new_tab_rows(self):
        """Cmd-T into the preloaded New Tab page and its Cmd-W (`debug.new_tab bench_open` / `bench_close`). The
        cover frame is `visible_ms`: the first display frame on which the pane shows the New Tab page and its strip
        the tab. `frames.first_tick_ms` is the first display-link tick after the key whatever it shows (info)."""
        key_ms, visible_ms, live_ms, first_tick, closes, spare = [], [], [], [], [], 0
        for _ in range(self.opts.runs):
            self.until(lambda: any(s.get("ready") for s in (self.rpc("debug.new_tab", {"action": "state"}) or {}).get("spares") or []),
                       self.opts.open_timeout)
            opened = self.rpc("debug.new_tab", {"action": "bench_open"}, timeout=20) or {}
            key_ms.append(opened.get("key_ms"))
            visible_ms.append(opened.get("visible_ms"))
            live_ms.append(opened.get("live_ms"))
            first_tick.append((opened.get("frames") or {}).get("first_tick_ms"))
            spare += int(bool((opened.get("opening") or {}).get("spare")))
            closes.append((self.rpc("debug.new_tab", {"action": "bench_close"}, timeout=20) or {}).get("key_ms"))
        self.add(series("new_tab.key_turn_ms", key_ms, ("p99", "<=", 4)),
                 series("new_tab.cover_frame_ms", visible_ms, ("p50", "<=", 8.3), note="key to the frame that shows the page"),
                 series("new_tab.cover_frame_p99_ms", visible_ms, ("p99", "<=", 16.7)),
                 series("new_tab.first_tick_ms", first_tick, note="info: the first display-link tick after the key"),
                 self.live_row("new_tab.live_ms", live_ms),
                 row("new_tab.from_spare", spare, ("==", self.opts.runs)),
                 series("new_tab.cmd_w_key_turn_ms", closes, ("p99", "<=", 4)))

    def live_row(self, name, live_ms):
        """Key to the live frame (`debug.new_tab bench_open` `live_ms`), with D4's ceiling as its target until spike
        090 writes one; unscored on a build that reports no live frame."""
        if all(value is None for value in live_ms):
            return row(name, None, ("p95", "<=", LIVE_CEILING_MS), "ms", note="debug.new_tab bench_open reports no live_ms")
        return series(name, live_ms, ("p95", "<=", LIVE_CEILING_MS), note="key to the first frame the page painted after its show")

    # Spike 090: the preload's park state.

    PARK_ROWS = ("park.renderer_wakeups_per_s", "park.page_wakeups_per_s", "park.key_turn_ms", "park.cover_frame_ms",
                 "park.cover_frame_p99_ms", "park.live_frame_ms", "park.refresh_hz")

    def parked(self):
        """The preload row parked as --park asks, or None."""
        census = self.census()
        return next((s for s in census.spares("preload") if park_state(s) == self.opts.park), None) if census else None

    def park_wait(self):
        """How long a park may take: the preload loads, paints, hides and (frozen) freezes."""
        return self.opts.hide_settle + self.opts.open_timeout

    def park(self):
        census = self.census()
        spare = self.until(self.parked, self.park_wait()) if census is not None else None
        if spare is None:
            seen = sorted({str(park_state(s)) for s in (self.census() or Census([])).spares("preload")})
            note = ("no debug.webui in this build" if census is None else
                    f"the preload is parked as {', '.join(seen) or 'nothing'}, not {self.opts.park}: "
                    f"the build does not honor {PARK_TUNABLE}")
            self.add(row("park.state_as_asked", None, ("==", 1), note=note), *(row(name, None, note=note) for name in self.PARK_ROWS))
            return
        self.add(row("park.state_as_asked", 1, ("==", 1), note=f"{self.opts.park}, engine {self.opts.engine}"))
        self.park_wakeups(spare)
        self.park_opens()

    def park_wakeups(self, spare):
        """Wakeups/s of the parked preload's process in 1 s windows over --measure s. A window after which the
        preload is no longer parked as asked in the same process, or whose process was not read, is a missed sample."""
        pid = Census.pid(spare)
        samples = []
        for _ in range(max(1, round(self.opts.measure))):
            window = self.instance.window(1, per_pid=True)
            entry = next((p for p in window.get("pids") or [] if p.get("pid") == pid), None)
            still = self.parked()
            samples.append(entry.get("wakeups_per_s") if entry and still and Census.pid(still) == pid else None)
        kind = "WebContent" if self.opts.engine == "webkit" else "renderer"
        self.add(series("park.renderer_wakeups_per_s", samples, unit="/s", note=f"the preload's {kind}, pid {pid}, 1 s windows"),
                 self.page_wakeups_row("park.page_wakeups_per_s"))

    def park_opens(self):
        """--runs Cmd-T opens, each from a preload parked as asked and closed with Cmd-W. A run whose preload did not
        park again in time is a missed sample."""
        key_ms, cover_ms, live_ms, refresh_ms = [], [], [], []
        for _ in range(self.opts.runs):
            if not self.until(self.parked, self.park_wait()):
                for samples in (key_ms, cover_ms, live_ms):
                    samples.append(None)
                continue
            opened = self.rpc("debug.new_tab", {"action": "bench_open"}, timeout=20) or {}
            key_ms.append(opened.get("key_ms"))
            cover_ms.append(opened.get("visible_ms"))
            live_ms.append(opened.get("live_ms"))
            refresh = (opened.get("frames") or {}).get("refresh_ms")
            if isinstance(refresh, (int, float)) and refresh > 0:
                refresh_ms.append(refresh)
            self.rpc("debug.new_tab", {"action": "bench_close"}, timeout=20)
        refresh = stats.summary(refresh_ms).get("p50") if refresh_ms else None
        self.add(series("park.key_turn_ms", key_ms, ("p99", "<=", 4)),
                 series("park.cover_frame_ms", cover_ms, ("p50", "<=", 8.3), note="key to the frame that shows the cover"),
                 series("park.cover_frame_p99_ms", cover_ms, ("p99", "<=", 16.7)),
                 self.live_row("park.live_frame_ms", live_ms),
                 row("park.refresh_hz", round(1000 / refresh, 1) if refresh else None, (">=", 119), "Hz",
                     note="" if refresh else "debug.new_tab bench_open reports no frames.refresh_ms"))

    def settings_open(self, view):
        """One Cmd-, : {"ms": key to the page's first painted frame, or None when it never answered; "preloaded":
        the page shown had painted before the key; "polled": no app timestamp, the poll's own time; "commit_ms"}.
        The key's start is its `debug.action_budget` run's start_uptime_ns (else just before `debug.key`) and the
        frame is `debug.page` painted_uptime, both on the uptime clock, so the poll's resolution is not in the
        result."""
        sequence = self.budget_sequence()
        sent = self.uptime()
        self.key(",", "cmd")
        shown = self.until(lambda: self.react_view(view, "cmux.settings") and self.painted("cmux.settings"),
                           self.opts.open_timeout, step=LATENCY_STEP)
        polled_ms = round((self.uptime() - sent) * 1000, 1)
        run = self.budget_run("openSettings", sequence) or {}
        result = {"ms": None, "preloaded": False, "polled": False, "commit_ms": run.get("commit_ms")}
        if not shown:
            return result
        start = run["start_uptime_ns"] / 1e9 if isinstance(run.get("start_uptime_ns"), (int, float)) else sent
        painted = self.painted_uptime("cmux.settings")
        if painted is None:
            result.update(ms=polled_ms, polled=True)
        elif painted < start:
            result.update(preloaded=True)
        else:
            result.update(ms=round((painted - start) * 1000, 1))
        return result

    def settings_close(self):
        """Cmd-W on the Settings tab: (its commit ms, the renderer pid that held the page, the engine page closes in
        the key's turn or None when the build stamps none)."""
        sequence = self.budget_sequence()
        pid = Census.pid((self.census() or Census([])).page("cmux.settings") or {})
        before = self.retire()
        sent = self.uptime()
        self.key("w", "cmd")
        self.until(lambda: not self.live("cmux.settings"), self.opts.open_timeout)
        run = self.budget_run("closeTab", sequence) or {}
        start = run["start_uptime_ns"] / 1e9 if isinstance(run.get("start_uptime_ns"), (int, float)) else sent
        return run.get("commit_ms"), pid, self.engine_closes_in_turn(before, self.retire(), start)

    def retire(self):
        """`debug.webui` `retire` ({engine_closes, engine_close_uptimes, ...}), or None when the build has none."""
        reply = self.rpc("debug.webui")
        retire = reply.get("retire") if isinstance(reply, dict) else None
        valid = isinstance(retire, dict) and isinstance(retire.get("engine_closes"), (int, float)) \
            and isinstance(retire.get("engine_close_uptimes"), list)
        return retire if valid else None

    @staticmethod
    def engine_closes_in_turn(before, after, start):
        """The engine page closes stamped between the `before` and `after` reads (`retire`) from `start` to
        CLOSE_TURN_WINDOW after it: the key's turn and its frames (the retirer's deadline comes later). None when a
        read had no `retire`."""
        if before is None or after is None:
            return None
        new = int(after["engine_closes"] - before["engine_closes"])
        stamps = after["engine_close_uptimes"][-new:] if new > 0 else []
        return sum(1 for t in stamps if isinstance(t, (int, float)) and start <= t < start + CLOSE_TURN_WINDOW)

    def drop_renderer(self, pid):
        """Kills the renderer that held the closed Settings page, so the next open starts a fresh one. Refused
        (False) when the census does not name it or it still runs another page or a spare."""
        census = self.census()
        if not pid or census is None or census.renderers().get(pid) or any(Census.pid(s) == pid for s in census.spares()):
            return False
        self.kill(pid, signal.SIGKILL)
        return bool(self.until(lambda: not self.pid_exists(pid), self.opts.open_timeout, step=LATENCY_STEP))

    def settings_rows(self):
        """Cmd-, Settings: the first open and --cold-runs opens after its renderer was killed (cold), --runs opens
        with the renderer live (warm), each with its Cmd-W."""
        view = _Envelope(self.rpc)
        warm, cold, open_turns, close_turns, engine_closes = [], [], [], [], []
        preloaded = polled = skipped = 0

        def sample(into, first=False):
            nonlocal preloaded, polled
            result = self.settings_open(view)
            if first and self.opts.page_code_cache:  # Settings' renderer runs now: no sample is taken without the switch
                self.check_code_cache_arm("while Settings shows", need_renderer=True)
            open_turns.append(result["commit_ms"])
            preloaded += int(result["preloaded"])
            polled += int(result["polled"])
            if not result["preloaded"]:
                into.append(result["ms"])
            turn, pid, closes = self.settings_close()
            close_turns.append(turn)
            engine_closes.append(closes)
            return pid

        pid = sample(cold, first=True)
        for _ in range(self.opts.runs):
            pid = sample(warm)
        for _ in range(self.opts.cold_runs):
            if not self.drop_renderer(pid):
                skipped += 1
                continue
            pid = sample(cold)
        how = "key (debug.action_budget start) to the page's first painted frame (debug.page painted_uptime)"
        if polled:
            how += f"; {polled} samples had no painted_uptime and are the socket poll's time"
        self.add(series("settings.cold_open_ms", cold, ("p95", "<=", 150),
                        note=f"the first open and opens after the Settings renderer was killed; {skipped} kills refused "
                             "(the census named no renderer, or it held another page)"),
                 series("settings.open_ms", warm, ("p95", "<=", 50), note=how),
                 row("settings.preloaded_opens", preloaded, note="opens that showed a page painted before the key"),
                 row("settings.cover_frame_ms", None, ("p99", "<=", 16.7), "ms",
                     note="no frame signal for Settings while preloaded yet"),
                 series("settings.key_turn_ms", open_turns, ("p99", "<=", 4)),
                 series("settings.cmd_w_key_turn_ms", close_turns, ("p99", "<=", 4)),
                 self.engine_close_row(engine_closes))

    @staticmethod
    def engine_close_row(closes):
        """p13-webui-064: every Settings Cmd-W makes 0 engine page closes in its turn (PageRetirer ends the page at its
        deadline). Unscored when a close had no `debug.webui` `retire` to read."""
        if not closes or any(c is None for c in closes):
            return row("settings.cmd_w_engine_close_calls", None, ("==", 0),
                       note="no debug.webui retire (engine_close_uptimes) in this build")
        return row("settings.cmd_w_engine_close_calls", sum(closes), ("==", 0),
                   note=f"engine page closes within {int(CLOSE_TURN_WINDOW * 1000)} ms of {len(closes)} Cmd-W keys")

    def conversation_tabs(self):
        """{tab id: pane id} of every chat tab."""
        topology = (self.rpc("snapshot.get") or {}).get("topology") or {}
        return {t["id"]: p.get("id") for w in topology.get("workspaces") or [] for p in stress_session.Stress.panes(w)
                for t in p.get("tabs") or [] if t.get("kind") == "conversation" and t.get("id")}

    def frozen_chat(self):
        """A chat of --chat-turns turns, hidden until frozen, then shown again --runs times: the time to its
        transcript answering (readiness polled every LATENCY_STEP; the page reports no frame timestamp)."""
        before = self.conversation_tabs()
        self.action("palette.newAgentChat")
        made = {}

        def opened():
            made.update({tab: pane for tab, pane in self.conversation_tabs().items() if tab not in before})
            return made

        if len(self.until(opened, self.opts.open_timeout)) != 1:
            raise ShapeError(f"palette.newAgentChat opened {len(made)} chat tabs, not 1")
        chat, pane = next(iter(made.items()))
        ready = lambda: (self.rpc("debug.agent_pane", {"action": "readiness", "pane": pane}, timeout=20) or {})  # noqa: E731
        if not self.until(lambda: ready().get("composer_visible"), self.opts.open_timeout):
            raise ShapeError("the agent chat never showed its composer")
        seeded = self.rpc("debug.agent_pane", {"action": "seed_rows", "count": self.opts.chat_turns, "pane": pane}, timeout=60)
        if not isinstance(seeded, dict) or seeded.get("error"):
            raise ShapeError(f"seed_rows was refused: {json.dumps(seeded)[:200]}")
        shows = []
        for _ in range(self.opts.runs):
            self.hide_pages()
            self.settle(self.opts.hide_settle, "chat hides and freezes")
            started = self.uptime()
            self.action("tab.focus", target=f"tab:{chat}")
            shown = self.until(lambda: (ready().get("transcript_rows") or 0) > 0, self.opts.open_timeout, step=LATENCY_STEP)
            shows.append(round((self.uptime() - started) * 1000, 1) if shown else None)
        self.add(series("frozen_chat.live_ms", shows, ("p95", "<=", 150),
                        note=f"{self.opts.chat_turns} seeded turns; tab.focus to transcript rows, polled"),
                 row("frozen_chat.first_frame_ms", None, ("p99", "<=", 16.7), "ms",
                     note="the agent pane reports no first-frame timestamp yet"))

    def crash(self):
        shown = self.open_pages(PRIVILEGED5)
        census = self.census()
        if census is None:
            self.add(row("crash", None, note="no debug.webui in this build: the shown page's renderer is unknown"))
            return
        outcomes = []
        for index in range(self.opts.kills):
            page = census.page(shown) or {}
            pid = Census.pid(page)
            if not pid:
                # Past the cap the page stays crashed (no renderer): expected. Before it the census lost the pid.
                outcomes.append({"kill": index + 1, "renderer": None, "app_alive": bool(self.alive())})
                break
            sharing = len(census.renderers().get(pid, []))
            hidden_before = {p.get("page"): Census.pid(p) for p in census.pages("hidden", "frozen")}
            reloads_before = page.get("reloads")
            killed_at = self.uptime()
            self.kill(pid, signal.SIGKILL)
            back = self.until(lambda: self.renderer_of(shown) not in (None, pid) and self.painted(shown),
                              self.opts.open_timeout, step=LATENCY_STEP)
            back_ms = None
            if back:
                painted = self.painted_uptime(shown)
                back_ms = round(((painted if painted is not None and painted > killed_at else self.uptime()) - killed_at) * 1000, 1)
            census = self.census() or Census([])
            # A hidden page reloaded when it has a renderer it did not have before the kill.
            reloaded_hidden = sum(1 for p in census.pages("hidden", "frozen")
                                  if Census.pid(p) and Census.pid(p) != hidden_before.get(p.get("page")))
            reloads_after = (census.page(shown) or {}).get("reloads")
            state = self.rpc("debug.page", {"page": shown})
            notice = state.get("crash_notice") if isinstance(state, dict) and not state.get("error") else None
            outcomes.append({"kill": index + 1, "renderer": pid, "pages_in_renderer": sharing, "shown_back_ms": back_ms,
                             "hidden_reloaded": reloaded_hidden, "app_alive": bool(self.alive()),
                             "notice": None if notice is None else bool(notice),
                             "reloads": reloads_after - reloads_before
                             if isinstance(reloads_after, int) and isinstance(reloads_before, int) else None})
            if not self.alive():
                break
        self.facts["kills"] = outcomes
        killed = [o for o in outcomes if o["renderer"]]
        lost = [o for o in outcomes if not o["renderer"] and o["kill"] <= GROUP_CAP + 1]
        capped = [o for o in killed if o["kill"] <= GROUP_CAP]
        first = killed[0] if killed else {}
        self.add(row("app_survived", int(all(o["app_alive"] for o in outcomes)) if outcomes else None, ("==", 1)),
                 row("pages_in_killed_renderer", first.get("pages_in_renderer"), ("==", 5)),
                 series("shown_page_back_ms", [o["shown_back_ms"] for o in capped], ("max", "<=", self.opts.open_timeout * 1000),
                        note="kill to the shown page's next painted frame (debug.page painted_uptime)"),
                 row("hidden_pages_reloaded", sum(o["hidden_reloaded"] for o in killed) if killed else None, ("==", 0)),
                 row("shown_page_notice", None if first.get("notice") is None else int(first["notice"]), ("==", 1),
                     note="" if first.get("notice") is not None else "debug.page reports no crash_notice for pages yet"),
                 row("shown_page_reloads", first.get("reloads"), ("==", 1),
                     note="" if first.get("reloads") is not None else "the census reports no reload count yet"))
        if lost:
            self.add(row("shown_page_renderer", None, note=f"no renderer pid for {shown} in the census at kill {lost[0]['kill']}"))
        past_cap = next((o for o in killed if o["kill"] == GROUP_CAP + 1), None)
        if past_cap is not None:
            self.add(row("reload_past_group_cap", int(past_cap["shown_back_ms"] is not None), ("==", 0)))

    def renderer_of(self, page_id):
        return Census.pid((self.census() or Census([])).page(page_id) or {})

    def selected_tab(self):
        """The selected tab of the first pane, the tab new tabs open beside."""
        topology = (self.rpc("snapshot.get") or {}).get("topology") or {}
        for workspace in topology.get("workspaces") or []:
            for pane in stress_session.Stress.panes(workspace):
                tabs = [t for t in pane.get("tabs") or [] if t.get("id")]
                if tabs:
                    return next((t for t in tabs if t.get("selected")), tabs[-1])["id"]
        raise ShapeError("no tab to open a browser tab beside")

    def tab_count(self, kind):
        topology = (self.rpc("snapshot.get") or {}).get("topology") or {}
        return sum(1 for w in topology.get("workspaces") or [] for p in stress_session.Stress.panes(w)
                   for t in p.get("tabs") or [] if t.get("kind") == kind)

    def open_candidates(self):
        """A browser tab and a chat, so the pressure pass ranks browser tabs, chats and pages (D6)."""
        for kind, open_it in (("browser", lambda: self.action(f"openBrowser.{self.opts.engine}", {"url": "about:blank"},
                                                               target=f"tab:{self.selected_tab()}")),
                              ("conversation", lambda: self.action("palette.newAgentChat"))):
            count = self.tab_count(kind)
            open_it()
            if not self.until(lambda: self.tab_count(kind) > count, self.opts.open_timeout):
                raise ShapeError(f"no {kind} tab opened for the pressure session")

    def pressure(self):
        self.open_candidates()
        self.open_pages(PRIVILEGED5 + [PAGES10[5], PAGES10[7]])
        self.settle(self.opts.hide_settle, "pages hide and freeze")
        if self.census() is None:
            self.add(row("pressure", None, note="no debug.webui in this build"))
            return
        try:
            self.pressure_rows()
        finally:
            self.rpc("debug.hibernation.pressure", {"level": "none"})

    def pressure_rows(self):
        """Critical pressure through the memory coordinator's override (`debug.hibernation.pressure`), the one path
        the preload slot, the spare windows and the ranked discard pass follow (p13-webui-047). The caller clears
        the override."""
        reply = self.rpc("debug.hibernation.pressure", {"level": "critical"})
        ran, why = self.acknowledged(reply, ("override",))
        if ran and reply.get("level") != "critical":
            ran, why = False, f"the coordinator's level is {reply.get('level')!r}, not critical"
        if not ran:
            note = f"debug.hibernation.pressure {why}"
            self.add(row("preload_after_pressure", None, ("==", 0), note=note),
                     row("renderers_after_discard", None, note=note),
                     row("pages_left_undiscarded", None, ("==", 0), note=note))
            return
        right_after = self.census() or Census([])
        self.add(row("preload_after_pressure", len(right_after.spares("preload")), ("==", 0)))
        self.until(lambda: not (self.census() or Census([])).pages("hidden", "frozen"), self.opts.open_timeout)
        census = self.census() or Census([])
        shown_groups = {p.get("group") for p in census.pages("active")}
        self.add(row("renderers_after_discard", len(census.renderers()), ("==", len(shown_groups))),
                 row("pages_left_undiscarded", len(census.pages("hidden", "frozen")), ("==", 0)),
                 row("discards_in_importance_order", None, ("==", 1),
                     note="debug.webui reports no discard order over browser tabs, chats and pages yet"))

    def priority(self):
        self.open_pages(PRIVILEGED5)
        renderers = self.page_renderers(self.census())
        if not renderers:
            self.add(row("page_renderers", 0, (">=", 1), tier="train", note="no page renderer pid in the census or procs"),
                     row("backgrounded_renderers", None, tier="train", note="no page renderer to watch"))
            return
        before = self.priorities(list(renderers))
        self.hide_pages()
        started = self.clock.monotonic()
        backgrounded = {}

        def all_background():
            for pid, pri in self.priorities(list(renderers)).items():
                if pri <= BACKGROUND_PRI and pid not in backgrounded:
                    backgrounded[pid] = round((self.clock.monotonic() - started) * 1000, 1)
            return len(backgrounded) == len(renderers)

        self.until(all_background, self.opts.priority_wait, step=0.1)
        after = self.priorities(list(renderers))
        self.facts["priority"] = {str(pid): {"pages": renderers[pid], "shown": before.get(pid), "hidden": after.get(pid),
                                             "background_ms": backgrounded.get(pid)} for pid in renderers}
        self.add(row("page_renderers", len(renderers), (">=", 1), tier="train"),
                 row("backgrounded_renderers", len(backgrounded), ("==", len(renderers)), tier="train",
                     note=f"ps priority <= {BACKGROUND_PRI} within {self.opts.priority_wait:g} s"),
                 series("background_ms", [backgrounded.get(pid) for pid in renderers],("max", "<=", self.opts.priority_wait * 1000), tier="train"))

    def run(self, mode):
        if self.opts.session == "stress":
            summary = stress_session.Stress(self.rpc, log=self.log).build()  # raises StressShapeError
            self.facts["stress"] = summary
        else:
            problems = light_problems((self.rpc("snapshot.get") or {}).get("topology") or {})
            if problems:
                raise ShapeError("not the light session: " + "; ".join(problems))
        self.facts["page_code_cache"] = bool(self.opts.page_code_cache)
        if self.facts["page_code_cache"]:
            self.check_code_cache_arm("before the mode")
        getattr(self, mode)()
        if self.facts["page_code_cache"]:
            self.code_cache_row()
        if not self.alive():
            self.add(row("app_alive_at_end", 0, ("==", 1)))
        return {"mode": mode, "engine": self.opts.engine, "session": self.opts.session, "park": self.opts.park,
                "rows": self.rows, "facts": self.facts}


class _Envelope:
    """bench-pages.py's view of a run: `call` answers {"result": ...} as bench-stalls.py's Run does."""

    def __init__(self, rpc):
        self.rpc = rpc

    def call(self, method, params=None):
        return {"result": self.rpc(method, params)}


# ---------------------------------------------------------------- spike 090's table and decision

TABLE_COLUMNS = (("Key to cover (ms)", "park.cover_frame_ms"), ("Key to live (ms)", "park.live_frame_ms"),
                 ("Parked wakeups/s", "park.renderer_wakeups_per_s"))


def park_rows(report):
    """{row name: row} of a park report, or None when it is not a measured park run."""
    if report.get("mode") != "park" or report.get("park") not in PARK_STATES or report.get("refused"):
        return None
    named = {entry.get("name"): entry for entry in report.get("rows") or [] if isinstance(entry, dict)}
    return named if (named.get("park.state_as_asked") or {}).get("value") == 1 else None


def _stat(entry, key):
    value = (entry or {}).get("value")
    return value.get(key) if isinstance(value, dict) else None


def _cell(entry):
    if not isinstance((entry or {}).get("value"), dict):
        return "not measured"
    return " / ".join(_fmt(_stat(entry, key)) for key in ("p50", "p95", "p99", "max")) + (
        f" ({_stat(entry, 'missed')} missed)" if _stat(entry, "missed") else "")


def park_table(runs):
    """Markdown lines of spike 090's table: one row per (job id, report), the variants that did not measure as asked
    included with their reason."""
    head = ["Park", "Engine", "Session", *(title + " p50 / p95 / p99 / max" for title, _ in TABLE_COLUMNS), "sha", "host", "job"]
    lines = ["| " + " | ".join(head) + " |", "|" + " --- |" * len(head)]
    for job, report in runs:
        named = park_rows(report)
        if named is None:
            why = report.get("refused") or next((e.get("note") for e in report.get("rows") or []
                                                 if e.get("name") == "park.state_as_asked" and e.get("note")), "not a park run")
            cells = [f"not measured: {why}"] * len(TABLE_COLUMNS)
        else:
            cells = [_cell(named.get(name)) for _, name in TABLE_COLUMNS]
        sha = (report.get("sha") or "-")[:12]
        lines.append("| " + " | ".join([str(report.get("park") or "-"), str(report.get("engine") or "-"),
                                         str(report.get("session") or "-"), *cells, sha, str(report.get("host") or "-"),
                                         str(job)]) + " |")
    return lines


def whole_frames(ms):
    """`ms` rounded up to whole 120 Hz frames."""
    return round(-(-ms // FRAME_120HZ_MS) * FRAME_120HZ_MS, 1)


def park_decision(reports):
    """Spike 090's rule (webui-DESIGN.md section 5): {"park", "targets", "why"}, or {"park": None, "why"} when the
    reports do not cover both park states on both engines for each session measured.

    Chrome never freezes its preloaded WebUI (chrome/browser/ui/webui/top_chrome/webui_contents_preload_manager.cc;
    CannotFreezeReason::kWebUI), so rendered is the default and frozen must earn its place: frozen wins only if, for
    every engine and session, its live p95 is no worse than rendered's by more than one 120 Hz frame and no worse than
    the D4 ceiling, and its parked renderer wakes less (p50). The D4 live-frame target of each session is the chosen
    state's worst engine p95, rounded up to whole 120 Hz frames and capped at the ceiling."""
    measured = {}
    for report in reports:
        named = park_rows(report)
        if named is not None:
            measured[(report["park"], report.get("engine"), report.get("session"))] = named
    sessions = sorted({session for _, _, session in measured})
    pairs = [(engine, session) for engine in ("chromium", "webkit") for session in sessions]
    missing = [f"{park} {engine} {session}" for engine, session in pairs or [("chromium", "light"), ("webkit", "light")]
               for park in PARK_STATES if (park, engine, session) not in measured]
    live = {key: _stat(named.get("park.live_frame_ms"), "p95") for key, named in measured.items()}
    wakeups = {key: _stat(named.get("park.renderer_wakeups_per_s"), "p50") for key, named in measured.items()}
    missing += [" ".join(map(str, key)) + " has no live p95 or parked wakeups" for key in measured
                if live[key] is None or wakeups[key] is None]
    if missing:
        return {"park": None, "why": "not measured: " + ", ".join(missing)}
    losses = []
    for engine, session in pairs:
        frozen, rendered = ("frozen", engine, session), ("rendered", engine, session)
        if live[frozen] > live[rendered] + FRAME_120HZ_MS:
            losses.append(f"{engine} {session}: frozen live p95 {live[frozen]:g} ms > rendered {live[rendered]:g} ms + 1 frame")
        if live[frozen] > LIVE_CEILING_MS:
            losses.append(f"{engine} {session}: frozen live p95 {live[frozen]:g} ms > {LIVE_CEILING_MS} ms")
        if wakeups[frozen] >= wakeups[rendered]:
            losses.append(f"{engine} {session}: frozen wakes {wakeups[frozen]:g}/s, rendered {wakeups[rendered]:g}/s")
    park = "rendered" if losses else "frozen"
    targets = {session: min(whole_frames(max(live[(park, engine, session)] for engine in ("chromium", "webkit"))), LIVE_CEILING_MS)
               for session in sessions}
    return {"park": park, "targets": targets, "why": "; ".join(losses) or "frozen costs at most one frame and wakes less"}


def park_table_main(argv):
    parser = argparse.ArgumentParser(prog="bench-webui.py park-table", description="Spike 090's table from park reports.")
    parser.add_argument("--run", nargs=2, action="append", required=True, metavar=("JOB_ID", "REPORT"),
                        help="a cmux-ci job id and the webui-park.json it wrote")
    opts = parser.parse_args(argv)
    runs = []
    for job, path in opts.run:
        with open(path) as handle:
            runs.append((job, json.load(handle)))
    for text in park_table(runs):
        print(text)
    decision = park_decision([report for _, report in runs])
    print()
    if decision["park"] is None:
        print(f"Decision: none ({decision['why']}).")
    else:
        targets = ", ".join(f"{session} <= {ms:g} ms p95" for session, ms in decision["targets"].items())
        print(f"Decision: {decision['park']} ({decision['why']}). D4 key to live frame: {targets}.")
    return 0


# ---------------------------------------------------------------- command line


def launch_config(opts):
    """The app's cmux-next.json for a run. --every-page-hidden turns page freezing off (p13-webui.md section 3.C:
    `browser.freezeHiddenTabs` "off" is a freeze-only keep reason), so its window measures pages that still run.
    `browser.hibernation` is written ("moderate", the default timeouts): with it unwritten hidden pages only freeze
    and are never discarded on their own, at any pressure (the planner's discards_off keep reason, trunk #25920), and
    the discard and pressure rows measure discards."""
    browser = {"defaultEngine": opts.engine, "hibernation": "moderate"}
    if opts.every_page_hidden or opts.mode == "push":
        browser["freezeHiddenTabs"] = "off"
    return {"browser": browser, "appearance": {"backgroundOpacity": 1}}


def parse(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mode", choices=MODES)
    parser.add_argument("--app", required=True, help="the tagged cmux DEV bundle")
    parser.add_argument("--engine", choices=["chromium", "webkit"], default="chromium", help="browser.defaultEngine")
    parser.add_argument("--session", choices=["light", "stress"], default="light")
    parser.add_argument("--settle", type=float, default=60, help="s after launch (home: before the window)")
    parser.add_argument("--measure", type=float, default=60, help="s of the idle or delivery window")
    parser.add_argument("--hide-settle", type=float, default=10, help="s after hiding, before frozen pages are read")
    parser.add_argument("--discard-settle", type=float, default=300, help="s after hiding, before discards are read")
    parser.add_argument("--open-timeout", type=float, default=20, help="s a page may take to open or come back")
    parser.add_argument("--priority-wait", type=float, default=1.0, help="s a hidden renderer may take to background")
    parser.add_argument("--runs", type=int, default=20, help="samples per open row (and frozen chat shows)")
    parser.add_argument("--cold-runs", type=int, default=20, help="Settings opens after its renderer was killed")
    parser.add_argument("--chat-turns", type=int, default=2000, help="turns of the frozen chat (0: no chat row)")
    parser.add_argument("--kills", type=int, default=GROUP_CAP + 1)
    parser.add_argument("--push-hz", type=float, default=10, help="push: host calls per page per second")
    parser.add_argument("--every-page-hidden", action="store_true",
                        help="pages10: hide all ten pages, then measure page renderer and GPU wakeups (task 037, MQ5)")
    parser.add_argument("--page-code-cache", action="store_true",
                        help="task 052's A/B: Chromium with the code cache spike's switches (Debug development bundles)")
    parser.add_argument("--enable-feature", action="append", default=[], metavar="NAME",
                        help="a feature to turn on for the run (CMUX_ENABLE_FEATURES), repeatable: an off feature's arm")
    parser.add_argument("--park", choices=PARK_STATES,
                        help=f"the preload's park state ({PARK_TUNABLE}; required by park, spike 090)")
    parser.add_argument("--out")
    opts = parser.parse_args(argv)
    for name in ("settle", "measure", "hide_settle", "discard_settle", "open_timeout", "priority_wait"):
        if getattr(opts, name) < 0:
            parser.error(f"--{name.replace('_', '-')} must be >= 0")
    if opts.push_hz <= 0:
        parser.error("--push-hz must be > 0")
    if opts.runs < 1 or opts.kills < 1 or opts.cold_runs < 0:
        parser.error("--runs and --kills must be >= 1, --cold-runs >= 0")
    if opts.every_page_hidden and opts.mode != "pages10":
        parser.error("--every-page-hidden is a pages10 option")
    if opts.page_code_cache and opts.engine != "chromium":
        parser.error("--page-code-cache needs --engine chromium")
    if opts.mode == "park" and not opts.park:
        parser.error("park needs --park frozen or --park rendered (one variant per run)")
    return opts


def checkout_sha():
    """The commit of this checkout (the fleet step's --ref), or None outside a git checkout."""
    try:
        done = subprocess.run(["git", "-C", ROOT, "rev-parse", "HEAD"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    return (done.stdout.strip() or None) if done.returncode == 0 else None


def launch_env(opts, tunables):
    """The app's environment: the React page tunables file, --enable-feature's features, and with --page-code-cache
    task 052's switches."""
    env = {"CMUX_NEXT_DEBUG_TUNABLES_FILE": tunables}
    if opts.enable_feature:
        env["CMUX_ENABLE_FEATURES"] = ",".join(opts.enable_feature)
    if opts.page_code_cache:
        env["CMUX_NEXT_CEF_EXTRA_SWITCHES"] = ":".join(CODE_CACHE_SWITCHES)
    return env


def module_mode(mode):
    """The module of a MODULE_MODES mode (it imports its siblings by name, so HERE goes on sys.path)."""
    if HERE not in sys.path:
        sys.path.insert(0, HERE)
    name = MODULE_MODES[mode]
    return load(name, os.path.join(HERE, name + ".py"))


def module_parser(mode):
    """The command line of a MODULE_MODES mode: its module's options, `mode` set to the mode."""
    module = module_mode(mode)
    parser = argparse.ArgumentParser(prog=f"bench-webui.py {mode}", description=module.__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.set_defaults(mode=mode)
    module.add_arguments(parser)
    return parser


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["park-table"]:
        return park_table_main(argv[1:])
    if argv and argv[0] in MODULE_MODES:
        return module_mode(argv[0]).main(module_parser(argv[0]).parse_args(argv[1:]))
    opts = parse(argv)
    if sys.platform != "darwin":
        raise SystemExit("bench-webui: macOS only (a fleet GUI mini, never a laptop)")
    launch = load("bench_launch", os.path.join(HERE, "bench_launch.py"))
    procs = load("procs", os.path.join(ROOT, "scripts/perf-bench/procs.py"))
    sharing = load("bench_renderer_sharing", os.path.join(HERE, "bench_renderer_sharing.py"))
    pages = load("bench_pages", os.path.join(HERE, "bench-pages.py"))
    out = os.path.abspath(opts.out or tempfile.mkdtemp(prefix="bench-webui-"))
    os.makedirs(out, exist_ok=True)
    tunables = os.path.join(out, "debug-tunables.json")
    # The React History and App Store pages (bench-pages.py's PAGES tunables) and the preload's park state.
    values = {"history.surface": "web", pages.PAGES["apps"]["tunable"]: "web"}
    if opts.park:
        values[PARK_TUNABLE] = opts.park
    with open(tunables, "w") as handle:
        json.dump({"version": 1, "values": values}, handle)
    app = launch.BenchApp(opts.app, out=out, config=launch_config(opts), env=launch_env(opts, tunables))
    status = 0
    report = {"mode": opts.mode, "engine": opts.engine, "session": opts.session, "park": opts.park, "rows": []}
    try:
        app.launch()
        instance = procs.Instance(app.app, app.process.pid)
        bench = Bench(opts, app.rpc, instance,
                      browser_renderers=lambda: {pid for pid, tabs in (sharing.renderer_map(app.socket).get("owners") or {}).items() if tabs},
                      kind_of=procs.kind_of, type_kind=procs.process_type_kind, react_view=pages.react_view,
                      alive=lambda: app.process.poll() is None)
        if opts.mode != "home":
            bench.settle(opts.settle, "launch")
        report = bench.run(opts.mode)
    except (ShapeError, stress_session.StressShapeError) as error:
        print(f"bench-webui: refused: {error}", flush=True)
        report["refused"] = str(error)
        status = 2
    finally:
        app.stop()
    report.update(host=os.uname().nodename, sha=checkout_sha(), load_average=os.getloadavg(), app=opts.app,
                  options={k: v for k, v in vars(opts).items() if k != "app"})
    for entry in report["rows"]:
        print(line(opts.mode, entry), flush=True)
    path = os.path.join(out, f"webui-{opts.mode}.json")
    with open(path, "w") as handle:
        json.dump(report, handle, indent=1)
    print(f"bench-webui: wrote {path}", flush=True)
    if status == 0 and any(entry["name"] == "app_alive_at_end" for entry in report["rows"]):
        status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
