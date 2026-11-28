#!/usr/bin/env python3
"""Graceful web swap films and edit-to-visible latency on a fleet Mac GUI session (cmux#50535).

The scenario of the capture-Mac runs (scripts/measure/graceful-swap.py on air-blue), made on the step's own app:

  graceful-swap-fleet.py --app "cmux DEV <tag>.app" --tree CHECKOUT --out DIR [--runs 20] [--films LIST]
                         [--series LIST] [--window X,Y,W,H]

1. A fresh HOME (DIR/scratch/home): cmux-next.json at HOME/.config/cmux/cmux-next.json (CMUX_NEXT_CONFIG_FILE),
   web-dev.json beside it, and the fake ACP agent (cmux-tui/crates/acpmux/tests/fake_agent.py) as a harness
   profile in HOME/.config/cmux-next/harnesses/gswfake.toml (and `agent.harness.add`, which the app reads at once).
   The app is launched directly (a fleet step has no LaunchServices session), as bench_memory.launch does.
2. One window: sidebar | Settings | chat-a (focused: a half-typed draft and an image chip) | chat-b (unfocused: a
   two-line draft), with chat-c (a draft) as a hidden tab behind chat-b. Chats are `cmux agents chat new --harness
   gswfake`; drafts go through the app's acpmux socket (`_acpmux/draft_set {sessionId, text}`); the chip through
   `debug.agent_pane set_files`. The regions are the panes' own rects (their first terminal's window_fraction,
   read before the terminals close), so nothing here assumes a display size.
3. Films, each by the app's own recorder (`debug.motion` record_start: every frame the window server composites
   for this app's windows, from the window's top-left corner, written off the main thread; no Screen Recording
   grant), analyzed by graceful-swap.py's `analyze` (same regions, same verdicts), one `GRACEFUL_SWAP {json}` each:
     install-app   web-overlay.sh install-app APP (the app's own bundle: a same-web swap must look like nothing)
     off           web-overlay.sh off
     background    web-dev.json "trigger":"background", then install-app again (pages in sight must hold it)
     customize-try / customize-revert   cmux customize try RECIPE --minutes 5, then cmux customize revert
4. Latency series on the dev server (`web-overlay.sh server --local --worktree TREE`), one `.tsx` save per film,
   undone on the next (`GRACEFUL_SWAP_LATENCY {json}` each, the bench's hot_swap_mac_* rows):
     composer   ComposerFoot.tsx: watch=focused (chat-a) gives the `focused` row and watch=unfocused (chat-b) the
                `unfocused` row, from the same films; the other regions (sidebar, Settings) must keep their picture
     hidden     the same save while chat-c is hidden behind chat-b, then selecting chat-c (tab.focus) is the filmed
                trigger: the sample is settled_ms of the pane (show to the last frame that differs from the end
                picture: when the hidden tab, shown again, stands with the change), the `hidden` row
     settings   SettingsApp.tsx's title (watch=settings; both chats, with their drafts, must keep): an extra
                `unfocused` receipt labelled settings, only with --series settings
--tree is the commit under test (graceful-swap-fleet.sh --build-at=SHA checks it out and builds it): its
graceful-swap.py does the analysis, its webviews are what the dev server serves and the saves edit.
`scripts/bench/cmux-bench graceful-swap --import LOG` takes the step log (the last latency line of a log; import
each receipt file in DIR/latency/*.json for every surface). Writes DIR/films/*.mov(+.frames.json), DIR/runs/...
(run.json per film), DIR/latency/<series>-<surface>.json and DIR/summary.json.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shlex
import shutil
import socket
import struct
import subprocess
import sys
import time
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
NEXT = ROOT / "scripts" / "cmux-next"
sys.path.insert(0, str(NEXT))
import bench_launch as bl  # noqa: E402
import bench_memory as bm  # noqa: E402
from state_wait import wait_stable, wait_until  # noqa: E402


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


GS = None  # graceful-swap.py of the tree under test (--tree), loaded in main()
STRESS = load("perf_stress_session", NEXT / "perf-stress-session.py")

HARNESS_ID = "gswfake"
# The film's tail after a latency save: a save not shown by then is a miss, counted as at least this long by
# the importer. 2.5 s hid saves that showed at ~3 s (18 of 20 at 75ef6ec3); 8 s measures them.
LATENCY_WINDOW_S = 8.0

EDITS = {
    "composer": ("webviews/src/agent-session/acpmux/ComposerFoot.tsx",
                 "{children}</InQuietRow.Provider>",
                 "{children}<span style={{marginLeft: 6}}>GSW</span></InQuietRow.Provider>"),
    "settings": ("webviews/src/pages/settings/components/SettingsApp.tsx",
                 '{t("settingsPage.title")}</h2>', '{t("settingsPage.title")} GSW</h2>'),
}
DRAFTS = {"a": "half-typed in the focused chat, caret at the end",
          "b": "a draft for the unfocused chat, kept across the swap: line one\nand a second line",
          "c": "a draft in the hidden tab, behind chat-b"}


def log(text: str) -> None:
    print(text, flush=True)


def host_now() -> float:
    """The recorder's clock (CACurrentMediaTime: mach_absolute_time in seconds)."""
    return time.clock_gettime(time.CLOCK_UPTIME_RAW)


