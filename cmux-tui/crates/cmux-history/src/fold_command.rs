//! Finished shell commands from one machine's session journal: port of Swift
//! `TerminalCommandFold`, plus the entry mapping of the app's
//! `CommandHistory.entries()`.

use std::collections::VecDeque;

use serde_json::Value;

use crate::entry::{HistoryEntry, HistoryKind};
use crate::hidden::HiddenHistory;
use crate::journal::{EntryContext, Envelope, signed, string_at};

/// The journal kind the fold reads (`terminal-command-journal-v1`).
pub const COMMAND_JOURNAL_KIND: &str = "shell.command.finished";

/// The title of a command entry whose command line was not recorded.
const UNKNOWN_COMMAND: &str = "Command";

/// A finished shell command.
#[derive(Clone, Debug, PartialEq)]
pub struct TerminalCommand {
    pub machine: String,
    pub terminal: String,
    /// The command line (sensitive; absent when not recorded).
    pub command: Option<String>,
    pub cwd: Option<String>,
    pub exit_code: Option<i64>,
    pub started_at_ms: i64,
    pub duration_ms: Option<f64>,
}

impl TerminalCommand {
    /// `<machine>/<terminal>/<start ms>`: the id hides use.
    pub fn qualified_id(&self) -> String {
        format!("{}/{}/{}", self.machine, self.terminal, self.started_at_ms)
    }

    /// The wire entry for this command.
    pub fn entry(&self, context: &EntryContext<'_>) -> HistoryEntry {
        let title = self.command.clone().unwrap_or_else(|| UNKNOWN_COMMAND.to_owned());
        let mut entry = HistoryEntry::new(
            format!("command:{}", self.qualified_id()),
            HistoryKind::Command,
            self.started_at_ms,
            title,
        );
        entry.detail.clone_from(&self.cwd);
        entry.machine = (self.machine != context.local_machine).then(|| self.machine.clone());
        entry.available = context.available;
        entry.cwd.clone_from(&self.cwd);
        entry.command.clone_from(&self.command);
        entry.exit_code = self.exit_code;
        entry
    }
}

/// One machine's finished commands, oldest first, at most `capacity`;
/// re-reading from an older cursor never double counts.
#[derive(Clone, Debug, PartialEq)]
pub struct TerminalCommandFold {
    machine: String,
    capacity: usize,
    cursor: u64,
    commands: VecDeque<TerminalCommand>,
}

impl TerminalCommandFold {
    /// The most commands kept per machine.
    pub const DEFAULT_CAPACITY: usize = 1_000;

    pub fn new(machine: impl Into<String>) -> Self {
        Self::with_capacity(machine, Self::DEFAULT_CAPACITY)
    }

    /// A fold that keeps the newest `capacity` (at least 1) commands.
    pub fn with_capacity(machine: impl Into<String>, capacity: usize) -> Self {
        Self {
            machine: machine.into(),
            capacity: capacity.max(1),
            cursor: 0,
            commands: VecDeque::new(),
        }
    }

    pub fn machine(&self) -> &str {
        &self.machine
    }

    /// The last applied journal sequence.
    pub fn cursor(&self) -> u64 {
        self.cursor
    }

    /// Oldest first.
    pub fn commands(&self) -> impl ExactSizeIterator<Item = &TerminalCommand> {
        self.commands.iter()
    }

    /// Applies records in journal order. Every record after the cursor moves
    /// it; only a `shell.command.finished` record with a start time and a
    /// terminal subject adds a command.
    pub fn apply(&mut self, records: &[Value]) {
        for envelope in records.iter().filter_map(Envelope::parse) {
            if envelope.sequence <= self.cursor {
                continue;
            }
            self.cursor = envelope.sequence;
            if let Some(command) = self.command(&envelope) {
                self.commands.push_back(command);
            }
        }
        while self.commands.len() > self.capacity {
            self.commands.pop_front();
        }
    }

    /// Entries for every command that `hidden` does not hide, oldest first
    /// (the query sorts).
    pub fn entries(&self, context: &EntryContext<'_>, hidden: &HiddenHistory) -> Vec<HistoryEntry> {
        self.commands
            .iter()
            .filter(|command| {
                !hidden.hides(&command.qualified_id(), command.started_at_ms, Some("command"))
            })
            .map(|command| command.entry(context))
            .collect()
    }

    fn command(&self, record: &Envelope<'_>) -> Option<TerminalCommand> {
        if record.kind != COMMAND_JOURNAL_KIND {
            return None;
        }
        let payload = record.payload?;
        let started_at_ms = string_at(Some(payload), &["started_at_ms"])?.parse().ok()?;
        let terminal = record.subject("terminal")?;
        Some(TerminalCommand {
            machine: self.machine.clone(),
            terminal: terminal.to_owned(),
            command: string_at(Some(payload), &["command"]).map(str::to_owned),
            cwd: string_at(Some(payload), &["cwd"]).map(str::to_owned),
            exit_code: payload.get("exit_code").filter(|value| value.is_number()).and_then(signed),
            started_at_ms,
            duration_ms: string_at(Some(payload), &["duration_ms"])
                .and_then(|text| text.parse().ok()),
        })
    }
}

#[cfg(test)]
#[path = "fold_command_tests.rs"]
mod tests;
