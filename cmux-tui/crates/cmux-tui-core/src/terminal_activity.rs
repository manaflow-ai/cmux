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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::terminal_metadata::TerminalMetadata;

    #[test]
    fn command_marks_drive_busy_and_report_each_change_once() {
        let mut activity = ShellActivity::default();
        assert!(!activity.take_change(), "idle at start is not a change");
        assert!(!activity.observe(ShellMark::InputStart, 5));
        assert!(!activity.observe(ShellMark::CommandStart, 10));
        assert_eq!(activity.busy_since_ms(), Some(10));
        // A repeated C keeps the first start time.
        activity.observe(ShellMark::CommandStart, 20);
        assert_eq!(activity.busy_since_ms(), Some(10));
        assert!(activity.take_change());
        assert!(!activity.take_change());
        activity.observe(ShellMark::CommandEnd { exit_code: Some(1) }, 30);
        assert_eq!(activity.busy_since_ms(), None);
        assert!(activity.take_change());
        activity.observe(ShellMark::CommandStart, 40);
        assert!(activity.observe(ShellMark::PromptStart, 50));
        assert_eq!(activity.busy_since_ms(), None);
    }

    #[test]
    fn terminal_output_tracks_busy_and_a_new_prompt_clears_stale_progress() {
        let mut metadata = TerminalMetadata::default();
        metadata.observe_output(b"\x1b]133;A\x07\x1b]133;B\x07\x1b]133;C\x07");
        assert!(metadata.busy_since_ms().is_some());
        assert!(metadata.take_busy_change());
        metadata.observe_output(b"\x1b]9;4;1;40\x07");
        assert!(metadata.progress().is_some());
        // The command ends without clearing its progress; the next prompt does.
        metadata.observe_output(b"\x1b]133;D;0\x07");
        assert!(metadata.busy_since_ms().is_none());
        assert!(metadata.progress().is_some());
        metadata.observe_output(b"\x1b]133;A\x07");
        assert!(metadata.progress().is_none());
        assert!(metadata.take_busy_change());
        // Shell history still sees every mark.
        assert_eq!(metadata.take_shell_marks().len(), 5);
    }

    #[test]
    fn busy_json_carries_the_start_as_a_decimal_string() {
        assert_eq!(busy_json(1_790_000_000_123), json!({"since_ms": "1790000000123"}));
    }
}
