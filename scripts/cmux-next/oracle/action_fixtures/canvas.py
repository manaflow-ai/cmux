"""Canvas-layout gap fixture (p15-oracle-083): the `canvasLayout` registry context for the 13 canvas actions.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, tasks 082-087, and the family interface in
action_fixtures/__init__.py. Stdlib only, Python 3.9+, safe under `python3 -I`. The every-action sweep enters
CONTEXTS["canvasLayout"] (Sweep.ready) and leaves it in its restore; the oracle's app driver runs `setup(rpc)` and
`teardown(rpc)` for a case whose fixture.setup is "canvas" (driver_app.setup_fixture). Both drive the same
CanvasLayout through the Driver seam.

The app publishes `canvasLayout` while the active window's active screen shows a canvas (AppServices+Canvas.swift),
and toggleCanvasLayout seeds the canvas from the frames its panes show (CanvasHandlers.toggle). So enter makes a
layout whose seed gives every canvas action something to do, waits until the panes stop moving, then shows the
canvas:

  newColumn, column.widthOneThird   B: a column one third wide right of the base pane
  newRow                            C: below B in that column (B and C are half height)
  newColumn, column.widthTwoThirds  D: a full-height column two thirds wide right of B, focused

D (the focused pane, the equalize reference) is wider and taller than B, D's left edge is right of B's, B's bottom is
above D's and C's top below B's: each of align left/right/top/bottom, equalize widths/heights and distribute
horizontally/vertically moves at least one pane (CanvasArranger.frames), and tidy packs them. enter checks those six
edge and size differences on the settled frames (debug.pane_chrome) and names the one that does not hold, so a
layout change never turns these rows into quiet "nothing to arrange" refusals. A fresh canvas is at zoom 1, so
canvasZoomReset first zooms in (PREPARE). leave shows the daemon layout again; what enter made is an extra the sweep's
close_new (or the oracle's reset) closes.

Chrome reference (chromium/src): chrome/test/interaction/interactive_browser_test.h composes one shared setup with
the step under test, and ui/views/test/views_test_base.h gives each test a fixture that builds its widget tree in
SetUp and tears it down in TearDown: the canvas here is set up and left the same way around every sample.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

FAMILY = "canvas"
CONTEXT = "canvasLayout"
TOGGLE = "toggleCanvasLayout"
# A canvas action that needs only `canvasLayout`: action.describe says whether the context holds.
PROBE = "canvasTidy"
# The layout the canvas is seeded from (see the module doc): action.run steps on the focused pane.
BUILD: Tuple[Tuple[str, Dict[str, Any]], ...] = (
    ("newColumn", {}),
    ("column.widthOneThird", {}),
    ("newRow", {}),
    ("newColumn", {}),
    ("column.widthTwoThirds", {}),
)
# Seconds the panes get to reach their frames (a column width animates), and the context to follow a toggle.
SETTLE_S = 5.0
CONTEXT_S = 2.0
# Frames are rounded to whole points before they are compared.
EDGE_PT = 1.0

PREPARE = {
    # A fresh canvas is at zoom 1, where Actual Size refuses (canvasZoomLimit): zoom in first.
    "canvasZoomReset": [("canvasZoomIn", {})],
}
CLOSES = (
    "canvasAlignBottom", "canvasAlignLeft", "canvasAlignRight", "canvasAlignTop",
    "canvasDistributeHorizontally", "canvasDistributeVertically", "canvasEqualizeHeights", "canvasEqualizeWidths",
    "canvasOverview", "canvasTidy", "canvasZoomIn", "canvasZoomOut", "canvasZoomReset",
)


class FixtureSetupError(RuntimeError):
    """The canvas context did not hold (oracle setup) or would not go (oracle teardown): the case's Crash."""


def reply_error(reply: Any) -> Optional[str]:
    """The error or refusal of an action.run or control reply, or None."""
    if not isinstance(reply, dict):
        return None if reply is not None else "no reply"
    error = reply.get("error")
    if error:
        if isinstance(error, dict):
            return f"{error.get('code', '')}: {error.get('message', '')}"[:200]
        return str(error)[:200]
    refused = reply.get("refused_action")
    return f"refused: {refused}"[:200] if refused else None


def canvas_shown(driver: Any) -> bool:
    """True while the registry has `canvasLayout`: the probe action is available."""
    reply = driver.rpc("action.describe", {"action": PROBE})
    info = reply.get("action") if isinstance(reply, dict) else None
    return isinstance(info, dict) and info.get("available") is True


def pane_cells(driver: Any) -> List[Tuple[int, int, int, int]]:
    """The pane cells [x, y, w, h] of the session's window (debug.pane_chrome's first, as the sweep reads it),
    rounded to EDGE_PT and sorted, or [] when the reply has none."""
    reply = driver.rpc("debug.pane_chrome", {"after": "sync"})
    windows = reply.get("windows") if isinstance(reply, dict) else None
    window = windows[0] if isinstance(windows, list) and windows and isinstance(windows[0], dict) else {}
    cells = []
    for pane in window.get("panes") or []:
        cell = pane.get("cell") if isinstance(pane, dict) else None
        if isinstance(cell, list) and len(cell) == 4 and all(isinstance(v, (int, float)) for v in cell):
            cells.append(tuple(int(round(v / EDGE_PT)) for v in cell))
    return sorted(cells)


