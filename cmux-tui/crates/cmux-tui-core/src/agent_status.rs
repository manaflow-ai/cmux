//! What an agent needs from the person: the one status vocabulary every
//! surface shows (TUI sidebar and tab chips, `terminal list --agents`, the
//! raw `list-agents` reply and the docs): `working`, `blocked`, `done`,
//! `idle` and `unknown`.
//!
//! `done` means "the agent finished a turn that nobody has looked at yet".
//! It is derived, never stored: an agent whose roster state is `idle` while
//! its terminal still carries the daemon's unread marker (the agent hook's
//! "finished" notification sets it) is `done`. The marker is cleared only by
//! an explicit acknowledgement (a frontend that shows the tab to the person,
//! or a keystroke in it), so a CLI or socket read never clears it, and the
//! marker survives a daemon restart.
//!
//! The roster state keeps its own meaning (`done` there is a session that
//! ended); [`AgentStatus::from_state`] maps an ended session to no status.

use crate::AgentState;

/// The status the person sees for one agent.
///
/// Ordered by attention: [`AgentStatus::rank`] puts `blocked` first, then
/// `done`, `working`, `idle` and `unknown`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AgentStatus {
    /// The agent waits on the person: an approval, a question, a plan
    /// review or an error.
    Blocked,
    /// The agent finished a turn the person has not seen yet.
    Done,
    /// The agent runs a turn.
    Working,
    /// The agent waits at its prompt and the person saw its last turn.
    Idle,
    /// The agent's state is not known.
    Unknown,
}

impl AgentStatus {
    /// Every status, most urgent first.
    pub const ALL: [AgentStatus; 5] = [
        AgentStatus::Blocked,
        AgentStatus::Done,
        AgentStatus::Working,
        AgentStatus::Idle,
        AgentStatus::Unknown,
    ];

    /// The wire and display word.
    pub fn as_str(self) -> &'static str {
        match self {
            AgentStatus::Blocked => "blocked",
            AgentStatus::Done => "done",
            AgentStatus::Working => "working",
            AgentStatus::Idle => "idle",
            AgentStatus::Unknown => "unknown",
        }
    }

    /// Parse a status word. The older CLI words stay accepted as aliases:
    /// `busy` is `working`, `waiting-for-input` (and `waiting`, `input`,
    /// `attention`) is `blocked`.
    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "blocked" | "waiting-for-input" | "waiting" | "input" | "attention" => {
                AgentStatus::Blocked
            }
            "done" => AgentStatus::Done,
            "working" | "busy" => AgentStatus::Working,
            "idle" => AgentStatus::Idle,
            "unknown" => AgentStatus::Unknown,
            _ => return None,
        })
    }

    /// The status of an agent whose roster state is `state`. `unseen` is
    /// whether its terminal carries an unread marker. `None` for a session
    /// that ended: it is no longer an agent.
    pub fn from_state(state: AgentState, unseen: bool) -> Option<Self> {
        Some(match state {
            AgentState::Working => AgentStatus::Working,
            AgentState::Blocked => AgentStatus::Blocked,
            AgentState::Idle if unseen => AgentStatus::Done,
            AgentState::Idle => AgentStatus::Idle,
            AgentState::Unknown => AgentStatus::Unknown,
            AgentState::Done => return None,
        })
    }

    /// [`Self::from_state`] for a roster state word (`working`, `blocked`,
    /// `idle`, `done`, `unknown`); an unknown word is [`Self::Unknown`].
    pub fn from_state_str(state: &str, unseen: bool) -> Option<Self> {
        let state = match state {
            "working" => AgentState::Working,
            "blocked" => AgentState::Blocked,
            "idle" => AgentState::Idle,
            "done" => AgentState::Done,
            _ => AgentState::Unknown,
        };
        Self::from_state(state, unseen)
    }

    /// Attention rank, higher first: blocked 4, done 3, working 2, idle 1,
    /// unknown 0.
    pub fn rank(self) -> u8 {
        match self {
            AgentStatus::Blocked => 4,
            AgentStatus::Done => 3,
            AgentStatus::Working => 2,
            AgentStatus::Idle => 1,
            AgentStatus::Unknown => 0,
        }
    }

    /// The status a group of agents (a tab, a pane, a workspace) shows: the
    /// most urgent one, or `None` for a group without agents.
    pub fn rollup(statuses: impl IntoIterator<Item = AgentStatus>) -> Option<Self> {
        statuses.into_iter().max_by_key(|status| status.rank())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finished_turn_is_done_until_its_marker_is_read() {
        assert_eq!(AgentStatus::from_state(AgentState::Idle, true), Some(AgentStatus::Done));
        assert_eq!(AgentStatus::from_state(AgentState::Idle, false), Some(AgentStatus::Idle));
        // A working or blocked agent keeps its state whatever the marker says.
        assert_eq!(AgentStatus::from_state(AgentState::Working, true), Some(AgentStatus::Working));
        assert_eq!(AgentStatus::from_state(AgentState::Blocked, true), Some(AgentStatus::Blocked));
        // An ended session is no agent.
        assert_eq!(AgentStatus::from_state(AgentState::Done, true), None);
        assert_eq!(AgentStatus::from_state_str("done", false), None);
        assert_eq!(AgentStatus::from_state_str("odd", false), Some(AgentStatus::Unknown));
    }

    #[test]
    fn rollup_prefers_blocked_then_done_then_working() {
        use AgentStatus::*;
        assert_eq!(AgentStatus::rollup([Idle, Working, Done]), Some(Done));
        assert_eq!(AgentStatus::rollup([Idle, Blocked, Done, Working]), Some(Blocked));
        assert_eq!(AgentStatus::rollup([Unknown, Idle]), Some(Idle));
        assert_eq!(AgentStatus::rollup([Unknown, Working]), Some(Working));
        assert_eq!(AgentStatus::rollup([]), None);
        let mut ranked = AgentStatus::ALL.to_vec();
        ranked.sort_by_key(|status| std::cmp::Reverse(status.rank()));
        assert_eq!(ranked, AgentStatus::ALL);
    }

    #[test]
    fn status_words_round_trip_and_accept_old_cli_words() {
        for status in AgentStatus::ALL {
            assert_eq!(AgentStatus::parse(status.as_str()), Some(status));
        }
        assert_eq!(AgentStatus::parse("busy"), Some(AgentStatus::Working));
        assert_eq!(AgentStatus::parse("waiting-for-input"), Some(AgentStatus::Blocked));
        assert_eq!(AgentStatus::parse("ended"), None);
    }
}
