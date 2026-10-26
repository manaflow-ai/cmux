"""Canvas-layout fixture for the every-action sweep and the oracle's action cases (p15-oracle-083).

The 13 actions that require the `canvasLayout` context (PaneActionCatalog, AppServices+Canvas.swift) were gaps:
the sweep's CONTEXT_SETUP only knows tab kinds. This fixture gives the base pane's screen a canvas whose panes
differ in position, width and height, so every arrange command moves something (CanvasArranger refuses a
canvas of one pane, or one where nothing moves, with "nothing to arrange").

Layout before the toggle, from the base pane A (each split focuses its new pane):

    +-------+-------+
    |       |   B   |      splitRight -> B, splitDown -> C, splitRight -> D (focused)
    |   A   +---+---+      A is twice D's width and height; B is twice D's width.
    |       | C | D |
    +-------+---+---+

tests/oracle/gap-closures/canvas.json says, per closed id, what it moves on that canvas.

Interface read by the sweep's per-family loader (action_fixtures/__init__.py, p15-oracle-046):

  FAMILY      the family slug (case-v1 `fixtures.setup`).
  CONTEXTS    {context key: ContextFixture}. `enter(driver)` runs where show() makes the base pane show a tab
              kind, before action.describe: it returns None, or the reason the context did not hold (the row's
              `gap` skip). `leave(driver)` runs in the restore before close_new whenever `enter` ran, also when
              the sample stopped after it; it returns None or a drift note. The panes `enter` made are extras
              close_new closes like PREPARE's.
  PREPARE     {action id: [(action, args)]}, merged into the sweep's PREPARE.
  CLOSES      the gap ids this fixture closes (tests/oracle/gap-closures/canvas.json lists the same ids).

`driver` is the sweep's narrow seam: `run(action, args)` is action.run with focus (the PREPARE path),
`rpc(method, params)` one socket call, `wait(predicate, seconds)` its bounded poll. Every reply is the raw
socket reply dict.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable, Optional, Protocol

FAMILY = "canvas"
CONTEXT = "canvasLayout"
TOGGLE = "toggleCanvasLayout"
# Available only while the active screen shows a canvas (registry context `canvasLayout`): the probe for "shown".
PROBE = "canvasTidy"
SPLITS = ("splitRight", "splitDown", "splitRight")
# The store applies a split after its action.run reply, and the control catalog republishes the registry
# context after the toggle's turn (STORE_APPLY_S in the sweep).
APPLY_S = 5.0

CLOSES = (
    "canvasAlignBottom", "canvasAlignLeft", "canvasAlignRight", "canvasAlignTop",
    "canvasDistributeHorizontally", "canvasDistributeVertically", "canvasEqualizeHeights", "canvasEqualizeWidths",
    "canvasOverview", "canvasTidy", "canvasZoomIn", "canvasZoomOut", "canvasZoomReset",
)

# A fresh canvas is at zoom 1, where Actual Size has nothing to do (RefusalStrings.canvasZoomLimit).
PREPARE = {"canvasZoomReset": [("canvasZoomIn", {})]}


class Driver(Protocol):
    def run(self, action: str, args: Optional[dict] = None) -> Any: ...

    def rpc(self, method: str, params: Optional[dict] = None) -> Any: ...

    def wait(self, predicate: Callable[[], Any], seconds: float) -> Any: ...


@dataclass(frozen=True)
class ContextFixture:
    enter: Callable[[Driver], Optional[str]]
    leave: Callable[[Driver], Optional[str]]


def error_of(reply: Any) -> Optional[str]:
    """The sweep's error_of: the reply's error as `code: message`, or None."""
    if isinstance(reply, dict) and reply.get("error"):
        error = reply["error"]
        if isinstance(error, dict):
            return f"{error.get('code', '')}: {error.get('message', '')}"[:240]
        return str(error)[:240]
    return None


def canvas_shown(driver: Driver) -> bool:
    """True when the active screen shows a canvas: the canvas actions are available (action.describe)."""
    reply = driver.rpc("action.describe", {"action": PROBE})
    info = reply.get("action") if isinstance(reply, dict) else None
    return isinstance(info, dict) and info.get("available") is True


def pane_count(driver: Driver) -> int:
    """Panes of the shown window, behind the read barrier: every split the daemon committed is in the store."""
    reply = driver.rpc("debug.pane_chrome", {"after": "sync"})
    windows = reply.get("windows") if isinstance(reply, dict) else None
    window = windows[0] if isinstance(windows, list) and windows and isinstance(windows[0], dict) else {}
    return sum(1 for pane in window.get("panes") or [] if isinstance(pane, dict) and pane.get("pane") and pane.get("cell"))


def enter(driver: Driver) -> Optional[str]:
    """Splits the focused base pane into the documented layout, then shows its screen as a canvas."""
    if canvas_shown(driver):
        return "a canvas already shows before the setup (an earlier restore left it)"
    before = pane_count(driver)
    for step in SPLITS:
        error = error_of(driver.run(step, {}))
        if error:
            return f"setup {step} failed: {error}"[:200]
    if not driver.wait(lambda: pane_count(driver) >= before + len(SPLITS), APPLY_S):
        return f"the {len(SPLITS)} setup splits did not show"
    error = error_of(driver.run(TOGGLE, {}))
    if error:
        return f"setup {TOGGLE} failed: {error}"[:200]
    if not driver.wait(lambda: canvas_shown(driver), APPLY_S):
        return f"{TOGGLE} showed no canvas"
    return None


def leave(driver: Driver) -> Optional[str]:
    """Shows the screen's daemon layout again. A canvas is client-local (LayoutModel.canvases): turning it off drops
    its frames, camera and overview, so nothing an arrange or zoom changed outlives the sample."""
    if not canvas_shown(driver):
        return None
    error = error_of(driver.run(TOGGLE, {}))
    if error:
        return f"{TOGGLE} off failed: {error}"[:120]
    if not driver.wait(lambda: not canvas_shown(driver), APPLY_S):
        return f"{TOGGLE} left the canvas shown"
    return None


CONTEXTS = {CONTEXT: ContextFixture(enter=enter, leave=leave)}
