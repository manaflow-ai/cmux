"""Typing latency keys for the key-to-photon videos (VIDEO EXTRA item 1, lead 2026-11-02 00:29Z).

driver.py loads this file (load_extensions) on the mini under the stock /usr/bin/python3 (3.9, standard library
only). It must not import driver.py: install() gets the driver module instead.

The video (the HARNESS kit's debug.motion record_*, frames.json `t` in host seconds, CACurrentMediaTime's clock)
shows when each typed character appears. This group types the characters as real HID keys (ext_realkey press: a
CuaDriver desktop-scope key event through the window server) and records, for each key, the host time just before
and just after the post, on the same clock (time.monotonic, mach_absolute_time on macOS). The judge
(shortcut-frames/judge.py with --crop on the target's rect, or typing-judge.py) counts the display refreshes from
`t_post` to the first frame that shows the character.

Steps (`do`):
  video_close_open {tail?: 0.3}
                `finally` clean-up: stops a recording (ext_video) that a failed or not-run step left open, so the
                movie of a red attempt is written with its trace, events and meta.
  typing_keys   {count?: 60, seed?: 1, gap_ms?: [90, 210], charset?: "abcdefghijklmnopqrstuvwxyz", label?, target?,
                 prime?: "", prime_pause_ms?: 600}
                COUNT printable keys, each after a random gap in GAP_MS (a person's pace; fixed SEED), into whatever
                has the keyboard now. No Return. TARGET names what should take them (terminal, composer,
                address_bar): recorded with the target's rect (`typing_rect`) for the judge's crop. Result:
                {"keys": [{"i", "ch", "t_post", "t_back"}...], "rect": ..., "label"}. Real keys only (key_path=real):
                a debug.key path never reaches the window server, so it would not measure what a person sees.
  typing_rect   {target: terminal | composer | address_bar | pane:NAME}
                the target's rect in the window's points from its top-left (terminal: the focused pane's grid
                frame from debug.surfaces; address_bar: debug.omnibar field_frame flipped by debug.layers; composer:
                the whole window (the judge finds the band the keys changed); pane:NAME: that pane's frame), plus the
                window frame; kept in the result.
"""
import random
import time

D = None


def install(driver):
    global D
    D = driver


def _realkey():
    import ext_realkey
    return ext_realkey


def _surfaces(j):
    return [p for w in (j.app.rpc("debug.surfaces") or {}).get("windows", []) for p in w.get("panes", [])
            if isinstance(p, dict)]


def _pane_rect(j, pick):
    for p in _surfaces(j):
        if pick(p):
            g = p.get("grid") or {}
            if all(k in g for k in ("frame_x", "frame_y", "frame_width", "frame_height")):
                return [g["frame_x"], g["frame_y"], g["frame_width"], g["frame_height"]], p.get("pane")
    return None, None


def step_typing_rect(j, step):
    target = step.get("target", "terminal")
    rk = _realkey()
    win = rk._layers_window(j) or {}
    rect, pane = None, None
    if target == "terminal":
        rect, pane = _pane_rect(j, lambda p: p.get("focused"))
    elif target == "composer":
        # A composer is no terminal (no grid frame): the whole window; the judge finds the band the keys changed.
        frame = (win or {}).get("frame")
        if frame:
            rect, pane = [0.0, 0.0, float(frame[2]), float(frame[3])], None
    elif target.startswith("pane:"):
        named = (getattr(j, "smoke_named", {}) or {}).get(target[5:]) or {}
        rect, pane = _pane_rect(j, lambda p: p.get("pane") == named.get("pane"))
    elif target == "address_bar":
        bar = j.app.rpc("debug.omnibar") or {}
        frame = bar.get("field_frame") if isinstance(bar, dict) else None
        if isinstance(frame, list) and len(frame) == 4 and win.get("frame"):
            fx, fy, fw, fh = (float(v) for v in frame)
            wh = float(win["frame"][3])
            rect = [fx, wh - fy - fh, fw, fh]  # bottom-left window points -> top-left
    if rect is None:
        raise D.StepError(f"typing_rect: no rect for {target!r}")
    j.typing_rect = {"target": target, "rect_points_top_left": rect, "pane": pane, "window": win}
    return j.typing_rect


def step_typing_keys(j, step):
    if (j.spec.get("options") or {}).get("key_path") != "real":
        raise D.NotRun("typing_keys: real keys only (journey option key_path=real)")
    rk = _realkey()
    rk.require_front(j)
    count = int(step.get("count", 60))
    lo, hi = (float(x) / 1000.0 for x in step.get("gap_ms", [90, 210]))
    charset = step.get("charset", "abcdefghijklmnopqrstuvwxyz")
    rng = random.Random(int(step.get("seed", 1)))
    rect = step_typing_rect(j, {"target": step["target"]}) if step.get("target") else getattr(j, "typing_rect", None)
    # PRIME characters first, not measured: a field's placeholder goes away at its first key, which would read as
    # a glyph that vanished; then a pause so the first measured key starts from a still frame.
    for ch in step.get("prime", ""):
        rk.press_char(j, ch)
    if step.get("prime"):
        time.sleep(float(step.get("prime_pause_ms", 600)) / 1000.0)
    keys = []
    next_at = D.now()
    for i in range(count):
        ch = rng.choice(charset)
        left = next_at - D.now()
        if left > 0.004:
            time.sleep(left - 0.003)  # sleep most of the gap; spin the last 3 ms (sleep's wake-up jitter)
        while D.now() < next_at:
            pass
        t_post = D.now()
        rk.press_char(j, ch)
        t_back = D.now()
        # t_post: just before CuaDriver's call; the key's HID event is made inside it (the call takes ~11 ms a key,
        # ext_realkey.press), so `call_ms` is kept beside it and the judge reports refreshes from both ends.
        keys.append({"i": i, "ch": ch, "t_post": round(t_post, 6), "t_back": round(t_back, 6),
                     "call_ms": round((t_back - t_post) * 1000, 2)})
        next_at = t_post + rng.uniform(lo, hi)
    return {"label": step.get("label"), "keys": keys, "rect": rect, "key_path": "real_hid",
            "clock": "time.monotonic (mach_absolute_time, the clock of frames.json t)"}


def step_video_close_open(j, step):
    """Clean-up for `finally`: stops the recording a failed or not-run step left open (ext_video video_stop with a
    short tail), so a red attempt keeps its movie, trace, events and meta (review must-fix 3 at 042d49a86b4)."""
    rec = getattr(j, "video", None)
    if not rec:
        return {"open": None}
    import ext_video
    return dict(ext_video.step_video_stop(j, {"name": rec["name"], "tail": float(step.get("tail", 0.3))}) or {},
                closed=rec["name"])


STEPS = {"typing_keys": step_typing_keys, "typing_rect": step_typing_rect, "video_close_open": step_video_close_open}
CONDITIONS = {}
