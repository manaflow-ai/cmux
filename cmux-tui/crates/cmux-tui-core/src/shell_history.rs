//! Terminal command history from OSC 133 prompt marks
//! (`terminal-command-journal-v1`, plans/cmux-next/history.md section 6).
//!
//! Shell integration (Ghostty's bash, zsh, fish and elvish scripts, and
//! most others) brackets each command with OSC 133 marks: `A` prompt start,
//! `B` input start (the prompt ended), `C` command start (Enter), and
//! `D[;exit]` command end. A [`CommandTracker`] per terminal turns those
//! marks into finished commands: the command line is the screen text from
//! the `B` position to the end of that row, read when `C` arrives; the
//! working directory is the terminal's OSC 7 directory at `C`.
//!
//! Recording is opt-in per daemon (`set-terminal-command-history`), off by
//! default: no mark is tracked and nothing is journaled until a client turns
//! it on. A command line can hold secrets, so the journal record is
//! `sensitive` (trusted local clients only) and capped at
//! [`MAX_COMMAND_BYTES`]. No `C` mark is emitted at a password prompt, so a
//! typed password is never read.

// Not wired yet (failing-test commit).
#![allow(dead_code)]

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
        let _ = data;
        None
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
    /// The cursor as (column, absolute row): the scrollback rows above the
    /// active area plus the active row, so a row keeps its number while
    /// output scrolls it into the scrollback.
    fn cursor_absolute(&mut self) -> Option<(u16, u64)>;
    /// The text of absolute row `start.1` from column `start.0` to its end.
    fn row_text(&mut self, start: (u16, u64)) -> Option<String>;
    /// The terminal's working directory (OSC 7).
    fn cwd(&mut self) -> Option<String>;
}

/// Per-terminal state between marks.
#[derive(Debug, Default)]
pub(crate) struct CommandTracker {
    input_start: Option<(u16, u64)>,
    running: Option<RunningCommand>,
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
        let _ = (mark, now_ms, screen);
        None
    }

    fn finish(&mut self, exit_code: Option<i32>, now_ms: u64) -> Option<FinishedCommand> {
        let running = self.running.take()?;
        Some(FinishedCommand {
            command: running.command,
            cwd: running.cwd,
            exit_code,
            started_at_ms: running.started_at_ms,
            duration_ms: now_ms.saturating_sub(running.started_at_ms),
        })
    }
}

