//! The roster's record of what the screen-detection plugin last saw on each
//! terminal, and the rules that let the screen end a hook-owned `blocked`
//! row ([`AgentRoster::screen_clears_hook_blocker`]), a `working` row whose
//! turn ended without a hook, or a row whose agent exited
//! ([`AgentRoster::screen_ends_hook_row`]).

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{
    AGENT_HOOK_PRODUCER_ID, AgentRoster, RosterEntry, RosterEvent, agent_state_from_str,
    valid_component,
};
use crate::{AgentSource, AgentState};

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
    /// When the plugin saw it (`observed_at_ms`), so a late append never
    /// replaces a newer observation and a turn's end is judged only by what
    /// the screen showed during that turn.
    #[serde(default)]
    observed_at_ms: u64,
    /// The process the plugin saw (`source_session`, `pid:<n>`): a turn's
    /// end or an exit counts only for the process whose screen showed it.
    #[serde(default)]
    source_session: Option<String>,
}

/// A hook's turn start on a terminal ([`AgentRoster::screen_ends_hook_row`]).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct HookTurnStart {
    /// The hook's commit time.
    pub(super) at_ms: u64,
    /// The screen's `working` stretch that was already running when the turn
    /// started, by when the plugin first saw it: a prompt typed while the
    /// screen reads working, then the spinner, is one stretch the plugin
    /// reports once.
    #[serde(default)]
    pub(super) screen_working_since_ms: Option<u64>,
}

impl ScreenEvidence {
    /// When the plugin first saw the `working` stretch it reports now.
    pub(super) fn working_since_ms(&self) -> Option<u64> {
        (self.state == AgentState::Working.as_str()).then_some(self.observed_at_ms)
    }

    /// A restored record names a valid plugin and a live state.
    pub(super) fn valid(&self) -> bool {
        self.producer != AGENT_HOOK_PRODUCER_ID
            && valid_component(&self.producer)
            && self.generation != Some(0)
            && agent_state_from_str(&self.state).is_some_and(|state| state != AgentState::Done)
    }
}

