"""The remaining gap fixtures (p15-oracle-087): the open palette, Home's Channels and a terminal's focused TextBox.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, tasks 082-087, and the family interface in action_fixtures/__init__.py.
Stdlib only, Python 3.9+, safe under `python3 -I`. The record of what this family closes, and of the gaps that stay
with their reasons, is tests/oracle/gap-closures/misc.json; scripts/cmux-next/oracle/apply_gap_closures.py applies
every gap-closures record to every-action-gaps.json.

Each context is a registry fact the sweep's CONTEXT_SETUP does not make, set up the way a person makes it and checked
on the action that needs it (action.describe's `missing_context`), so a fixture that stops working names the fact
instead of turning its rows into quiet refusals:

  paletteOpen          Command Palette (commandPalette) over the session's window: Select Next and Previous Item
                       move its selection. leave closes it with the palette's Escape when the restore's did not.
  homeChannelsEnabled  Enable Channels (home.enableChannels writes home.channelsEnabled): Open Channels shows the
                       sidebar's Channels page. leave disables Channels again if enter enabled it (the dock then
                       selects Home, HomeDock.followChannelsSetting).
  textBoxFocused       a terminal tab of its own (newSurface) whose TextBox composer has the keyboard
                       (focusTextBoxInput): Shift-Tab cycles its submit action. The tab is an extra the sweep's
                       close_new closes, and its TextBox and submit action go with it.

Chrome reference (chromium/src): chrome/test/interaction/interactive_browser_test.h composes one shared setup with the
step under test and waits for the state a step needs (WaitForState) instead of sleeping; ui/views/test/
views_test_base.h builds a test's widgets in SetUp and removes them in TearDown, as enter and leave do here.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Dict, List, Optional

FAMILY = "misc"

PALETTE_FACT = "paletteOpen"
CHANNELS_FACT = "homeChannelsEnabled"
TEXTBOX_FACT = "textBoxFocused"
# The action each fact is read on: describe names the fact in `missing_context` while it does not hold.
PROBES = {PALETTE_FACT: "commandPaletteNext", CHANNELS_FACT: "home.channels", TEXTBOX_FACT: "cycleTextBoxSubmitAction"}
# Seconds a fact gets to be published after the step that makes it (the registry context follows the view a turn
# later, and a settings write goes through the settings file).
CONTEXT_S = 3.0

CLOSES = ("commandPaletteNext", "commandPalettePrevious", "cycleTextBoxSubmitAction", "home.channels")


def reply_error(reply: Any) -> Optional[str]:
    """The error or refusal of an action.run reply, or None."""
    if not isinstance(reply, dict):
        return None if reply is not None else "no reply"
    error = reply.get("error")
    if error:
        if isinstance(error, dict):
            return f"{error.get('code', '')}: {error.get('message', '')}"[:200]
        return str(error)[:200]
    refused = reply.get("refused_action")
    return f"refused: {refused}"[:200] if refused else None


def missing_context(driver: Any, action: str) -> Optional[List[str]]:
    """The context facts action.describe says `action` lacks ([] when it is available or lacks none), or None when
    describe gives no answer."""
    reply = driver.rpc("action.describe", {"action": action})
    info = reply.get("action") if isinstance(reply, dict) else None
    if not isinstance(info, dict):
        return None
    return list(info.get("missing_context") or []) if info.get("available") is False else []


def holds(driver: Any, fact: str) -> bool:
    """True while `fact` is in the registry context: its probe action does not name it missing."""
    missing = missing_context(driver, PROBES[fact])
    return missing is not None and fact not in missing


def await_fact(driver: Any, fact: str, after: str, on: bool = True) -> Optional[str]:
    """Waits until `fact` holds (or, `on` False, until it does not) after the step `after`: None, or why not."""
    if driver.wait(lambda: holds(driver, fact) == on, CONTEXT_S):
        return None
    return f"{fact} is still {'off' if on else 'on'} {CONTEXT_S:.0f} s after {after}"


def run_step(driver: Any, action: str) -> Optional[str]:
    why = reply_error(driver.run(action, {}))
    return f"{action} failed: {why}" if why else None


class PaletteOpen:
    """paletteOpen: the command palette shows over the session's window. Makes no object; the restore's Escape to the
    palette usually closes it first, and leave closes it when that did not."""

    OPEN = "commandPalette"

    def enter(self, driver: Any) -> Optional[str]:
        if holds(driver, PALETTE_FACT):
            return None
        return run_step(driver, self.OPEN) or await_fact(driver, PALETTE_FACT, self.OPEN)

    def leave(self, driver: Any) -> Optional[str]:
        if not holds(driver, PALETTE_FACT):
            return None
        driver.rpc("debug.key", {"key": "escape", "target": "palette"})
        return await_fact(driver, PALETTE_FACT, "Escape to the palette", on=False)


@dataclass
class HomeChannels:
    """homeChannelsEnabled: Channels is on (home.channelsEnabled). `enabled`: enter turned it on, so leave turns it off;
    a session that had Channels on keeps it."""

    enabled: bool = False

    ENABLE = "home.enableChannels"
    DISABLE = "home.disableChannels"

    def enter(self, driver: Any) -> Optional[str]:
        if holds(driver, CHANNELS_FACT):
            return None
        why = run_step(driver, self.ENABLE)
        if why:
            return why
        self.enabled = True  # the write may land after the wait: leave turns it off either way
        return await_fact(driver, CHANNELS_FACT, self.ENABLE)

    def leave(self, driver: Any) -> Optional[str]:
        if not self.enabled:
            return None
        self.enabled = False
        return run_step(driver, self.DISABLE) or await_fact(driver, CHANNELS_FACT, self.DISABLE, on=False)


@dataclass
class TextBoxFocus:
    """textBoxFocused: a terminal tab enter made shows its TextBox with the keyboard. `made`: that tab exists (an extra
    close_new closes), so a second enter before leave (the key-not-routed retry) only gives its box the keyboard
    back."""

    made: bool = False

    NEW_TERMINAL = "newSurface"
    FOCUS_BOX = "focusTextBoxInput"

    def enter(self, driver: Any) -> Optional[str]:
        if self.made:
            # Focus TextBox gives a box that has the keyboard back to its terminal: run it only once the fact is
            # known to be off, not while it is still on its way.
            if await_fact(driver, TEXTBOX_FACT, "the first enter") is None:
                return None
        else:
            why = run_step(driver, self.NEW_TERMINAL)
            if why:
                return why
            self.made = True
        # The tab's box is hidden or without the keyboard here: Focus TextBox shows it with the keyboard.
        return run_step(driver, self.FOCUS_BOX) or await_fact(driver, TEXTBOX_FACT, self.FOCUS_BOX)

    def leave(self, driver: Any) -> Optional[str]:
        self.made = False
        return None


CONTEXTS: Dict[str, Any] = {PALETTE_FACT: PaletteOpen, CHANNELS_FACT: HomeChannels, TEXTBOX_FACT: TextBoxFocus}
