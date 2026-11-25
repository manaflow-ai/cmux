"""Human-like pointer drags posted to one process (CGEventPostToPid, the call cua-driver posts with): mouse down, a
path of dragged events with chaotic timing, mouse up. No focus is taken and the person's cursor does not move.

`chaotic_path(start, rng, ...)` builds a path the way a person drags a window corner, an edge or a divider: segments
at varying speed, pauses, overshoots that come back, quick flicks and back-and-forth wiggles. `post_drag(pid, path)`
posts it, one event at each point's time. Coordinates are global screen points with a top-left origin (as
cua-driver's list_windows bounds). Python's ctypes only: no pyobjc, nothing to build.
"""
import ctypes, ctypes.util, math, random, time

_cg = ctypes.CDLL(ctypes.util.find_library("CoreGraphics") or
                  "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
_cf = ctypes.CDLL(ctypes.util.find_library("CoreFoundation") or
                  "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")


class CGPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


_cg.CGEventCreateMouseEvent.restype = ctypes.c_void_p
_cg.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, CGPoint, ctypes.c_uint32]
_cg.CGEventPostToPid.restype = None
_cg.CGEventPostToPid.argtypes = [ctypes.c_int32, ctypes.c_void_p]
_cg.CGEventSetIntegerValueField.restype = None
_cg.CGEventSetIntegerValueField.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int64]
_cf.CFRelease.restype = None
_cf.CFRelease.argtypes = [ctypes.c_void_p]

LEFT_DOWN, LEFT_UP, MOVED, LEFT_DRAGGED = 1, 2, 5, 6
CLICK_STATE = 1  # kCGMouseEventClickState
WINDOW_UNDER_POINTER = 91  # kCGMouseEventWindowUnderMousePointer
WINDOW_THAT_CAN_HANDLE = 92  # kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent


def _post(pid, kind, x, y, window_id=None):
    """One mouse event to `pid`. With `window_id` the event names the window under the pointer, as the window server's
    own events do: without it AppKit has no window to send a pid-posted event to and drops it (a corner, edge or
    divider drag changed nothing: the retest agent's ptrtest, 2026-11-24)."""
    event = _cg.CGEventCreateMouseEvent(None, kind, CGPoint(x, y), 0)
    if not event:
        raise OSError("CGEventCreateMouseEvent failed")
    if kind in (LEFT_DOWN, LEFT_UP, LEFT_DRAGGED):
        _cg.CGEventSetIntegerValueField(event, CLICK_STATE, 1)
    if window_id:
        _cg.CGEventSetIntegerValueField(event, WINDOW_UNDER_POINTER, int(window_id))
        _cg.CGEventSetIntegerValueField(event, WINDOW_THAT_CAN_HANDLE, int(window_id))
    _cg.CGEventPostToPid(pid, event)
    _cf.CFRelease(event)


def chaotic_path(start, rng, axis="xy", reach=(260, 140), seconds=4.0, hz=120.0):
    """[(t, x, y)] from `start`: a person's drag of a corner (`axis` "xy"), a vertical edge or divider ("x") or a
    horizontal edge ("y"), within `reach` points each way, about `seconds` long. Moves: an ease to a target at a
    random speed, a pause, an overshoot past the target and back, a quick flick, a wiggle of a few short back and
    forths. Ends at rest near the start (so repeated drags keep the window in range)."""
    x0, y0 = start
    rx, ry = reach
    t, x, y, path = 0.0, x0, y0, [(0.0, x0, y0)]

    def go(tx, ty, dur):
        nonlocal t, x, y
        steps = max(1, int(dur * hz))
        sx, sy = x, y
        for i in range(1, steps + 1):
            u = i / steps
            e = u * u * (3 - 2 * u)  # ease in-out
            jitter = rng.uniform(-0.6, 0.6)
            x, y = sx + (tx - sx) * e + jitter, sy + (ty - sy) * e + jitter
            t += dur / steps
            path.append((t, x, y))

    def target():
        tx = x0 + (rng.uniform(-rx, rx) if "x" in axis else 0)
        ty = y0 + (rng.uniform(-ry, ry) if "y" in axis else 0)
        return tx, ty

    while t < seconds:
        move = rng.choice(["ease", "ease", "pause", "overshoot", "flick", "wiggle"])
        if move == "ease":
            go(*target(), rng.uniform(0.15, 0.9))
        elif move == "pause":
            t += rng.uniform(0.08, 0.45)
            path.append((t, x, y))
        elif move == "overshoot":
            tx, ty = target()
            over = rng.uniform(1.15, 1.4)
            go(x + (tx - x) * over, y + (ty - y) * over, rng.uniform(0.12, 0.35))
            go(tx, ty, rng.uniform(0.1, 0.25))
        elif move == "flick":
            go(*target(), rng.uniform(0.04, 0.1))
        else:  # wiggle
            amp = rng.uniform(15, 70)
            for k in range(rng.randint(3, 7)):
                sign = 1 if k % 2 == 0 else -1
                go(x + (sign * amp if "x" in axis else 0), y + (sign * amp * 0.6 if "y" in axis else 0),
                   rng.uniform(0.05, 0.14))
    go(x0, y0, rng.uniform(0.2, 0.5))
    return path


def post_drag(pid, path, hold_down=0.05, window_id=None):
    """Posts mouse down at the path's first point, a dragged event at each later point at its time, then mouse up at
    the last, each naming `window_id` when given. Returns (started, ended) in time.monotonic seconds."""
    _, x, y = path[0]
    _post(pid, MOVED, x, y, window_id)
    time.sleep(0.03)  # pointer harness: the hover reaches the edge before the press, as a hand's does
    started = time.monotonic()
    _post(pid, LEFT_DOWN, x, y, window_id)
    time.sleep(hold_down)  # pointer harness: a hand's press before it moves
    base = time.monotonic()
    for t, px, py in path[1:]:
        due = base + t
        wait = due - time.monotonic()
        if wait > 0:
            time.sleep(wait)  # pointer harness: one event at each point's time
        _post(pid, LEFT_DRAGGED, px, py, window_id)
    _, x, y = path[-1]
    _post(pid, LEFT_UP, x, y, window_id)
    return started, time.monotonic()


def strokes(path, min_points=3):
    """`path` cut into straight strokes at each pause and each turn of direction: [(x0, y0, x1, y1, ms, steps)], for
    a driver whose drag is one press, straight moves and a release (cua-driver's `drag`). Its strokes keep the path's
    speeds, pauses (between strokes) and reversals; the button is up between strokes."""
    out, seg = [], [path[0]]

    def flush():
        if len(seg) >= min_points:
            (t0, x0, y0), (t1, x1, y1) = seg[0], seg[-1]
            if abs(x1 - x0) + abs(y1 - y0) >= 6:
                out.append((x0, y0, x1, y1, max(16, int((t1 - t0) * 1000)), len(seg) - 1))

    for prev, point in zip(path, path[1:]):
        dt = point[0] - prev[0]
        if dt > 0.06:  # a pause
            flush(); seg[:] = [point]; continue
        if len(seg) >= 2:
            ax, ay = seg[-1][1] - seg[-2][1], seg[-1][2] - seg[-2][2]
            bx, by = point[1] - prev[1], point[2] - prev[2]
            if ax * bx + ay * by < 0 and math.hypot(bx, by) > 1.0:  # a turn back
                flush(); seg[:] = [prev]
        seg.append(point)
    flush()
    return out


def seeded(seed):
    return random.Random(seed)
