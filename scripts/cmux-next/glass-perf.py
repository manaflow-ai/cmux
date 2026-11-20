#!/usr/bin/env python3
"""Glass perf: what the app costs idle and under load with 1, 10 and 50 glass surfaces on screen (bench glass-perf).

Leo, 2026-11-20: "i hope we got good numbers on idle ram/cpu/gpu and under load too". Before any glass surface
change lands, one harness gives one row per run that every later pass appends to (cmuxterm-hq docs/perf/glass-bench.md).

It launches a bench build of the app (split-spring.sh --config=bench: Release optimization with the debug.* methods)
with a scratch HOME, a background picture (appearance.background, so the glass has art behind it) and one agent
chat on the acpmux test agent (idle_cost_agent.py) open in the window. The chat page is a Chromium page of the real web
UI; the run adds N `.ui-glass` boxes to it (the web UI's own glass class, glass.css; the lens draws at most 32 of
them, lens.ts MAX_RECTS, the rest as plain CSS glass), since the app has no setting for a count of glass surfaces.
For each glass mode (`glass.lens` Debug choice: plain is the default Leo runs; lens refracts) and each count:

  idle  --idle seconds with nothing moving (after --settle s). No frame probe runs in it (its display link would
        wake the app); the window's frames are left out (`-`).
  load  --load seconds of: a reply streaming into the chat (20 words/s), wheel scrolling over the chat, a window
        resize (programmatic setFrame steps of the window, 25 ms apart: AppKit's setFrame, not a live-resize drag),
        3 popovers opened and closed (Command Palette, icon picker, group editor), and the window background
        changed twice (appearance.background between two paintings).

Per window, over every process of the app's bundle (bench_memory.owned: the app, its Chromium helpers, the cmux-tui
daemon and terminal hosts, acpmux) and the WebKit processes it owns:
  rss_mb        RSS at the window's end, total and by group: app, web (Chromium and WebKit helpers), daemon
  cpu_pct       CPU time over the window / its length (100 = one core), total and by group
  energy_mw     the CPU energy macOS accounts to those processes (proc_pid_rusage V6 ri_energy_nj; no GPU or display
                energy, no root needed); with passwordless sudo also powermetrics' GPU and package power
  gpu_pct       the GPU's Device Utilization % (ioreg IOAccelerator PerformanceStatistics, sampled each second): the
                whole Mac's GPU, read with no root and nothing attached to the app (macOS gives no per-process GPU
                time there); a quiet display worker runs nothing else
  gpu_ms_per_frame  gpu_pct x the window's length / the frames drawn (load: the chat page's frames; idle: the
                display's refresh), the GPU busy time per frame
  frame p50/p95 load only: the chat page's requestAnimationFrame intervals (a recorder put in the page for the
                window) and the app's own display-link intervals and main-thread ms per frame (`debug.frames`)

--scenario composer (ask-dc87c949b1, Leo 2026-11-20 on the composer lens: "Like, why not offer the option? I think it
looks neat. I like the refraction."): the chat composer over a chat of --messages messages (the launched app's chat gets
them from the test agent, one echoed turn per two messages) scrolled fast (the transcript's scroller moved 60 CSS px a
frame, top to bottom and back, inside the page) for --load seconds, once per glass mode (the `glass.lens` Debug choice,
Debug Settings > Glass and Overlays > Liquid Glass: `plain` blurs, `lens` refracts). On today's builds the lens bends a
still of the wallpaper (cmuxTheme.backdrop), not the live chat under the composer; the rows say so (`lens_source`:
`wallpaper-still`); a build whose composer bends the live chat (`[data-composer-lens]`, cmux#47802) says `live-content`. Rows: frame p50/p95 (the page's frames), GPU %, CPU %, RSS, energy.

--attach SOCKET --app-pid PID measures an app someone else runs (a person's NIGHTLY), by its control socket only: it
never launches, quits, restarts or ends that app, opens nothing but the chat --session names (with --open; else the
chat already shown), and puts the `glass.lens` choice back as it found it. It adds no glass boxes and runs only
--scenario composer.

Prints one GLASS-PERF {json} line per run and writes {"runs": [...], "rows": [...]} to --json. The web lens's own
GPU cost per frame is the glass-engine bench (webviews/bench/glass-engine.bench.ts), not this one.

Fleet (an owned display mini's console):
  cmux-ci run --class exclusive --display --measurement --label measure --script scripts/measure/split-spring.sh \
    --ref <sha> --arg=--suite=glass-perf --arg=--config=bench --arg=--app-cache \
    --artifact artifacts/split-spring/report.json [--arg=--surfaces=1,10,50] [--arg=--modes=plain,lens]
or `scripts/bench/cmux-bench glass-perf --build <sha>`.

Usage: glass-perf.py --app APP --out DIR [--json PATH] [--scenario surfaces|composer|all] [--surfaces 1,10,50]
       [--modes plain,lens] [--idle 60] [--load 45] [--settle 15] [--messages 2000]
       glass-perf.py --app '/Applications/cmux NIGHTLY.app' --attach SOCKET --app-pid PID --scenario composer
       --session ID [--open] --out DIR
"""
from __future__ import annotations