def png(path: Path, w: int = 96, h: int = 64) -> None:
    """A small striped PNG for the image chip (no tools needed)."""
    rows = b"".join(b"\x00" + b"".join(bytes((40 + (x * 3) % 200, 90 + (y * 2) % 150, 200)) for x in range(w))
                    for y in range(h))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


class Scenario:
    def __init__(self, opts):
        self.opts = opts
        self.app = os.path.realpath(opts.app)
        self.out = Path(opts.out).resolve()
        self.scratch = self.out / "scratch"
        self.home = self.scratch / "home"
        self.config = self.home / ".config" / "cmux" / "cmux-next.json"
        # Harness profiles: `cmux-next` on macOS (cmux-config NEXT_DIR, location.rs; #53567).
        self.harnesses = self.home / ".config" / "cmux-next" / "harnesses"
        self.work = self.scratch / "work"
        self.tree = Path(opts.tree).resolve()
        self.cli_path = os.path.join(self.app, "Contents/Resources/bin/cmux")
        self.socket = None
        self.st = None
        self.regions: list[tuple[str, tuple[int, int, int, int]]] = []
        self.chats: dict[str, dict] = {}
        self.workspace = self.screen = None
        self.panes: list[str] = []
        self.probe_src = None
        self.results = {"films": {}, "latency": {}, "setup": {}}

    # The app.

    def env(self) -> dict:
        path = os.environ.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        return {**os.environ, "HOME": str(self.home), "CFFIXED_USER_HOME": str(self.home),
                "TMPDIR": str(self.scratch / "tmp") + "/", "CMUX_NEXT_CONFIG_FILE": str(self.config),
                "CMUX_WEB_SLOT_STATE_DIR": str(self.scratch / "web-slot"), "PATH": path, "APP": self.app,
                # web-overlay.sh checks and writes for this app only; unset, it checks the Mac's installed
                # NIGHTLY/NEXT, whose web ABI is not the tree's (step 294dc843: ABI 9 vs 7, every film no-op).
                "CMUX_WEB_OVERLAY_APP": self.app,
                "CMUX": self.cli_path, "CMUX_APP_SOCKET": self.socket or ""}

    def rpc(self, method, params=None, timeout=60):
        return bl.rpc_at(self.socket, method, params, timeout)

    def cli(self, *args, timeout=120, json_out=True):
        argv = [self.cli_path, "--app-socket", self.socket] + (["--json"] if json_out else []) + list(args)
        done = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, env=self.env())
        text = (done.stdout or "").strip()
        if json_out:
            try:
                return json.loads(text) if text else {"error": done.stderr.strip()[:400] or f"exit {done.returncode}"}
            except ValueError:
                return {"error": (text + done.stderr).strip()[:400], "exit": done.returncode}
        return {"exit": done.returncode, "out": (text + done.stderr)[-1500:]}

    def launch(self):
        session = bl.gui_session()
        log(f"GSW-FLEET session: {json.dumps(session, default=str)[:400]}")
        if not session.get("ok"):
            sys.exit(f"graceful-swap-fleet: no GUI session on this host ({bl.no_session_detail(session)})")
        for d in (self.home / "Library", self.config.parent, self.harnesses, self.work, self.scratch / "tmp"):
            d.mkdir(parents=True, exist_ok=True)
        fake = ROOT / "cmux-tui/crates/acpmux/tests/fake_agent.py"
        (self.harnesses / f"{HARNESS_ID}.toml").write_text(
            f'schema = 1\nid = "{HARNESS_ID}"\nname = "GS test agent"\nprotocol = "acp"\n'
            f'command = {json.dumps(sys.executable)}\nargs = [{json.dumps(str(fake))}]\n')
        bm.clear_saved_state(self.app)
        x, y, w, h = self.opts.window.split(",")
        pid, sock, _ = bm.launch(self.app, {}, extra_env={
            "CMUX_NEXT_CONFIG_FILE": str(self.config), "CFFIXED_USER_HOME": str(self.home),
            "CMUX_NEXT_TEST_WINDOW_FRAME": f"{x},{y},{w},{h}", "CMUX_NEXT_TEST_WINDOW_SCREEN": "0",
            "CMUX_DEV_BACKEND_MODE": "local", "SHELL": "/bin/zsh"}, direct=True, scratch=str(self.scratch))
        self.socket = sock
        log(f"GSW-FLEET launched pid {pid} socket {sock}")
        if not STRESS.wait(lambda: (self.rpc("debug.windows") or {}).get("windows"), 90, step=0.5):
            sys.exit("graceful-swap-fleet: the app showed no window in 90 s")
        self.st = STRESS.Stress(self.rpc)
        self.fake = fake

    # The scenario.

    def harness(self):
        app = bm.App(self.app, self.socket)
        for _ in range(5):
            added = app.run("agent.harness.add", id=HARNESS_ID, name="GS test agent", command=sys.executable,
                            args=shlex.quote(str(self.fake)), protocol="acp", replace="true")
            if "timeout" not in str(added.get("code") or added.get("error") or ""):
                break
            time.sleep(5)  # the app is still starting: the add goes on; try again (it replaces the same id)
        log(f"GSW-FLEET harness add: {json.dumps(added)[:300]}")
        log(f"GSW-FLEET trust: {json.dumps(self.cli('setup', 'trust', str(self.work)))[:300]}")

    def pane_tabs(self, pane):
        return self.st.tabs(self.workspace, pane)

    def shown_tab(self, pane):
        """The tab `pane` has selected and on screen: debug.surfaces' selected_tab when its shown_tab agrees, else
        the topology pane's `selected`. A pane's `tabs` records carry no selected flag, so they cannot say."""
        for window in (self.rpc("debug.surfaces", {}, 30) or {}).get("windows") or []:
            for entry in window.get("panes") or []:
                if str(entry.get("pane")) == str(pane) and entry.get("selected_tab"):
                    shown = entry.get("shown_tab")
                    return entry["selected_tab"] if shown in (None, entry["selected_tab"]) else None
        record = next((p for p in self.st.panes(self.st.workspace(self.workspace)) if p.get("id") == pane), None)
        return (record or {}).get("selected")

    def show_tab(self, key, timeout=10.0, raise_on_timeout=True):
        """Selects chat `key`'s tab in its pane, keyboard focus staying where it is, and waits until the pane shows it.
        `cmux tab ID show` only describes a tab (a properties table): it never selected one, so the hidden series
        filmed chat-b throughout. Raises when the pane does not show the tab, so a run never measures the wrong page."""
        tab, pane = self.chats[key]["tab"], self.chats[key]["pane"]
        reply = self.st.action("tab.focus", target=f"tab:{tab}", focus=False, timeout=30)
        if not STRESS.wait(lambda: self.shown_tab(pane) == tab, timeout, step=0.02):
            if not raise_on_timeout:
                log(f"GSW-FLEET chat-{key} was not shown in {timeout:g} s (it shows {self.shown_tab(pane)})")
                return None
            raise RuntimeError(f"chat-{key} ({tab}) was not shown in pane {pane} in {timeout:g} s "
                               f"(it shows {self.shown_tab(pane)}; tab.focus said {json.dumps(reply)[:200]})")
        return tab

    def fractions(self) -> dict[str, list[float]]:
        """{pane id: its terminal's window_fraction [x, y, w, h]} from debug.surfaces."""
        found = {}

        def walk(node):
            if isinstance(node, dict):
                frac = (node.get("surface") or {}).get("window_fraction") if isinstance(node.get("surface"), dict) else None
                if node.get("pane") and frac:
                    found[str(node["pane"])] = frac
                for value in node.values():
                    walk(value)
            elif isinstance(node, list):
                for value in node:
                    walk(value)
        walk(self.rpc("debug.surfaces", {}, 60))
        if found and not all(p in found for p in self.panes) and len(found) == len(self.panes):
            # The report names panes by its own key: the panes are left to right, so order by x.
            found = dict(zip(self.panes, sorted(found.values(), key=lambda f: f[0])))
        return found

    def window_points(self):
        reply = self.rpc("debug.window_list") or {}
        main = [w for w in reply.get("windows") or [] if w.get("kind") == "main"]
        frame = (main[0] if main else {}).get("frame") or []
        screen = (self.rpc("debug.window_frame", {"screen": 0}) or {}).get("visible_frame") or []
        rect = lambda r: [r.get(k, 0) for k in ("x", "y", "width", "height")] if isinstance(r, dict) else list(r)
        return rect(frame), rect(screen)

    def build(self):
        st = self.st
        self.harness()
        self.workspace = st.new_workspace()
        if not self.workspace:
            sys.exit(f"graceful-swap-fleet: no new workspace ({st.refusals[-2:]})")
        st.show(self.workspace)
        first = STRESS.wait(lambda: (st.panes(st.workspace(self.workspace)) or [{}])[0].get("id"), 30, step=0.1)
        p1 = st.split(self.workspace, first, "splitRight")
        p2 = st.split(self.workspace, p1, "splitRight") if p1 else None
        if not (first and p1 and p2):
            sys.exit(f"graceful-swap-fleet: the three panes did not come ({st.refusals[-3:]})")
        self.panes = [first, p1, p2]
        space = st.workspace(self.workspace) or {}
        self.screen = ((space.get("screens") or [{}])[0]).get("id")
        terminals = {p: [t.get("id") for t in st.settled_tabs(self.workspace, p) if t.get("kind") == "terminal"]
                     for p in self.panes}
        # The terminals draw, so their window fractions are set: every pane has one and they stopped moving.
        fracs = STRESS.wait(lambda: (lambda f: f if all(p in f for p in self.panes) else None)(self.fractions()), 20, step=0.5)
        fracs = wait_stable(self.fractions, "the panes' window fractions", timeout=20, interval=0.25,
                            raise_on_timeout=False) if fracs else self.fractions()
        frame, screen = self.window_points()
        log(f"GSW-FLEET layout: panes {self.panes} fractions {fracs} window {frame} screen {screen}")
        self.results["setup"].update(panes=self.panes, fractions=fracs, window=frame, screen=screen)
        if not all(p in fracs for p in self.panes) or len(frame) != 4:
            sys.exit("graceful-swap-fleet: no rect for every pane (debug.surfaces window_fraction) or no window frame")
        self.frame_points = frame
        # Chats: a and b's sibling c, each on the fake agent.
        for key, pane in (("a", p1), ("b", p2), ("c", p2)):
            made = self.cli("agents", "chat", "new", "--pane", pane, "--harness", HARNESS_ID, "--cwd", str(self.work),
                            "--name", f"chat-{key}", "--", f"hello {key}")
            log(f"GSW-FLEET chat-{key}: {json.dumps(made)[:400]}")
            result = made.get("result") or {}
            if not result.get("chat") or not result.get("tab"):
                sys.exit(f"graceful-swap-fleet: chat-{key} did not open: {json.dumps(made)[:400]}")
            if result.get("pane") != pane:
                moved = self.cli("tab", result["tab"], "move", "--workspace", self.workspace, "--screen", self.screen,
                                 "--pane", pane, "--index", "0", json_out=False)
                log(f"GSW-FLEET chat-{key} moved to {pane}: {moved}")
            self.chats[key] = {"session": result["chat"], "tab": result["tab"], "pane": pane}
        # Settings in the first pane.
        st.focus_pane(first)
        before = {t.get("id") for t in self.pane_tabs(first)}
        settings = self.cli("app", "settings", json_out=False)
        log(f"GSW-FLEET settings: {settings}")
        new = STRESS.wait(lambda: [t for t in self.pane_tabs(first) if t.get("id") not in before] or None, 20, step=0.25)
        if not new:
            # Opened elsewhere (a pane of its own): move the tab that is not in any of our panes' old lists.
            every = {p.get("id"): p for p in st.panes(st.workspace(self.workspace))}
            stray = [(pid, t) for pid, p in every.items() if pid not in self.panes for t in p.get("tabs") or []]
            log(f"GSW-FLEET settings tab not in the first pane; others: {[(p, t.get('kind'), t.get('id')) for p, t in stray]}")
            if stray:
                self.cli("tab", stray[0][1]["id"], "move", "--workspace", self.workspace, "--screen", self.screen,
                         "--pane", first, "--index", "0", json_out=False)
        # The terminals go; each pane shows its page. A pane whose page did not come keeps its terminal: closing its only
        # tab would close the pane and move every rect measured above.
        settled = STRESS.wait(lambda: [t for t in self.pane_tabs(first) if t.get("kind") != "terminal"] or None, 10, step=0.25)
        if not settled:
            log(f"GSW-FLEET the first pane has no Settings tab; its tabs: {self.pane_tabs(first)}")
            terminals.pop(first, None)
        for pane, ids in terminals.items():
            for tab in ids:
                st.action("closeTab", target=f"tab:{tab}", focus=False)
        closed = {tab for ids in terminals.values() for tab in ids}
        if not STRESS.wait(lambda: not any(t.get("id") in closed for p in self.panes for t in self.pane_tabs(p)), 15, step=0.1):
            log(f"GSW-FLEET the terminals did not all close in 15 s: {[self.pane_tabs(p) for p in self.panes]}")
        self.show_tab("b")
        self.show_tab("a")
        # Drafts through acpmux, the chip through the page's file input, then chat-a has the focus.
        sock = bm.FakeChats.acpmux_socket(self.app)
        self.acpmux = sock
        for key, text in DRAFTS.items():
            log(f"GSW-FLEET draft {key}: {json.dumps(self.acpmux_call('_acpmux/draft_set', {'sessionId': self.chats[key]['session'], 'text': text}))[:300]}")
        image = self.work / "chip.png"
        png(image)
        st.focus_pane(p1)
        ready = STRESS.wait(lambda: (lambda r: r if isinstance(r, dict) and not r.get("error") else None)(
            self.rpc("debug.agent_pane", {"action": "readiness", "pane": p1}, 30)), 30, step=0.5)
        log(f"GSW-FLEET chat-a readiness: {json.dumps(ready)[:300]}")
        chip = self.rpc("debug.agent_pane", {"action": "set_files", "pane": p1, "paths": [str(image)]}, 30)
        log(f"GSW-FLEET chip: {json.dumps(chip)[:300]}")
        focus = self.rpc("debug.agent_pane", {"action": "focus_composer", "pane": p1}, 30)
        log(f"GSW-FLEET focus composer: {json.dumps(focus)[:200]}")
        self.results["setup"].update(chats=self.chats, chip=chip)
        # The pages settle with their drafts: each chat in sight shows its composer with the whole draft, then holds.
        if not wait_until(lambda: all(r.get("composer_visible") and r.get("composer_text_length") == len(DRAFTS[k])
                                      for k, r in self.chat_pages().items()),
                          "the chats' composers showing their drafts", timeout=30, interval=0.2, raise_on_timeout=False):
            log(f"GSW-FLEET the drafts did not all show in 30 s: {self.chat_pages()}")
        self.settle_pages("the chats with their drafts")
        self.make_regions(fracs)

    def chat_pages(self) -> dict:
        """{chat key: its pane's debug.agent_pane readiness} for the chats in sight (a and b; c is hidden behind b)."""
        return {k: self.rpc("debug.agent_pane", {"action": "readiness", "pane": self.chats[k]["pane"]}, 30) or {}
                for k in ("a", "b") if k in self.chats}

    def settle_pages(self, what: str, timeout: float = 30):
        """Until the chats' readiness (composer, draft, document) reads the same for about 1.5 s, or `timeout` s."""
        if wait_stable(self.chat_pages, what, timeout=timeout, interval=0.25, reads=6, raise_on_timeout=False) is None:
            log(f"GSW-FLEET {what}: the pages did not settle in {timeout:g} s")

    def probe_file(self):
        """The in-page probe's journal (webviews swapProbe.ts), once the app has written one."""
        if not self.probe_src:
            self.probe_src = next(iter(sorted((self.home / "Library/Application Support").glob("*/diagnostics/agent-page-flicker.ndjson"))), None)
        return self.probe_src

    def acpmux_call(self, method, params):
        with socket.socket(socket.AF_UNIX) as c:
            c.settimeout(10)
            c.connect(self.acpmux)
            f = c.makefile("rw")
            f.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}) + "\n")
            f.flush()
            while True:
                line = f.readline()
                if not line:
                    return None
                reply = json.loads(line)
                if reply.get("id") == 1:
                    return reply

    def make_regions(self, fracs):
        """Regions in movie pixels: each pane's rect inset 4 points, and the sidebar left of the first pane, times the
        movie's scale (set by the first film: device pixels per point)."""
        _, _, w, h = self.frame_points
        rect = lambda f: (f[0] * w, f[1] * h, f[2] * w, f[3] * h)
        settings, focused, unfocused = (rect(fracs[p]) for p in self.panes)
        top, height = settings[1], settings[3]
        self.region_points = [("sidebar", (4, top + 4, settings[0] - 12, height - 8)),
                              ("settings", (settings[0] + 4, top + 4, settings[2] - 8, height - 8)),
                              ("focused", (focused[0] + 4, top + 4, focused[2] - 8, height - 8)),
                              ("unfocused", (unfocused[0] + 4, top + 4, unfocused[2] - 8, height - 8))]
        log(f"GSW-FLEET regions (window points): {self.region_points}")

    def scaled(self, scale):
        return [(n, tuple(int(round(v * scale)) for v in r)) for n, r in self.region_points]

    # Films.

    def record(self, name: str, trigger, pre=1.2, post=3.5, label=None) -> dict:
        films = self.out / "films"
        films.mkdir(parents=True, exist_ok=True)
        movie = films / f"{name}.mov"
        started = self.rpc("debug.motion", {"action": "record_start", "path": str(movie), "seconds": int(pre + post + 40), "mbps": 24})
        if not isinstance(started, dict) or started.get("error"):
            raise RuntimeError(f"record_start: {started}")
        if not STRESS.wait(lambda: (self.rpc("debug.motion", {"action": "record_read"}) or {}).get("capturing"), 10, step=0.1):
            raise RuntimeError(f"the recorder never captured: {self.rpc('debug.motion', {'action': 'record_read'})}")
        time.sleep(pre)  # sleep-ok: the film's lead-in before the trigger, part of what is recorded
        epoch_ms = time.time() * 1000
        t_trigger = host_now()
        if callable(trigger):
            said, code, text = trigger(), 0, "python"
        else:
            done = subprocess.run(["/bin/zsh", "-c", trigger], capture_output=True, text=True, timeout=180, env=self.env())
            said, code, text = (done.stdout + done.stderr)[-1500:], done.returncode, trigger
        t_returned = host_now()
        time.sleep(post)  # sleep-ok: the film's tail after the trigger, the window the change must show in
        self.rpc("debug.motion", {"action": "record_stop"})
        if not STRESS.wait(lambda: (self.rpc("debug.motion", {"action": "record_read"}) or {}).get("written"), 30, step=0.2):
            raise RuntimeError(f"the film was not written: {self.rpc('debug.motion', {'action': 'record_read'})}")
        frames = json.loads(Path(str(movie) + ".frames.json").read_text())
        rows = frames.get("frames", frames) if isinstance(frames, dict) else frames
        first = next((r[0] for r in rows if isinstance(r, list) and len(r) >= 3 and r[2]), None)
        if first is None:
            raise RuntimeError(f"{movie}: no frame in the movie ({len(rows)} frames listed)")
        run = self.out / "runs" / name
        run.mkdir(parents=True, exist_ok=True)
        marks = run / "marks.txt"
        marks.write_text(f"start 0.000\ntrigger {t_trigger - first:.3f}\ntrigger-returned {t_returned - first:.3f} {code}\n")
        (run / "trigger.log").write_text(str(said))
        width, height, _, _ = GS.probe_video(movie)
        if not hasattr(self, "scale"):
            # Device pixels per point: the movie runs from the window's top-left to its screen's right edge.
            frame, screen = self.window_points()
            span = max(frame[2], (screen[0] + screen[2]) - frame[0]) if len(screen) == 4 else frame[2]
            self.scale = max(1, round(width / span))
            self.regions = self.scaled(self.scale)
            log(f"GSW-FLEET movie {width}x{height}, scale {self.scale}, regions (movie pixels) {self.regions}")
        probe = None
        if self.probe_file() and self.probe_src.exists():
            probe = run / "probe.ndjson"
            kept = []
            for line in self.probe_src.read_text(errors="replace").splitlines():
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                at = record.get("at")
                at_ms = at if isinstance(at, (int, float)) else _iso_ms(at)
                if record.get("kind") == "swap" and at_ms and at_ms >= epoch_ms - 2000:
                    record["at"] = at_ms
                    kept.append(json.dumps(record))
            probe.write_text("\n".join(kept) + ("\n" if kept else ""))
        result = GS.analyze(movie, marks, self.regions, run, label or name, text, probe, run / "frames")
        result["trigger_exit"] = code
        if code:
            result["ok"] = False  # a trigger that did nothing films nothing: "kept" is not a pass
            log(f"GSW-FLEET {name}: the trigger exited {code}: {str(said)[-600:]}")
        return result

    def films(self):
        overlay = shlex.quote(str(self.tree / "scripts/cmux-next/web-overlay.sh"))
        web_dev = self.config.parent / "web-dev.json"
        background = ("python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d[\"trigger\"]=\"background\"; "
                      "json.dump(d, open(p, \"w\"))' " + shlex.quote(str(web_dev)))
        asked = ("python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d.pop(\"trigger\", None); "
                 "json.dump(d, open(p, \"w\"))' " + shlex.quote(str(web_dev)))
        recipe = self.recipe()
        plan = {
            "install-app": f'{overlay} install-app "$APP"',
            "off": f"{overlay} off",
            "background": f'{overlay} install-app "$APP" >/dev/null && sleep 2 && {background} && {overlay} install-app "$APP"',
            "customize-try": f'"$CMUX" customize try {shlex.quote(recipe)} --minutes 5' if recipe else None,
            "customize-revert": '"$CMUX" customize revert' if recipe else None,
        }
        for name in self.opts.films.split(","):
            trigger = plan.get(name)
            if not trigger:
                log(f"GSW-FLEET film {name}: not run (no such film, or no customize recipe)")
                self.results["films"][name] = {"not_run": "no trigger"}
                continue
            try:
                result = self.record(name, trigger, post=5.0 if name.startswith("customize") else 4.0)
                self.results["films"][name] = {k: result.get(k) for k in ("ok", "regions", "probe", "trigger_exit")}
            except Exception as error:  # noqa: BLE001  one film's fault ends no other film
                log(f"GSW-FLEET film {name} FAILED: {error}")
                self.results["films"][name] = {"error": str(error)[:400]}
            if name == "background":
                subprocess.run(["/bin/zsh", "-c", asked], env=self.env(), check=False)
            time.sleep(2)

    def recipe(self) -> str | None:
        done = subprocess.run([self.cli_path, "customize", "recipes", "--json"], capture_output=True, text=True,
                              timeout=60, env=self.env())
        try:
            listed = json.loads(done.stdout)
        except ValueError:
            listed = {"error": (done.stdout + done.stderr)[-300:]}
        names = []

        def walk(node):
            if isinstance(node, dict):
                for key in ("name", "id", "slug"):
                    if isinstance(node.get(key), str):
                        names.append(node[key])
                        return
                for value in node.values():
                    walk(value)
            elif isinstance(node, list):
                for value in node:
                    walk(value)
        walk(listed)
        log(f"GSW-FLEET customize recipes: {names[:10]} ({str(listed)[:200] if not names else ''})")
        return names[0] if names else None

    # Latency.

    def edit(self, kind: str, on: bool):
        rel, plain, marked = EDITS[kind]
        path = self.tree / rel
        text = path.read_text()
        old, new = (plain, marked) if on else (marked, plain)
        if old not in text:
            return f"{kind} already {'on' if on else 'off'}"
        path.write_text(text.replace(old, new, 1))
        return "saved"

    def server(self):
        overlay = str(self.tree / "scripts/cmux-next/web-overlay.sh")
        done = subprocess.run([overlay, "server", "--local", "--worktree", str(self.tree)], capture_output=True, text=True,
                              timeout=600, env=self.env())
        log(f"GSW-FLEET dev server: exit {done.returncode}: {(done.stdout + done.stderr).strip()[-800:]}")
        if done.returncode:
            raise RuntimeError("the dev server did not start")
        # Every page reloads onto the dev server (an asked change): the chats come back with composer and draft, and hold.
        wait_until(lambda: all(r.get("composer_visible") and r.get("composer_text_length") == len(DRAFTS[k])
                               for k, r in self.chat_pages().items()),
                   "the chats back on the dev server", timeout=60, interval=0.25, raise_on_timeout=False)
        self.settle_pages("the pages on the dev server", timeout=60)

    def summary(self, series, surface, watch, others, runs, sample="first_change_ms"):
        rows = [r.get("regions", {}) for r in runs]
        seen = [float(r.get(watch, {}).get(sample)) for r in rows if r.get(watch, {}).get(sample) is not None]
        out = {"version": GS.VERSION, "label": f"fleet-{series}", "runs": len(runs), "watch": watch, "surface": surface,
               "sample": sample, "window_ms": round(LATENCY_WINDOW_S * 1000),
               "fps": [r.get("video", {}).get("fps") for r in runs], "regions": {}}
        out["regions"][watch] = {"n": len(seen), "missed": len(rows) - len(seen), "p50_ms": GS.percentile(seen, 50),
                                 "p95_ms": GS.percentile(seen, 95), "max_ms": max(seen) if seen else None,
                                 "samples_ms": seen}
        for name in others:
            kept = [bool(r.get(name, {}).get("kept")) for r in rows]
            out["regions"][name] = {"n": len(kept), "kept": sum(kept), "lost": len(kept) - sum(kept),
                                    "transient_frames": sum(r.get(name, {}).get("transient_frames", 0) for r in rows)}
        folder = self.out / "latency"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / f"{series}-{surface}.json").write_text(json.dumps(out, indent=2) + "\n")
        print("GRACEFUL_SWAP_LATENCY " + json.dumps(out, separators=(",", ":")), flush=True)
        self.results["latency"][f"{series}-{surface}"] = {k: out["regions"][watch][k] for k in ("n", "missed", "p50_ms", "p95_ms")}

    def series(self, kind, runs, before=None, trigger_for=None, after=None, post=LATENCY_WINDOW_S, edit="composer"):
        results = []
        for i in range(runs + 1):  # run 0 warms the dev server's compile of the file and is not counted
            on = i % 2 == 0
            try:
                if before:
                    before(on)
                trigger = trigger_for(on) if trigger_for else (lambda on=on: self.edit(edit, on))
                result = self.record(f"{kind}-{i:02d}", trigger, pre=1.0, post=post, label=f"latency-{kind}")
            except Exception as error:  # noqa: BLE001  a missed film counts as missed, the series goes on
                log(f"GSW-FLEET {kind} run {i} FAILED: {error}")
                result = {"regions": {}, "video": {}, "error": str(error)[:300]}
            if after:
                after(on)
            if i:
                results.append(result)
            time.sleep(0.5)
        if self.edit(edit, False) == "saved":
            self.settle_pages(f"the pages after the {edit} edit was undone")
        return results

    def latency(self):
        self.server()
        wanted = self.opts.series.split(",")
        if "composer" in wanted:
            runs = self.series("composer", self.opts.runs)
            self.summary("composer", "focused", "focused", ["sidebar", "settings"], runs)
            self.summary("composer", "unfocused", "unfocused", ["sidebar", "settings"], runs)
        if "hidden" in wanted:
            def hide_and_save(on):
                self.show_tab("b")  # raises when chat-b does not come back: that run counts as missed
                self.edit("composer", on)
                time.sleep(2.5)  # the hidden page takes the change while out of sight
            runs = self.series("hidden", self.opts.runs, before=hide_and_save,
                               trigger_for=lambda on: (lambda: self.show_tab("c")),
                               after=lambda on: self.show_tab("b", raise_on_timeout=False))
            self.summary("hidden", "hidden", "unfocused", ["sidebar", "settings", "focused"], runs, sample="settled_ms")
            self.st.focus_pane(self.panes[1])
        if "settings" in wanted:
            runs = self.series("settings", self.opts.runs, edit="settings")
            self.summary("settings", "unfocused", "settings", ["sidebar", "focused", "unfocused"], runs)

    def stop(self):
        try:
            subprocess.run([str(self.tree / "scripts/cmux-next/web-overlay.sh"), "server", "off"], env=self.env(),
                           capture_output=True, timeout=60)
        except Exception:  # noqa: BLE001
            pass
        for kind in EDITS:
            try:
                self.edit(kind, False)
            except OSError:
                pass
        bm.end_bundle(self.app)


