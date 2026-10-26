"""Canvas-layout fixture for the every-action sweep and the oracle's action cases (p15-oracle-083).

The 13 actions that require the `canvasLayout` context (PaneActionCatalog, AppServices+Canvas.swift) were gaps:
the sweep's CONTEXT_SETUP only knows tab kinds. This fixture gives the base pane's screen a canvas whose panes
differ in position, width and height, so every arrange command moves something (CanvasArranger refuses a
canvas of one pane, or one where nothing moves, with "nothing to arrange").

Layout before the toggle. The splits carve A..D out of the base pane A (each split focuses its new pane); the
canvas also holds the session's other panes on that screen, which the fixture does not touch (the light base's
right-hand sibling S from build_light's splitRight, more on STRESS):

    +-------+-------+-------+
    |       |   B   |       |      splitRight -> B, splitDown -> C, splitRight -> D (focused)
    |   A   +---+---+   S   |      A is twice D's width and height; B is twice D's width.
    |       | C | D |       |
    +-------+---+---+-------+

tests/oracle/gap-closures/canvas.json says, per closed id, why it moves a pane of A..D whatever panes surround
them; canvas_test.py's ArrangeMovesTests checks it with S and with a STRESS-like extra column.

Interface read by the sweep's per-family loader (action_fixtures/__init__.py, p15-oracle-046):

  FAMILY      the family slug (case-v1 `fixtures.setup`).
  CONTEXTS    {context key: factory}. The loader calls the factory once per sweep run and keeps the
              ContextFixture it returns. `enter(driver)` runs where show() makes the base pane show a tab kind,
              before action.describe: it returns None, or the reason the context did not hold (the row's `gap`
              skip). It may run again before `leave` (the key-not-routed retry's second ready()) and then keeps
              what the first call made. `leave(driver)` runs in the restore before close_new whenever `enter`
              ran, also when the sample stopped after it; it returns None or a drift note. The panes `enter`
              made are extras close_new closes like PREPARE's.
  PREPARE     {action id: [(action, args)]}, merged into the sweep's PREPARE.
  CLOSES      the gap ids this fixture closes (tests/oracle/gap-closures/canvas.json lists the same ids).

`driver` is the sweep's narrow seam: `run(action, args)` is action.run with focus (the PREPARE path),
`rpc(method, params)` one socket call, `wait(predicate, seconds)` its bounded poll. Every reply is the raw
socket reply dict.
"""

from __future__ import annotations

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


class ContextFixture(Protocol):
    def enter(self, driver: Driver) -> Optional[str]: ...

    def leave(self, driver: Driver) -> Optional[str]: ...


def error_of(reply: Any) -> Optional[str]:
    """The sweep's error_of: the reply's error as `code: message`, or None."""
    if isinstance(reply, dict) and reply.get("error"):
        error = reply["error"]
        if isinstance(error, dict):
            return f"{error.get('code', '')}: {error.get('message', '')}"[:240]
        return str(error)[:240]
    return None


def canvas_shown(driver: Driver) -> Optional[bool]:
    """Whether the active screen shows a canvas: the canvas actions are available (action.describe). None when the
    probe cannot be read (the describe call failed or answered no action)."""
    reply = driver.rpc("action.describe", {"action": PROBE})
    info = reply.get("action") if isinstance(reply, dict) and not error_of(reply) else None
    if not isinstance(info, dict) or not isinstance(info.get("available"), bool):
        return None
    return info["available"]


def pane_count(driver: Driver) -> int:
    """Panes of the shown window, behind the read barrier: every split the daemon committed is in the store."""
    reply = driver.rpc("debug.pane_chrome", {"after": "sync"})
    windows = reply.get("windows") if isinstance(reply, dict) else None
    window = windows[0] if isinstance(windows, list) and windows and isinstance(windows[0], dict) else {}
    return sum(1 for pane in window.get("panes") or [] if isinstance(pane, dict) and pane.get("pane") and pane.get("cell"))


class CanvasContext:
    """The `canvasLayout` context of one sweep run. It remembers what its `enter` made, so `enter` is idempotent
    until `leave` (the sweep's key-not-routed retry calls `ready()`, and so `enter`, again with no restore between)
    and `leave` turns off a canvas it toggled on even when the probe never reported it."""

    def __init__(self) -> None:
        self.split = False  # the three setup splits showed (their panes are close_new's extras)
        self.toggled = False  # toggleCanvasLayout answered without an error: the screen's canvas is on

    def enter(self, driver: Driver) -> Optional[str]:
        """Splits the focused base pane into the documented layout, then shows its screen as a canvas. A second
        call before `leave` keeps the panes and canvas the first one made."""
        if self.toggled:
            # The toggle handler ran on its action.run turn; only the catalog's registry context can lag.
            if driver.wait(lambda: canvas_shown(driver) is True, APPLY_S):
                return None
            return f"{TOGGLE} showed no canvas"
        shown = canvas_shown(driver)
        if shown is None:
            return f"action.describe {PROBE} answered no availability"
        if shown:
            return "a canvas already shows before the setup (an earlier restore left it)"
        if not self.split:
            before = pane_count(driver)
            for step in SPLITS:
                error = error_of(driver.run(step, {}))
                if error:
                    return f"setup {step} failed: {error}"[:200]
            if not driver.wait(lambda: pane_count(driver) >= before + len(SPLITS), APPLY_S):
                return f"the {len(SPLITS)} setup splits did not show"
            self.split = True
        error = error_of(driver.run(TOGGLE, {}))
        if error:
            return f"setup {TOGGLE} failed: {error}"[:200]
        self.toggled = True
        if not driver.wait(lambda: canvas_shown(driver) is True, APPLY_S):
            return f"{TOGGLE} showed no canvas"
        return None

    def leave(self, driver: Driver) -> Optional[str]:
        """Shows the screen's daemon layout again. A canvas is client-local (LayoutModel.canvases): turning it off
        drops its frames, camera and overview, so nothing an arrange or zoom changed outlives the sample. It toggles
        when `enter` toggled, whatever the probe says, and reports a canvas it cannot confirm off as drift."""
        toggled, self.toggled, self.split = self.toggled, False, False
        if not toggled:
            return None
        error = error_of(driver.run(TOGGLE, {}))
        if error:
            return f"{TOGGLE} off failed: {error}"[:120]
        if driver.wait(lambda: canvas_shown(driver) is False, APPLY_S):
            return None
        if canvas_shown(driver) is None:
            return f"after {TOGGLE} off, action.describe {PROBE} answered no availability: the canvas may still show"
        return f"{TOGGLE} left the canvas shown"


# One context object per sweep run: the loader calls the factory once and keeps what it returns.
CONTEXTS: dict[str, Callable[[], ContextFixture]] = {CONTEXT: CanvasContext}
