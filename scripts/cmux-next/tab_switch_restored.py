#!/usr/bin/env python3
"""Chromium tabs a relaunch restored, and live ones: switched to, judged from the frames, their reloads counted.

Leo, 2026-11-22 ~09:55Z: "this is so fucked. constant rerenders on every fucking page still." His recording: in a
Chromium pane, a tab not shown since the app's last relaunch shows the bare wallpaper and an empty omnibar ("Search or
type URL") for 4 to 7 s, then loads cold; a tab whose URL is a raw .mp4 downloads it again on every relaunch. The
frame-judged gate (chromium-return) only ever switched back to a tab that was live, so it never saw this.

Scenarios (tab_switch_frames.py --scenarios; both in the default set):
  chromium-warm      one pane of CHROMIUM_TABS Chromium tabs (local fixture pages, light and dark, one URL that
                     serves a 4 MB video/mp4, and real sites when the runner reaches them), every tab loaded and
                     shown once, then SWITCHES switches (Ctrl-Tab steps, nextSurface, and jumps, tab.focus)
  chromium-restored  the same pane after a relaunch (Quit and Keep Sessions, the app's processes gone, the app exec'd
                     again in the same home, as the settle matrix's launch-restore step does), RESTORE_SETTLE_S left
                     alone, then SWITCHES switches that visit every tab: each tab's first switch since the relaunch is
                     the one Leo's recording shows
Both run under each load the run asks for (idle, cpu, agents ...), the warm block first, then the relaunch.

Per switch, beside tab_switch_judge.judge_switch's fields (to_content_ms against the tab's own picture before the
relaunch, blank_frames, wrong_frames, ...):
  reloads              loads of the switched-to tab that started in the switch's window: its fixture page's GETs on
                       the harness's own HTTP server (no-store, so every load reaches it), and the page's own
                       performance.timeOrigin read after the switch (browser.page.eval; a real site's only source).
                       null when neither could be read (a real site on a build without browser.page.eval)
  downloads_restarted  the mp4's bodies (200 or 206, not a 304) served in the switch's window, any tab's
  omnibar_frames       frames after the switch whose omnibar band (the top OMNIBAR_POINTS of the content rect)
                       differs from the tab's own: an empty "Search or type URL" omnibar, a wrong URL
  first_since_launch   the tab had not been shown since the app started (the restored block's cold switches)
Blank frames also count a frame of the content area that shows the desktop: the bare wallpaper is not flat, so the
judge's flatness test alone calls it a wrong frame. The desktop's picture is recorded with the app quit, at the relaunch.
The row also carries downloads_restarted (the mp4's bodies served from the relaunch to the block's end, the switches'
included) and downloads_folder_added (files the relaunch added to the app's downloads folder).
Budgets (tab_switch_judge.budget_fails, tab_switch_gate.py): every switch's content within one display frame, 0 blank,
0 wrong, 0 reloads, 0 downloads restarted, 0 omnibar frames; a row's downloads_restarted 0.
"""
from __future__ import annotations

import http.server
import os
import random
import subprocess
import threading
import time
import urllib.request

import tab_switch_foreign as foreign
import tab_switch_judge as judge
import tab_switch_matrix as matrix

SCENARIOS = ("chromium-warm", "chromium-restored")
CHROMIUM_TABS = 10
SWITCHES = 20
RESTORE_SETTLE_S = 10.0
COLD_RECORD_S = 7.0  # a switch to a tab not shown since launch: Leo's recording loads for 4 to 7 s
WARM_RECORD_S = 1.5
SWITCHES_PER_BLOCK = 5  # a CuaDriver session ends when no tool call comes for a while (tab_switch_frames.run)
OMNIBAR_POINTS = 40
DESKTOP_SHARE = 0.25  # a content frame within this share of the desktop's picture shows the desktop (a blank pane)
MP4_BYTES = 4 << 20
MP4_PATH = "/media/clip.mp4"
REAL_SITES = ("https://example.com/", "https://info.cern.ch/hypertext/WWW/TheProject.html",
              "https://www.iana.org/help/example-domains")

