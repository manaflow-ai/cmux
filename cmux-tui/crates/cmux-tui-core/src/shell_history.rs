//! Terminal command history from OSC 133 prompt marks
//! (`terminal-command-journal-v1`, plans/cmux-next/history.md section 6).
//!
//! Shell integration (Ghostty's bash, zsh, fish and elvish scripts, and
//! most others) brackets each command with OSC 133 marks: `A` prompt start,
//! `B` input start (the prompt ended), `C` command start (Enter), and
//! `D[;exit]` command end. A [`CommandTracker`] per terminal turns those
//! marks into finished commands: the command line is the text of the cells
//! Ghostty marks as input (it assigns prompt, input and output semantics
//! byte by byte while it parses OSC 133), read when `C` arrives, so output
//! chunking, typeahead and reflow do not change it; the working directory is
//! the local path of the terminal's OSC 7 directory at `C`.
//!
//! Recording is opt-in per daemon (`set-terminal-command-history`), off by
//! default: nothing is journaled and no screen text is read until a client
//! turns it on. A command line can hold secrets, so the journal record is
//! `sensitive` (trusted local clients only) and capped at
//! [`MAX_COMMAND_BYTES`]. No `C` mark is emitted at a password prompt, so a
//! typed password is never read. A terminal finishes at most
//! [`MAX_COMMANDS_PER_SECOND`] commands a second: a program that prints marks
//! in a loop cannot flood the journal.

use serde_json::json;

use crate::resource::TerminalPublicId;
use crate::{
    JournalClass, JournalEventSchema, JournalIngress, JournalProducerManifest, JournalReplayPolicy,
    JournalSensitivity, JournalSubject,
};

/// The reserved producer of terminal command records.
pub(crate) const SHELL_PRODUCER_ID: &str = "cmux_shell";
pub(crate) const SHELL_PRODUCER_MANIFEST_VERSION: u32 = 1;

/// Longest command line kept, in UTF-8 bytes (cut at a character boundary).
pub(crate) const MAX_COMMAND_BYTES: usize = 1024;
/// Marks waiting for the owner to take them; a reader that never drains
/// keeps only the newest.
pub(crate) const MAX_PENDING_MARKS: usize = 32;
/// Most finished commands one terminal records in one second; the rest drop.
pub(crate) const MAX_COMMANDS_PER_SECOND: usize = 10;
/// Finished commands waiting for the journal worker; beyond it they drop.
pub(crate) const MAX_QUEUED_COMMANDS: usize = 256;
/// Rows scanned up from the cursor for the submitted input block.
pub(crate) const MAX_INPUT_ROWS: u32 = 32;
/// Journal kind of a finished command.
pub(crate) const COMMAND_FINISHED_KIND: &str = "shell.command.finished";

/// One OSC 133 mark.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ShellMark {
    PromptStart,
    InputStart,
    CommandStart,
    CommandEnd { exit_code: Option<i32> },
}