import argparse
import ctypes
import json
import os
import platform
import shlex
import socket
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench_memory as bm  # noqa: E402  (launch, App, FakeChats, owned, usage, GpuSampler, end_bundle)
from chat_renderer_crash import chat_pages, evaluate  # noqa: E402  (the chat pages, Runtime.evaluate in one)

AGENT = os.path.join(HERE, "idle_cost_agent.py")  # fake_agent.py plus `stream: S R`
ARTS = ("hokusai-great-wave", "dore-leviathan")
MB = 1048576.0
GLASS_ID = "__glassPerf"
# Lines the first prompt carries, so the chat has a long history to scroll (the test agent echoes it back).
HISTORY = "\n".join(f"line {i}: the glass bench scrolls this history while a reply streams in." for i in range(400))


def parse(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--app", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--json")
    p.add_argument("--tag")  # split-spring passes it; the app's name carries the tag
    p.add_argument("--surfaces", default="1,10,50")
    p.add_argument("--modes", default="plain,lens")
    p.add_argument("--idle", type=float, default=60.0)
    p.add_argument("--load", type=float, default=45.0)
    p.add_argument("--settle", type=float, default=15.0)
    p.add_argument("--scenario", choices=("surfaces", "composer", "all"), default="all")
    p.add_argument("--messages", type=int, default=2000, help="composer: the chat's message count (launched app)")
    p.add_argument("--attach", metavar="SOCKET", help="measure the app on this control socket; never launch or end it")
    p.add_argument("--app-pid", type=int)
    p.add_argument("--session", help="attach: the chat to measure (a long one)")
    p.add_argument("--open", action="store_true", help="attach: open --session's chat (it comes to the front)")
    opts, _unknown = p.parse_known_args(argv)
    return opts


def pct(values, q):
    values = sorted(v for v in values if isinstance(v, (int, float)))
    if not values:
        return None
    return round(values[min(len(values) - 1, int(round((len(values) - 1) * q)))], 2)


def group_of(kind: str) -> str:
    if kind == "app":
        return "app"
    if kind.startswith(("cef-", "webkit-")):
        return "web"
    return "daemon"


def energy_nj(pid: int):
    """ri_energy_nj (RUSAGE_INFO_V6 word 42), or None once the pid is gone."""
    buf = (ctypes.c_uint64 * 64)()
    if bm._libproc.proc_pid_rusage(ctypes.c_int(pid), ctypes.c_int(6), ctypes.byref(buf)) != 0:
        return None
    return buf[42]


def powermetrics(seconds: float, into: dict):
    """GPU and package power (mW) over `seconds` with passwordless sudo; nothing without it."""
    if subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode != 0:
        into["powermetrics"] = "no passwordless sudo"
        return
    out = subprocess.run(["sudo", "-n", "powermetrics", "-i", str(int(seconds * 1000)), "-n", "1", "--samplers",
                          "cpu_power,gpu_power"], capture_output=True, text=True, timeout=seconds + 30).stdout
    for line in out.splitlines():
        for key in ("CPU Power", "GPU Power", "Combined Power (CPU + GPU + ANE)"):
            if line.startswith(key + ":"):
                into[key.split(" (")[0].lower().replace(" ", "_") + "_mw"] = float(line.split(":")[1].split()[0])