# name -> (background, foreground, layout): visually distinct pages, light and dark, so a wrong tab is a wrong frame.
FIXTURES = (
    ("light-text", "#ffffff", "#1d1d1f", "text"),
    ("dark-text", "#111317", "#e8e8ea", "text"),
    ("light-grid", "#f4f1ea", "#7a3e00", "grid"),
    ("dark-grid", "#0d1b2a", "#7fd1ff", "grid"),
    ("light-form", "#eef6ee", "#145a32", "form"),
    ("dark-bars", "#1e0b24", "#ff7ad9", "bars"),
    ("light-long", "#fffbe6", "#5c4400", "long"),
    ("dark-long", "#202020", "#b6f0a0", "long"),
    ("light-head", "#e8eefc", "#0b3d91", "text"),
)


def fixture_html(name, background, foreground, layout):
    """One fixture page: static (nothing animates, so its picture is one frame), its name big at the top."""
    if layout == "grid":
        body = "".join(f"<div style='display:inline-block;width:110px;height:80px;margin:6px;background:{foreground};"
                       f"opacity:{0.25 + (i % 4) * 0.2:.2f}'></div>" for i in range(48))
    elif layout == "form":
        body = "".join(f"<p><label>Field {i} <input value='value {i}' style='font:24px -apple-system;width:420px'>"
                       f"</label></p>" for i in range(8))
    elif layout == "bars":
        body = "".join(f"<div style='height:28px;margin:8px 0;width:{20 + (i * 37) % 75}%;background:{foreground}'>"
                       f"</div>" for i in range(16))
    elif layout == "long":
        body = "".join(f"<p>Line {i}: the quick brown fox jumps over the lazy dog, tab {name}.</p>" for i in range(60))
    else:
        body = "".join(f"<p>Paragraph {i} of {name}. Restored tabs must show their last frame at once.</p>"
                       for i in range(12))
    return (f"<!doctype html><html><head><meta charset='utf-8'><title>{name}</title></head>"
            f"<body style='margin:0;padding:32px;background:{background};color:{foreground};font:22px -apple-system'>"
            f"<h1 style='font-size:64px;margin:0 0 24px'>{name}</h1>{body}</body></html>")


class FixtureServer:
    """The fixture pages and the mp4 on 127.0.0.1, every request logged: (time.monotonic(), path, status, bytes)."""

    def __init__(self):
        self.hits = []
        self.lock = threading.Lock()
        self.pages = {f"/p/{name}": fixture_html(name, bg, fg, layout).encode()
                      for name, bg, fg, layout in FIXTURES}
        rng = random.Random(20261122)
        self.mp4 = bytes(rng.getrandbits(8) for _ in range(4096)) * (MP4_BYTES // 4096)
        server = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):  # quiet: the hits are the log
                pass

            def handle(self):
                try:
                    super().handle()
                except (ConnectionResetError, BrokenPipeError):  # the page closed its connection (a tab parked)
                    pass

            def do_GET(self):  # noqa: N802 - http.server's name
                path = self.path.split("?", 1)[0]
                if path in server.pages:
                    data = server.pages[path]
                    self.send_response(200)
                    self.send_header("Content-Type", "text/html; charset=utf-8")
                    self.send_header("Cache-Control", "no-store")  # every load reaches the server: the counter
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    server.log(path, 200, len(data))
                    return
                if path == MP4_PATH:
                    # Cacheable, as a file server's mp4 is: a restore that keeps the bytes asks with If-None-Match and
                    # gets a 304, which is no download.
                    if self.headers.get("If-None-Match") == '"clip-1"':
                        self.send_response(304)
                        self.send_header("ETag", '"clip-1"')
                        self.send_header("Content-Length", "0")
                        self.end_headers()
                        server.log(path, 304, 0)
                        return
                    data, status = server.mp4, 200
                    rng_header = self.headers.get("Range") or ""
                    start, end = 0, len(data) - 1
                    if rng_header.startswith("bytes="):
                        first, _, last = rng_header[6:].partition("-")
                        try:
                            start = int(first) if first else 0
                            end = min(int(last), len(data) - 1) if last else len(data) - 1
                            status = 206
                        except ValueError:
                            start, end = 0, len(data) - 1
                    chunk = data[start:end + 1]
                    self.send_response(status)
                    self.send_header("Content-Type", "video/mp4")
                    self.send_header("Accept-Ranges", "bytes")
                    self.send_header("ETag", '"clip-1"')
                    self.send_header("Cache-Control", "public, max-age=86400")
                    if status == 206:
                        self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
                    self.send_header("Content-Length", str(len(chunk)))
                    self.end_headers()
                    try:
                        self.wfile.write(chunk)
                    except OSError:
                        pass
                    server.log(path, status, len(chunk))
                    return
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()
                server.log(path, 404, 0)

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.httpd.daemon_threads = True
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def log(self, path, status, size):
        with self.lock:
            self.hits.append((time.monotonic(), path, status, size))

    def url(self, path):
        return f"http://127.0.0.1:{self.port}{path}"

    def snapshot(self):
        with self.lock:
            return list(self.hits)

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def network_ok(url=REAL_SITES[0], timeout=4.0):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as answer:
            return answer.status < 400
    except Exception:  # noqa: BLE001 - no network is an answer
        return False