impl ShellMark {
    /// Parses the data after `133;` (for example `A`, `B`, `C;...`,
    /// `D;0`, `D;130;aid=12`). Unknown marks are ignored.
    pub(crate) fn parse(data: &[u8]) -> Option<Self> {
        let mut fields = data.split(|byte| *byte == b';');
        let mark = match fields.next()? {
            b"A" => Self::PromptStart,
            b"B" => Self::InputStart,
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

/// A command that ran and finished.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct FinishedCommand {
    pub(crate) command: Option<String>,
    pub(crate) cwd: Option<String>,
    pub(crate) exit_code: Option<i32>,
    pub(crate) started_at_ms: u64,
    pub(crate) duration_ms: u64,
}

/// What the tracker reads from the terminal when a mark arrives.
pub(crate) trait CommandScreen {
    /// The submitted command line: the newest block of input cells.
    fn input_text(&mut self) -> Option<String>;
    /// The terminal's working directory, as a local path.
    fn cwd(&mut self) -> Option<String>;
}

/// Per-terminal state between marks.
#[derive(Debug, Default)]
pub(crate) struct CommandTracker {
    running: Option<RunningCommand>,
    /// Finish times inside the last second (the rate limit).
    recent: std::collections::VecDeque<u64>,
}

#[derive(Debug)]
struct RunningCommand {
    command: Option<String>,
    cwd: Option<String>,
    started_at_ms: u64,
}

impl CommandTracker {
    /// Applies one mark at `now_ms`; returns a command when one finished.
    pub(crate) fn apply(
        &mut self,
        mark: ShellMark,
        now_ms: u64,
        screen: &mut impl CommandScreen,
    ) -> Option<FinishedCommand> {
        match mark {
            // A prompt without D (shells that skip it on ^C): the command
            // ended, exit status unknown.
            ShellMark::PromptStart => self.finish(None, now_ms),
            ShellMark::InputStart => None,
            ShellMark::CommandStart => {
                let command = screen.input_text().and_then(|text| clean_command(&text));
                self.running =
                    Some(RunningCommand { command, cwd: screen.cwd(), started_at_ms: now_ms });
                None
            }
            ShellMark::CommandEnd { exit_code } => self.finish(exit_code, now_ms),
        }
    }

    /// Forgets a running command (recording turned off).
    pub(crate) fn reset(&mut self) {
        self.running = None;
    }

    fn finish(&mut self, exit_code: Option<i32>, now_ms: u64) -> Option<FinishedCommand> {
        let running = self.running.take()?;
        while self.recent.front().is_some_and(|time| now_ms.saturating_sub(*time) >= 1_000) {
            self.recent.pop_front();
        }
        if self.recent.len() >= MAX_COMMANDS_PER_SECOND {
            return None;
        }
        self.recent.push_back(now_ms);
        Some(FinishedCommand {
            command: running.command,
            cwd: running.cwd,
            exit_code,
            started_at_ms: running.started_at_ms,
            duration_ms: now_ms.saturating_sub(running.started_at_ms),
        })
    }
}

/// The local path of an OSC 7 report (`file://host/path`), or `None` for
/// another host's directory or an unreadable report.
pub(crate) fn command_cwd(report: &str) -> Option<String> {
    crate::platform::terminal_pwd_to_local_path(report)
        .map(|path| path.to_string_lossy().into_owned())
}

/// A command line as stored: trimmed, without control characters, cut to
/// [`MAX_COMMAND_BYTES`] at a character boundary; `None` when empty.
pub(crate) fn clean_command(text: &str) -> Option<String> {
    let visible: String = text.chars().filter(|character| !character.is_control()).collect();
    let trimmed = visible.trim();
    if trimmed.is_empty() {
        return None;
    }
    let mut end = trimmed.len().min(MAX_COMMAND_BYTES);
    while !trimmed.is_char_boundary(end) {
        end -= 1;
    }
    Some(trimmed[..end].trim_end().to_owned())
}

/// The reserved `cmux_shell` producer: one observation kind, sensitive.
pub(crate) fn built_in_shell_producer_manifest() -> JournalProducerManifest {
    let payload_schema = json!({
        "type":"object",
        "required":["started_at_ms","duration_ms"],
        "properties":{
            "command":{"type":["string","null"],"maxLength":MAX_COMMAND_BYTES},
            "cwd":{"type":["string","null"],"maxLength":4096},
            "exit_code":{"type":["integer","null"]},
            "started_at_ms":{"type":"string","pattern":"^[0-9]{1,20}$"},
            "duration_ms":{"type":"string","pattern":"^[0-9]{1,20}$"}
        },
        "additionalProperties":false
    });
    JournalProducerManifest {
        producer_id: SHELL_PRODUCER_ID.into(),
        namespace: "shell".into(),
        manifest_version: SHELL_PRODUCER_MANIFEST_VERSION,
        max_sensitivity: JournalSensitivity::Sensitive,
        permissions: vec!["journal.append.shell".into()],
        events: vec![JournalEventSchema {
            kind: COMMAND_FINISHED_KIND.into(),
            schema_version: 1,
            class: JournalClass::Observation,
            replay: JournalReplayPolicy::Advisory,
            sensitivity: JournalSensitivity::Sensitive,
            payload_schema,
        }],
    }
}

/// The journal record of `command` run in `terminal`. Times are decimal
/// strings, like the journal's own sequence numbers.
pub(crate) fn command_journal_ingress(
    terminal: &TerminalPublicId,
    command: &FinishedCommand,
) -> JournalIngress {
    JournalIngress {
        producer_id: SHELL_PRODUCER_ID.into(),
        manifest_version: SHELL_PRODUCER_MANIFEST_VERSION,
        kind: COMMAND_FINISHED_KIND.into(),
        schema_version: 1,
        occurred_at_ms: None,
        subjects: vec![JournalSubject { kind: "terminal".into(), id: terminal.to_string() }],
        sensitivity: Some(JournalSensitivity::Sensitive),
        payload: json!({
            "command": command.command,
            "cwd": command.cwd,
            "exit_code": command.exit_code,
            "started_at_ms": command.started_at_ms.to_string(),
            "duration_ms": command.duration_ms.to_string(),
        }),
        causation_id: None,
        correlation_id: None,
    }
}

/// [`CommandScreen`] over a live terminal.
pub(crate) struct TerminalCommandScreen<'a>(pub(crate) &'a mut ghostty_vt::Terminal);

impl CommandScreen for TerminalCommandScreen<'_> {
    fn input_text(&mut self) -> Option<String> {
        self.0.latest_input_text(MAX_INPUT_ROWS)
    }

    fn cwd(&mut self) -> Option<String> {
        self.0.pwd().as_deref().and_then(command_cwd)
    }
}
