//! Terminal activity facts published on the terminal record behind
//! `terminal-activity-v1` (plans/cmux-next/status-indicators.md section 5).
//! The session host is their only writer: `progress` is the parsed OSC 9;4
//! report (`terminal_metadata::TerminalProgress`), `busy` is a shell command
//! running between OSC 133 `C` and `D`. A new prompt (`A`) ends the command
//! and clears a stale progress report; an exited terminal publishes neither.
//! Clients decide how long a command must run before they show it.

use crate::shell_history::ShellMark;
use serde_json::{Value, json};

pub(crate) const CAPABILITY: &str = "terminal-activity-v1";

/// The shell command state of one terminal, from OSC 133 marks.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ShellActivity {
    busy_since_ms: Option<u64>,
    published_busy_since_ms: Option<u64>,
}

impl ShellActivity {
    /// Apply one mark seen at `now_ms`. Returns true when the mark starts a
    /// new prompt, which clears any OSC 9;4 progress the finished command
    /// left behind.
    pub(crate) fn observe(&mut self, mark: ShellMark, now_ms: u64) -> bool {
        match mark {
            ShellMark::CommandStart => {
                self.busy_since_ms.get_or_insert(now_ms);
                false
            }
            ShellMark::CommandEnd { .. } => {
                self.busy_since_ms = None;
                false
            }
            ShellMark::PromptStart => {
                self.busy_since_ms = None;
                true
            }
            ShellMark::InputStart => false,
        }
    }

    /// When the running command started, if one runs.
    pub(crate) fn busy_since_ms(&self) -> Option<u64> {
        self.busy_since_ms
    }

    /// Whether the busy fact changed since the last call (marks it taken).
    pub(crate) fn take_change(&mut self) -> bool {
        let changed = self.busy_since_ms != self.published_busy_since_ms;
        self.published_busy_since_ms = self.busy_since_ms;
        changed
    }
}

/// The `busy` field of a terminal record.
pub(crate) fn busy_json(since_ms: u64) -> Value {
    json!({"since_ms": since_ms.to_string()})
}