def missing_spread(cells: Sequence[Tuple[int, int, int, int]]) -> List[str]:
    """The pane edges and sizes that are the same for every cell: an arrangement that lines them up or copies them
    would move nothing. [] when each differs between two panes."""
    measures = {
        "left edge": lambda c: c[0], "right edge": lambda c: c[0] + c[2],
        "top edge": lambda c: c[1], "bottom edge": lambda c: c[1] + c[3],
        "width": lambda c: c[2], "height": lambda c: c[3],
    }
    return [name for name, measure in measures.items() if len({measure(c) for c in cells}) < 2]


@dataclass
class CanvasLayout:
    """The `canvasLayout` context (action_fixtures.ContextFixture). `made`: enter built the seed layout and the
    canvas shows it, until leave."""

    made: bool = False

    def enter(self, driver: Any) -> Optional[str]:
        if self.made:
            # Entered again before leave (the key-not-routed retry): keep the layout, show the canvas if it went.
            return None if canvas_shown(driver) else self.show(driver)
        if canvas_shown(driver):
            # A canvas left from before seeds from another layout: start from the daemon layout.
            why = self.toggle(driver, shown=False)
            if why:
                return why
        for action, args in BUILD:
            why = reply_error(driver.run(action, args))
            if why:
                return f"setup {action} failed: {why}"
        why = self.settle(driver)
        if why:
            return why
        why = self.show(driver)
        if why is None:
            self.made = True
        return why

    def leave(self, driver: Any) -> Optional[str]:
        """Shows the daemon layout again when the canvas shows; a note when it would not go."""
        self.made = False
        return self.toggle(driver, shown=False) if canvas_shown(driver) else None

    def show(self, driver: Any) -> Optional[str]:
        return self.toggle(driver, shown=True)

    @staticmethod
    def toggle(driver: Any, shown: bool) -> Optional[str]:
        """Runs toggleCanvasLayout and waits until the context is `shown`: None, or why it did not get there."""
        why = reply_error(driver.run(TOGGLE, {}))
        if why:
            return f"{TOGGLE} failed: {why}"
        if not driver.wait(lambda: canvas_shown(driver) == shown, CONTEXT_S):
            return f"{CONTEXT} is still {'off' if shown else 'on'} after {TOGGLE}"
        return None

    @staticmethod
    def settle(driver: Any) -> Optional[str]:
        """Waits until two reads of the pane cells agree (the column widths stopped animating) and the cells differ in
        every edge and size; None, or which did not hold."""
        reads: List[List[Tuple[int, int, int, int]]] = []

        def settled() -> bool:
            reads.append(pane_cells(driver))
            return len(reads) >= 2 and reads[-1] == reads[-2] and bool(reads[-1]) and not missing_spread(reads[-1])

        if driver.wait(settled, SETTLE_S):
            return None
        last = reads[-1] if reads else []
        if not last:
            return "debug.pane_chrome shows no pane cells"
        missing = missing_spread(last)
        if missing:
            return f"the seed panes share one {', '.join(missing)}: {last[:6]}"
        return f"the pane cells did not settle in {SETTLE_S:.0f} s"


CONTEXTS = {CONTEXT: CanvasLayout}


@dataclass
class RpcDriver:
    """The Driver seam over the oracle's one control call (driver_app.AppCaseRun.rpc): action.run with focus as the
    sweep's SweepDriver.run, and a bounded poll. `clock` and `pause` are injected for tests."""

    call: Callable[..., Any]
    clock: Callable[[], float] = time.monotonic
    pause: Callable[[float], Any] = time.sleep
    step_s: float = 0.05

    def run(self, action: str, args: Optional[dict] = None) -> Any:
        params: Dict[str, Any] = {"action": action, "focus": True}
        if args:
            params["args"] = dict(args)
        return self.call("action.run", params)

    def rpc(self, method: str, params: Optional[dict] = None) -> Any:
        return self.call(method, params or {})

    def wait(self, predicate: Callable[[], Any], seconds: float) -> Any:
        deadline = self.clock() + seconds
        while True:  # bounded poll of the app's socket state in a test harness
            value = predicate()
            if value or self.clock() >= deadline:
                return value or None
            self.pause(self.step_s)  # test harness: the poll interval


def setup(rpc: Callable[..., Any]) -> None:
    """The oracle's fixture.setup "canvas": the case starts on a canvas seeded as the sweep's rows are."""
    why = CanvasLayout().enter(RpcDriver(rpc))
    if why:
        raise FixtureSetupError(f"{CONTEXT}: {why}")


def teardown(rpc: Callable[..., Any]) -> None:
    """The case's canvas goes (the oracle's reset closes the panes setup made)."""
    note = CanvasLayout().leave(RpcDriver(rpc))
    if note:
        raise FixtureSetupError(f"{CONTEXT}: {note}")