/// A command line as stored: trimmed, without control characters, cut to
/// [`MAX_COMMAND_BYTES`] at a character boundary; `None` when empty.
pub(crate) fn clean_command(text: &str) -> Option<String> {
    let _ = text;
    None
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
    fn cursor_absolute(&mut self) -> Option<(u16, u64)> {
        let (column, row) = self.0.cursor_position()?;
        let scrollbar = self.0.scrollbar()?;
        let active_top = scrollbar.total.checked_sub(u64::from(self.0.rows()))?;
        Some((column, active_top + u64::from(row)))
    }

    fn row_text(&mut self, start: (u16, u64)) -> Option<String> {
        let last_column = self.0.cols().checked_sub(1)?;
        if start.0 > last_column {
            return Some(String::new());
        }
        self.0.selection_text_absolute(start, (last_column, start.1))
    }

    fn cwd(&mut self) -> Option<String> {
        self.0.pwd()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct FakeScreen {
        cursor: Option<(u16, u64)>,
        rows: std::collections::HashMap<u64, String>,
        cwd: Option<String>,
    }

    impl CommandScreen for FakeScreen {
        fn cursor_absolute(&mut self) -> Option<(u16, u64)> {
            self.cursor
        }
        fn row_text(&mut self, start: (u16, u64)) -> Option<String> {
            let row = self.rows.get(&start.1)?;
            Some(row.chars().skip(usize::from(start.0)).collect())
        }
        fn cwd(&mut self) -> Option<String> {
            self.cwd.clone()
        }
    }

    #[test]
    fn shell_history_parses_osc_133_marks() {
        assert_eq!(ShellMark::parse(b"A"), Some(ShellMark::PromptStart));
        assert_eq!(ShellMark::parse(b"A;cl=m;aid=7"), Some(ShellMark::PromptStart));
        assert_eq!(ShellMark::parse(b"B"), Some(ShellMark::InputStart));
        assert_eq!(ShellMark::parse(b"C"), Some(ShellMark::CommandStart));
        assert_eq!(ShellMark::parse(b"C;"), Some(ShellMark::CommandStart));
        assert_eq!(ShellMark::parse(b"D"), Some(ShellMark::CommandEnd { exit_code: None }));
        assert_eq!(ShellMark::parse(b"D;0"), Some(ShellMark::CommandEnd { exit_code: Some(0) }));
        assert_eq!(
            ShellMark::parse(b"D;130;aid=12"),
            Some(ShellMark::CommandEnd { exit_code: Some(130) })
        );
        assert_eq!(ShellMark::parse(b"D;x"), Some(ShellMark::CommandEnd { exit_code: None }));
        assert_eq!(ShellMark::parse(b"P;k=i"), None);
        assert_eq!(ShellMark::parse(b""), None);
        assert_eq!(ShellMark::parse(b"AB"), None);
    }

    fn screen(prompt_row: u64, line: &str) -> FakeScreen {
        let mut screen = FakeScreen { cwd: Some("/repo".into()), ..FakeScreen::default() };
        screen.rows.insert(prompt_row, line.into());
        screen
    }

    #[test]
    fn shell_history_tracks_a_command_from_input_start_to_end() {
        let mut screen = screen(40, "~/repo % ls -la   ");
        let mut tracker = CommandTracker::default();
        assert_eq!(tracker.apply(ShellMark::PromptStart, 1_000, &mut screen), None);
        screen.cursor = Some((9, 40));
        assert_eq!(tracker.apply(ShellMark::InputStart, 1_000, &mut screen), None);
        screen.cursor = Some((0, 41));
        assert_eq!(tracker.apply(ShellMark::CommandStart, 2_000, &mut screen), None);
        screen.cwd = Some("/elsewhere".into());
        let finished = tracker
            .apply(ShellMark::CommandEnd { exit_code: Some(0) }, 2_750, &mut screen)
            .expect("finished command");
        assert_eq!(finished.command.as_deref(), Some("ls -la"));
        assert_eq!(finished.cwd.as_deref(), Some("/repo"), "directory at command start");
        assert_eq!(finished.exit_code, Some(0));
        assert_eq!(finished.started_at_ms, 2_000);
        assert_eq!(finished.duration_ms, 750);
    }

    #[test]
    fn shell_history_skips_an_empty_enter_and_a_stray_end() {
        let mut screen = screen(3, "% ");
        let mut tracker = CommandTracker::default();
        screen.cursor = Some((2, 3));
        tracker.apply(ShellMark::InputStart, 1, &mut screen);
        // zsh runs no preexec for an empty line: D without C.
        assert_eq!(
            tracker.apply(ShellMark::CommandEnd { exit_code: Some(0) }, 2, &mut screen),
            None
        );
        assert_eq!(
            tracker.apply(ShellMark::CommandEnd { exit_code: Some(1) }, 3, &mut screen),
            None
        );
    }

    #[test]
    fn shell_history_keeps_a_command_without_a_readable_line() {
        let mut screen = FakeScreen::default();
        let mut tracker = CommandTracker::default();
        // No B mark (shell without input-start marks): the command has no text.
        tracker.apply(ShellMark::CommandStart, 10, &mut screen);
        let finished =
            tracker.apply(ShellMark::CommandEnd { exit_code: Some(2) }, 30, &mut screen).unwrap();
        assert_eq!(finished.command, None);
        assert_eq!(finished.exit_code, Some(2));
        assert_eq!(finished.duration_ms, 20);
    }

    #[test]
    fn shell_history_a_new_prompt_ends_an_unfinished_command() {
        let mut screen = screen(5, "$ sleep 100");
        let mut tracker = CommandTracker::default();
        screen.cursor = Some((2, 5));
        tracker.apply(ShellMark::InputStart, 0, &mut screen);
        tracker.apply(ShellMark::CommandStart, 100, &mut screen);
        let finished = tracker.apply(ShellMark::PromptStart, 400, &mut screen).unwrap();
        assert_eq!(finished.command.as_deref(), Some("sleep 100"));
        assert_eq!(finished.exit_code, None);
        assert_eq!(finished.duration_ms, 300);
        assert_eq!(
            tracker.apply(ShellMark::CommandEnd { exit_code: Some(0) }, 500, &mut screen),
            None
        );
    }

    #[test]
    fn shell_history_journal_record_matches_the_producer_schema() {
        let manifest = built_in_shell_producer_manifest();
        assert_eq!(manifest.events.len(), 1);
        assert_eq!(manifest.events[0].kind, COMMAND_FINISHED_KIND);
        let terminal = TerminalPublicId::parse("term_00000000000000000000000000000001").unwrap();
        let ingress = command_journal_ingress(
            &terminal,
            &FinishedCommand {
                command: Some("make test".into()),
                cwd: Some("/repo".into()),
                exit_code: Some(2),
                started_at_ms: 1_000,
                duration_ms: 50,
            },
        );
        assert_eq!(ingress.payload["started_at_ms"], "1000");
        assert_eq!(ingress.payload["exit_code"], 2);
        assert_eq!(ingress.subjects[0].kind, "terminal");
        assert_eq!(ingress.sensitivity, Some(JournalSensitivity::Sensitive));
        // The journal kernel accepts it, and rejects a payload off the schema.
        let kernel = crate::journal_kernel::JournalKernel::new(None, &[manifest]).unwrap();
        kernel.validate_ingress(&ingress).expect("schema-valid shell command record");
        let mut extra = ingress.clone();
        extra.payload["typed_input"] = serde_json::json!("secret");
        assert!(kernel.validate_ingress(&extra).is_err());
        let mut empty = ingress;
        empty.payload["command"] = serde_json::Value::Null;
        empty.payload["exit_code"] = serde_json::Value::Null;
        kernel.validate_ingress(&empty).expect("null command and exit code are allowed");
    }

    #[test]
    fn shell_history_cleans_and_caps_the_command_line() {
        assert_eq!(clean_command("  echo hi \u{7}\t "), Some("echo hi".into()));
        assert_eq!(clean_command("   "), None);
        let long = "é".repeat(MAX_COMMAND_BYTES);
        let cleaned = clean_command(&long).unwrap();
        assert!(cleaned.len() <= MAX_COMMAND_BYTES);
        assert!(cleaned.chars().all(|character| character == 'é'));
    }
}