def window(pid: int, bundle: str, seconds: float, during=None) -> dict:
    """CPU, energy, GPU and (at the end) RSS of every owned process over `seconds`; `during(deadline)` runs meanwhile."""
    start = {}
    for p, (kind, _cmd) in bm.owned(pid, bundle).items():
        got, nj = bm.usage(p), energy_nj(p)
        if got is not None:
            start[p] = (kind, got[3], nj)
    gpu = bm.GpuSampler(interval=1.0)
    power: dict = {}
    pm = threading.Thread(target=powermetrics, args=(seconds, power), daemon=True)
    began = time.monotonic()
    gpu.start()
    pm.start()
    if during:
        during(began + seconds)
    left = began + seconds - time.monotonic()
    if left > 0:
        time.sleep(left)  # test script: the measured window
    elapsed = time.monotonic() - began
    groups: dict = {}
    total = {"rss_mb": 0.0, "cpu_pct": 0.0, "energy_mw": 0.0}
    for p, (kind, _cmd) in bm.owned(pid, bundle).items():
        got, nj = bm.usage(p), energy_nj(p)
        if got is None:
            continue
        g = groups.setdefault(group_of(kind), {"n": 0, "rss_mb": 0.0, "cpu_pct": 0.0, "energy_mw": 0.0})
        g["n"] += 1
        g["rss_mb"] += got[0] / MB
        total["rss_mb"] += got[0] / MB
        if p in start:
            cpu = 100 * (got[3] - start[p][1]) / 1e9 / elapsed
            g["cpu_pct"] += cpu
            total["cpu_pct"] += cpu
            if nj is not None and start[p][2] is not None:
                mw = (nj - start[p][2]) / 1e6 / elapsed
                g["energy_mw"] += mw
                total["energy_mw"] += mw
    pm.join(seconds + 40)
    rounded = lambda d: {k: (round(v, 2) if isinstance(v, float) else v) for k, v in d.items()}  # noqa: E731
    return {"seconds": round(elapsed, 1), "total": rounded(total), "groups": {k: rounded(v) for k, v in groups.items()},
            "gpu": gpu.finish(), "power": power}


