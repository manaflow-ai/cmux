"""The `--modes display` row of chromium-host-bench.py (p01-process-221): a Chromium page whose browser runs in the
Chromium Host (`debug.cef` backend `host`) follows the display of the cmux window that shows it. The host's page window
is never ordered in, so Chromium learns its display only from cmux (`cmux_shim_browser_set_page_display`, sent by the
page view on a window, screen, backing or display change); its begin-frames, devicePixelRatio and color space are
then that display's, as Chrome's page follows the display its app shim reports
(`RenderWidgetHostNSViewHost::OnScreenInfosChanged`, content/common/render_widget_host_ns_view.mojom).

The probe page records every animation frame's time and devicePixelRatio. The row measures:

  start     on the window's display: rAF/s against the display's refresh rate (pass: within RATE_TOLERANCE) and
            devicePixelRatio against its backing scale (pass: equal)
  move      with a second display (cmux20-bench has an external one, at another scale): the window moves there
            (`debug.window_frame` {screen}); frames until the rAF interval is the new display's (pass: <= 2) and until
            devicePixelRatio is its scale (pass: <= 1); then the same rate and scale checks there
  back      the window moves back to its first frame, judged the same way, so both directions of the move are
            measured whichever display the window starts on
  scale_up  the one of move and back that goes from the lower scale to the higher (1x to 2x): its frames until
            devicePixelRatio is the new scale, as its own field (not_measurable when both displays share a scale)

Frames after a move count from the move itself, not from a mark the page took before the request: the bench reads
the wall clock when `debug.window_frame` returns (it calls `setFrame` before it answers) and maps that instant onto
the page's `performance.now()` with a `Date.now()` read beside it, so neither the request's legs nor the eval's
round trip fall inside the frame budgets.

A display whose mode reports no refresh rate (0) is measured but not judged on rate. With one display the move row
says not_measurable. Without the host backend the row says so and the mode fails: it could not run.
"""
import ctypes
import ctypes.util
import time

RATE_TOLERANCE = 0.1
# The rAF interval is the display's once this many intervals in a row are within INTERVAL_TOLERANCE of its period.
STEADY_INTERVALS = 2
INTERVAL_TOLERANCE = 0.25
MOVE_FRAMES = 2
SCALE_FRAMES = 1
SAMPLE_S = 1.0
SETTLE_S = 1.5

PAGE = """<!doctype html><meta charset=utf-8><title>display probe</title>
<style>html,body{margin:0;height:100%;background:#305020}</style>
<script>
// Every animation frame's time (performance.now) and devicePixelRatio, oldest first, bounded.
const F = [];
function tick(t) { F.push([+t.toFixed(3), devicePixelRatio]); if (F.length > 6000) F.splice(0, 2000); requestAnimationFrame(tick); }
requestAnimationFrame(tick);
window.__framesSince = at => F.filter(f => f[0] >= at);
</script>"""


class CGRect(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double), ("w", ctypes.c_double), ("h", ctypes.c_double)]


