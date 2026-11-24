//! Part of `Hub`; see `hub/mod.rs`. What every surface draws for a background command: its
//! command line, how it stands (running, or how it ended and its exit code), and the end of what
//! it printed, read from the output file Claude Code writes (Leo, 2026-11-24, on a "Background
//! command completed" row that opened to a Shell card with no command and no output: "but i
//! couldnt... do anything?").
//!
//! One shape, built here only, from the process registry's record (`processes.rs`) and, for a
//! shell the registry never heard of, from Claude Code's own task lines (`background_cause.rs`
//! `ShellHint`):
//!
//! - a background turn's `started` record carries it as `cause.command` (`background_turn.rs`),
//!   so the chat row that turn draws opens to it without a read, and keeps it after the output
//!   file is gone;
//! - `_acpmux/process/tail` answers with the same fields (`command`, `state`, `exitCode`,
//!   `outputState`), which the composer hat, Session Info and the Background tasks panel read.
//!
//! `outputState` is `printed` (the tail is in `output`), `empty` (the command printed nothing),
//! or `gone` (no file was named, or it was deleted): clients say "Output no longer available"
//! there, never an empty box.

use serde::Serialize;
use std::io::{Read, Seek, SeekFrom};

/// The most of the end of an output file read for a command's end.
pub(super) const END_TAIL_BYTES: u64 = 8 << 10;

/// The most lines of output a command's end carries.
pub(super) const END_TAIL_LINES: usize = 20;

/// What its output file holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum OutputState {
    /// It printed something: the tail is in `output`.
    Printed,
    /// Its file is there and holds nothing visible.
    Empty,
    /// No file was named, or it is gone.
    Gone,
}

/// A background command as every surface draws it.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CommandEnd {
    /// The command line as the call typed it; empty when nothing named it.
    pub command: String,
    /// What the call said it does (Claude's Bash `description`), when it differs from `command`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// `running`, `completed`, `failed`, `stopped` or `lost`.
    pub state: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i64>,
    pub output_state: OutputState,
    /// The last [`END_TAIL_LINES`] lines it printed (colour codes kept), when `printed`.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub output: String,
    /// `output` starts after the beginning of what it printed.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub cut: bool,
}

impl CommandEnd {
    /// A command's end, its output read from `file` now.
    pub(super) fn read(
        command: &str,
        description: Option<&str>,
        state: &'static str,
        exit_code: Option<i64>,
        file: Option<&str>,
    ) -> Self {
        let (output_state, output, cut) = read_tail(file, state == "running");
        let description =
            description.map(str::trim).filter(|d| !d.is_empty() && *d != command.trim());
        CommandEnd {
            command: command.to_owned(),
            description: description.map(str::to_owned),
            state,
            exit_code,
            output_state,
            output,
            cut,
        }
    }

    pub(super) fn to_value(&self) -> serde_json::Value {
        serde_json::to_value(self).unwrap_or(serde_json::Value::Null)
    }
}

/// The end of `file`: its state, its last [`END_TAIL_LINES`] lines, and whether those start
/// after its beginning. A running command whose file is not named or written yet printed
/// nothing yet (`empty`); an ended one's missing file is `gone`. Anything but a regular file is
/// never opened (a FIFO's open waits for a writer).
pub(super) fn read_tail(file: Option<&str>, running: bool) -> (OutputState, String, bool) {
    let missing = if running { OutputState::Empty } else { OutputState::Gone };
    let Some(file) = file.filter(|f| !f.is_empty()) else { return (missing, String::new(), false) };
    match std::fs::metadata(file) {
        Ok(m) if m.is_file() => {}
        _ => return (missing, String::new(), false),
    }
    let Ok(mut f) = std::fs::File::open(file) else { return (missing, String::new(), false) };
    let len = f.metadata().map(|m| m.len()).unwrap_or(0);
    let start = len.saturating_sub(END_TAIL_BYTES);
    let mut bytes = Vec::new();
    if f.seek(SeekFrom::Start(start)).is_err()
        || f.take(END_TAIL_BYTES).read_to_end(&mut bytes).is_err()
    {
        return (missing, String::new(), false);
    }
    tail_lines(&String::from_utf8_lossy(&bytes), start > 0)
}