def tab_urls(server, real):
    """The CHROMIUM_TABS URLs, in strip order: fixtures, the mp4 in the middle, real sites when `real`, then fixtures
    up to the count."""
    fixtures = [server.url(f"/p/{name}") for name, *_ in FIXTURES]
    urls = fixtures[:4] + [server.url(MP4_PATH)] + (list(REAL_SITES) if real else []) + fixtures[4:]
    return urls[:CHROMIUM_TABS]


def switch_plan(count, start, switches=SWITCHES, seed=7):
    """`switches` steps over `count` tabs from tab `start`: [(kind, target index)], kind "next" (Ctrl-Tab: the next tab,
    wrapping) or "jump" (a tab picked by id). Every tab other than `start` is visited in the first count - 1 steps (the
    restored block's cold switches), Ctrl-Tab steps and jumps mixed; the rest revisit, never the tab already shown."""
    rng = random.Random(seed)
    plan, current, unseen = [], start, [i for i in range(count) if i != start]
    for step in range(switches):
        nxt = (current + 1) % count
        if unseen:
            if step % 3 != 2 and nxt in unseen:
                kind, target = "next", nxt
            else:
                target = rng.choice([i for i in unseen if i != nxt] or unseen)
                kind = "next" if target == nxt else "jump"
            unseen.remove(target)
        elif step % 3 == 0:
            kind, target = "next", nxt
        else:
            target = rng.choice([i for i in range(count) if i not in (current, nxt)] or [nxt])
            kind = "jump"
        plan.append((kind, target))
        current = target
    return plan


def windows_of(walls, labels, end_wall):
    """Each label's window on the monotonic clock: from its leave flip to the next label's leave (the last: end_wall)."""
    starts = [walls[f"{label}:leave"] for label in labels]
    return list(zip(starts, starts[1:] + [end_wall]))


def attribute(hits, windows, paths, mp4=MP4_PATH):
    """Per window: (GETs of its target path, mp4 bodies served). `paths[i]` is window i's target path (None: a page the
    server does not serve, no count)."""
    out = []
    for (t0, t1), path in zip(windows, paths):
        inside = [h for h in hits if t0 <= h[0] < t1]
        loads = None if path is None else sum(1 for h in inside if h[1] == path and h[2] in (200, 206))
        bodies = sum(1 for h in inside if h[1] == mp4 and h[2] in (200, 206))
        out.append((loads, bodies))
    return out


