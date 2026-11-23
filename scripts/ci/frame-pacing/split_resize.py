"""A page beside a terminal while its pane is resized: the split divider dragged, the sidebar
toggled, or the window's corner dragged.

Used by golden.py (`split_resize`, the browser pane and the divider) and
scripts/cmux-next/split-resize-bench.py (`--pane`, `--gesture`). The page is one of:

- `browser`: the workspace is split right and the right pane opens the local probe page of
  browser_resize.py in a Chromium tab; it records `[performance.timeOrigin + rAF timestamp,
  innerWidth, innerHeight]` on every animation frame (`window.__rz`, read with `browser.page.eval`);
- `chat`: the workspace is split right and the right pane opens an agent chat; the same recorder
  runs in the chat page through `debug.agent_pane` `resize_probe` (`start` resets it, `read`
  returns its frames and the app's clock), as `browser.page.eval` does not reach a chat;
- `terminal`: the workspace is split right and the right pane shows a terminal (the split's own, else a new
  terminal tab, `newSurface`) that `cat`s a generated transcript (`seed` / 4 turns, as a chat seeds about four rows
  a turn; default TRANSCRIPT_TURNS), each turn a user line and one or two assistant paragraphs of long prose lines,
  so every column change reflows a long wrapped scrollback. It stands in for Claude Code in a terminal (Leo's 2026-11-18 bar: the chat pane must reflow on a
  divider drag "as fast as Claude Code does [in a terminal] when the pane is resized"): Claude Code is not signed in
  on the fleet Macs, so a terminal reflowing a long wrapped transcript is what it is measured against. The
  terminal's own report gives its frames: `debug.motion`'s `terminal` target
  (TerminalSurfaceView+MotionSample.swift) samples, on every display frame of the same trace, the surface layer's
  width in points (its area) and the width in pixels of the IOSurface it shows (the frame Ghostty last drew,
  divided by the backing scale read at rest: the width it was laid out at), and Ghostty's frame counter; a sample
  whose counter or shown width changed is one of the terminal's frames. `debug.terminal_final_grid` runs beside
  each gesture and records the grids each terminal drew (`grid_reflows`: the new grids drawn while the pane moved,
  the most of any one terminal, each a reflow of its scrollback; data only, its clock is not the trace's).

The gestures (`GESTURES`), each traced four times:

- `divider`: the divider beside the page dragged through the real mouse path (`debug.mouse` down
  on the divider, one drag event per 120 Hz frame, up), which the divider view tracks as a
  person's drag;
- `divider-pause`: the same divider held down and dragged 240 points narrower and back in steps with a
  250 ms rest between them, as a person's hand pauses on it (Leo's 2026-11-18 recording beside a long
  chat paused this way and stalled at each pause);
- `sidebar`: `toggleSidebar` (hide, show, hide, show): the panes move and resize together;
- `window-edge`: the window's bottom-right corner dragged in and out by 200 x 100 points, one
  drag event per 120 Hz frame, as scripts/cmux-next/resize-frames-live.py does (AppKit's live
  resize).

`debug.motion` `trace_*` samples, once per display frame, the dividers and panes
(ScreenContentView+MotionSample.swift), the window size, and each Chromium host (`page`,
CEFHostView+MotionSample.swift: host size, the fork's page window size, wall ms, the host's and
the page window's screen x, the width of the pane's page area, then whether the page is
detached from the window and the hosted root's size and screen x, which show the page's pixels
while it is detached and no page window is over the pane). The judge reports, per gesture:

- `area_lag`: frames the pane's page area trails what moved it (the divider, the window's width);
- `edge_lag`: frames the page's left edge (its window's, else the hosted root's) trails the page
  area's (the page's pixels follow the pane only as fast as they do);
- `layout_lag`: frames, and ms, from the page area taking a width to the page's first
  animation frame laid out at that width (p50, p95, max), and `stale_frames`, the display
  frames in which the page was laid out at a different width than its area;
- `relayouts`: the widths the page laid out at while the pane moved (each one a step the
  page catches up by), and `settle_ms`, from the pane's last move to the page laid out at
  the area's final width;
- `gap_frames`: display frames in which the page area was wider than the page's pixels
  (the host view shows there);
- `dropped`: display frames the app missed while the pane moved (an interval over 1.5
  refresh periods), and `page_dropped`, the same for the page's own animation frames.

A chat's page area is its pane's content width (`panes`), offset by the chat page's width at
rest, and its wall clock the trace's `t0_s` on the app's clock (`resize_probe`'s `clock`).
`seed` > 0 fills the chat with that many rows first (`debug.agent_pane` `seed_rows`, about four
rows a turn), so the drag runs beside a long chat. A terminal needs no clock: its frames are the trace's own
samples, its page area the surface layer's width; its widths match within TERMINAL_TOLERANCE points (a pixel
width over the backing scale rounds), and it has no page window, so `edge_lag` is not measured for it.

Every pane gives the same verdict keys, so the chat and the terminal compare row for row.

Report only: no threshold fails a run.
"""

from __future__ import annotations

import json
import random
import shlex
import time
from pathlib import Path

import browser_resize

# The divider's drags (points), each from where the divider is then. 60, not 160: a split beside a docked chat leaves
# the divider about 75 points each way before a pane's minimum width, and on 2026-11-19 a 160-point drag stopped at
# that limit after 74 points, so the next drags pressed beside the divider and moved nothing.
DRAGS = (-60, 60, -60, 60)
PANES = ("browser", "chat", "terminal")
# The terminal's transcript: turns when `seed` is 0 (about the chat's 2800 seeded rows), and its words.
TRANSCRIPT_TURNS = 700
TRANSCRIPT_WORDS = ("the", "pane", "layout", "reflow", "width", "frame", "divider", "agent", "session", "change",
                    "message", "terminal", "scrollback", "column", "renders", "while", "after", "before", "because",
                    "resize", "measure", "every", "display", "refresh", "cursor", "transcript", "wraps", "line",
                    "prose", "long", "reads", "writes", "tool", "result", "output", "context", "window", "steady",
                    "under", "load", "each", "turn", "keeps", "its", "text", "and", "then", "with", "from", "into")
