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
//! So the daemon publishes it as one of two quiet states, neither of them a
//! loading state (cx-ag5.6.5):
//! - `running`: a non-interactive command (`sleep 5`, `cargo build`,
//!   `npm run dev`).
//! - `in_use`: the command took the terminal for interaction (the alternate
//!   screen, mouse or focus reporting, or bracketed paste: htop, vim, less,
//!   ssh, a REPL). Once seen it stays for the rest of the command, so a
//!   program that leaves the alternate screen for a moment (vim `:!ls`)
//!   does not flip back. Bracketed paste and focus reporting count only
//!   after the command was seen with them off: a shell can still have them
//!   on when it prints `C` (fish turns bracketed paste off in a later write).
//!
//! Work in progress comes only from a program's own report (OSC 7501
//! `working`, OSC 9;4) or an agent's state, never from this module.
//! `busy` is the older field: it is published only for a `running` command.
//!
//! `prompt` is the shell sitting at its prompt: from a prompt start (`A`)
//! until the next command starts (`C`). A shell without integration never
//! publishes it. `cmux terminal <t> wait --until prompt|idle` waits on these
//! facts (cx-6so.14).
//!
//! `last_output` is when the terminal last printed anything, with or
//! without shell integration. Reads (`terminal.list`, `terminal.show`) and
//! every other publish carry the exact time; output on its own pushes an
//! upsert at most once per `OUTPUT_PUBLISH_INTERVAL_MS`, so a streaming
//! command does not commit a revision per chunk.

use crate::shell_history::ShellMark;
use serde_json::{Value, json};

pub(crate) const CAPABILITY: &str = "terminal-activity-v1";

/// How stale a pushed `last_output` may get while output keeps arriving.
const OUTPUT_PUBLISH_INTERVAL_MS: u64 = 5_000;

/// DEC private mouse tracking modes (X10, normal, button, any-event). The
/// prompt resets them, so a command that has one on turned it on itself.
const MOUSE_MODES: [u16; 4] = [9, 1000, 1002, 1003];
/// Focus reporting and bracketed paste: a program that reads lines from
/// the user turns them on (a REPL, a remote shell over ssh), but the line
/// editor of the shell turns them on too, and turns them off around `C`.
const LINE_MODES: [u16; 2] = [1004, 2004];

/// The terminal modes after one output chunk that tell how a command uses
/// the terminal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct TerminalModes {
    /// The alternate screen or mouse tracking: only a program that owns the
    /// terminal turns these on.
    pub(crate) exclusive: bool,
    /// Bracketed paste or focus reporting.
    pub(crate) line: bool,
}

/// The modes of `term` now.
pub(crate) fn terminal_modes(term: &ghostty_vt::Terminal) -> TerminalModes {
    TerminalModes {
        exclusive: term.active_screen() == ghostty_vt::Screen::Alternate
            || MOUSE_MODES.iter().any(|mode| term.mode(*mode, false)),
        line: LINE_MODES.iter().any(|mode| term.mode(*mode, false)),
    }
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

/// A terminal's shell state as it crosses the terminal-host protocol
/// (`FLAG_SHELL_ACTIVITY`, cx-6so.59), so a daemon that adopts the host after
/// a restart still sees the prompt or the running command. The times are
/// Unix ms, so they mean the same in both processes.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct ShellActivitySnapshot {
    pub(crate) busy_since_ms: Option<u64>,
    pub(crate) interactive: bool,
    pub(crate) line_modes_armed: bool,
    pub(crate) prompt_since_ms: Option<u64>,
}

/// The shell command state of one terminal, from OSC 133 marks and the
/// terminal modes the command set.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ShellActivity {
    busy_since_ms: Option<u64>,
    interactive: bool,
    /// The running command was seen with the line modes off, so turning
    /// them on is the command's own doing.
    line_modes_armed: bool,
    /// When the shell drew the prompt it sits at (`A`, until the next `C`).
    prompt_since_ms: Option<u64>,
    /// When the terminal last printed anything.
    last_output_ms: Option<u64>,
    published: (Option<u64>, bool, Option<u64>),
    published_output_ms: Option<u64>,
}