def desktop_frames(switch_frames, mark, w, content, desktop, reference, before, frame_ms, tolerance):
    """Display frames after `mark` whose content area shows the desktop (the bare wallpaper of an empty pane): within
    DESKTOP_SHARE of the desktop's picture, and neither the tab's own picture nor the frame before the switch."""
    if desktop is None:
        return 0
    after = [f for f in switch_frames if f[0] > mark]
    dc = judge.crop(desktop, w, content)
    rc = judge.crop(reference, w, content) if reference is not None else None
    bc = judge.crop(before, w, content) if before is not None else None
    times = [f[0] for f in after]
    ends = times[1:] + [times[-1] + frame_ms / 1000] if times else []
    count = 0
    for (t, frame), t_next in zip(after, ends):
        c = judge.crop(frame, w, content)
        if rc is not None and judge.diff_share(c, rc) <= tolerance:
            continue
        if bc is not None and judge.diff_share(c, bc) <= tolerance:
            continue
        if judge.diff_share(c, dc) <= DESKTOP_SHARE:
            count += judge.frames_covered(t, t_next, frame_ms)
    return count


def omnibar_frames(switch_frames, mark, w, band, reference, before, tolerance):
    """Frames after `mark`, up to the first that equals the reference's band for good, whose omnibar band differs from
    the reference's and from the frame before the switch (the old tab's, until the switch commits)."""
    if reference is None:
        return 0
    after = [f for f in switch_frames if f[0] > mark]
    rb = judge.crop(reference, w, band)
    bb = judge.crop(before, w, band) if before is not None else None
    crops = [judge.crop(f[1], w, band) for f in after]
    settled = len(crops)
    while settled > 0 and judge.diff_share(crops[settled - 1], rb) <= tolerance:
        settled -= 1
    count = 0
    for c in crops[:settled]:
        if bb is not None and judge.diff_share(c, bb) <= tolerance:
            continue
        if judge.diff_share(c, rb) > tolerance:
            count += 1
    return count


