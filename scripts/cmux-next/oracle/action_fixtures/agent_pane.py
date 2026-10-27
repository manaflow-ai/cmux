"""The agentPane gap fixtures (p15-oracle-085): an agent chat on the mock agent, checked for each fact its actions need.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, tasks 082-087 and section 3. Stdlib only, Python 3.9+, loaded by
action_fixtures.load_families (the sweep and the oracle share it). The record of what it closes, and why, is
tests/oracle/gap-closures/agentPane.json; p15-oracle-087 applies it to every-action-gaps.json.

The chat is the session's own: every sweep launch runs the mock agent (CMUX_NEXT_AGENT_PANE_MOCK=1, MockAgentPaneHost),
whose in-page daemon (webviews/src/agent-session/acpmux/mock.ts) serves seeded chats (turns, permission waits), their
repository (mockGit.ts: status, diff, commit, push) and that repository's checkpoints (checkpoints/mock.ts:
git.capabilities, git.checkpoint.*), so no scratch repository is needed. The base pane's chat tab is that chat, and the
sweep's `chat` context (CONTEXT_SETUP agentPaneFocused) shows it with tab.focus, as a user or script would.

Five gaps were the sweep describing an action before the app published the chat's focus; Sweep.described now waits
for the facts the session set up (reading only, the wait recorded as the row's context_wait_ms), so they close with
no fixture of their own. This family owns the one fact the sweep does not set up, checkpointCaptureAvailable: it holds
when the focused chat's page reports checkpoint support (`pane.checkpointAvailability`,
AgentTabs.publishCheckpointAvailability), which the mock page does once its daemon answers git.capabilities.

Chrome reference (chromium/src): chrome/test/interaction/interactive_browser_test.h, WaitForState: an interactive
test waits for the state a step needs instead of sleeping, and names the state that never came.
"""

from __future__ import annotations

from typing import Any, Dict, Optional

FAMILY = "agentPane"

# The only action that requires checkpointCaptureAvailable (AgentActionCatalog): its describe says whether the fact
# holds in the focused window (`missing_context`), with no app state of its own.
CHECKPOINT_PROBE = "agentPane.createCheckpoint"
CHECKPOINT_FACT = "checkpointCaptureAvailable"
FOCUS_FACT = "agentPaneFocused"
# The page asks its daemon for checkpoint support once, on mount and reconnect (checkpoints/controller.tsx).
CHECKPOINT_HOLD_S = 3.0
NOT_FOCUSED = "the chat tab.focus showed never took the keyboard (agentPaneFocused not published)"
NO_CHECKPOINT_SUPPORT = ("the focused chat's page never reported checkpoint support (pane.checkpointAvailability): "
                         "its daemon did not answer git.capabilities with checkpoints")


def missing_context(reply: Any) -> Optional[list]:
    """The context facts an action.describe reply says are missing ([] when none), or None for a reply that is not a
    describe answer (an error, an unreachable app)."""
    action = reply.get("action") if isinstance(reply, dict) else None
    if not isinstance(action, dict):
        return None
    missing = action.get("missing_context") or []
    return list(missing) if action.get("available") is False else []


class CheckpointCapture:
    """checkpointCaptureAvailable: the chat the sweep's show('chat') focused reports checkpoint support. It only
    reads (the fact is published for the chat with the keyboard: FocusEffectApplier.publish ->
    AgentTabs.setCheckpointFocus), makes nothing, so `leave` has nothing to close."""

    def __init__(self) -> None:
        self.last: Optional[list] = None

    def enter(self, driver: Any) -> Optional[str]:
        def holds() -> bool:
            self.last = missing_context(driver.rpc("action.describe", {"action": CHECKPOINT_PROBE}))
            return self.last is not None and CHECKPOINT_FACT not in self.last

        if driver.wait(holds, CHECKPOINT_HOLD_S):
            return None
        if self.last is None:
            return f"{CHECKPOINT_PROBE} has no describe answer"
        return NOT_FOCUSED if FOCUS_FACT in self.last else NO_CHECKPOINT_SUPPORT

    def leave(self, driver: Any) -> Optional[str]:
        self.last = None
        return None


CONTEXTS: Dict[str, Any] = {CHECKPOINT_FACT: CheckpointCapture}
CLOSES = (
    "agentPane.archiveChat",
    "agentPane.createCheckpoint",
    "agentPane.git.commit",
    "agentPane.permission.allowChat",
    "agentPane.permission.refresh",
    "agentPane.previousTurn",
)