/// What one plugin observation proves next to the same plugin's previous
/// one on the terminal ([`AgentRoster::note_screen_evidence`]).
#[derive(Debug, Clone, Copy, Default)]
pub(super) struct ScreenNote {
    /// It saw a blocker and now sees the agent working or idle.
    pub(super) cleared_blocker: bool,
    /// It saw the agent working, at this time, and now sees its own idle
    /// prompt.
    pub(super) ended_turn_seen_working_at: Option<u64>,
    /// It saw the agent and now sees its process gone.
    pub(super) saw_exit: bool,
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
    /// `generation`, seen at `observed_at_ms`, and say what it proves next to
    /// the same child's previous one ([`ScreenNote`]). A new child's first
    /// report proves nothing, whatever an earlier child of the same plugin
    /// saw. Repeated reports of the same state change nothing, so the
    /// plugin's stable-blocker refreshes keep the record at `blocked`. A late
    /// report (an older child's, one whose exit never reached the journal, or
    /// an observation older than the recorded one) is neither recorded nor
    /// proves anything.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn note_screen_evidence(
        &mut self,
        terminal_id: &str,
        producer: &str,
        generation: Option<u64>,
        source_session: Option<&str>,
        state: AgentState,
        visible_idle: bool,
        observed_at_ms: u64,
    ) -> ScreenNote {
        let late = |stored: &ScreenEvidence| {
            stored.producer == producer
                && (matches!((stored.generation, generation), (Some(stored), Some(new)) if new < stored)
                    || observed_at_ms < stored.observed_at_ms)
        };
        if self.screen_evidence.get(terminal_id).is_some_and(late) {
            return ScreenNote::default();
        }
        let previous = if state == AgentState::Done {
            self.screen_evidence.remove(terminal_id)
        } else {
            self.screen_evidence.insert(
                terminal_id.to_string(),
                ScreenEvidence {
                    producer: producer.to_string(),
                    generation,
                    state: state.as_str().to_string(),
                    observed_at_ms,
                    source_session: source_session.map(str::to_owned),
                },
            )
        };
        let Some(previous) = previous
            .filter(|previous| previous.producer == producer && previous.generation == generation)
        else {
            return ScreenNote::default();
        };
        let same_process = previous.source_session.as_deref() == source_session;
        ScreenNote {
            cleared_blocker: matches!(state, AgentState::Working | AgentState::Idle)
                && previous.state == AgentState::Blocked.as_str(),
            ended_turn_seen_working_at: (state == AgentState::Idle
                && same_process
                && visible_idle
                && previous.state == AgentState::Working.as_str())
            .then_some(previous.observed_at_ms),
            saw_exit: state == AgentState::Done && same_process,
        }
    }

    /// Whether a plugin observation ends a hook-owned `working` row even
    /// while the hook is fresh, or removes a hook row. A turn's end and an
    /// agent's exit can come with no hook: Claude Code fires no `Stop` when
    /// the person interrupts the turn with Esc (manaflow-ai/cmux#36529), a
    /// `Stop` that ran can be lost on its way (#21229), and a killed harness
    /// sends no `SessionEnd` (#20874). The screen proves it, observed after
    /// the hook's last report: the same plugin child saw this turn run
    /// (`working` first seen after the hook's latest turn start, or the
    /// `working` stretch already running when it started, [`HookTurnStart`];
    /// with no turn start, since the row became `working`) and now sees the
    /// agent's own idle prompt, or saw this agent's process (since the hook
    /// session took the terminal, `apply` drops older evidence) and now
    /// sees its process gone (`saw_exit`; the detector confirms an exit
    /// over six scans). A plain screen `idle`, or an exit another producer
    /// reports, proves nothing.
    pub(super) fn screen_ends_hook_row(
        existing: &RosterEntry,
        turn_start: Option<&HookTurnStart>,
        note: ScreenNote,
        state: AgentState,
        observed_at_ms: u64,
    ) -> bool {
        let ends = match state {
            AgentState::Idle => {
                existing.agent_state() == AgentState::Working
                    && note.ended_turn_seen_working_at.is_some_and(|seen_at| match turn_start {
                        Some(start) => {
                            seen_at >= start.at_ms || start.screen_working_since_ms == Some(seen_at)
                        }
                        None => seen_at >= existing.since_ms(),
                    })
            }
            AgentState::Done => note.saw_exit,
            _ => false,
        };
        ends && observed_at_ms > existing.updated_at_ms
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

impl AgentRoster {
    /// Whether `event`, a plugin's `state.changed` that is not in the journal
    /// yet, repeats what the roster holds from the same plugin child: the
    /// same producer, generation, state and process, in the screen record
    /// and in the terminal's entry, which that plugin owns. Folding such a
    /// report moves two times and nothing else (the record's `observed_at_ms`
    /// and the entry's `updated_at_ms`): no state, no source, no fence, no
    /// [`ScreenNote`]. The screen detector sends one each 800 ms while a
    /// dialog is visible. On an entry a hook owns, the same report is
    /// evidence the roster orders by its time, so this says `false`.
    pub(crate) fn plugin_report_moves_only_its_time(&self, event: &RosterEvent<'_>) -> bool {
        if event.plugin_event_name() != Some("state.changed") {
            return false;
        }
        let Some(state) = event.normalized("state").and_then(agent_state_from_str) else {
            return false;
        };
        let generation_tag = event.normalized("plugin_generation");
        if state == AgentState::Done
            || self.plugin_observation_is_fenced(event.producer_id, generation_tag)
        {
            return false;
        }
        let Some(terminal_id) = event.terminal_id() else { return false };
        let generation = generation_tag.and_then(|value| value.parse::<u64>().ok());
        let session = event.normalized("source_session");
        let observed_at_ms = event.plugin_observed_at_ms().unwrap_or(event.committed_at_ms);
        let record_holds = self.screen_evidence.get(terminal_id).is_some_and(|stored| {
            stored.producer == event.producer_id
                && stored.generation == generation
                && stored.state == state.as_str()
                && stored.source_session.as_deref() == session
                && observed_at_ms >= stored.observed_at_ms
        });
        record_holds
            && self.entries.get(terminal_id).is_some_and(|entry| {
                entry.agent_source() == AgentSource::Plugin
                    && entry.producer.as_deref() == Some(event.producer_id)
                    && entry
                        .producer_generation
                        .as_deref()
                        .and_then(|value| value.parse::<u64>().ok())
                        == generation
                    && entry.state == state.as_str()
                    && entry.session.as_deref() == session
                    && event.adapter_id().is_none_or(|agent| entry.agent.as_deref() == Some(agent))
                    && observed_at_ms >= entry.updated_at_ms
            })
    }
}