/// The last [`END_TAIL_LINES`] lines of `text`, a read that starts at byte `cut_start` > 0 when
/// `cut_start` (its first line may be cut mid-way, so it is dropped).
pub(super) fn tail_lines(text: &str, cut_start: bool) -> (OutputState, String, bool) {
    let text = if cut_start { text.split_once('\n').map_or("", |(_, rest)| rest) } else { text };
    let text = text.replace("\r\n", "\n");
    let text = text.trim_end_matches(['\n', '\r', ' ', '\t']);
    if text.trim().is_empty() {
        return (OutputState::Empty, String::new(), false);
    }
    let lines: Vec<&str> = text.split('\n').collect();
    let keep = lines.len().min(END_TAIL_LINES);
    let cut = cut_start || keep < lines.len();
    (OutputState::Printed, lines[lines.len() - keep..].join("\n"), cut)
}

/// A process's state as a command's end names it.
pub(super) fn state_word(state: super::processes::ProcessState) -> &'static str {
    use super::processes::ProcessState as S;
    match state {
        S::Running => "running",
        S::Exited => "completed",
        S::Failed => "failed",
        S::Killed => "stopped",
        S::Lost => "lost",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str, body: &[u8]) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("acpmux-command-end-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(name);
        std::fs::write(&path, body).unwrap();
        path
    }

    #[test]
    fn a_finished_command_carries_its_line_exit_and_last_lines() {
        let body: String = (1..=30).map(|i| format!("line {i}\n")).collect();
        let path = temp("printed.output", body.as_bytes());
        let end = CommandEnd::read(
            "cargo test",
            Some("Run the tests"),
            "completed",
            Some(0),
            path.to_str(),
        );
        assert_eq!(end.output_state, OutputState::Printed);
        assert!(end.cut);
        assert_eq!(end.output.lines().count(), END_TAIL_LINES);
        assert_eq!(end.output.lines().last(), Some("line 30"));
        let v = end.to_value();
        assert_eq!(v["command"], "cargo test");
        assert_eq!(v["description"], "Run the tests");
        assert_eq!(v["exitCode"], 0);
        assert_eq!(v["outputState"], "printed");
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn an_empty_file_is_empty_and_a_missing_one_is_gone_once_it_ended() {
        let path = temp("empty.output", b"\n\n");
        let end = CommandEnd::read("true", None, "completed", Some(0), path.to_str());
        assert_eq!(
            (end.output_state, end.output.as_str(), end.cut),
            (OutputState::Empty, "", false)
        );
        std::fs::remove_file(&path).ok();
        let end = CommandEnd::read("true", None, "completed", Some(0), path.to_str());
        assert_eq!(end.output_state, OutputState::Gone);
        assert_eq!(end.to_value()["outputState"], "gone");
        // No file named at all: gone once it ended, nothing printed yet while it runs.
        assert_eq!(
            CommandEnd::read("x", None, "failed", Some(1), None).output_state,
            OutputState::Gone
        );
        assert_eq!(
            CommandEnd::read("x", None, "running", None, None).output_state,
            OutputState::Empty
        );
    }

    #[test]
    fn a_description_equal_to_the_command_is_not_repeated() {
        let end = CommandEnd::read("ls", Some("ls"), "completed", None, None);
        assert_eq!(end.description, None);
        assert!(end.to_value().get("description").is_none());
    }

    #[test]
    fn a_long_tail_drops_its_cut_first_line() {
        let (state, out, cut) = tail_lines("half a line\nwhole\n", true);
        assert_eq!((state, out.as_str(), cut), (OutputState::Printed, "whole", true));
    }
}