impl ShellActivity {
    /// Apply one mark seen at `now_ms`. Returns true when the mark starts a
    /// new prompt, which clears any OSC 9;4 progress the finished command
    /// left behind.
    pub(crate) fn observe(&mut self, mark: ShellMark, now_ms: u64) -> bool {
        match mark {
            ShellMark::CommandStart => {
                self.busy_since_ms.get_or_insert(now_ms);
                self.prompt_since_ms = None;
                false
            }
            ShellMark::CommandEnd { .. } => {
                self.end();
                false
            }
            ShellMark::PromptStart => {
                self.end();
                self.prompt_since_ms.get_or_insert(now_ms);
                true
            }
            ShellMark::InputStart => false,
        }
    }

    fn end(&mut self) {
        self.busy_since_ms = None;
        self.interactive = false;
        self.line_modes_armed = false;
    }

    /// Whether the running command still counts as non-interactive (asks
    /// the terminal only then).
    pub(crate) fn wants_interactive_check(&self) -> bool {
        self.busy_since_ms.is_some() && !self.interactive
    }

    /// Applies the terminal modes seen after an output chunk while a
    /// command runs.
    pub(crate) fn note_modes(&mut self, modes: TerminalModes) {
        if self.busy_since_ms.is_none() {
            return;
        }
        if modes.exclusive || (modes.line && self.line_modes_armed) {
            self.interactive = true;
        } else if !modes.line {
            self.line_modes_armed = true;
        }
    }

    /// The running command's state and start time, if one runs.
    pub(crate) fn command(&self) -> Option<(CommandActivity, u64)> {
        let since = self.busy_since_ms?;
        let state =
            if self.interactive { CommandActivity::InUse } else { CommandActivity::Running };
        Some((state, since))
    }

    /// When the shell drew the prompt it sits at, if it does.
    pub(crate) fn prompt_since(&self) -> Option<u64> {
        self.prompt_since_ms
    }

    /// Notes output seen at `now_ms`.
    pub(crate) fn note_output(&mut self, now_ms: u64) {
        self.last_output_ms = Some(now_ms);
    }

    /// When the terminal last printed anything, if it did.
    pub(crate) fn last_output(&self) -> Option<u64> {
        self.last_output_ms
    }

    /// The state a terminal host hands to the daemon that adopts it.
    #[cfg_attr(not(unix), allow(dead_code))]
    pub(crate) fn snapshot(&self) -> ShellActivitySnapshot {
        ShellActivitySnapshot {
            busy_since_ms: self.busy_since_ms,
            interactive: self.interactive,
            line_modes_armed: self.line_modes_armed,
            prompt_since_ms: self.prompt_since_ms,
        }
    }

    /// Takes a terminal host's state. The facts publish as a change on the
    /// next `take_change`.
    pub(crate) fn restore(&mut self, snapshot: ShellActivitySnapshot) {
        self.busy_since_ms = snapshot.busy_since_ms;
        self.interactive = snapshot.busy_since_ms.is_some() && snapshot.interactive;
        self.line_modes_armed = snapshot.busy_since_ms.is_some() && snapshot.line_modes_armed;
        self.prompt_since_ms = snapshot.prompt_since_ms;
    }

    /// Keeps `previous`'s last output (the host's state does not carry it),
    /// so a reconnect neither drops it nor pushes it again.
    pub(crate) fn keep_output_of(&mut self, previous: &ShellActivity) {
        self.last_output_ms = previous.last_output_ms;
        self.published_output_ms = previous.published_output_ms;
    }

