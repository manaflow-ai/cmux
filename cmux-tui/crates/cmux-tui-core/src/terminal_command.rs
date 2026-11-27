//! The last command a shell finished, from OSC 133 marks in the output
//! (`terminal-exit-status-v1`).
//!
//! `C` starts a command, `D;<code>` finishes it with that exit status, and a
//! prompt (`A`) that arrives while a command runs finishes it with no status
//! (some shells skip `D` on ^C). A shell without integration sends no marks,
//! so it never publishes a record: a missing `last_command` means
//! "unknown", never success. The record is not part of the terminal-host
//! handoff, so a daemon that adopts a terminal after a restart learns it from
//! the next command; a reconnect to the same host keeps the whole tracker. A
//! changed record is published once as a terminal upsert (`has_change`,
//! `mark_published`).

use serde_json::{Value, json};

/// The last command a shell finished (OSC 133 `C` .. `D`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct LastCommand {
    /// The exit status `D` reported; `None` when it reported none.
    pub(crate) exit_code: Option<i32>,
    /// When its `C` mark arrived, if this terminal saw it.
    pub(crate) started_at_ms: Option<u64>,
    pub(crate) finished_at_ms: u64,
}

/// The OSC 133 marks this tracker reads.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ShellMark {
    PromptStart,
    CommandStart,
    CommandEnd { exit_code: Option<i32> },
}

impl ShellMark {
    /// Parses the data after `133;` (for example `A`, `C;...`, `D;0`,
    /// `D;130;aid=12`). Other marks are ignored.
    pub(crate) fn parse(data: &[u8]) -> Option<Self> {
        let mut fields = data.split(|byte| *byte == b';');
        let mark = match fields.next()? {
            b"A" => Self::PromptStart,
            b"C" => Self::CommandStart,
            b"D" => {
                let exit_code = fields
                    .next()
                    .and_then(|field| std::str::from_utf8(field).ok())
                    .and_then(|field| field.parse::<i32>().ok());
                Self::CommandEnd { exit_code }
            }
            _ => return None,
        };
        Some(mark)
    }
}

/// The command state of one terminal's shell.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub(crate) struct CommandTracker {
    /// When the running command's `C` arrived.
    busy_since_ms: Option<u64>,
    last: Option<LastCommand>,
    /// The record last handed to the public graph.
    published: Option<LastCommand>,
}

impl CommandTracker {
    /// Apply one mark that arrived at `now_ms`.
    pub(crate) fn observe(&mut self, mark: ShellMark, now_ms: u64) {
        match mark {
            ShellMark::CommandStart => {
                self.busy_since_ms.get_or_insert(now_ms);
            }
            ShellMark::CommandEnd { exit_code } => self.finish(exit_code, now_ms),
            ShellMark::PromptStart => {
                if self.busy_since_ms.is_some() {
                    self.finish(None, now_ms);
                }
            }
        }
    }

    fn finish(&mut self, exit_code: Option<i32>, now_ms: u64) {
        self.last = Some(LastCommand {
            exit_code,
            started_at_ms: self.busy_since_ms.take(),
            finished_at_ms: now_ms,
        });
    }

    /// The last command the shell finished, if one did.
    pub(crate) fn last_command(&self) -> Option<LastCommand> {
        self.last
    }

    /// Whether the record changed since the last call, marking it published.
    #[cfg(test)]
    pub(crate) fn take_change(&mut self) -> bool {
        let changed = self.last != self.published;
        self.published = self.last;
        changed
    }

    /// Record `published` as the record the public graph has.
    pub(crate) fn mark_published(&mut self, published: Option<LastCommand>) {
        self.published = published;
    }

    /// Whether `take_change` would report a change now; marks nothing.
    pub(crate) fn has_change(&self) -> bool {
        self.last != self.published
    }
}