# Points a terminal's shown width may differ from its layer's and still count as laid out at it (pixels over scale).
TERMINAL_TOLERANCE = 1.0
GESTURES = ("divider", "divider-pause", "sidebar", "window-edge")
# `divider-pause`: each move's points, then the rest after it, with the mouse held down throughout.
PAUSED_DRAG = ((-30, 0.25), (-30, 0.25), (60, 0.25), (30, 0.25), (-30, 0.0))
# The window corner's moves (points, window-local): in, out, in, out.
EDGE_DRAGS = ((-200, -100), (200, 100), (-200, -100), (200, 100))
TARGETS = ["dividers", "panes", "page", "window"]


def _vertical(sample: dict) -> list:
    """The vertical split dividers (taller than wide) of a `dividers` sample."""
    return [row for row in sample.get("dividers") or [] if len(row) >= 5 and float(row[4]) > float(row[3])]


def _pane_row(sample: dict, pane: str | None) -> list | None:
    """The `panes` row of `pane` (the rightmost pane when it is None or not found), or None."""
    rows = [row for row in sample.get("panes") or [] if len(row) >= 12]
    if not rows:
        return None
    if pane:
        found = next((row for row in rows if str(row[0]) == pane), None)
        if found is not None:
            return found
    return max(rows, key=lambda row: float(row[1]))


def _divider(sample: dict, pane: str | None = None) -> list | None:
    """The divider the gestures drag: beside `pane` (its nearer edge), else the leftmost vertical one; or None."""
    rows = _vertical(sample)
    if not rows:
        return None
    row = _pane_row(sample, pane) if pane else None
    if row is None:
        return min(rows, key=lambda divider: float(divider[1]))
    left, right = float(row[1]), float(row[1]) + float(row[3])

    def distance(divider: list) -> float:
        middle = float(divider[1]) + float(divider[3]) / 2
        return min(abs(middle - left), abs(middle - right))
    # A tie goes to the leftmost: a chat docked at the window's right edge has a divider on both sides, and the
    # one at the window's edge doesn't move (the chat run on 2026-11-18 dragged it: no drag moved its pane).
    return min(rows, key=lambda divider: (round(distance(divider)), float(divider[1])))


def _page(sample: dict) -> list | None:
    """The rightmost Chromium host of a `page` sample (the split's new pane), or None."""
    rows = [row for row in sample.get("page") or [] if len(row) >= 5]
    if not rows:
        return None
    return max(rows, key=lambda row: float(row[5]) if len(row) >= 8 else 0.0)


def _terminal(sample: dict) -> list | None:
    """The rightmost terminal surface of a `terminal` sample (the split's new pane), or None: `[x, y, width, height,
    shown width px, shown height px, frames, ...]` (TerminalSurfaceView+MotionSample.swift)."""
    rows = [row for row in sample.get("terminal") or [] if len(row) >= 7]
    if not rows:
        return None
    return max(rows, key=lambda row: float(row[0]))


def transcript(turns: int, seed: int = 1) -> str:
    """A long chat transcript as plain text: per turn a user line and one or two assistant paragraphs, each one long
    line of prose (200 to 1400 characters) the terminal wraps. The same text for the same `turns` and `seed`."""
    pick = random.Random(seed)

    def prose(low: int, high: int) -> str:
        words: list[str] = []
        length, goal = 0, pick.randint(low, high)
        while length < goal:
            word = pick.choice(TRANSCRIPT_WORDS)
            words.append(word)
            length += len(word) + 1
        return " ".join(words).capitalize() + "."

    lines = []
    for turn in range(1, turns + 1):
        lines.append(f"> [{turn}] {prose(80, 400)}")
        for _ in range(pick.randint(1, 2)):
            lines.append(f"  {prose(200, 1400)}")
        lines.append("")
    return "\n".join(lines) + "\n"


def _pixels(row: list) -> tuple[float, float, str | None]:
    """(width, screen x, source) of where a `page` row's page shows its pixels: its page window, else (a detached
    or hosted page with no page window over the pane) the hosted root at the host's left edge; -1s when neither."""
    if float(row[2]) >= 0:
        return float(row[2]), float(row[6]) if len(row) >= 8 else -1.0, "window"
    if len(row) >= 12 and float(row[9]) >= 0:
        return float(row[9]), float(row[11]), "hosted"
    return -1.0, -1.0, None


# The page-window counters of `debug.cef` (CEFTrackerStats) a gesture's trace reports the change of.
CEF_COUNTERS = ("fences", "fence_joined", "fence_presented", "fence_missed", "fences_expired", "detaches",
                "attaches", "geometry_posts", "clip_builds", "clip_ms", "occlusion_reads")


def _cef_counters(reply) -> dict[str, float]:
    """CEF_COUNTERS wherever they sit in a `debug.cef` reply (the first of each found); {} for none."""
    found: dict[str, float] = {}
    stack = [reply]
    while stack:
        node = stack.pop()
        if isinstance(node, dict):
            for key, value in node.items():
                if key in CEF_COUNTERS and key not in found and isinstance(value, (int, float)):
                    found[key] = float(value)
                elif isinstance(value, (dict, list)):
                    stack.append(value)
        elif isinstance(node, list):
            stack.extend(node)
    return found


def _cef_engine(reply) -> dict[str, float]:
    """The engine's fork API (`fork_api`) and each shown page window's hosting (`hosted.<tab id>`: 1 hosted in the
    window's layer tree, 0 a page window of its own) wherever they sit in a `debug.cef` reply. A resize fence joins
    only a hosted page on an engine at `CEFLayerHosting.resizeFenceForkAPI` or later, so a gesture whose `cef.fences`
    stayed 0 says here which of the two it lacked."""
    found: dict[str, float] = {}
    stack = [reply]
    while stack:
        node = stack.pop()
        if isinstance(node, dict):
            for key, value in node.items():
                if (key == "fork_api" or key.startswith("hosted.")) and key not in found and isinstance(value, (int, float)):
                    found[key] = float(value)
                elif isinstance(value, (dict, list)):
                    stack.append(value)
        elif isinstance(node, list):
            stack.extend(node)
    return found


