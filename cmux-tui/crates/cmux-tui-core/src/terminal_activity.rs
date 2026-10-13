//! Terminal activity facts published on the terminal record behind
//! `terminal-activity-v1` (plans/cmux-next/status-indicators.md section 5).
//! The session host is their only writer: `progress` is the parsed OSC 9;4
//! report (`terminal_metadata::TerminalProgress`), `activity` is a shell
//! command running between OSC 133 `C` and `D`. A new prompt (`A`) ends the
//! command and clears a stale progress report; an exited terminal publishes
//! neither.
//!
//! A running command is never "work in progress" by itself: the shell only
//! knows that a command has not returned, not that the user waits for it.
//! So the daemon publishes it as one of two quiet states, and clients never
//! draw a spinner for either (cx-ag5.6.5):
//! - `running`: a non-interactive command (`sleep 5`, `cargo build`,
//!   `npm run dev`).
//! - `in_use`: the command took the terminal for interaction (the alternate
//!   screen, mouse or focus reporting, or bracketed paste: htop, vim, less,
//!   ssh, a REPL). Once seen it stays for the rest of the command, so a
//!   program that leaves the alternate screen for a moment (vim `:!ls`)
//!   does not flip back.
//!
//! Work in progress comes only from a program's own report (OSC 7501
//! `working`, OSC 9;4) or an agent's state, never from this module.
//! `busy` is the older field: it is published only for a `running` command.

use crate::shell_history::ShellMark;
use serde_json::{Value, json};

pub(crate) const CAPABILITY: &str = "terminal-activity-v1";

/// DEC private modes that only a program reading the terminal
/// interactively turns on: X10/normal/button/any-event mouse tracking,
/// focus reporting and bracketed paste. Shells turn bracketed paste off
/// before they run a command (OSC 133 `C`), so a program that turns it on
/// reads lines from the user (a REPL, a remote shell over ssh).
const INTERACTIVE_MODES: [u16; 6] = [9, 1000, 1002, 1003, 1004, 2004];

/// Whether the terminal is set up for interactive use now.
pub(crate) fn terminal_is_interactive(term: &ghostty_vt::Terminal) -> bool {
    term.active_screen() == ghostty_vt::Screen::Alternate
        || INTERACTIVE_MODES.iter().any(|mode| term.mode(*mode, false))
}

/// How a running shell command uses its terminal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CommandActivity {
    Running,
    InUse,
}

impl CommandActivity {
    fn as_str(self) -> &'static str {
        match self {
            Self::Running => "running",
            Self::InUse => "in_use",
        }
    }
}

/// The shell command state of one terminal, from OSC 133 marks and the
/// terminal modes the command set.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ShellActivity {
    busy_since_ms: Option<u64>,
    interactive: bool,
    published: (Option<u64>, bool),
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
                self.end();
                false
            }
            ShellMark::PromptStart => {
                self.end();
                true
            }
            ShellMark::InputStart => false,
        }
    }

    fn end(&mut self) {
        self.busy_since_ms = None;
        self.interactive = false;
    }

    /// Whether the running command still counts as non-interactive (asks
    /// the terminal only then).
    pub(crate) fn wants_interactive_check(&self) -> bool {
        self.busy_since_ms.is_some() && !self.interactive
    }

    /// The running command set the terminal up for interactive use.
    pub(crate) fn note_interactive(&mut self) {
        if self.busy_since_ms.is_some() {
            self.interactive = true;
        }
    }

    /// The running command's state and start time, if one runs.
    pub(crate) fn command(&self) -> Option<(CommandActivity, u64)> {
        let since = self.busy_since_ms?;
        let state = if self.interactive { CommandActivity::InUse } else { CommandActivity::Running };
        Some((state, since))
    }

    /// Whether the command fact changed since the last call (marks it taken).
    pub(crate) fn take_change(&mut self) -> bool {
        let current = (self.busy_since_ms, self.interactive);
        let changed = current != self.published;
        self.published = current;
        changed
    }
}

/// The `activity` field of a terminal record.
pub(crate) fn activity_json(state: CommandActivity, since_ms: u64) -> Value {
    json!({"state": state.as_str(), "since_ms": since_ms.to_string()})
}

/// The older `busy` field of a terminal record (a `running` command only).
pub(crate) fn busy_json(since_ms: u64) -> Value {
    json!({"since_ms": since_ms.to_string()})
}