/// The `last_command` field of a terminal record: `exit_code` only when the
/// shell reported one; times are decimal strings.
pub(crate) fn last_command_json(last: LastCommand) -> Value {
    let mut value = serde_json::Map::new();
    value.insert("finished_at_ms".into(), json!(last.finished_at_ms.to_string()));
    if let Some(code) = last.exit_code {
        value.insert("exit_code".into(), json!(code));
    }
    if let Some(started) = last.started_at_ms {
        value.insert("started_at_ms".into(), json!(started.to_string()));
    }
    Value::Object(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn read_run_last_command_records_the_exit_code_of_d() {
        let mut tracker = CommandTracker::default();
        assert_eq!(tracker.last_command(), None, "no command, no record");
        tracker.observe(ShellMark::PromptStart, 1_000);
        assert_eq!(tracker.last_command(), None, "a prompt alone finishes nothing");

        tracker.observe(ShellMark::CommandStart, 2_000);
        tracker.observe(ShellMark::CommandEnd { exit_code: Some(7) }, 2_500);
        let last =
            LastCommand { exit_code: Some(7), started_at_ms: Some(2_000), finished_at_ms: 2_500 };
        assert_eq!(tracker.last_command(), Some(last));
        tracker.observe(ShellMark::PromptStart, 2_501);
        assert_eq!(tracker.last_command(), Some(last), "the prompt after D keeps D's status");
        assert_eq!(
            last_command_json(last),
            json!({"exit_code": 7, "started_at_ms": "2000", "finished_at_ms": "2500"})
        );
    }

    #[test]
    fn read_run_last_command_without_d_or_without_a_code_has_no_exit_code() {
        let mut tracker = CommandTracker::default();
        tracker.observe(ShellMark::CommandStart, 10);
        tracker.observe(ShellMark::PromptStart, 20);
        let last = tracker.last_command().unwrap();
        assert_eq!(last.exit_code, None, "a prompt without D: status unknown, not 0");
        assert_eq!(last_command_json(last), json!({"started_at_ms": "10", "finished_at_ms": "20"}));

        tracker.observe(ShellMark::CommandStart, 30);
        tracker.observe(ShellMark::CommandEnd { exit_code: None }, 40);
        assert_eq!(tracker.last_command().unwrap().exit_code, None);
    }

    #[test]
    fn read_run_last_command_parses_marks() {
        assert_eq!(ShellMark::parse(b"A"), Some(ShellMark::PromptStart));
        assert_eq!(ShellMark::parse(b"C;cmdline=ls"), Some(ShellMark::CommandStart));
        assert_eq!(
            ShellMark::parse(b"D;130;aid=12"),
            Some(ShellMark::CommandEnd { exit_code: Some(130) })
        );
        assert_eq!(ShellMark::parse(b"D"), Some(ShellMark::CommandEnd { exit_code: None }));
        assert_eq!(ShellMark::parse(b"D;x"), Some(ShellMark::CommandEnd { exit_code: None }));
        assert_eq!(ShellMark::parse(b"B"), None);
    }

    #[test]
    fn read_run_last_command_publishes_each_new_record_once() {
        let mut tracker = CommandTracker::default();
        assert!(!tracker.take_change(), "no record, nothing to publish");
        tracker.observe(ShellMark::CommandStart, 1);
        assert!(!tracker.has_change(), "a running command changes no record");
        tracker.observe(ShellMark::CommandEnd { exit_code: Some(0) }, 2);
        assert!(tracker.has_change());
        assert!(tracker.take_change(), "a finished command publishes");
        assert!(!tracker.take_change(), "once");
        tracker.observe(ShellMark::PromptStart, 3);
        assert!(!tracker.take_change(), "the prompt after D keeps the record");
        tracker.observe(ShellMark::CommandStart, 4);
        tracker.observe(ShellMark::CommandEnd { exit_code: Some(0) }, 5);
        assert!(tracker.take_change(), "an equal status at a new time is a new record");
    }
}