def from_point(point_of, run):
    """A gesture that starts where `point_of()` says (a divider's center), prepared before its trace: calling the
    result reads the point now and returns the gesture, which `run`s from it (an error with no point).

    The app has one motion trace (MotionFrameTrace.shared), and reading a divider's place is a trace of its own
    (`at_rest`). Read inside the gesture's trace, it ended that trace, and the gesture's trace_stop returned the
    0.2 s at rest: every divider drag of steps d315c76a, bee050aa, c9df4d3c and bead182b (2026-11-20 to 22) read
    12 to 16 samples of a still divider, and the bench measured nothing."""
    def prepare():
        point = point_of()
        return (lambda: run(*point)) if point else (lambda: {"error": "no divider"})
    return prepare


def drive(driver, out: Path, strip: bool = False, pane: str = "browser",
          gestures: tuple[str, ...] | list[str] = ("divider",), seed: int = 0, profile=None, sight=None) -> None:
    """Splits right, opens the page (`pane`) in the right pane, then traces each of `gestures` four times.

    `strip`: then one more divider drag, held open while `debug.window_snapshot` takes the window every
    12 moves (`strip-NN.png` in `out`): a frame strip of where the page is while the divider moves.
    Snapshots perturb timing, so that drag is not measured.

    `profile`: called just before the first divider drag; it returns a callable that ends the profile it
    started (the bench's CPU sample of the app through that drag).

    `sight`: called just before each gesture; what it returns (whether the window can get frames) goes in the
    gesture's trace as `sight`."""
    if pane not in PANES:
        driver.save("split_resize", {"error": f"unknown pane {pane!r}"})
        return
    unknown = [gesture for gesture in gestures if gesture not in GESTURES]
    if unknown:
        driver.save("split_resize", {"error": f"unknown gestures {unknown}"})
        return
    # A workspace of its own first. A fresh launch lands on the docked Home (#46526): its chat dock refuses to split
    # and its columns sit in a scrolling strip whose divider moved only when the drag ended (2026-11-20, fleet step
    # cfe8a822: the divider read the same x in every sample of three drags, then 60 points further after each).
    # A workspace's own split divider resizes its panes live, as a person drags it beside a chat.
    workspace = driver.call("action.run", {"action": "workspace.newAtBottom", "focus": True}, timeout=30)
    time.sleep(1.5)
    split = driver.call("action.run", {"action": "splitRight", "focus": True}, timeout=30)
    split = {"workspace": workspace, **split} if isinstance(split, dict) else split
    if "error" in split or (split.get("data") or {}).get("not_run"):
        # A fresh window focuses its chat dock, which never splits ("The agent chat can't be split."): split the
        # first other pane instead. Before this the chat suite measured no drag (0 moving frames) on such a window.
        driver.call("debug.motion", {"action": "trace_start", "targets": ["panes"]})
        time.sleep(0.2)
        panes = driver.call("debug.motion", {"action": "trace_stop"})
        last = [sample for sample in panes.get("samples") or [] if sample.get("panes")]
        for row in (last[-1].get("panes") or []) if last else []:
            tried = driver.call("action.run", {"action": "splitRight", "target": f"pane:{row[0]}", "focus": True},
                                timeout=30)
            if "error" not in tried and not (tried.get("data") or {}).get("not_run"):
                split = {"refused": split, "split": tried, "pane": row[0]}
                break
    time.sleep(1.0)
    chat_pane: str | None = None
    # The pane the page is in, whose divider the gestures drag (the chat's, the terminal's; the browser's: None).
    beside: str | None = None
    targets = TARGETS + (["terminal"] if pane == "terminal" else [])
    if pane == "browser":
        page = out / "split-resize-probe.html"
        page.write_text(browser_resize.PROBE_PAGE)
        opened = driver.call("action.run", {"action": "openBrowser.chromium", "args": {"url": page.as_uri()},
                                            "focus": True}, timeout=90)

        def evaluate(script: str):
            result = driver.call("browser.page.eval", {"script": script}, timeout=20)
            return result.get("value") if "error" not in result else None

        def reset() -> None:
            evaluate("window.__rz.length = 0, true")

        def read() -> tuple[list, dict | None]:
            raw = evaluate("JSON.stringify(window.__rz)")
            try:
                return (json.loads(raw) if isinstance(raw, str) else []), None
            except ValueError:
                return [], None

        def recording() -> bool:
            return evaluate("document.readyState === 'complete' && Array.isArray(window.__rz) && window.__rz.length > 2") is True
    elif pane == "terminal":
        def shown() -> tuple[list | None, list | None]:
            """The rightmost pane's `panes` row and the terminal surface inside it (None when it shows none)."""
            driver.call("debug.motion", {"action": "trace_start", "targets": ["panes", "terminal"]})
            time.sleep(0.2)
            snapshot = driver.call("debug.motion", {"action": "trace_stop"})
            rows = [sample for sample in snapshot.get("samples") or [] if sample.get("panes")]
            right = _pane_row(rows[-1], None) if rows else None
            surface = _terminal(rows[-1]) if rows else None
            if right is None or surface is None:
                return right, None
            # The surface is the right pane's when its middle is inside the pane's shown rect.
            middle = float(surface[0]) + float(surface[2]) / 2
            inside = float(right[1]) <= middle <= float(right[1]) + float(right[3])
            return right, surface if inside else None

        right, surface = shown()
        beside = str(right[0]) if right is not None else None
        opened: dict = {"split_terminal": surface is not None}
        tab = None
        if right is not None and surface is None:
            # The split's new pane shows no terminal (it split a page): a new terminal tab in it.
            made = driver.call("action.run", {"action": "newSurface", "target": f"pane:{right[0]}", "focus": True}, timeout=30)
            if "error" in made or (made.get("data") or {}).get("not_run"):
                made = driver.call("action.run", {"action": "newSurface", "focus": True}, timeout=30)
            opened["new_tab"] = made
            created = made.get("created") or (made.get("data") or {}).get("created") or []
            tab = next((str(item) for item in created if str(item).startswith("tab_")), None)
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline and surface is None:
                time.sleep(0.5)
                right, surface = shown()
        turns = max(1, seed // 4) if seed > 0 else TRANSCRIPT_TURNS
        text = out / "split-resize-transcript.txt"
        text.write_text(transcript(turns))
        command = f"clear; cat {shlex.quote(str(text))}\r"
        sent = driver.call("action.run", {"action": "terminal.sendText", "args": {"text": command}, "focus": True,
                                          **({"target": f"tab:{tab}"} if tab else {})}, timeout=30)
        opened.update({"transcript": {"turns": turns, "bytes": text.stat().st_size}, "sent": sent})

        def frames_drawn() -> float | None:
            _, row = shown()
            return float(row[6]) if row is not None and float(row[4]) > 0 else None

        # The transcript has printed when the terminal stops drawing: its frame counter holds for 1.5 s (at most 60 s).
        deadline, last, still_since = time.monotonic() + 60, frames_drawn(), time.monotonic()
        while time.monotonic() < deadline and time.monotonic() - still_since < 1.5:
            time.sleep(0.5)
            now = frames_drawn()
            if now != last:
                last, still_since = now, time.monotonic()
        opened["printed_s"] = round(60 - max(0.0, deadline - time.monotonic()), 1)

        def reset() -> None:
            pass

        def read() -> tuple[list, dict | None]:
            # The terminal's frames are the trace's own `terminal` samples (judge_drag reads them there).
            return [], None

        def recording() -> bool:
            return frames_drawn() is not None
    else:
        # The chat opens in the split's new pane (the rightmost), not in a chat dock.
        driver.call("debug.motion", {"action": "trace_start", "targets": ["panes"]})
        time.sleep(0.2)
        snapshot = driver.call("debug.motion", {"action": "trace_stop"})
        rows = [sample for sample in snapshot.get("samples") or [] if sample.get("panes")]
        right = _pane_row(rows[-1], None) if rows else None
        opened = {"error": "no pane"}
        if right is not None:
            opened = driver.call("action.run", {"action": "palette.newAgentChat", "target": f"pane:{right[0]}", "focus": True})
        if "error" in opened:
            opened = driver.call("action.run", {"action": "palette.newAgentChat", "focus": True})
        ready: dict = {}
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            ready = driver.call("debug.agent_pane", {"action": "readiness"}, timeout=30)
            # The page itself, not only its pane: a seed sent before the page has loaded its debug hook times out and
            # never lands (2026-11-20, fleet step 48feb75e: readiness named a pane, the seed timed out, 0 rows).
            if "error" not in ready and ready.get("pane") and ready.get("document_ready") and ready.get("composer_visible"):
                break
            time.sleep(0.5)
        chat_pane = ready.get("pane") if "error" not in ready else None
        beside = chat_pane
        target = {"pane": chat_pane} if chat_pane else {}
        seeded = None
        if seed > 0:
            # The seed answers when the rows have committed, which can outlast the page call's 5 s on a fleet Mac
            # (all three tries timed out on 2026-11-19); the page goes on seeding. Seeding again only starts over,
            # so the chat's own row count (`chat_state`) says when it holds the seed, for up to 60 s.
            # A seed that has not landed 20 s after it was sent is sent again (each one replaces the rows), at most
            # three times in 90 s.
            seeded = {"sent": [], "ready": ready}
            began = time.monotonic()
            deadline, resend_at = began + 90, began
            while time.monotonic() < deadline:
                if time.monotonic() >= resend_at and len(seeded["sent"]) < 3:
                    seeded["sent"].append(driver.call("debug.agent_pane", {"action": "seed_rows", "count": seed,
                                                                           **target}, timeout=120))
                    resend_at = time.monotonic() + 20
                rows = driver.call("debug.agent_pane", {"action": "chat_state", **target}, timeout=20).get("rows")
                seeded["rows"] = rows
                if isinstance(rows, int) and rows >= seed - 1:  # a 2800-row seed showed 2799 rows (2026-11-19)
                    break
                time.sleep(1.0)
            seeded["waited_s"] = round(time.monotonic() - began, 1)
            opened = {"opened": opened, "seeded": seeded}
            if not (isinstance(seeded.get("rows"), int) and seeded["rows"] >= seed - 1):
                # A short chat measures nothing about a long one: say so instead of reporting its drags.
                driver.save("split_resize", {"error": f"the chat never held its {seed}-row seed", "pane": pane,
                                             "split": split, "opened": opened})
                return
            time.sleep(2.0)

        def probe(step: str) -> dict:
            return driver.call("debug.agent_pane", {"action": "resize_probe", "step": step, **target}, timeout=20)

        def reset() -> None:
            probe("start")

        def read() -> tuple[list, dict | None]:
            result = probe("read")
            frames = result.get("frames")
            return (frames if isinstance(frames, list) else []), result.get("clock")

        def recording() -> bool:
            probe("start")
            time.sleep(0.3)
            return len(read()[0]) > 2

    deadline = time.monotonic() + 60
    ready_page = False
    while time.monotonic() < deadline:
        if recording():
            ready_page = True
            break
        time.sleep(0.5)
    if not ready_page:
        driver.save("split_resize", {"error": f"the probe never ran in the {pane} pane", "pane": pane, "split": split,
                                     "opened": opened})
        return
    time.sleep(1.5)

    def at_rest() -> dict | None:
        """One sample of the window at rest: the dividers, the panes and the window size."""
        if "error" in driver.call("debug.motion", {"action": "trace_start", "targets": targets}):
            return None
        time.sleep(0.2)
        snapshot = driver.call("debug.motion", {"action": "trace_stop"})
        rest = [sample for sample in snapshot.get("samples") or [] if sample.get("window")]
        return rest[-1] if rest else None

    rest = at_rest()
    if rest is None or (("divider" in gestures or "divider-pause" in gestures or strip) and not _divider(rest, beside)):
        driver.save("split_resize", {"error": "no split divider in the window", "pane": pane, "split": split,
                                     "opened": opened, "rest": rest})
        return
    period = 1 / 120

    def drag_path(x0: float, y0: float, dx: float, dy: float, steps: int = 60) -> dict:
        """Pressed once at (x0, y0), then one drag event per 120 Hz frame to (x0 + dx, y0 + dy), then released."""
        down = driver.call("debug.mouse", {"action": "down", "x": x0, "y": y0})
        began = time.monotonic()
        for step in range(1, steps + 1):
            x, y = x0 + dx * step / steps, y0 + dy * step / steps
            driver.call("debug.mouse", {"action": "drag", "x": x, "y": y, "to_x": x, "to_y": y, "steps": 1,
                                        "press": False, "release": False})
            wait = began + step * period - time.monotonic()
            if wait > 0:
                time.sleep(wait)
        driver.call("debug.mouse", {"action": "up", "x": x0 + dx, "y": y0 + dy})
        return {"from": [x0, y0], "dx": dx, "dy": dy, "down": down, "wall_s": round(time.monotonic() - began, 3)}

    def divider_point() -> tuple[float, float] | None:
        sample = at_rest()
        divider = _divider(sample, beside) if sample else None
        if divider is None:
            return None
        return float(divider[1]) + float(divider[3]) / 2, float(divider[2]) + float(divider[4]) / 2

    def paused_drag(x0: float, y0: float) -> dict:
        """Pressed once at (x0, y0), then PAUSED_DRAG's moves one drag event per 120 Hz frame, each followed by its
        rest with the mouse still down, then released where the moves end."""
        down = driver.call("debug.mouse", {"action": "down", "x": x0, "y": y0})
        began = time.monotonic()
        at = began
        x = x0
        for dx, rest in PAUSED_DRAG:
            steps = max(1, round(abs(dx) / 4))
            for step in range(1, steps + 1):
                to = x + dx * step / steps
                driver.call("debug.mouse", {"action": "drag", "x": to, "y": y0, "to_x": to, "to_y": y0, "steps": 1,
                                            "press": False, "release": False})
                at += period
                if at > time.monotonic():
                    time.sleep(at - time.monotonic())
            x += dx
            at += rest
            if at > time.monotonic():
                time.sleep(at - time.monotonic())
        driver.call("debug.mouse", {"action": "up", "x": x, "y": y0})
        return {"from": [x0, y0], "dx": x - x0, "dy": 0, "down": down, "wall_s": round(time.monotonic() - began, 3)}

    def acts(gesture: str) -> list:
        """Each gesture's preparation: called before its trace starts, it returns the gesture (`from_point`)."""
        if gesture == "divider-pause":
            point = divider_point()
            if point is None:
                return []
            # Each drag starts from the divider's place then (PAUSED_DRAG's moves add up to none).
            return [from_point(divider_point, paused_drag) for _ in range(4)]
        if gesture == "divider":
            if divider_point() is None:
                return []
            return [from_point(divider_point, lambda x, y, dx=dx: drag_path(x, y, dx, 0)) for dx in DRAGS]
        if gesture == "sidebar":
            return [lambda: lambda: driver.call("action.run", {"action": "toggleSidebar"}) for _ in range(4)]
        sample = at_rest()
        if not sample:
            return []
        w, h = float(sample["window"][0]), float(sample["window"][1])
        moves = []
        for dx, dy in EDGE_DRAGS:
            moves.append(lambda w=w, h=h, dx=dx, dy=dy: lambda: drag_path(w - 1, h - 1, dx, dy))
            w, h = w + dx, h + dy
        return moves

    drags = []
    for gesture in gestures:
        for prepare in acts(gesture):
            act = prepare()  # where it starts, read before its trace (from_point)
            reset()
            cef_reply = driver.call("debug.cef", {}, timeout=10)
            cef_before = _cef_counters(cef_reply)
            cef_engine = _cef_engine(cef_reply)
            if pane == "terminal":
                # Each terminal's drawn and PTY grids through the gesture (data: the reflows it drew).
                driver.call("debug.terminal_final_grid", {"action": "start"}, timeout=10)
            # Whether the window can get frames now (`sight`: the app active, the window on screen and not covered): a
            # window out of sight gets no frame ticks, and a drag's moves wait for one (DividerDrag.waitForFrame).
            seen = sight() if sight is not None else None
            stop_profile = profile() if profile is not None and gesture == "divider" and not drags else None
            trace = driver.trace(targets, act, 0.8 if gesture != "sidebar" else 1.2)
            if stop_profile is not None:
                stop_profile()
            if pane == "terminal":
                trace["grids"] = (driver.call("debug.terminal_final_grid", {"action": "stop"}, timeout=20)
                                  .get("terminals"))
            trace["page_frames"], clock = read()
            cef_after = _cef_counters(driver.call("debug.cef", {}, timeout=10))
            # What the page windows did through this gesture: resize fences joined, presented, missed, expired.
            trace["cef"] = {key: round(cef_after[key] - cef_before.get(key, 0.0), 2) for key in cef_after}
            # The engine and the pages' hosting as the gesture began: which a fence needs (`_cef_engine`).
            trace["cef_engine"] = cef_engine
            trace.update({"gesture": gesture, "pane": pane, "chat_pane": chat_pane, "beside": beside, "clock": clock,
                          "sight": seen})
            drags.append(trace)
            time.sleep(0.6)
    shots = []
    point = divider_point() if strip else None
    if point is not None:
        x, y = point
        driver.call("debug.mouse", {"action": "down", "x": x, "y": y})
        for step in range(1, 97):
            at = x - 200 * step / 96
            driver.call("debug.mouse", {"action": "drag", "x": at, "y": y, "to_x": at, "to_y": y, "steps": 1,
                                        "press": False, "release": False})
            time.sleep(1 / 120)
            if step % STRIP_EVERY == 0:
                path = out / f"strip-{step // STRIP_EVERY:02d}.png"
                shots.append({"step": step, "path": path.name,
                              "result": driver.call("debug.window_snapshot", {"kind": "main", "path": str(path)}, timeout=20)})
        driver.call("debug.mouse", {"action": "up", "x": x - 200, "y": y})
        time.sleep(1.0)
        path = out / "strip-landed.png"
        shots.append({"step": "landed", "path": path.name,
                      "result": driver.call("debug.window_snapshot", {"kind": "main", "path": str(path)}, timeout=20)})
    driver.save("split_resize", {"drags": drags, "pane": pane, "gestures": list(gestures), "split": split,
                                 "opened": opened, "chat_pane": chat_pane, "beside": beside, "strip": shots})


# The recording drag: a window snapshot every this many of its 96 moves (16 frames, then one after it landed).
STRIP_EVERY = 6


def judge_drag(trace: dict, refresh: float) -> dict:
    gesture = trace.get("gesture") or "divider"
    chat = trace.get("pane") == "chat"
    terminal = trace.get("pane") == "terminal"
    chat_pane = trace.get("chat_pane")
    # The pane whose divider the gestures drag: the chat's, the terminal's (the browser's: the leftmost divider).
    beside = trace.get("beside") or (chat_pane if chat else None)
    if chat:
        samples = [sample for sample in trace.get("samples") or [] if _pane_row(sample, chat_pane)]
    elif terminal:
        samples = [sample for sample in trace.get("samples") or [] if _terminal(sample)]
    else:
        samples = [sample for sample in trace.get("samples") or [] if _page(sample)]
    if gesture in ("divider", "divider-pause"):
        samples = [sample for sample in samples if _divider(sample, beside)]
    if len(samples) < 3:
        return {"error": "no per-frame samples with a divider and a chat pane" if chat
                else "no per-frame samples with a divider and a terminal surface" if terminal
                else "no per-frame samples with a divider and a Chromium host"}
    lag_frames, changes, p = browser_resize._lag_frames, browser_resize._changes, browser_resize._percentile
    # How far the page's width may be from its area's and still count as laid out at it.
    tolerance = TERMINAL_TOLERANCE if terminal else 0.5
    times = [float(sample.get("t", 0)) for sample in samples]
    page = sorted((float(row[0]), float(row[1])) for row in trace.get("page_frames") or [] if len(row) >= 2)
    # The page's pixels: a Chromium host's row (a chat in CEF has one too: the only one then; a terminal has none).
    rows = [] if terminal else [_page(sample) for sample in samples]
    if chat and not all(row is not None and len(sample.get("page") or []) == 1 for row, sample in zip(rows, samples)):
        rows = []
    extended = bool(rows) and all(len(row) >= 8 for row in rows)
    surfaces = [_terminal(sample) for sample in samples] if terminal else []
    shown_widths: list[float] = []
    if terminal:
        # The terminal's area is its surface layer's width (points); what it is laid out at, the IOSurface it shows
        # (pixels) over the backing scale, read where both are known (1 or 2 on a Mac: the nearest whole ratio).
        ratios = [float(row[4]) / float(row[2]) for row in surfaces if float(row[4]) > 0 and float(row[2]) > 0]
        scale = max(1.0, float(round(ratios[0]))) if ratios else 1.0
        area = [(i, float(row[2])) for i, row in enumerate(surfaces)]
        walls = times
        shown_widths = [float(row[4]) / scale if float(row[4]) > 0 else -1.0 for row in surfaces]
        # The terminal's frames: the samples whose frame counter or shown width changed (the first one included).
        page = [(times[i], shown_widths[i]) for i, row in enumerate(surfaces) if shown_widths[i] >= 0 and (
            i == 0 or float(row[6]) != float(surfaces[i - 1][6]) or shown_widths[i] != shown_widths[i - 1])]
    elif chat:
        # The chat page's width is its pane's content width at a constant offset (borders), read at rest.
        clock = trace.get("clock") or {}
        try:
            # The trace's host clock (`t0_s`, CACurrentMediaTime seconds) on the epoch the page's frames use.
            shift = float(clock["epoch_ms"]) - float(clock["host_s"]) * 1000
            walls = [float(trace["t0_s"]) * 1000 + t + shift for t in times]
        except (KeyError, TypeError, ValueError):
            return {"error": "no clock to line up the chat page's frames with the trace"}
        content = [float(_pane_row(sample, chat_pane)[11]) for sample in samples]
        # The page's width at rest: its last frame up to the first sample (else its first frame).
        before = [w for t, w in page if t <= walls[0]] or [w for _, w in page[:1]]
        offset = (before[-1] - content[0]) if before else 0.0
        area = [(i, v + offset) for i, v in enumerate(content)]
    else:
        # The pane's page area: the host view's superview (newer samplers), else the host itself.
        area = [(i, float(row[7]) if extended else float(row[0])) for i, row in enumerate(rows)]
        walls = [float(row[4]) for row in rows]
    pixels = [_pixels(row) for row in rows] if rows else []
    # The page's shown width per sample (-1: none): a terminal's drawn frame, else the page window or hosted root.
    page_window = list(enumerate(shown_widths)) if terminal else [(i, width) for i, (width, _, _) in enumerate(pixels)]

    divider_rows = [_divider(sample, beside) for sample in samples]
    divider = [(i, float(row[1])) for i, row in enumerate(divider_rows) if row is not None]
    window = [(i, float((sample.get("window") or [0])[0])) for i, sample in enumerate(samples)]
    # What moved the pane, and the area it should have taken from it.
    area_lags: list[int] = []
    if gesture in ("divider", "divider-pause") and divider:
        pane_row = _pane_row(samples[0], beside) if (chat or terminal) else None
        page_right = float(pane_row[1]) >= divider[0][1] if pane_row is not None else True
        if page_right:
            total = area[0][1] + divider[0][1]
            area_lags = lag_frames([(i, total - v) for i, v in divider], area)
        else:
            offset = divider[0][1] - area[0][1]
            area_lags = lag_frames([(i, v - offset) for i, v in divider], area)
        driver_series = divider
    elif gesture == "window-edge":
        total = area[0][1] - window[0][1]
        area_lags = lag_frames([(i, v + total) for i, v in window], area)
        driver_series = window
    else:
        driver_series = area
    edge_lags: list[int] = []
    gap_frames = 0
    if extended:
        # The page's left edge against the host's (both screen x): a page window's offset at rest is kept; the
        # hosted root sits on the host's left edge.
        host_x = [(i, float(row[5])) for i, row in enumerate(rows)]
        windowed = [(i, row) for i, row in enumerate(rows) if pixels[i][2] == "window" and pixels[i][1] >= 0]
        rest = windowed[0][1] if windowed else None
        page_x = []
        for i, row in enumerate(rows):
            width, x, source = pixels[i]
            if source == "window" and x >= 0 and rest is not None:
                page_x.append((i, x - float(rest[6]) + float(rest[5])))
            elif source == "hosted" and x >= 0:
                page_x.append((i, x))
        edge_lags = lag_frames(host_x, page_x)
        gap_frames = sum(1 for (_, a), (_, w) in zip(area, page_window) if w >= 0 and a - w > 0.5)
    elif terminal:
        # The surface layer wider than the frame it shows (the layer's ground shows beside the frame).
        gap_frames = sum(1 for (_, a), (_, w) in zip(area, page_window) if w >= 0 and a - w > tolerance)

    moving = [i for (i, a), (_, b) in zip(driver_series, driver_series[1:]) if abs(b - a) > 0.5]
    first, last = (moving[0], moving[-1] + 1) if moving else (0, 0)
    layout_lags, stale, relayouts, settle_ms = [], 0, 0, None
    if page:
        for index, width in changes([(float(i), v) for i, v in area])[1:]:
            wall = walls[int(index)]
            hit = next((t for t, w in page if t >= wall - refresh / 2 and abs(w - width) <= tolerance), None)
            if hit is not None:
                layout_lags.append(max(0.0, (hit - wall) / refresh))
        # Only the frames the pane moved in, the same frames `moving_frames` counts.
        for index in moving:
            width, wall = area[min(index + 1, len(area) - 1)][1], walls[min(index + 1, len(walls) - 1)]
            shown = [w for t, w in page if t <= wall + refresh / 2]
            if shown and abs(shown[-1] - width) > tolerance:
                stale += 1
        if moving:
            during = [w for t, w in page if walls[first] <= t <= walls[min(last, len(walls) - 1)] + refresh]
            relayouts = len(changes([(0.0, w) for w in during])) - 1 if during else 0
            final = area[-1][1]
            end = walls[min(last, len(walls) - 1)]
            settled = next((t for t, w in page if t >= end - refresh / 2 and abs(w - final) <= tolerance), None)
            settle_ms = round(max(0.0, settled - end), 1) if settled is not None else None
    intervals = [b - a for a, b in zip(times[first:last + 1], times[first + 1:last + 1])]
    dropped = sum(max(0, round(interval / refresh) - 1) for interval in intervals if interval > 1.5 * refresh)
    # The longest the app went without a display frame while the pane moved (a held commit shows here).
    worst_stall_ms = round(max(intervals), 1) if intervals else None
    page_times = [t for t, _ in page if walls[first] <= t <= walls[min(last, len(walls) - 1)] + refresh] if moving else []
    page_dropped = sum(max(0, round((b - a) / refresh) - 1) for a, b in zip(page_times, page_times[1:])
                       if b - a > 1.5 * refresh)

    def spread(values: list[float], scale: float = 1.0) -> dict | None:
        """p50/p95/max of `values` times `scale`; None when nothing was measured (never a zero lag)."""
        if not values:
            return None
        return {"p50": round(p(values, 0.5) * scale, 2), "p95": round(p(values, 0.95) * scale, 2),
                "max": round(max(values) * scale, 2), "measured": len(values)}

    host = [(i, float(row[0])) for i, row in enumerate(rows)]
    return {
        "gesture": gesture,
        "pane": trace.get("pane") or "browser",
        "frames": len(samples),
        "divider_moving_frames": sum(1 for (_, a), (_, b) in zip(divider, divider[1:]) if abs(b - a) > 0.5),
        # The frames what moved the pane (the divider, the window's width, else the area) moved in.
        "moving_frames": len(moving),
        # Samples with no page window and no hosted root (no width): their edge and gap are not measured.
        "unmatched_page_window": sum(1 for _, w in page_window if w < 0),
        # Samples whose page was detached from the window, and those whose pixels were read from the hosted root.
        "detached_frames": sum(1 for row in rows if len(row) >= 12 and float(row[8]) > 0),
        "hosted_matched": sum(1 for _, _, source in pixels if source == "hosted"),
        "area_moving_frames": sum(1 for a, b in zip(area, area[1:]) if abs(b[1] - a[1]) > 0.5),
        "area_lag": spread(area_lags),
        "edge_lag": spread(edge_lags),
        "layout_lag": spread(layout_lags),
        "layout_lag_ms": spread(layout_lags, refresh),
        "stale_frames": stale,
        "relayouts": relayouts,
        "settle_ms": settle_ms,
        "gap_frames": gap_frames,
        "dropped": dropped,
        "worst_stall_ms": worst_stall_ms,
        # The app's display-frame intervals while the pane moved (ms): p50, p95, max.
        "interval_ms": spread(intervals),
        # The page windows' counters through the gesture (`debug.cef`; drive's `cef`).
        "cef": trace.get("cef"),
        # The engine's fork API and the pages' hosting as the gesture began (`_cef_engine`).
        "cef_engine": trace.get("cef_engine"),
        "page_dropped": page_dropped,
        "page_frames": len(page),
        # The host's widths over the drag: one value when it held its size (no Chromium host: None).
        "host_widths": {"min": min(v for _, v in host), "max": max(v for _, v in host),
                        "distinct": len({round(v) for _, v in host})} if host else None,
        # A terminal's grids drawn through the gesture (`debug.terminal_final_grid`, drive's `grids`): per terminal
        # shown, the new grids it drew (each one a reflow of its scrollback); the most of any one. Not a terminal: None.
        "grid_reflows": _grid_reflows(trace.get("grids")) if terminal else None,
    }


def _grid_reflows(grids) -> dict | None:
    """The new grids each terminal of a `debug.terminal_final_grid` stop reply drew after the trace began (its first
    mark is the grid it showed then): `max` over the terminals, and the terminals that drew one; None with no reply."""
    if not isinstance(grids, dict) or not grids:
        return None
    counts = [max(0, len(terminal.get("drawn") or []) - 1) for terminal in grids.values() if isinstance(terminal, dict)]
    return {"max": max(counts, default=0), "terminals": len(counts), "reflowed": sum(1 for n in counts if n)}


def _summary(measured: list[dict]) -> dict:
    settles = [drag["settle_ms"] for drag in measured if drag["settle_ms"] is not None]

    def worst(key: str, field: str | None):
        """The largest `field` of `key` (or `key` itself, field None) over the drags that measured it; None when none did."""
        values = [drag[key] if field is None else drag[key][field] for drag in measured if drag.get(key) is not None]
        return max(values) if values else None

    return {
        "layout_lag_p50": worst("layout_lag", "p50"),
        "layout_lag_p95": worst("layout_lag", "p95"),
        "layout_lag_max": worst("layout_lag", "max"),
        "layout_lag_ms_p95": worst("layout_lag_ms", "p95"),
        "stale_frames": sum(drag["stale_frames"] for drag in measured),
        "moving_frames": sum(drag["moving_frames"] for drag in measured),  # the frames stale_frames reads
        "relayouts": sum(drag["relayouts"] for drag in measured),
        "settle_ms_max": max(settles, default=None),
        "area_lag_max": worst("area_lag", "max"),
        "edge_lag_max": worst("edge_lag", "max"),
        "unmatched_page_window": sum(drag["unmatched_page_window"] for drag in measured),
        "detached_frames": sum(drag["detached_frames"] for drag in measured),
        "hosted_matched": sum(drag["hosted_matched"] for drag in measured),
        "gap_frames": sum(drag["gap_frames"] for drag in measured),
        "dropped": sum(drag["dropped"] for drag in measured),
        "worst_stall_ms": worst("worst_stall_ms", None),
        "page_dropped": sum(drag["page_dropped"] for drag in measured),
        "interval_ms_p95": worst("interval_ms", "p95"),
        "interval_ms_max": worst("interval_ms", "max"),
        "grid_reflows_max": worst("grid_reflows", "max"),  # a terminal's most reflows in one gesture; else None
        "cef": {key: round(sum((drag.get("cef") or {}).get(key, 0.0) for drag in measured), 2) for key in CEF_COUNTERS},
        # The first gesture's engine and hosting (`_cef_engine`): what a `cef.fences` of 0 lacked.
        "cef_engine": next((drag.get("cef_engine") for drag in measured if drag.get("cef_engine")), None),
    }


def judge(data: dict, refresh: float) -> dict:
    drags = [judge_drag(trace, refresh) for trace in data.get("drags") or []]
    # A drag in which nothing moved (no split, a missed divider) measured nothing: never a passing "ok".
    measured = [drag for drag in drags if "error" not in drag and drag.get("moving_frames", 0) > 0]
    if not measured:
        return {"ok": True, "problems": [], "measured": False, "pane": data.get("pane") or "browser",
                "note": "not measured: " + (data.get("error") or next((drag["error"] for drag in drags if "error" in drag), None)
                                            or "no drag that moved its pane")}
    gestures = {}
    for gesture in GESTURES:
        of_gesture = [drag for drag in measured if drag["gesture"] == gesture]
        if of_gesture:
            gestures[gesture] = {"pane": data.get("pane") or "browser", "gesture": gesture, "measured": True,
                                 **_summary(of_gesture)}
    return {"ok": True, "problems": [], "measured": True, "pane": data.get("pane") or "browser",
            "refresh_ms": refresh, "drags": drags, "gestures": gestures, **_summary(measured)}


def markdown_row(verdict: dict) -> str:
    if not verdict.get("measured"):
        return f"| split_resize | report | | | | {verdict.get('note', 'not measured')} (reported only) |"

    def shown(value) -> str:
        return "n/a" if value is None else f"{value:g}"

    what = {"divider": "a dragged divider", "divider-pause": "a divider dragged with pauses", "sidebar": "a toggled sidebar", "window-edge": "a dragged window corner"}
    gesture = verdict.get("gesture")
    page = {"chat": "Agent chat", "terminal": "Terminal with a long transcript"}.get(verdict.get("pane"), "Chromium page")
    return (f"| split_resize | ok | | | | {page} beside {what.get(gesture, 'a resized pane')}: page edge trails the pane "
            f"≤{shown(verdict['edge_lag_max'])} frames ({verdict['unmatched_page_window']} samples with no page window, "
            f"{verdict.get('detached_frames', 0)} detached); "
            f"laid out at its area's width {shown(verdict['layout_lag_p50'])}/{shown(verdict['layout_lag_p95'])}/"
            f"{shown(verdict['layout_lag_max'])} frames after it "
            f"(p50/p95/max; p95 {shown(verdict['layout_lag_ms_p95'])} ms), stale in {verdict['stale_frames']} of "
            f"{verdict['moving_frames']} moving frames, {verdict['relayouts']} relayouts while moving, settled "
            f"≤{shown(verdict['settle_ms_max'])} ms after the last move; {verdict['dropped']} app and {verdict['page_dropped']} "
            f"page frames dropped, worst app frame {shown(verdict.get('worst_stall_ms'))} ms (reported only) |")