def cg_displays():
    """Each active display: {id, bounds [x, y, w, h] in CoreGraphics points (top left of the main display), hz (0 when
    the mode reports none), scale (pixels per point)}."""
    cg = ctypes.CDLL(ctypes.util.find_library("CoreGraphics") or
                     "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    cg.CGDisplayBounds.restype = CGRect
    cg.CGDisplayBounds.argtypes = [ctypes.c_uint32]
    cg.CGDisplayCopyDisplayMode.restype = ctypes.c_void_p
    cg.CGDisplayCopyDisplayMode.argtypes = [ctypes.c_uint32]
    cg.CGDisplayModeGetRefreshRate.restype = ctypes.c_double
    cg.CGDisplayModeGetRefreshRate.argtypes = [ctypes.c_void_p]
    for name in ("CGDisplayModeGetPixelWidth", "CGDisplayModeGetWidth"):
        getattr(cg, name).restype = ctypes.c_size_t
        getattr(cg, name).argtypes = [ctypes.c_void_p]
    cg.CGDisplayModeRelease.argtypes = [ctypes.c_void_p]
    ids = (ctypes.c_uint32 * 16)()
    count = ctypes.c_uint32()
    if cg.CGGetActiveDisplayList(16, ids, ctypes.byref(count)) != 0:
        return []
    displays = []
    for display in ids[:count.value]:
        bounds = cg.CGDisplayBounds(display)
        mode = cg.CGDisplayCopyDisplayMode(display)
        hz, scale = 0.0, None
        if mode:
            hz = round(cg.CGDisplayModeGetRefreshRate(mode), 2)
            width = cg.CGDisplayModeGetWidth(mode)
            scale = round(cg.CGDisplayModeGetPixelWidth(mode) / width, 3) if width else None
            cg.CGDisplayModeRelease(mode)
        displays.append({"id": int(display), "bounds": [bounds.x, bounds.y, bounds.w, bounds.h], "hz": hz, "scale": scale})
    return displays


def display_of(screen_frame, displays):
    """The display whose bounds are `screen_frame` (AppKit points, bottom left of the main display), or None."""
    if not (isinstance(screen_frame, list) and len(screen_frame) == 4):
        return None
    main = next((d for d in displays if d["bounds"][0] == 0 and d["bounds"][1] == 0), None)
    if main is None:
        return None
    x, y, w, h = screen_frame
    top = main["bounds"][3] - (y + h)
    for display in displays:
        bx, by, bw, bh = display["bounds"]
        if all(abs(a - b) <= 1 for a, b in ((bx, x), (by, top), (bw, w), (bh, h))):
            return display
    return None


def rate(frames):
    """Animation frames per second over `frames` ([[time ms, dpr], ...]), or None below two frames."""
    if len(frames) < 2 or frames[-1][0] <= frames[0][0]:
        return None
    return round((len(frames) - 1) / ((frames[-1][0] - frames[0][0]) / 1000), 2)


def frames_to_rate(frames, hz):
    """Frames from the first one until the rAF interval is `hz`'s period for STEADY_INTERVALS intervals in a row
    (the index of the frame that starts that run), or None when it never is."""
    if not hz:
        return None
    period = 1000 / hz
    run = 0
    for index in range(1, len(frames)):
        interval = frames[index][0] - frames[index - 1][0]
        run = run + 1 if abs(interval - period) <= period * INTERVAL_TOLERANCE else 0
        if run == STEADY_INTERVALS:
            return index - STEADY_INTERVALS
    return None


def frames_to_scale(frames, scale):
    """Frames from the first one until devicePixelRatio is `scale` and stays so, or None when it never is."""
    if scale is None:
        return None
    for index in range(len(frames)):
        if all(abs(f[1] - scale) < 0.01 for f in frames[index:]):
            return index
    return None


def judge(frames, display):
    """The rate and scale checks of one display over `frames`."""
    measured, dpr = rate(frames), frames[-1][1] if frames else None
    row = {"display": display["id"], "hz": display["hz"], "scale": display["scale"], "raf_per_s": measured, "dpr": dpr}
    rate_ok = None if not display["hz"] else (measured is not None and
                                              abs(measured - display["hz"]) <= display["hz"] * RATE_TOLERANCE)
    scale_ok = dpr is not None and display["scale"] is not None and abs(dpr - display["scale"]) < 0.01
    row["pass"] = scale_ok and rate_ok is not False
    if rate_ok is None:
        row["rate_not_judged"] = "the display's mode reports no refresh rate"
    return row


def page_time_at(page_eval, wall_s):
    """The page's `performance.now()` at the wall clock instant `wall_s` (time.time()), or None when the page does not
    answer: `Date.now()` read beside `performance.now()` gives the offset between the two clocks (1 ms resolution)."""
    clocks = page_eval("[Date.now(), performance.now()]")
    if not (isinstance(clocks, list) and len(clocks) == 2):
        return None
    wall_ms, page_ms = clocks
    return wall_s * 1000 - (wall_ms - page_ms)


def run(rpc, wait, page_eval, url, sleep, displays=cg_displays, clock=time.time):
    """The row; returns (row, ok). `sleep` is the bench's harness wait (time.sleep) and `clock` its wall clock
    (time.time); tests pass a fake clock's."""
    backend = (rpc("debug.cef") or {}).get("backend")
    if backend != "host":
        return {"not_run": f"the Chromium backend is {backend!r}, not the Chromium Host (a Release build, or "
                           "browserHost.helper off)", "pass": False}, False
    opened = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True, "origin": "script"},
                 timeout=120)
    if not wait(lambda: page_eval("document.title === 'display probe' && document.readyState === 'complete'"), 60, 0.5):
        return {"error": f"the probe never loaded: {str(opened)[:200]}", "pass": False}, False
    known = displays()
    start = rpc("debug.window_frame") or {}
    here = display_of(start.get("screen_frame"), known)
    if here is None:
        return {"error": "the window's display is not one CoreGraphics lists", "window": start, "displays": known,
                "pass": False}, False

    def sample():
        mark = page_eval("performance.now()")
        sleep(SAMPLE_S)  # test harness: one sample window of animation frames
        return page_eval(f"__framesSince({mark})") or []

    def move_to(target, params):
        """Moves the window with `debug.window_frame` `params` and judges the page's switch to `target`."""
        moved = rpc("debug.window_frame", params) or {}
        mark = page_time_at(page_eval, clock())
        landed = display_of(moved.get("screen_frame"), known)
        sleep(SETTLE_S)  # test harness: the page settles on the new display
        frames = (page_eval(f"__framesSince({mark})") or []) if mark is not None else []
        move = {"to": target["id"], "landed": landed and landed["id"],
                "frames_to_rate": frames_to_rate(frames, target["hz"]),
                "frames_to_scale": frames_to_scale(frames, target["scale"]), "there": judge(sample(), target)}
        rate_ok = not target["hz"] or (move["frames_to_rate"] is not None and move["frames_to_rate"] <= MOVE_FRAMES)
        scale_ok = move["frames_to_scale"] is not None and move["frames_to_scale"] <= SCALE_FRAMES
        move["pass"] = move["landed"] == target["id"] and rate_ok and scale_ok and move["there"]["pass"]
        return move

    row = {"displays": known, "start": judge(sample(), here)}
    others = [d for d in known if d["id"] != here["id"]]
    # A display at another scale first, so one of the two moves is a 1x to 2x one.
    other = next((d for d in others if d["scale"] != here["scale"]), others[0] if others else None)
    if other is None:
        row["move"] = {"not_measurable": "one display: no move to measure (cmux20-bench has an external display)"}
        row["pass"] = row["start"]["pass"]
        return row, True
    row["move"] = move_to(other, {"screen": known.index(other)})
    if isinstance(start.get("frame"), list):
        row["back"] = move_to(here, {"frame": start["frame"]})
    else:
        row["back"] = {"not_measurable": "debug.window_frame gave no frame to move the window back to"}
    row["scale_up"] = scale_up(here, other, row["move"], row["back"])
    row["pass"] = (row["start"]["pass"] and row["move"]["pass"] and row["back"].get("pass", False)
                   and row["scale_up"].get("pass", True))
    return row, True


def scale_up(here, other, move, back):
    """The 1x to 2x result: the measured move from the lower scale to the higher."""
    if here["scale"] is None or other["scale"] is None or here["scale"] == other["scale"]:
        return {"not_measurable": "the two displays share a scale: no 1x to 2x move"}
    low, high, judged = (here, other, move) if here["scale"] < other["scale"] else (other, here, back)
    if "frames_to_scale" not in judged:
        return {"not_measurable": judged.get("not_measurable", "the move was not measured"), "pass": False}
    frames = judged["frames_to_scale"]
    return {"move": "move" if judged is move else "back", "from_scale": low["scale"], "to_scale": high["scale"],
            "frames_to_scale": frames, "pass": frames is not None and frames <= SCALE_FRAMES}
