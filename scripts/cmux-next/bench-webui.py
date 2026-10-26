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
            counts, Chromium renderers, extension renderers, whole-tree footprint, web helper CPU and wakeups/s,
            `debug.wakeups` owners of pages, the preload and spares.
  pages10   D3. Opens settings, history, cloud, apps, keybindings, files, diff, markdown, editor and chief-usage (the
            last one shown), then: renderers that hold no browser tab, DevTools on page renderers (`unscored` on
            fork < 29: clicks use DevTools there), frozen pages --hide-settle s after hiding, the delivery window
            (below), discarded pages and footprint at --discard-settle s against the one-page footprint.
  open      D4, light or STRESS. Cmd-T into the preloaded New Tab (`debug.new_tab bench_open`: key turn, visible,
            first frame) and its Cmd-W; Cmd-, Settings (key to answering page; the key's commit from
            `debug.action_budget`) and its Cmd-W; a frozen chat of --chat-turns turns shown again.
  crash     D5. 5 privileged pages, 1 shown; kill -9 of the shown page's renderer --kills times: cmux survives, the
            shown page paints again (until the group cap, 3 per 600 s), hidden pages do not reload.
  pressure  D6. `debug.webui pressure critical`: the preload slot right after, renderers once discards settle.
  priority  D12. Page renderers (or WebContent processes) with every page hidden: backgrounded (`ps` priority <= 4,
            darwinbg) within --priority-wait s.
  delivery  D3's delivery rows alone: events and native pushes to frozen pages over --measure s while
            `debug.webui publish` drives one stream per page at 10 Hz and the appearance toggles every second.

The page census is `debug.webui` (task 001). A build without it (the base of the program) gets `unscored` for the
census rows and still measures the process rows. Keys read, per row of its `rows` list: `row` (page, spare or
process), `page`, `engine`, `group`, `state` (active, hidden, frozen, discarded, crashed), `keep_reasons`,
`renderer_pid`, `webkit_pid`, `hidden_deliveries`, `hidden_pushes`, `devtools`, `spare_kind`, `pid`,
`process_kind` (renderer, extension, utility, gpu). Change them in ``Census`` only.

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
MODES = ("home", "pages10", "open", "crash", "pressure", "priority", "delivery")
# D3's ten pages: (page id, the action that opens it, its arguments; "{md}" and "{txt}" are scratch files).
PAGES10 = [("cmux.settings", "openSettings", {}), ("cmux.history", "history.show", {}),
           ("cmux.cloud", "palette.openCloudPane", {}), ("cmux.apps", "appStore.show", {}),
           ("cmux.keybindings", "keybindings.open", {}), ("cmux.files", "files.open", {}),
           ("cmux.diff", "openDiffViewer", {"path": ROOT}), ("cmux.markdown", "openMarkdownFile", {"path": "{md}"}),
           ("cmux.editor", "file.open", {"path": "{txt}"}), ("cmux.chief-usage", "chief.openUsage", {})]
PRIVILEGED5 = PAGES10[:5]  # one capability group (section 3.B): the crash, pressure and priority sessions
WEB_KINDS = ("renderer", "gpu", "helper")  # procs.kind_of names of CEF processes; utility:* and webkit-* by prefix
BACKGROUND_PRI = 4  # `ps -o pri` of a darwinbg task: Chrome backgrounds a hidden renderer so (base/process/process_mac.cc)
GROUP_CAP = 3  # crash budget per group in 600 s (section 3.C)


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


def row(name, value, target=None, unit="", note=""):
    """One result row. `value` is a number, a perf_stats summary, or None (unscored, `note` says why). `target` is
    (op, bound) for a number or (stat, op, bound) for a summary; it is printed and marked, never an exit status."""
    status = "info"
    if value is None:
        status = "unscored"
    elif target:
        stat, op, bound = target if len(target) == 3 else (None, *target)
        measured = value.get(stat) if isinstance(value, dict) else value
        status = "unscored" if measured is None else ("met" if OPS[op](measured, bound) else "missed")
    return {"name": name, "value": value, "target": list(target) if target else None, "unit": unit,
            "status": status, "note": note}


