//! The roster's record of what the screen-detection plugin last saw on each
//! terminal, and the rule that lets the screen end a hook-owned `blocked`
//! row ([`AgentRoster::screen_clears_hook_blocker`]).

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{
    AGENT_HOOK_PRODUCER_ID, AgentRoster, RosterEntry, RosterEvent, agent_state_from_str,
    valid_component,
};
use crate::AgentState;

/// The last state a userland plugin child saw on a terminal's screen, kept
/// whether or not that observation won source arbitration. The record names
/// the child (`generation`): only the child that saw a blocker can say that
/// it went away, and the child's exit drops its records. A hook cannot say that a
/// dialog went away without an answer (Claude Code fires no hook when the
/// person dismisses a permission dialog with Esc), so the roster keeps the
/// screen's own record of the dialog ([`AgentRoster::note_screen_evidence`]).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct ScreenEvidence {
    producer: String,
    /// The plugin child's generation (`normalized.plugin_generation`), when
    /// the supervisor tagged it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    generation: Option<u64>,
    state: String,
}

impl ScreenEvidence {
    /// A restored record names a valid plugin and a live state.
    pub(super) fn valid(&self) -> bool {
        self.producer != AGENT_HOOK_PRODUCER_ID
            && valid_component(&self.producer)
            && self.generation != Some(0)
            && agent_state_from_str(&self.state).is_some_and(|state| state != AgentState::Done)
    }
}

impl RosterEvent<'_> {
    /// The plugin saw the agent's own idle prompt (`native.visible.idle`,
    /// the screen detector's prompt-box rules): positive evidence that no
    /// dialog covers it.
    pub(super) fn plugin_visible_idle(&self) -> bool {
        self.payload.pointer("/native/visible/idle").and_then(Value::as_bool) == Some(true)
    }
}

impl AgentRoster {
    /// Record the observation of `terminal_id` by `producer`'s child
    /// `generation` and return whether it ends a blocker the same child saw:
    /// its previous observation was `blocked` and this one is `working` or
    /// `idle`. A new child's first report never does, whatever an earlier
    /// child of the same plugin saw. Repeated reports of the
    /// same state change nothing, so the plugin's stable-blocker refreshes
    /// keep the record at `blocked`.
    pub(super) fn note_screen_evidence(
        &mut self,
        terminal_id: &str,
        producer: &str,
        generation: Option<u64>,
        state: AgentState,
    ) -> bool {
        // A late report of an older child (one whose exit never reached the
        // journal) must not replace what a newer child saw.
        let older = |stored: &ScreenEvidence| {
            stored.producer == producer
                && matches!((stored.generation, generation), (Some(stored), Some(new)) if new < stored)
        };
        if self.screen_evidence.get(terminal_id).is_some_and(older) {
            return false;
        }
        if state == AgentState::Done {
            self.screen_evidence.remove(terminal_id);
            return false;
        }
        let previous = self.screen_evidence.insert(
            terminal_id.to_string(),
            ScreenEvidence {
                producer: producer.to_string(),
                generation,
                state: state.as_str().to_string(),
            },
        );
        matches!(state, AgentState::Working | AgentState::Idle)
            && previous.is_some_and(|previous| {
                previous.producer == producer
                    && previous.generation == generation
                    && previous.state == AgentState::Blocked.as_str()
            })
    }

    /// Drop the screen records of `producer`'s exited child, as the exit
    /// fence does: a tagged exit `generation` drops that child's and every
    /// older child's records, an untagged exit every untagged record. A later
    /// child starts with no evidence of a blocker.
    pub(super) fn forget_screen_evidence_of(&mut self, producer: &str, generation: Option<u64>) {
        self.screen_evidence.retain(|_, evidence| {
            evidence.producer != producer
                || match (evidence.generation, generation) {
                    (Some(seen), Some(exited)) => seen > exited,
                    (None, None) => false,
                    _ => true,
                }
        });
    }

    /// Whether a plugin observation replaces a hook-owned `blocked` row even
    /// while the hook is fresh. Blocked is the one hook state whose end can
    /// come without a hook: a dialog dismissed with Esc interrupts the turn,
    /// so neither the tool's completion nor the turn's end is reported. The
    /// screen must prove the dialog gone (`cleared_blocker`), observed after
    /// the hook reported the block: the same plugin saw the blocker and now
    /// sees it gone, or it sees the agent's own idle prompt
    /// (`native.visible.idle`), which no dialog shows. A dismissal faster than
    /// the plugin's scan leaves only the second proof. A plain screen `idle`
    /// proves nothing, so a hook question the screen rules do not recognize
    /// stays blocked.
    pub(super) fn screen_clears_hook_blocker(
        existing: &RosterEntry,
        cleared_blocker: bool,
        state: AgentState,
        observed_at_ms: u64,
    ) -> bool {
        cleared_blocker
            && existing.agent_state() == AgentState::Blocked
            && matches!(state, AgentState::Working | AgentState::Idle)
            && observed_at_ms > existing.updated_at_ms
    }
}