    /// Whether the command or prompt fact changed, or the last output moved
    /// a whole interval past the one published, since the last call (marks
    /// it taken).
    pub(crate) fn take_change(&mut self) -> bool {
        let current = (self.busy_since_ms, self.interactive, self.prompt_since_ms);
        let output_moved = match (self.last_output_ms, self.published_output_ms) {
            (Some(last), Some(published)) => {
                last < published || last - published >= OUTPUT_PUBLISH_INTERVAL_MS
            }
            (last, published) => last != published,
        };
        let changed = current != self.published || output_moved;
        if changed {
            self.published = current;
            self.published_output_ms = self.last_output_ms;
        }
        changed
    }
}

/// The `activity` field of a terminal record.
pub(crate) fn activity_json(state: CommandActivity, since_ms: u64) -> Value {
    json!({"state": state.as_str(), "since_ms": since_ms.to_string()})
}

/// The `prompt` field of a terminal record.
pub(crate) fn prompt_json(since_ms: u64) -> Value {
    json!({"since_ms": since_ms.to_string()})
}

/// The `last_output` field of a terminal record.
pub(crate) fn last_output_json(at_ms: u64) -> Value {
    json!({"at_ms": at_ms.to_string()})
}

/// The older `busy` field of a terminal record (a `running` command only).
pub(crate) fn busy_json(since_ms: u64) -> Value {
    json!({"since_ms": since_ms.to_string()})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_first_output_publishes_and_a_burst_publishes_at_most_once_per_interval() {
        let mut activity = ShellActivity::default();
        assert_eq!(activity.last_output(), None);
        assert!(!activity.take_change());

        activity.note_output(10_000);
        assert_eq!(activity.last_output(), Some(10_000));
        assert!(activity.take_change(), "the first output publishes");

        // More output inside the interval is read on demand, not pushed.
        activity.note_output(10_000 + OUTPUT_PUBLISH_INTERVAL_MS - 1);
        assert_eq!(activity.last_output(), Some(10_000 + OUTPUT_PUBLISH_INTERVAL_MS - 1));
        assert!(!activity.take_change());

        activity.note_output(10_000 + OUTPUT_PUBLISH_INTERVAL_MS);
        assert!(activity.take_change(), "output a whole interval later publishes");
        assert!(!activity.take_change());
    }

    #[test]
    fn a_prompt_publish_carries_the_latest_output_and_restarts_the_interval() {
        let mut activity = ShellActivity::default();
        activity.note_output(1_000);
        assert!(activity.take_change());
        activity.note_output(2_000);
        assert!(!activity.take_change());

        // The command ends at a new prompt: that publish names 2_000, so
        // output just after it waits a whole interval from there.
        activity.observe(ShellMark::PromptStart, 2_000);
        assert!(activity.take_change());
        activity.note_output(2_000 + OUTPUT_PUBLISH_INTERVAL_MS - 1);
        assert!(!activity.take_change());
    }

    #[test]
    fn restoring_a_host_state_keeps_the_last_output() {
        let mut previous = ShellActivity::default();
        previous.note_output(7_000);
        assert!(previous.take_change());

        let mut restored = ShellActivity::default();
        restored.restore(previous.snapshot());
        restored.keep_output_of(&previous);
        assert_eq!(restored.last_output(), Some(7_000));
        // The output was already published: no push now, and the next one
        // still waits a whole interval from 7_000.
        assert!(!restored.take_change());
        restored.note_output(7_000 + OUTPUT_PUBLISH_INTERVAL_MS - 1);
        assert!(!restored.take_change());
        restored.note_output(7_000 + OUTPUT_PUBLISH_INTERVAL_MS);
        assert!(restored.take_change());
    }

    #[test]
    fn a_clock_that_steps_back_still_records_the_output() {
        let mut activity = ShellActivity::default();
        activity.note_output(50_000);
        assert!(activity.take_change());
        activity.note_output(40_000);
        assert_eq!(activity.last_output(), Some(40_000));
        assert!(activity.take_change(), "a time before the published one publishes");
    }

    #[test]
    fn last_output_json_names_the_time_as_a_decimal_string() {
        assert_eq!(last_output_json(1_792_000_000_123), json!({"at_ms": "1792000000123"}));
    }
}