class Run:
    def __init__(self, opts):
        self.opts = opts
        self.bundle = os.path.realpath(opts.app.rstrip("/"))
        self.pid = self.app = self.chats = self.session = self.browser = None
        self.frame0 = None

    # -- setup -----------------------------------------------------------------------------------------------------
    def launch(self):
        config = {"appearance": {"background": ARTS[0]},
                  # The chat page stays live when hidden by a popover's focus; nothing hibernates mid-run.
                  "browser": {"hibernation": "off", "freezeHiddenTabs": "off"}}
        # The app activates (its window in front, so its frames are drawn) and may start agents (the test agent).
        env = {"CMUX_NEXT_NO_ACTIVATE": None, "ACPMUX_AGENT_LAUNCH": None}
        self.pid, sock, _scratch = bm.launch(self.bundle, config, env, direct=True)
        self.app = bm.App(self.bundle, sock)
        time.sleep(5)  # test script: the first window settles
        self.chats = bm.FakeChats(self.app, self.bundle, AGENT)
        made = subprocess.run([self.app.cli_path, "acp", "new", "--json", "-d", "-m", bm.FAKE_AGENT_ID,
                               "glass bench chat\n\n" + HISTORY], capture_output=True, text=True, timeout=120,
                              env=self.chats.env)
        try:
            self.session = json.loads(made.stdout)["sessionId"]
        except (ValueError, KeyError):
            raise SystemExit(f"glass-perf: acp new: {(made.stdout + made.stderr).strip()[:400]}")
        opened = self.app.action("agent.openSessionTab", session=self.session, focus=True)
        if opened.get("error") or opened.get("code"):
            raise SystemExit(f"glass-perf: agent.openSessionTab: {opened.get('message') or opened.get('error')}")
        # The group editor opens on the shown workspace's group.
        self.app.action("newWorkspaceGroup", name="Glass bench")
        self.app.call("debug.tunables", {"action": "activate"})
        frame = self.app.call("debug.window_frame", {})
        self.frame0 = (frame or {}).get("frame")
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            shown = [p for p in chat_pages(self.app) if not p.get("hidden")]
            if shown:
                self.browser = shown[0]["browser"]
                break
            time.sleep(1)  # test script: waiting for the chat page to load
        if self.browser is None:
            raise SystemExit("glass-perf: no shown chat page (renderers.list)")

    def fill_history(self):
        """The chat gets --messages messages: one echoed turn of the test agent per two (the first turn made two)."""
        turns = max(0, self.opts.messages // 2 - 1)
        failed = 0
        for i in range(turns):
            sent = subprocess.run([self.app.cli_path, "acp", "send", "--quiet", self.session,
                                   f"history {i}: the composer bench scrolls this chat fast."],
                                  capture_output=True, text=True, timeout=60, env=self.chats.env)
            failed += sent.returncode != 0
        return {"turns": turns, "failed": failed, "messages": 2 + 2 * (turns - failed)}

    def attach(self):
        """An app someone else runs: its socket and pid only; nothing launched, nothing ended."""
        self.app = bm.App(self.bundle, self.opts.attach)
        # The app on that socket says its own pid (`app identify`), unless --app-pid names it.
        self.pid = self.opts.app_pid or self.app.identify().get("pid")
        if not self.pid:
            raise SystemExit(f"glass-perf: {self.opts.attach}: no app answers identify (pass --app-pid)")
        if self.opts.open and self.opts.session:
            opened = self.app.action("agent.openSessionTab", session=self.opts.session, focus=True)
            if opened.get("error") or opened.get("code"):
                raise SystemExit(f"glass-perf: agent.openSessionTab: {opened.get('message') or opened.get('error')}")
            time.sleep(3)  # test script: the chat page shows
        shown = [p for p in chat_pages(self.app) if not p.get("hidden")]
        if not shown:
            raise SystemExit("glass-perf: no shown chat page in the attached app (open a long chat, or pass --session --open)")
        self.browser = shown[0]["browser"]

    def lens_choice(self):
        """The `glass.lens` choice now (None: the default, or a build without debug.tunables)."""
        row = self.app.call("debug.tunables", {"action": "get", "key": "glass.lens"}) or {}
        return None if row.get("error") else row.get("value")

    SCROLL_EXTENT = """(() => { let best = 0;
  for (const e of document.querySelectorAll('*')) { if (/(auto|scroll)/.test(getComputedStyle(e).overflowY) &&
    e.scrollHeight > e.clientHeight + 200) best = Math.max(best, e.scrollHeight); }
  return best; })()"""

    def pick_chat_page(self, wait: float = 90.0) -> dict:
        """Points self.browser at the shown chat page with the tallest scroller: the bench chat's transcript.

        renderers.list's order differs by host: on cmux20 (step 972b27e7, 2026-11-20) the first shown page had no
        scroller at all and both composer rows measured nothing. Waits up to `wait` s for a transcript to render."""
        deadline, seen = time.monotonic() + wait, []
        while True:
            seen = []
            for page in chat_pages(self.app):
                if page.get("hidden"):
                    continue
                extent, _error = evaluate(self.app, page["browser"], self.SCROLL_EXTENT)
                seen.append((extent if isinstance(extent, (int, float)) else 0, page["browser"]))
            seen.sort(key=lambda s: s[0], reverse=True)
            if (seen and seen[0][0] > 0) or time.monotonic() >= deadline:
                break
            time.sleep(2)  # test script: the transcript is still rendering
        if seen and seen[0][0] > 0:
            self.browser = seen[0][1]
        return {"pages": len(seen), "extent": seen[0][0] if seen else None}

    def composer(self, mode: str) -> dict:
        """The composer over the chat scrolled fast for --load seconds: page frames, CPU, GPU, RSS, energy."""
        picked = self.pick_chat_page()
        probe = self.js("""(() => {
  const all = [...document.querySelectorAll('*')].filter((e) => /(auto|scroll)/.test(getComputedStyle(e).overflowY) &&
    e.scrollHeight > e.clientHeight + 200);
  all.sort((a, b) => b.scrollHeight - a.scrollHeight);
  const sc = all[0];
  if (!sc) return JSON.stringify({error: 'no scroller'});
  window.__gpScroller = sc;
  const composer = document.querySelector('textarea, [contenteditable="true"]');
  const glass = document.querySelectorAll('.ui-glass').length;
  return JSON.stringify({scroll_height: sc.scrollHeight, client_height: sc.clientHeight, composer: !!composer, glass,
    lens: document.documentElement.getAttribute('data-glass') || null,
    composer_lens: !!document.querySelector('[data-composer-lens]')});
})()""")
        try:
            info = json.loads(probe or "{}")
        except ValueError:
            info = {"error": "unreadable probe"}
        info["page"] = picked
        time.sleep(self.opts.settle)  # test script: the page rests before the window
        self.js("""(() => { const sc = window.__gpScroller; if (!sc) return 'none';
  const a = window.__gpRaf = {t: [], on: true}; let dir = 1;
  const f = (t) => { if (!a.on) return; a.t.push(t);
    if (sc.scrollTop + sc.clientHeight >= sc.scrollHeight - 2) dir = -1; else if (sc.scrollTop <= 0) dir = 1;
    sc.scrollTop += 60 * dir; requestAnimationFrame(f); };
  requestAnimationFrame(f); return 'ok'; })()""")
        moving = window(self.pid, self.bundle, self.opts.load)
        page = self.page_intervals()
        # The lens attaches after the mode switch; read its marker once the window is over.
        info["composer_lens"] = bool(self.js("!!document.querySelector('[data-composer-lens]')"))
        util = moving["gpu"].get("device_utilization_pct")
        return {"state": "composer-scroll", "mode": mode, "surfaces": info.get("glass"), "probe": info, **moving,
                "lens_source": (("live-content" if info.get("composer_lens") else "wallpaper-still")
                                if mode == "lens" else None), "gpu_pct": util,
                "gpu_ms_per_frame": round(util / 100 * moving["seconds"] * 1000 / len(page), 3)
                if isinstance(util, (int, float)) and page else None,
                "frame": {"page_frames": len(page), "page_p50_ms": pct(page, 0.5), "page_p95_ms": pct(page, 0.95),
                          "page_max_ms": pct(page, 1.0)}}

    def page_intervals(self) -> list:
        raw = self.js("(() => { const a = window.__gpRaf; if (!a) return '[]'; a.on = false; const d = []; "
                      "for (let i = 1; i < a.t.length; i++) d.push(+(a.t[i] - a.t[i - 1]).toFixed(2)); "
                      "return JSON.stringify(d); })()")
        try:
            return json.loads(raw or "[]")
        except ValueError:
            return []

    def js(self, expression: str):
        value, error = evaluate(self.app, self.browser, expression)
        if error:
            print(f"glass-perf: evaluate: {error}", file=sys.stderr)
        return value

    def set_mode(self, mode: str) -> str:
        reply = self.app.call("debug.tunables", {"action": "set", "key": "glass.lens", "value": mode}) or {}
        return "ok" if not reply.get("error") else str(reply["error"])[:200]

    def set_glass(self, count: int) -> dict:
        expression = f"""(() => {{
  document.getElementById({json.dumps(GLASS_ID)})?.remove();
  const n = {int(count)};
  if (n > 0) {{
    const root = document.createElement('div');
    root.id = {json.dumps(GLASS_ID)};
    root.style.cssText = 'position:fixed;inset:0;pointer-events:none;z-index:2147483000';
    const cols = Math.ceil(Math.sqrt(n * 1.6)), rows = Math.ceil(n / cols), w = innerWidth / cols, h = innerHeight / rows;
    for (let i = 0; i < n; i++) {{
      const d = document.createElement('div');
      d.className = 'ui-glass';
      d.style.cssText = `position:absolute;left:${{(i % cols) * w + w * 0.1}}px;top:${{Math.floor(i / cols) * h + h * 0.1}}px;` +
        `width:${{w * 0.8}}px;height:${{h * 0.8}}px;border-radius:14px`;
      root.appendChild(d);
    }}
    document.body.appendChild(root);
  }}
  return JSON.stringify({{added: n, total: document.querySelectorAll('.ui-glass').length,
    lens: document.documentElement.getAttribute('data-glass') || null}});
}})()"""
        try:
            return json.loads(self.js(expression) or "{}")
        except ValueError:
            return {}

    # -- the load ----------------------------------------------------------------------------------------------------
    def wheel(self, dy: int, count: int = 12):
        x = 900 if not self.frame0 else int(self.frame0[2] * 0.6)
        self.app.call("debug.sidebar_wheel", {"x": x, "y": 400, "dy": dy, "count": count, "interval_ms": 16})

    def resize(self, steps: int = 40):
        if not self.frame0:
            return
        x, y, w, h = self.frame0
        for i in range(steps):
            shrink = 300 * (i % 20) / 19 if (i // 20) % 2 == 0 else 300 * (19 - i % 20) / 19
            self.app.call("debug.window_frame", {"frame": [x, y, w - shrink, h - shrink / 2]})
            time.sleep(0.025)  # test script: one resize step
        self.app.call("debug.window_frame", {"frame": [x, y, w, h]})

    def popovers(self) -> list:
        done = []
        self.app.action("commandPalette")
        time.sleep(1.0)  # test script: the palette shows
        self.app.action("commandPalette")
        done.append("palette")
        for kind in ("icon_picker", "group_editor"):
            reply = self.app.call("debug.overlay_open_bench", {"kind": kind, "mode": "as_is"}, timeout=30) or {}
            done.append(kind if not reply.get("error") else f"{kind}: {str(reply['error'])[:120]}")
        return done

    def load(self, deadline: float, notes: dict):
        sent = subprocess.run([self.app.cli_path, "acp", "send", "--no-wait", self.session,
                               f"stream: {int(self.opts.load) + 5} 20"], capture_output=True, text=True, timeout=60,
                              env=self.chats.env)
        notes["stream"] = sent.returncode == 0
        steps = [lambda: [self.wheel(-5) or time.sleep(0.1) for _ in range(20)],
                 lambda: self.resize(),
                 lambda: notes.__setitem__("popovers", self.popovers()),
                 lambda: [self.app.call("settings.set", {"path": "appearance.background", "value": art})
                          or time.sleep(2) for art in (ARTS[1], ARTS[0])],
                 lambda: [self.wheel(5) or time.sleep(0.1) for _ in range(20)]]
        while time.monotonic() < deadline - 1:
            for step in steps:
                if time.monotonic() >= deadline - 1:
                    break
                step()

    # -- one run -----------------------------------------------------------------------------------------------------
    def measure(self, mode: str, count: int) -> list[dict]:
        glass = self.set_glass(count)
        time.sleep(self.opts.settle)  # test script: the app settles before the idle window
        idle = window(self.pid, self.bundle, self.opts.idle)
        refresh_ms = 1000 / 60
        util = idle["gpu"].get("device_utilization_pct")
        idle_row = {"state": "idle", "mode": mode, "surfaces": count, "glass": glass, **idle,
                    "gpu_pct": util, "frame": None,
                    "gpu_ms_per_frame": round(util / 100 * refresh_ms, 3) if isinstance(util, (int, float)) else None}
        self.js("(() => { const a = window.__gpRaf = {t: [], on: true}; const f = (t) => { if (!a.on) return; "
                "a.t.push(t); requestAnimationFrame(f); }; requestAnimationFrame(f); return 'ok'; })()")
        self.app.call("debug.frames", {"action": "start"})
        notes: dict = {}
        loaded = window(self.pid, self.bundle, self.opts.load, during=lambda d: self.load(d, notes))
        host = self.app.call("debug.frames", {"action": "stop"}) or {}
        page = self.page_intervals()
        util = loaded["gpu"].get("device_utilization_pct")
        frames = len(page) or host.get("frames") or 0
        load_row = {"state": "load", "mode": mode, "surfaces": count, "glass": glass, **loaded, "load": notes,
                    "gpu_pct": util,
                    "gpu_ms_per_frame": round(util / 100 * loaded["seconds"] * 1000 / frames, 3)
                    if isinstance(util, (int, float)) and frames else None,
                    "frame": {"page_frames": len(page), "page_p50_ms": pct(page, 0.5), "page_p95_ms": pct(page, 0.95),
                              "page_max_ms": pct(page, 1.0), "host_frames": host.get("frames"),
                              "host_p50_ms": host.get("p50_ms"), "host_p95_ms": host.get("p95_ms"),
                              "host_missed": host.get("missed"), "main_p95_ms": host.get("main_p95_ms"),
                              "refresh_ms": host.get("refresh_ms")}}
        self.app.call("settings.set", {"path": "appearance.background", "value": ARTS[0]})
        if self.frame0:
            self.app.call("debug.window_frame", {"frame": self.frame0})
        time.sleep(5)  # test script: the reply ends and the window rests before the next count
        return [idle_row, load_row]


def rows_of(runs: list[dict], sha: str, host: str) -> list[dict]:
    """One flat row per run, as docs/perf/glass-bench.md lists them (pure)."""
    out = []
    for r in runs:
        f = r.get("frame") or {}
        out.append({"date": time.strftime("%Y-%m-%d", time.gmtime()), "sha": sha[:12], "host": host,
                    "state": r["state"], "mode": r["mode"], "surfaces": r["surfaces"],
                    "rss_mb": r["total"]["rss_mb"], "cpu_pct": r["total"]["cpu_pct"],
                    "gpu_pct": r.get("gpu_pct"), "gpu_ms_per_frame": r.get("gpu_ms_per_frame"),
                    "frame_p50_ms": f.get("page_p50_ms"), "frame_p95_ms": f.get("page_p95_ms"),
                    "energy_mw": r["total"]["energy_mw"], "gpu_power_mw": (r.get("power") or {}).get("gpu_power_mw"),
                    "lens_source": r.get("lens_source")})
    return out


def main(argv=None) -> int:
    opts = parse(argv)
    os.makedirs(opts.out, exist_ok=True)
    bm._direct_launch = not opts.attach
    sha = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True, cwd=HERE).stdout.strip()
    host = (subprocess.run(["scutil", "--get", "ComputerName"], capture_output=True, text=True).stdout.strip()
            or socket.gethostname())
    chip = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()
    print(f"GLASS-PERF-MACHINE host={host} sha={sha} chip={chip!r} macos={platform.mac_ver()[0]}", flush=True)
    report = {"sha": sha, "host": host, "chip": chip, "args": vars(opts), "runs": [], "errors": []}
    run = Run(opts)
    status = 0
    attached = bool(opts.attach)
    if attached and opts.scenario != "composer":
        raise SystemExit("glass-perf: --attach runs only --scenario composer")
    modes = [m for m in opts.modes.split(",") if m]
    found = None

    def record(r):
        report["runs"].append(r)
        print("GLASS-PERF " + json.dumps(r, sort_keys=True), flush=True)

    try:
        if attached:
            run.attach()
            found = run.lens_choice()
            report["lens_before"] = found
        else:
            run.launch()
            if opts.scenario in ("composer", "all"):
                report["history"] = run.fill_history()
                print(f"glass-perf: history {report['history']}", flush=True)
        for mode in modes:
            set_to = run.set_mode(mode)
            if set_to != "ok":
                report["errors"].append(f"glass.lens={mode}: {set_to}")
                continue
            if opts.scenario in ("composer", "all"):
                record(run.composer(mode))
            if opts.scenario in ("surfaces", "all") and not attached:
                for count in [int(c) for c in opts.surfaces.split(",") if c]:
                    for r in run.measure(mode, count):
                        record(r)
                run.set_glass(0)
    except (SystemExit, KeyboardInterrupt, OSError, subprocess.SubprocessError) as error:
        report["errors"].append(f"{type(error).__name__}: {error}"[:2000])
        print(f"glass-perf: {error}", file=sys.stderr)
        status = 1
    finally:
        if attached:
            if run.app is not None:
                # The person's choice back as it was (None: the default), and nothing of the bench left in the page.
                run.app.call("debug.tunables", {"action": "set", "key": "glass.lens", "value": found})
                if run.browser is not None:
                    run.js("(() => { if (window.__gpRaf) window.__gpRaf.on = false; delete window.__gpScroller; return 'ok'; })()")
        else:
            bm.end_bundle(run.bundle)
    report["rows"] = rows_of(report["runs"], sha, host)
    for row in report["rows"]:
        print("GLASS-PERF-ROW " + json.dumps(row, sort_keys=True), flush=True)
    path = opts.json or os.path.join(opts.out, "glass-perf.json")
    with open(path, "w") as f:
        json.dump(report, f, indent=1)
    print(f"glass-perf: {len(report['runs'])} runs, report {path} ({shlex.quote(path)})", flush=True)
    return status if report["runs"] else 1


if __name__ == "__main__":
    sys.exit(main())