class Restored:
    """The chromium-warm and chromium-restored blocks on a tab_switch_frames.Harness `h`."""

    def __init__(self, h, say):
        self.h, self.say = h, say
        self.server = FixtureServer()
        self.real = network_ok()
        self.urls = tab_urls(self.server, self.real)
        self.ids = []
        self.refs = {}
        self.desktop = None
        self.current = 0
        self.shown_since_launch = set()
        self.notes = []
        self.eval_ok = None
        # The first block of each scenario under idle keeps its video (OUT/clips/, a few MB): the one switch a person
        # reads, beside the numbers. --no-clips drops them.
        self.clips = not getattr(h.args, "no_clips", False)

    # -- build ---------------------------------------------------------------------------------------------------

    def build(self):
        c = self.h.c
        before = set(self.h.workspace_ids())
        reply = c.action("workspace new")
        if reply.get("error"):
            raise RuntimeError(f"workspace new: {reply['error']}")
        time.sleep(1.5)  # test script: the workspace's terminal attaches
        made = [w for w in self.h.workspace_ids() if w not in before]
        self.workspace = made[0] if made else self.h.focused_workspace()
        tabs, pane = c.focused_tabs()
        self.pane = (pane or {}).get("id")
        start_tabs = [t.get("id") for t in tabs]
        for url in self.urls:
            reply = c.action("openBrowser.chromium", url=url)
            if reply.get("error"):
                raise RuntimeError(f"openBrowser.chromium {url}: {reply['error']}")
            time.sleep(0.4)  # test script: one tab at a time, in order
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            tabs = self.pane_tabs()
            fresh = [t.get("id") for t in tabs if t.get("id") not in start_tabs]
            if len(fresh) >= len(self.urls) and not any(str(x).startswith("pending_tab_") for x in fresh):
                break
            time.sleep(0.3)  # test script: waiting for the tabs' ids
        else:
            raise RuntimeError(f"the pane never had {len(self.urls)} Chromium tabs: {fresh}")
        self.ids = fresh[:len(self.urls)]
        for tab in start_tabs:  # one pane of Chromium tabs only: the workspace's terminal goes
            c.action("closeTab", focus=False, target=f"tab:{tab}")
        time.sleep(1)  # test script: the terminal closes
        self.say(f"restored: {len(self.ids)} Chromium tabs in workspace {self.workspace}, real sites "
                 f"{'on' if self.real else 'off (no network)'}")

    def pane_tabs(self):
        return self.pane_and_tabs()[1]

    def pane_and_tabs(self):
        for workspace in self.h.c.topology().get("workspaces") or []:
            for screen in workspace.get("screens") or []:
                for pane in screen.get("panes") or []:
                    if pane.get("id") == self.pane:
                        return pane, pane.get("tabs") or []
        return None, []

    def selected(self):
        """The pane's shown tab id (a tab's `selected`, else the pane's `selected_tab`), None when unknown."""
        pane, tabs = self.pane_and_tabs()
        return next((t.get("id") for t in tabs if t.get("selected")), None) or (pane or {}).get("selected_tab")

    def show_workspace(self):
        self.h.c.action("goToWorkspace", workspace=self.workspace)
        time.sleep(0.5)  # test script: the workspace shows

    def calibrate(self):
        """Every tab loaded and shown, its picture taken once it settled (the reference its switches end on)."""
        h = self.h
        self.show_workspace()
        h.rec.begin()
        for i, tab in enumerate(self.ids):
            h.c.action("tab.focus", target=f"tab:{tab}")
            time.sleep(4.0 if self.urls[i].startswith("https://") else 2.0)  # test script: the page loads
            h.rec.flip(f"restored-ref-{i}")
        time.sleep(0.3)
        frames, flips = h.rec.end()
        self.refs = {i: h.at(frames, flips[f"restored-ref-{i}"]) for i in range(len(self.ids))}
        self.current = len(self.ids) - 1
        self.shown_since_launch = set(range(len(self.ids)))

    # -- the page's own clock ------------------------------------------------------------------------------------

    def time_origin(self, i):
        """The tab's performance.timeOrigin (epoch ms), None when browser.page.eval cannot read it."""
        if self.eval_ok is False:
            return None
        reply = self.h.c.call("browser.page.eval", {"tab": self.ids[i], "script": "performance.timeOrigin"}, timeout=8)
        value = reply.get("value") if isinstance(reply, dict) else None
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            self.eval_ok = True
            return float(value)
        if self.eval_ok is None:
            self.eval_ok = False
            self.notes.append(f"browser.page.eval: {str(reply)[:160]}")
        return None

    # -- blocks --------------------------------------------------------------------------------------------------

    def block(self, scenario, load):
        """SWITCHES switches in blocks of SWITCHES_PER_BLOCK, each judged; returns the switches."""
        h = self.h
        plan = switch_plan(len(self.ids), self.current)
        origins = {}
        if scenario == "chromium-warm":
            origins = {i: self.time_origin(i) for i in range(len(self.ids))}
        out = []
        for first in range(0, len(plan), SWITCHES_PER_BLOCK):
            chunk = plan[first:first + SWITCHES_PER_BLOCK]
            keep = self.clips and first == 0 and load in ("idle", "L0")
            if keep:
                h.rec.keep_next = os.path.join(h.args.out, "clips", f"{scenario}-{load}")
            h.rec.begin()
            labels, items, epochs = [], [], []
            for k, (kind, target) in enumerate(chunk):
                n = first + k + 1
                label = f"{scenario}/{load} switch {n}"
                cold = target not in self.shown_since_launch
                h.rec.flip(f"{label}:leave")
                h.rec.flip(f"{label}:mark")
                epochs.append(time.time())
                if kind == "next":
                    reply = h.c.action("nextSurface")
                else:
                    reply = h.c.action("tab.focus", target=f"tab:{self.ids[target]}")
                time.sleep(COLD_RECORD_S if cold else WARM_RECORD_S)
                h.rec.flip(f"{label}:end")
                shown = self.selected()
                if shown is not None and shown != self.ids[target] and not reply.get("error"):
                    # Ctrl-Tab went elsewhere (no wrap, another order): judged against the tab it showed.
                    if shown in self.ids:
                        self.say(f"  {label}: {kind} showed tab {self.ids.index(shown)}, planned {target}")
                        target = self.ids.index(shown)
                    else:
                        reply = {"error": f"the pane shows {shown}, not one of its Chromium tabs"}
                origin = self.time_origin(target)
                time.sleep(0.3)  # test script: the read's own work off the next switch's window
                labels.append(label)
                items.append({"kind": kind, "target": target, "cold": cold, "origin": origin,
                              "error": f"{kind}: {reply['error']}" if reply.get("error") else None})
                self.shown_since_launch.add(target)
                self.current = target
            end_wall = time.monotonic()
            frames, flips = h.rec.end()
            if keep and getattr(h.rec, "kept", None):
                self.say(f"restored: clip kept at {h.rec.kept}")
            hits = self.server.snapshot()
            windows = windows_of(h.rec.walls, labels, end_wall)
            paths = [self.path_of(item["target"]) for item in items]
            counts = attribute(hits, windows, paths)
            for label, item, epoch, (loads, bodies) in zip(labels, items, epochs, counts):
                out.append(self.judge_one(label, item, epoch, loads, bodies, frames, flips, origins))
        return out

    def path_of(self, i):
        url = self.urls[i]
        prefix = self.server.url("")
        return url[len(prefix):] if url.startswith(prefix) else None

    def judge_one(self, label, item, epoch, loads, bodies, frames, flips, origins):
        h = self.h
        if item["error"]:
            return {"label": label, "error": item["error"], "target": item["target"]}
        leave, mark, end = (flips[f"{label}:{k}"] for k in ("leave", "mark", "end"))
        covered = h.foreign_over(label)
        if covered:
            return {"label": label, "foreign_window": "+".join(foreign.owners(covered)),
                    "windows": covered}
        window = h.between(frames, leave, end)
        reference = self.refs.get(item["target"])
        switch = h.judge(window, mark, reference=reference)
        before = h.at(frames, leave)
        desk = desktop_frames(window, mark, h.rec.w, h.content, self.desktop, reference, before, h.rec.frame_ms,
                              h.args.tolerance)
        if desk:
            # A frame of the desktop is a blank pane; the judge called it wrong (the wallpaper is not flat).
            moved = min(desk, switch.get("wrong_frames") or 0)
            switch["wrong_frames"] = (switch.get("wrong_frames") or 0) - moved
            switch["blank_frames"] = (switch.get("blank_frames") or 0) + moved
            switch["desktop_frames"] = desk
        x0, y0, x1, _y1 = h.content
        band = (x0, y0, x1, min(h.content[3], y0 + int(OMNIBAR_POINTS * h.rec.scale)))
        switch["omnibar_frames"] = omnibar_frames(window, mark, h.rec.w, band, reference, before, h.args.tolerance)
        # Reloads: the fixture server's GETs in the window, and the page's own clock.
        origin, was = item["origin"], origins.get(item["target"])
        by_clock = None
        if origin is not None:
            if was is not None:
                by_clock = 1 if abs(origin - was) > 1.0 else 0
            else:
                by_clock = 1 if origin >= (epoch - 0.05) * 1000 else 0
            if was is not None:
                origins[item["target"]] = origin
        counts = [x for x in (loads, by_clock) if x is not None]
        switch["reloads"] = max(counts) if counts else None
        switch["reloads_server"] = loads
        switch["reloads_clock"] = by_clock
        switch["downloads_restarted"] = bodies
        switch.update({"label": label, "target": item["target"], "url": self.urls[item["target"]],
                       "via": item["kind"], "first_since_launch": item["cold"]})
        h.add_settle(switch, frames, window, leave, mark, end, reference, label)
        h.keep_sheet(switch, window, mark, label, reference)
        return switch

    def relaunch(self):
        """Quit and Keep Sessions, the processes gone, the desktop's picture taken, the app exec'd in the same home
        (tab_switch_matrix.launch_block's steps), then RESTORE_SETTLE_S untouched. Returns the mp4 and folder counts'
        starting points."""
        h = self.h
        downloads = os.path.join(h.app.root, "downloads")
        before_files = set(os.listdir(downloads)) if os.path.isdir(downloads) else set()
        started = time.monotonic()
        h.rec.begin()
        old = h.app.process
        h.c.action("quitKeepSessions", focus=False)
        try:
            old.wait(timeout=30)
        except subprocess.TimeoutExpired as error:
            h.rec.end()
            raise RuntimeError("the app did not quit in 30 s") from error
        matrix.quiesce(h.app.bundle)
        h.rec.flip("restored-desktop")
        time.sleep(0.4)
        h.rec.flip("restored-desktop-end")
        frames, flips = h.rec.end()
        self.desktop = h.at(frames, flips["restored-desktop"])
        h.app.spawn()
        if getattr(h, "watch", None) is not None:
            h.watch.log.own_pids.add(h.app.process.pid)
        time.sleep(3)  # test script: the window restores
        self.show_workspace()
        tabs = [t.get("id") for t in self.pane_tabs()]
        if tabs and any(t not in tabs for t in self.ids):
            self.say(f"restored: the tab ids changed across the relaunch; matched by order ({tabs})")
            self.ids = tabs[:len(self.ids)]
        selected = self.selected()
        self.current = self.ids.index(selected) if selected in self.ids else self.current
        self.shown_since_launch = {self.current}
        time.sleep(RESTORE_SETTLE_S)  # test script: the restore runs untouched, as a person's relaunch does
        return started, before_files, downloads

    def run(self, loads, enter, leave):
        """The rows: {(scenario, load): switches} and {(scenario, load): note}. `enter(load)` starts a load and
        returns its notes, `leave(load)` ends it."""
        rows, notes, extra = {}, {}, {}
        try:
            self.build()
            self.calibrate()
        except Exception as error:  # noqa: BLE001 - the rows say why
            for load in loads:
                for name in SCENARIOS:
                    notes[(name, load)] = f"setup: {type(error).__name__}: {error}"[:600]
            return rows, notes, extra
        for load in loads:
            for name in SCENARIOS:
                try:
                    if name == "chromium-restored":
                        started, files0, folder = self.relaunch()
                    setup = enter(load)
                    self.show_workspace()
                    time.sleep(1)  # test script: the load runs before the first switch
                    switches = self.block(name, load)
                    for s in switches:
                        if setup:
                            s["load_setup"] = setup
                    rows[(name, load)] = switches
                    if name == "chromium-restored":
                        hits = [x for x in self.server.snapshot() if x[0] >= started]
                        files = set(os.listdir(folder)) if os.path.isdir(folder) else set()
                        extra[(name, load)] = {
                            "downloads_restarted": sum(1 for x in hits if x[1] == MP4_PATH and x[2] in (200, 206)),
                            "downloads_folder_added": len(files - files0),
                            "loads_since_relaunch": {p: sum(1 for x in hits if x[1] == p and x[2] == 200)
                                                     for p in sorted({x[1] for x in hits})},
                        }
                except Exception as error:  # noqa: BLE001 - this row says why; the next still runs
                    notes[(name, load)] = f"{type(error).__name__}: {error}"[:600]
                    try:
                        self.h.rec.end()
                    except Exception:  # noqa: BLE001 - no block was open
                        pass
                finally:
                    leave(load)
        if self.notes:
            for key in list(rows):
                extra.setdefault(key, {})["notes_eval"] = "; ".join(self.notes)[:300]
        return rows, notes, extra

    def close(self):
        self.server.close()


def row_budget_fails(name, load, row_extra):
    """The row-level budget: no download restarted from the relaunch to the block's end."""
    restarted = (row_extra or {}).get("downloads_restarted") or 0
    return [f"{name}/{load}: the mp4 was downloaded again {restarted} times after the relaunch"] if restarted else []
