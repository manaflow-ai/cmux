"""Gap fixtures: space, workspace, workspaceGroup and sidebar session states (p15-oracle-086). Spec:
plans/cmux-next/chrome-parity/p15-oracle.md, tasks 082-087.

The gaps were "needs a room argument" (6 space moves), "needs a sidebar-section argument" (Add Group to Section) and
"needs a agent-chat argument" (the Priority view's 3 row actions): the sweep's base fills none of these targets.

A scratch space, SPACE, made once per launch through New Space when the launch does not already hold it, and named
by its name (AppActionContext.room resolves an id or a name). The run that makes it has no `focus`, so the window
stays in the base's space (RoomHandlers.startNewSpace). The restore never deletes a space: Delete Space takes its
space as a target only, and an UNDO step names no target.
The space is empty between samples (close_new closes every workspace the base does not have), so PREPARE gives it 3
workspaces before each sample through New Workspace in Space, then switches the window back to `default`, the room
every sweep session builds in. What each action does with it:
  space.newWindow      the new window shows the space: an extra close_new closes.
  space.newWorkspace   the window shows the new workspace there; UNDO switches back to `default`.
  space.switch         the window shows the space; UNDO switches back.
  workspace.duplicateToSpace  duplicates the base workspace there and the window follows it; UNDO switches back.
  workspace.moveToSpace  moves a new workspace (PREPARE, focused) there, never one of the base's.
  workspaceGroup.moveToSpace  moves a new group holding one new workspace (PREPARE, focused) there.

Add Group to Section adds a new group's workspace (PREPARE, focused) to `sec_top`, the default top section (Home, App
Store). It is a built-in section, which keeps no closed workspace (keeps_closed_by_default in the daemon's
sidebar_doc/model.rs), so close_new's close of that workspace removes the item too. A custom section would keep it,
drawn dimmed, for every later row.

Not here: a nested group. A subgroup may have no personal-group row (WorkspaceGroupHandlers newSubgroup), so the
topology does not list it and close_new cannot take it back. Nor the 3 sidebar.priority ids and the history chat
p15-oracle-270 needs for sidebar.chat.togglePin: they move to p15-oracle-274 (session.json `reasoned` and `follow_up`).
Both need a chat in the app's own acpmux (a Priority row is an AgentLaneStore lane, a history chat an entry of that
daemon's chat index), which the sweep's launch cannot make (ACPMUX_AGENT_LAUNCH=deny; the mock agent's chats stay in
its page), and the Priority view on for each sample, which no family step can set (restore_settings turns it off).

Chrome reference (chromium/src): chrome/browser/ui/tabs/tab_strip_model_unittest.cc and
chrome/browser/ui/browser_commands_unittest.cc build the tab groups and windows a test needs inside the test, through
the same model calls a person's commands make, and close them after it.
"""

from __future__ import annotations

from typing import Any, Mapping, Optional, Tuple

FAMILY = "session"
FOLLOW_UP = "p15-oracle-274"  # closes the ids session.json `reasoned` keeps open

SPACE = "Oracle Space"  # no colon: `room:<name>` parses as one target id
SPACE_TARGET = f"room:{SPACE}"
HOME_SPACE = "room:default"  # ProfileID.defaultProfile: the room every sweep session builds in
SECTION_TARGET = "sidebar-section:sec_top"  # SidebarLayoutDocument.topSectionID, a built-in section
APPEAR_S = 10.0  # the daemon's create-profile reply and the home store's mirror of it come well inside this

# 3 workspaces in the scratch space, then the window back in `default`. PREPARE runs with focus, so each new
# workspace shows (and the window enters the space) until the switch back.
SPACE_STEPS = [
    ("space.newWorkspace", {"space": SPACE_TARGET}),
    ("space.newWorkspace", {"space": SPACE_TARGET}),
    ("space.newWorkspace", {"space": SPACE_TARGET}),
    ("space.switch", {"space": HOME_SPACE}),
]
NEW_WORKSPACE = ("workspace.newAtBottom", {})
NEW_GROUP = ("workspace.newInNewGroup", {})  # a new workspace, focused, in a new group of its own
BACK_HOME = ("space.switch", {"space": HOME_SPACE})


def _error(reply: Any) -> Optional[str]:
    """The error of a socket reply (the sweep's rpc gives {"error": ...} for a failure), else None."""
    if isinstance(reply, dict) and reply.get("error"):
        return str(reply["error"])[:200]
    return None


def _held(driver: Any) -> bool:
    """True when the launch holds the scratch space: renaming it to its own name resolves it by name and changes
    nothing, and refuses when no space has that name."""
    reply = driver.rpc("action.run", {"action": "space.rename", "target": SPACE_TARGET, "args": {"name": SPACE}})
    return _error(reply) is None


class ScratchSpace:
    """The scratch space of one launch, made on the first row that names it."""

    def __init__(self) -> None:
        self.held = False

    def value(self, driver: Any, base: Mapping[str, Any]) -> Tuple[Optional[str], Optional[str]]:
        if not self.held:
            if not _held(driver):
                error = _error(driver.rpc("action.run", {"action": "space.new", "args": {"name": SPACE}}))
                if error:
                    return None, f"space.new did not make the scratch space: {error}"
                if not driver.wait(lambda: _held(driver), APPEAR_S):
                    return None, f"the scratch space {SPACE!r} did not appear within {APPEAR_S:g} s"
            self.held = True
        return SPACE_TARGET, None


class TopSection:
    """The default top section: every session's sidebar has it."""

    def value(self, driver: Any, base: Mapping[str, Any]) -> Tuple[str, None]:
        return SECTION_TARGET, None


SPACE_MOVES = (
    "space.newWindow",
    "space.newWorkspace",
    "space.switch",
    "workspace.duplicateToSpace",
    "workspace.moveToSpace",
    "workspaceGroup.moveToSpace",
)
CLOSES = (*SPACE_MOVES, "workspaceGroup.addToSection")
ARGUMENTS = {
    **{(ident, "space"): ScratchSpace for ident in SPACE_MOVES},
    ("workspaceGroup.addToSection", "section"): TopSection,
}
PREPARE = {
    **{ident: list(SPACE_STEPS) for ident in SPACE_MOVES},
    "workspace.moveToSpace": [*SPACE_STEPS, NEW_WORKSPACE],
    "workspaceGroup.moveToSpace": [*SPACE_STEPS, NEW_GROUP],
    "workspaceGroup.addToSection": [NEW_GROUP],
}
UNDO = {ident: BACK_HOME for ident in ("space.newWorkspace", "space.switch", "workspace.duplicateToSpace")}