def _iso_ms(value) -> float | None:
    if not isinstance(value, str):
        return None
    from datetime import datetime
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp() * 1000
    except ValueError:
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--tree", default=str(ROOT), help="the checkout the dev server serves and the saves edit")
    parser.add_argument("--out", required=True)
    parser.add_argument("--runs", type=int, default=20)
    parser.add_argument("--films", default="install-app,off,background,customize-try,customize-revert")
    parser.add_argument("--series", default="composer,hidden")
    parser.add_argument("--window", default="40,40,1440,900")
    opts = parser.parse_args()
    global GS
    harness = Path(opts.tree) / "scripts/measure/graceful-swap.py"
    if not harness.exists():
        sys.exit(f"graceful-swap-fleet: {harness} is missing: build at a commit that has the harness (cmux#50535)")
    GS = load("graceful_swap", harness)
    s = Scenario(opts)
    status = 0
    try:
        s.launch()
        s.build()
        if opts.films:
            s.films()
        if opts.series:
            s.latency()
    except SystemExit as error:
        log(f"GSW-FLEET stopped: {error}")
        status = 1
    except Exception as error:  # noqa: BLE001
        import traceback
        traceback.print_exc()
        log(f"GSW-FLEET failed: {error}")
        status = 1
    finally:
        (Path(opts.out) / "summary.json").write_text(json.dumps(s.results, indent=2, default=str) + "\n")
        log("GSW-FLEET summary " + json.dumps(s.results, separators=(",", ":"), default=str)[:6000])
        s.stop()
    if not s.results["latency"] and status == 0:
        status = 2
    sys.exit(status)


if __name__ == "__main__":
    main()
