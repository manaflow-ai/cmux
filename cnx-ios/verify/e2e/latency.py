"""Latency metrics, measured black-box from the simulator's own screen recording.

The AX tree takes ~2.5 s per read, far too coarse, so every metric is read from
`simctl io recordVideo` frames (variable frame rate, up to 60 fps, each frame
with its presentation time):

- keystroke -> echo: both ends are in the video. t0 is the first frame where
  the touched software key changes (its key-down highlight); t1 is the first
  frame where the terminal's cursor line changes. No clock mapping at all.
- the rest (cold connect, warm reconnect, tab switch): t0 is the host time of
  the launch or tap, mapped into video time with the offset measured from the
  recording's start; t1 is the first frame after which the watched region
  stays equal to its final, settled look. Accuracy is about one frame plus the
  start-offset error (tens of ms), fine for targets of 1 to 1.5 s.
"""
import json
import os
import random
import statistics
import subprocess
import tempfile
import time

SCALE = 3  # iPhone 17 Pro: 3 px per point


def frames(video, region_pts, fps_cap=None):
    """[(pts_seconds, bytes)] of the cropped region (points) for every frame."""
    x, y, w, h = [int(v * SCALE) for v in region_pts]
    w -= w % 2; h -= h % 2
    probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "frame=pts_time",
                            "-of", "csv=p=0", video], capture_output=True, text=True)
    times = [float(t.strip(",")) for t in probe.stdout.split() if t.strip(",") and t.strip(",") != "N/A"]
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", video, "-fps_mode", "passthrough", "-vf", f"crop={w}:{h}:{x}:{y},format=gray",
                          "-f", "rawvideo", "-"], capture_output=True).stdout
    n = w * h
    out = []
    for i in range(min(len(times), len(raw) // n)):
        out.append((times[i], raw[i * n:(i + 1) * n]))
    return out


def diff(a, b, step=7):
    """Mean absolute difference over sampled pixels (0..255)."""
    if len(a) != len(b):
        return 255.0
    s = 0; c = 0
    for i in range(0, len(a), step):
        s += abs(a[i] - b[i]); c += 1
    return s / max(c, 1)


def first_change(fr, after_t, threshold=2.0):
    """First frame time > after_t whose region differs from the frame just before after_t."""
    base = None
    for t, img in fr:
        if t <= after_t:
            base = img
            continue
        if base is None:
            base = img
            continue
        if diff(base, img) > threshold:
            return t
    return None


def settle_time(fr, after_t, until_t=None, threshold=2.0):
    """First frame time > after_t after which the region equals its final look (within the window)."""
    win = [(t, img) for t, img in fr if t > after_t and (until_t is None or t <= until_t)]
    if not win:
        return None
    final = win[-1][1]
    settled = None
    for t, img in win:
        if diff(final, img) <= threshold:
            if settled is None:
                settled = t
        else:
            settled = None
    return settled


def summarize(samples):
    s = sorted(x for x in samples if x is not None)
    if not s:
        return {"n": 0}
    p95 = s[min(len(s) - 1, int(round(0.95 * (len(s) - 1))))]
    return {"n": len(s), "median_ms": round(statistics.median(s) * 1000), "p95_ms": round(p95 * 1000),
            "min_ms": round(s[0] * 1000), "max_ms": round(s[-1] * 1000), "failed": len(samples) - len(s)}


class Latency:
    def __init__(self, journey, out_dir, log, samples=20):
        self.j, self.sim, self.mac = journey, journey.sim, journey.mac
        self.out, self.log, self.n = out_dir, log, samples
        os.makedirs(out_dir, exist_ok=True)
        self.metrics = {}

    def video(self, name):
        return os.path.join(self.out, f"{name}.mp4")

    # ---------------------------------------------------------------- keystroke echo
    def keystroke_echo(self, flood=False):
        name = "keystroke_echo_flood" if flood else "keystroke_echo_idle"
        j = self.j
        term = j.seed["term1"]
        j.back_to_list(); j.open_seed_workspace()
        if flood:
            # Output flood on the top rows only, so the prompt line stays measurable.
            # ~100 screen updates per second for at most 60 s (self-ending), top row only.
            j.mac_write(term, "(for i in $(seq 1 6000); do printf '\\0337\\033[1;1H%s %s %s\\0338' $i $RANDOM $RANDOM; sleep 0.01; done) & FLOODPID=$!\n")
            time.sleep(1.0)
        j.focus_terminal()
        # The page can be left scrolled up with the prompt off screen (typing does not
        # scroll back to the cursor); bring the prompt into view first.
        jump = self.sim.find(label="Scroll to bottom")
        if jump:
            self.sim.tap_el(jump[0]); time.sleep(1.0)
            self.metrics.setdefault("notes", []).append(f"{name}: the terminal was scrolled up with the prompt off screen; tapped Scroll to bottom")
        keys = self.sim.keyboard()
        letters = [k for k in "asdfghjkl" if k in keys]
        comp = self.sim.find(ident="terminal.composer.field")
        line_bottom = comp[0].frame[1] - 4 if comp else 640
        line_region = (0, line_bottom - 40, 402, 38)
        samples, taps = [], []
        vid = self.video(name)
        self.sim.record_start(vid)
        time.sleep(0.8)
        for i in range(self.n):
            k = keys[random.choice(letters)]
            taps.append((k.label, k.frame))
            self.sim.tap_el(k)
            time.sleep(0.45)
        time.sleep(0.5)
        self.sim.record_stop()
        # Clean the line on the Mac side and stop the flood.
        j.mac.cmux("terminal", term, "keys", "ctrl+u", check=False)
        if flood:
            j.mac_write(term, "kill $FLOODPID 2>/dev/null\n")
        j.hide_keyboard()
        # Analyse: key-down (key region changes) -> echo (line region changes).
        line = frames(vid, line_region)
        for idx, (label, (kx, ky, kw, kh)) in enumerate(taps):
            # Key popup grows above the key; watch the key and the popup above it.
            kfr = frames(vid, (max(kx - 4, 0), max(ky - 60, 0), min(kw + 8, 402 - max(kx - 4, 0)), kh + 60))
            # Search windows: taps are ~0.45+ s apart; locate this tap's key-down in order.
            if idx == 0:
                self._cursor = 0.3
            t0 = first_change(kfr, self._cursor, threshold=1.0)
            if t0 is None:
                samples.append(None); continue
            t1 = first_change(line, t0 - 0.001, threshold=0.2)
            samples.append((t1 - t0) if t1 is not None and t1 - t0 < 1.5 else None)
            self._cursor = t0 + 0.3
        self.metrics[name] = summarize(samples) | {"video": os.path.basename(vid),
                                                   "taps": [[l, list(f)] for l, f in taps], "line_region": list(line_region)}
        self.log(f"    {name}: {self.metrics[name]}")

    # ---------------------------------------------------------------- connects
    def _status_region(self):
        s = self.sim.find(ident="mac-link-status")
        return s[0].frame if s else (0, 160, 402, 30)

    def _list_region(self):
        return (0, 150, 402, 300)

    def cold_connect(self):
        """Kill + launch. Two numbers per launch: the Mac sees the phone's link up
        (cnx-hostd log, same host clock), and the list region settles with the Mac's rows (video)."""
        j = self.j
        j.back_to_list()
        region = self._list_region()
        samples, links = [], []
        vid = self.video("cold_connect")
        t_rec = self.sim.record_start(vid)
        launches = []
        for i in range(self.n):
            self.sim.terminate("dev.cmux.cnx")
            time.sleep(1.0)
            # -cnx-tab (DEBUG) only picks the first tab, so the list is on screen from launch.
            t = self.sim.launch("dev.cmux.cnx", args=("-cnx-tab", "workspaces"))
            launches.append(t - t_rec)
            up = None
            while time.time() - t < 20 and up is None:
                ev = [e for e in self.mac.link_events(t) if e[1] == "up"]
                up = ev[0][0] - t if ev else None
                time.sleep(0.3)
            links.append(up)
            ok = self.sim.wait(prefix=j.ws_name, kind="Button", timeout=15)
            if not ok:
                launches[-1] = None
            time.sleep(1.5)
        self.sim.record_stop()
        fr = frames(vid, region)
        for i, t0 in enumerate(launches):
            if t0 is None:
                samples.append(None); continue
            nxt = next((x for x in launches[i + 1:] if x is not None), None)
            t1 = settle_time(fr, t0, (nxt - 1.0) if nxt else None)
            samples.append((t1 - t0) if t1 else None)
        self.metrics["cold_connect_to_list"] = summarize(samples) | {"video": os.path.basename(vid),
            "note": "simctl launch (process start) to the list region settled with the Mac's rows (video)"}
        self.metrics["cold_link_up"] = summarize(links) | {"note": "simctl launch to cnx-hostd logging the phone's link up"}
        self.log(f"    cold: {self.metrics['cold_connect_to_list']} link: {self.metrics['cold_link_up']}")

    def warm_reconnect(self, background_s=20):
        """Home, `background_s` in background, foreground. Measured on the Mac side: the
        foreground to cnx-hostd's next link up when the link dropped in background."""
        j = self.j
        j.back_to_list()
        samples, survived = [], 0
        for i in range(self.n):
            self.sim.home()
            t_bg = time.time()
            time.sleep(background_s)
            t = self.sim.launch("dev.cmux.cnx", terminate=False)
            up = None
            while time.time() - t < 15 and up is None:
                ev = [e for e in self.mac.link_events(t) if e[1] == "up"]
                up = ev[0][0] - t if ev else None
                time.sleep(0.2)
            if up is None and not [e for e in self.mac.link_events(t_bg) if e[1] == "down"]:
                survived += 1
                up = 0.0  # the link never dropped: nothing to reconnect
            samples.append(up)
            time.sleep(1.0)
        self.metrics["warm_reconnect"] = summarize(samples) | {
            "note": f"after {background_s} s in background: foreground to cnx-hostd's link up; {survived} of {self.n} links survived the background (0 ms)"}
        self.log(f"    warm: {self.metrics['warm_reconnect']}")

    def tab_switch(self):
        j = self.j
        j.back_to_list(); j.open_seed_workspace()
        samples = []
        vid = self.video("tab_switch")
        t_rec = self.sim.record_start(vid)
        taps = []
        for i in range(self.n):
            name = "e2e-t2" if i % 2 == 0 else "e2e-t1"
            self.sim.tap_q(label="Tabs", kind="Button")
            cand = self.sim.wait(contains=name, timeout=8)
            if not cand:
                taps.append(None); continue
            t = self.sim.tap_el(cand)
            taps.append(t - t_rec)
            time.sleep(1.5)
        self.sim.record_stop()
        fr = frames(vid, (0, 100, 402, 560))
        for i, t0 in enumerate(taps):
            if t0 is None:
                samples.append(None); continue
            nxt = next((x for x in taps[i + 1:] if x is not None), None)
            t1 = settle_time(fr, t0, (nxt - 2.5) if nxt else None)
            samples.append((t1 - t0) if t1 else None)
        self.metrics["tab_switch"] = summarize(samples) | {"video": os.path.basename(vid),
                                                         "note": "tap on a tab card in the grid to the terminal page settled"}
        self.log(f"    tab switch: {self.metrics['tab_switch']}")

    def run(self, which=None):
        plan = [("keystroke_echo_idle", lambda: self.keystroke_echo(False)),
                ("keystroke_echo_flood", lambda: self.keystroke_echo(True)),
                ("tab_switch", self.tab_switch),
                ("cold_connect_to_list", self.cold_connect),
                ("warm_reconnect", self.warm_reconnect)]
        for key, fn in plan:
            if which and key not in which:
                continue
            try:
                fn()
            except Exception as e:  # a metric failing must not stop the others
                self.metrics[key] = {"n": 0, "error": str(e)[:300]}
                self.log(f"    {key} ERROR {e}")
                try:
                    self.sim.record_stop()
                except Exception:
                    pass
        self.metrics["agent_first_token"] = {"n": 0, "blocked": "no credit-free real harness (see agent_chat)"}
        self.metrics["feed_answer_round_trip"] = {"n": 0, "blocked": "no agent asks without a harness (see feed)"}
        return self.metrics