def series(name, values, target=None, unit="ms", note=""):
    """A latency row: the percentiles of `values` (None entries are samples that never finished, counted apart)."""
    timed = [v for v in values if isinstance(v, (int, float))]
    summary = stats.summary(timed)
    summary["missed"] = len(values) - len(timed)
    return row(name, summary if timed else None, target, unit, note or ("" if timed else "no sample finished"))


def line(mode, entry):
    value = entry["value"]
    if isinstance(value, dict):
        shown = " ".join(f"{k}={_fmt(value.get(k))}" for k in ("n", "p50", "p95", "p99", "max", "missed"))
    else:
        shown = f"value={_fmt(value)}"
    target = "".join(str(part) for part in entry["target"]) if entry["target"] else "-"
    note = f" note={json.dumps(entry['note'])}" if entry["note"] else ""
    return f"WEBUI-ROW mode={mode} row={entry['name']} {shown} unit={entry['unit'] or '-'} target={target} status={entry['status']}{note}"


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
        if not isinstance(reply, dict) or reply.get("error") or not isinstance(reply.get("rows"), list):
            return None
        return cls([r for r in reply["rows"] if isinstance(r, dict)])

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
    browser tab), `kill(pid, signal)`, `alive()`, `priorities(pids)`, `react_view` (bench-pages.py) and `clock`."""

    def __init__(self, opts, rpc, instance, browser_renderers, kind_of, react_view, alive, kill=os.kill,
                 priorities=read_priorities, clock=time, log=None):
        self.opts, self.rpc, self.instance = opts, rpc, instance
        self.browser_renderers, self.kind_of, self.react_view = browser_renderers, kind_of, react_view
        self.alive, self.kill, self.priorities, self.clock = alive, kill, priorities, clock
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
        kinds = window.get("kinds") or {}
        count = lambda test: sum(int(entry.get("n", 0)) for kind, entry in kinds.items() if test(kind))  # noqa: E731
        web = lambda kind: kind in WEB_KINDS or kind.startswith(("utility:", "webkit-"))  # noqa: E731
        cef = lambda kind: kind in WEB_KINDS or kind.startswith("utility:")  # noqa: E731
        census = self.census()
        chromium = self.opts.engine == "chromium"
        self.add(row("webcontent_processes", count(lambda k: k == "webkit-webcontent"), ("==", 0) if chromium else ("<=", 1)),
                 row("cef_processes", count(cef), None if chromium else ("==", 0)),
                 row("chromium_renderers", count(lambda k: k == "renderer"), ("==", 1) if chromium else ("==", 0)),
                 row("extension_renderers", None if census is None else len(census.processes("extension")), ("==", 0),
                     note="" if census else "no debug.webui in this build"),
                 row("footprint_mb", memory.get("mb"), ("<=", 250) if chromium else ("<=", 150), "MB"),
                 row("web_helper_cpu_pct", round(sum(e.get("cpu_pct", 0) for k, e in kinds.items() if web(k)), 3),
                     ("<=", 0.3) if chromium else None, "%"),
                 row("web_helper_wakeups_per_s", round(sum(e.get("wakeups_per_s", 0) for k, e in kinds.items() if web(k)), 2),
                     ("<=", 1.0) if chromium else ("<=", 0.2), "/s"))
        ledger = (self.rpc("debug.wakeups", timeout=30) or {}).get("ledger") or []
        owners = [e for e in ledger if any(word in str(e.get("owner", "")).lower() for word in ("page", "preload", "spare"))]
        self.add(row("page_preload_spare_wakeups_per_s", round(sum(e.get("per_second", 0) for e in owners), 2), ("==", 0), "/s",
                     note=", ".join(f"{e.get('owner')}:{e.get('reason')}" for e in owners[:6])))
        if census is not None:
            preload = census.spares("preload")
            self.add(row("preload_frozen", int(all(s.get("state") == "frozen" for s in preload)) if preload else None, ("==", 1),
                         note="" if preload else "no preload row"))
        self.facts.update(window=window, memory=memory)

    def pages10(self, discard=True):
        first = PAGES10[0][0]
        self.open_pages(PAGES10[:1])
        self.settle(self.opts.hide_settle, "one page")
        one_page = self.instance.memory().get("mb")
        self.open_pages(PAGES10[1:])
        self.check_engine("pages10")
        census = self.census()
        renderers = self.page_renderers(census)
        self.add(row("page_renderers", len(renderers), ("<=", 4),
                     note="" if census else "renderers holding no browser tab (no debug.webui in this build)"))
        api = self.fork_api()
        self.add(row("devtools_on_page_renderers",
                     None if census is None or api < 29 else sum(1 for p in census.pages() if p.get("devtools")), ("==", 0),
                     note="" if census and api >= 29 else f"fork api {api} < 29: clicks use DevTools" if census else "no debug.webui"))
        hidden_at = self.clock.monotonic()
        self.settle(self.opts.hide_settle, "pages hide and freeze")
        census = self.census()
        last_hidden = PAGES10[-2][0]
        self.add(row("frozen_pages", None if census is None else len(census.pages("frozen")), ("==", 8)),
                 row("last_hidden_not_frozen", None if census is None else
                     int((census.page(last_hidden) or {}).get("state") == "hidden"), ("==", 1)))
        self.delivery_window(census)
        if not discard:
            return
        self.settle(self.opts.discard_settle - (self.clock.monotonic() - hidden_at), "discard of hidden pages")
        census = self.census()
        keepless = None if census is None else [p for p in census.pages() if p.get("page") != PAGES10[-1][0] and not p.get("keep_reasons")]
        footprint = self.instance.memory().get("mb")
        self.add(row("discarded_pages", None if census is None else sum(1 for p in keepless if p.get("state") == "discarded"),
                     ("==", len(keepless) if keepless is not None else 9)),
                 row("one_page_footprint_mb", one_page, unit="MB", note=f"after {first} only"),
                 row("footprint_at_discard_mb", footprint, ("<=", round((one_page or 0) + 5, 1)), "MB"))

    def delivery_window(self, census):
        """Events and pushes to frozen pages over --measure s of publishing and appearance toggles."""
        if census is None:
            self.add(row("frozen_hidden_traffic", None, ("==", 0), note="no debug.webui in this build"))
            return
        before = census.hidden_traffic()
        self.rpc("debug.webui", {"action": "publish", "hz": 10, "seconds": self.opts.measure})

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
        self.add(row("frozen_hidden_traffic", sum(traffic.values()), ("==", 0),
                     note=", ".join(f"{p}={n}" for p, n in traffic.items() if n)))

    def delivery(self):
        self.open_pages(PAGES10)
        self.settle(self.opts.hide_settle, "pages hide and freeze")
        self.delivery_window(self.census())

    def budget_sequence(self):
        recent = (self.rpc("debug.action_budget", {"limit": 64}) or {}).get("recent") or []
        return max((int(r.get("sequence", 0)) for r in recent), default=0)

    def commit_ms(self, action, after):
        """The action's commit time in its key's turn (`debug.action_budget`), newer than sequence `after`."""
        recent = (self.rpc("debug.action_budget", {"limit": 64}) or {}).get("recent") or []
        runs = sorted((r for r in recent if r.get("id") == action and int(r.get("sequence", 0)) > after),
                      key=lambda r: int(r.get("sequence", 0)))
        return runs[0].get("commit_ms") if runs else None

    def key(self, key, *modifiers):
        return self.rpc("debug.key", {"key": key, "modifiers": list(modifiers)})

    def open(self):
        key_ms, visible_ms, first_frame, closes, spare = [], [], [], [], 0
        for _ in range(self.opts.runs):
            self.until(lambda: any(s.get("ready") for s in (self.rpc("debug.new_tab", {"action": "state"}) or {}).get("spares") or []),
                       self.opts.open_timeout)
            opened = self.rpc("debug.new_tab", {"action": "bench_open"}, timeout=20) or {}
            key_ms.append(opened.get("key_ms"))
            visible_ms.append(opened.get("visible_ms"))
            first_frame.append((opened.get("frames") or {}).get("first_tick_ms"))
            spare += int(bool((opened.get("opening") or {}).get("spare")))
            closes.append((self.rpc("debug.new_tab", {"action": "bench_close"}, timeout=20) or {}).get("key_ms"))
        self.add(series("new_tab.key_turn_ms", key_ms, ("p99", "<=", 4)),
                 series("new_tab.first_frame_ms", first_frame, ("p99", "<=", 16.7)),
                 series("new_tab.visible_ms", visible_ms, ("p95", "<=", 50)),
                 row("new_tab.from_spare", spare, ("==", self.opts.runs)),
                 series("new_tab.cmd_w_key_turn_ms", closes, ("p99", "<=", 4)))
        opens, open_turns, close_turns = [], [], []
        view = _Envelope(self.rpc)
        for _ in range(self.opts.runs):
            sequence = self.budget_sequence()
            started = self.clock.monotonic()
            self.key(",", "cmd")
            shown = self.until(lambda: self.react_view(view, "cmux.settings") and self.painted("cmux.settings"), self.opts.open_timeout)
            opens.append(round((self.clock.monotonic() - started) * 1000, 1) if shown else None)
            open_turns.append(self.commit_ms("openSettings", sequence))
            sequence = self.budget_sequence()
            self.key("w", "cmd")
            self.until(lambda: not self.live("cmux.settings"), self.opts.open_timeout)
            close_turns.append(self.commit_ms("closeTab", sequence))
        self.add(row("settings.cold_open_ms", opens[0] if opens else None, ("<=", 150), "ms", "the first open of the run"),
                 series("settings.open_ms", opens[1:], ("p95", "<=", 50), note="key to the page answering, socket polls included"),
                 series("settings.key_turn_ms", open_turns, ("p99", "<=", 4)),
                 series("settings.cmd_w_key_turn_ms", close_turns, ("p99", "<=", 4)))
        if self.opts.chat_turns > 0:
            self.frozen_chat()

    def frozen_chat(self):
        self.action("palette.newAgentChat")
        ready = lambda: (self.rpc("debug.agent_pane", {"action": "readiness"}, timeout=20) or {})  # noqa: E731
        if not self.until(lambda: ready().get("composer_visible"), self.opts.open_timeout):
            raise ShapeError("the agent chat never showed its composer")
        self.rpc("debug.agent_pane", {"action": "seed_rows", "count": self.opts.chat_turns}, timeout=60)
        chat = self.newest_tab("conversation")
        shows = []
        for _ in range(max(1, self.opts.runs // 4)):
            self.hide_pages()
            self.settle(self.opts.hide_settle, "chat hides and freezes")
            started = self.clock.monotonic()
            self.action("tab.focus", target=f"tab:{chat}")
            shown = self.until(lambda: ready().get("transcript_rows", 0) > 0, self.opts.open_timeout)
            shows.append(round((self.clock.monotonic() - started) * 1000, 1) if shown else None)
        self.add(series("frozen_chat.live_ms", shows, ("p95", "<=", 150), note=f"{self.opts.chat_turns} seeded turns"))

    def newest_tab(self, kind):
        topology = (self.rpc("snapshot.get") or {}).get("topology") or {}
        tabs = [t for w in topology.get("workspaces") or [] for p in stress_session.Stress.panes(w)
                for t in p.get("tabs") or [] if t.get("kind") == kind]
        if not tabs:
            raise ShapeError(f"no {kind} tab")
        return tabs[-1]["id"]

    def crash(self):
        shown = self.open_pages(PRIVILEGED5)
        census = self.census()
        if census is None:
            self.add(row("crash", None, note="no debug.webui in this build: the shown page's renderer is unknown"))
            return
        outcomes = []
        for index in range(self.opts.kills):
            pid = Census.pid(census.page(shown) or {})
            if not pid:
                outcomes.append({"kill": index + 1, "renderer": None})
                break
            sharing = len(census.renderers().get(pid, []))
            hidden_before = {p.get("page"): Census.pid(p) for p in census.pages("hidden", "frozen")}
            self.kill(pid, signal.SIGKILL)
            started = self.clock.monotonic()
            back = self.until(lambda: self.renderer_of(shown) not in (None, pid) and self.painted(shown), self.opts.open_timeout)
            census = self.census() or Census([])
            # A hidden page reloaded when it has a renderer it did not have before the kill.
            reloaded_hidden = sum(1 for p in census.pages("hidden", "frozen")
                                  if Census.pid(p) and Census.pid(p) != hidden_before.get(p.get("page")))
            outcomes.append({"kill": index + 1, "renderer": pid, "pages_in_renderer": sharing,
                             "shown_back_ms": round((self.clock.monotonic() - started) * 1000, 1) if back else None,
                             "hidden_reloaded": reloaded_hidden, "app_alive": bool(self.alive())})
            if not self.alive():
                break
        self.facts["kills"] = outcomes
        capped = [o for o in outcomes if o["kill"] <= GROUP_CAP]
        self.add(row("app_survived", int(all(o.get("app_alive") for o in outcomes)), ("==", 1)),
                 row("pages_in_killed_renderer", outcomes[0].get("pages_in_renderer") if outcomes else None, ("==", 5)),
                 series("shown_page_back_ms", [o.get("shown_back_ms") for o in capped], ("max", "<=", self.opts.open_timeout * 1000)),
                 row("hidden_pages_reloaded", sum(o.get("hidden_reloaded", 0) for o in outcomes), ("==", 0)))
        if len(outcomes) > GROUP_CAP:
            self.add(row("reload_past_group_cap", int(outcomes[GROUP_CAP].get("shown_back_ms") is not None), ("==", 0)))

    def renderer_of(self, page_id):
        return Census.pid((self.census() or Census([])).page(page_id) or {})

    def pressure(self):
        self.open_pages(PRIVILEGED5 + [PAGES10[5], PAGES10[7]])
        self.settle(self.opts.hide_settle, "pages hide and freeze")
        if self.census() is None:
            self.add(row("pressure", None, note="no debug.webui in this build"))
            return
        reply = self.rpc("debug.webui", {"action": "pressure", "level": "critical"})
        right_after = self.census() or Census([])
        self.add(row("preload_after_pressure", len(right_after.spares("preload")), ("==", 0),
                     note="" if not (reply or {}).get("error") else str(reply.get("error"))[:120]))
        self.until(lambda: not (self.census() or Census([])).pages("hidden", "frozen"), self.opts.open_timeout)
        census = self.census() or Census([])
        shown_groups = {p.get("group") for p in census.pages("active")}
        self.add(row("renderers_after_discard", len(census.renderers()), ("==", len(shown_groups))),
                 row("pages_left_undiscarded", len(census.pages("hidden", "frozen")), ("==", 0)))

    def priority(self):
        self.open_pages(PRIVILEGED5)
        renderers = self.page_renderers(self.census())
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
        self.add(row("page_renderers", len(renderers)),
                 row("backgrounded_renderers", len(backgrounded), ("==", len(renderers)),
                     note=f"ps priority <= {BACKGROUND_PRI} within {self.opts.priority_wait:g} s"),
                 series("background_ms", list(backgrounded.values()), ("max", "<=", self.opts.priority_wait * 1000)))

    def run(self, mode):
        if self.opts.session == "stress":
            summary = stress_session.Stress(self.rpc, log=self.log).build()  # raises StressShapeError
            self.facts["stress"] = summary
        else:
            problems = light_problems((self.rpc("snapshot.get") or {}).get("topology") or {})
            if problems:
                raise ShapeError("not the light session: " + "; ".join(problems))
        getattr(self, mode)()
        if not self.alive():
            self.add(row("app_alive_at_end", 0, ("==", 1)))
        return {"mode": mode, "engine": self.opts.engine, "session": self.opts.session, "rows": self.rows, "facts": self.facts}


class _Envelope:
    """bench-pages.py's view of a run: `call` answers {"result": ...} as bench-stalls.py's Run does."""

    def __init__(self, rpc):
        self.rpc = rpc

    def call(self, method, params=None):
        return {"result": self.rpc(method, params)}


# ---------------------------------------------------------------- command line


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
    parser.add_argument("--runs", type=int, default=20, help="samples per open row")
    parser.add_argument("--chat-turns", type=int, default=2000, help="turns of the frozen chat (0: no chat row)")
    parser.add_argument("--kills", type=int, default=GROUP_CAP + 1)
    parser.add_argument("--out")
    opts = parser.parse_args(argv)
    for name in ("settle", "measure", "hide_settle", "discard_settle", "open_timeout", "priority_wait"):
        if getattr(opts, name) < 0:
            parser.error(f"--{name.replace('_', '-')} must be >= 0")
    if opts.runs < 1 or opts.kills < 1:
        parser.error("--runs and --kills must be >= 1")
    return opts


def main(argv=None):
    opts = parse(sys.argv[1:] if argv is None else argv)
    if sys.platform != "darwin":
        raise SystemExit("bench-webui: macOS only (a fleet GUI mini, never a laptop)")
    launch = load("bench_launch", os.path.join(HERE, "bench_launch.py"))
    procs = load("procs", os.path.join(ROOT, "scripts/perf-bench/procs.py"))
    sharing = load("bench_renderer_sharing", os.path.join(HERE, "bench_renderer_sharing.py"))
    pages = load("bench_pages", os.path.join(HERE, "bench-pages.py"))
    out = os.path.abspath(opts.out or tempfile.mkdtemp(prefix="bench-webui-"))
    os.makedirs(out, exist_ok=True)
    tunables = os.path.join(out, "debug-tunables.json")
    with open(tunables, "w") as handle:  # the React History and App Store pages (bench-pages.py's PAGES tunables)
        json.dump({"version": 1, "values": {"history.surface": "web", pages.PAGES["apps"]["tunable"]: "web"}}, handle)
    app = launch.BenchApp(opts.app, out=out, config={"browser": {"defaultEngine": opts.engine}, "appearance": {"backgroundOpacity": 1}},
                          env={"CMUX_NEXT_DEBUG_TUNABLES_FILE": tunables})
    status = 0
    report = {"mode": opts.mode, "rows": []}
    try:
        app.launch()
        instance = procs.Instance(app.app, app.process.pid)
        bench = Bench(opts, app.rpc, instance,
                      browser_renderers=lambda: {pid for pid, tabs in (sharing.renderer_map(app.socket).get("owners") or {}).items() if tabs},
                      kind_of=procs.kind_of, react_view=pages.react_view, alive=lambda: app.process.poll() is None)
        if opts.mode != "home":
            bench.settle(opts.settle, "launch")
        report = bench.run(opts.mode)
    except (ShapeError, stress_session.StressShapeError) as error:
        print(f"bench-webui: refused: {error}", flush=True)
        report["refused"] = str(error)
        status = 2
    finally:
        app.stop()
    report.update(host=os.uname().nodename, load_average=os.getloadavg(), app=opts.app,
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
