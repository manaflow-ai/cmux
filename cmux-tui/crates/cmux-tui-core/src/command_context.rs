//! `terminal-command-context` (`terminal-command-context-v1`): the newest
//! command a live shell finished, as the text a chat takes. Fix on a failed
//! command and Send Last Output to Chat read it once, when the person asks;
//! nothing here runs per output line.
//!
//! The command line and output come from the OSC 133 semantics Ghostty keeps
//! per row and cell ([`ghostty_vt::Terminal::last_command_output`]), the exit
//! status from the shell's `D` mark ([`crate::terminal_activity`]) and the
//! directory from OSC 7. A shell without integration has no command to read.

use serde_json::Value;
use serde_json::json;

/// Most output rows scanned up from the prompt.
pub(crate) const MAX_OUTPUT_ROWS: u32 = 400;
/// Most output bytes kept, the newest (cut at a character boundary).
pub(crate) const MAX_OUTPUT_BYTES: usize = 12 * 1024;

/// What the chat text asks for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Deserialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum Intent {
    /// The command, its output and status, for the person to write about.
    #[default]
    Context,
    /// The same, asking the agent to find the cause and fix it.
    Fix,
}

/// The newest finished command of one terminal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CommandContext {
    pub(crate) command: Option<String>,
    pub(crate) exit_code: Option<i32>,
    pub(crate) cwd: Option<String>,
    pub(crate) output: String,
    /// Older output was left out (rows past the scan, or bytes past the cap).
    pub(crate) truncated: bool,
}

impl CommandContext {
    /// Keeps the newest [`MAX_OUTPUT_BYTES`] of `output`.
    pub(crate) fn new(
        read: ghostty_vt::CommandOutput,
        exit_code: Option<i32>,
        cwd: Option<String>,
    ) -> Self {
        let (output, cut) = newest_bytes(&read.output, MAX_OUTPUT_BYTES);
        Self {
            command: read.command.and_then(|line| crate::shell_history::clean_command(&line)),
            exit_code,
            cwd,
            output: output.to_owned(),
            truncated: read.truncated || cut,
        }
    }

    /// The Markdown a chat composer takes: the command after its directory,
    /// then its output, in one fenced block, as the terminal showed them.
    pub(crate) fn chat_text(&self, intent: Intent) -> String {
        let mut transcript = String::new();
        if let Some(command) = &self.command {
            match &self.cwd {
                Some(cwd) => transcript.push_str(&format!("{cwd} $ {command}\n")),
                None => transcript.push_str(&format!("$ {command}\n")),
            }
        }
        if self.truncated {
            transcript.push_str("…\n");
        }
        transcript.push_str(&self.output);
        let transcript = transcript.trim_end();
        let fence = "`".repeat(longest_backtick_run(transcript).max(2) + 1);
        let status = match self.exit_code {
            Some(0) => String::new(),
            Some(code) => format!(" (exit code {code})"),
            None => String::new(),
        };
        let lead = match intent {
            Intent::Fix => format!("This command failed{status}. Find the cause and fix it.\n\n"),
            Intent::Context if status.is_empty() => String::new(),
            Intent::Context => format!("This command exited{status}.\n\n"),
        };
        format!("{lead}{fence}console\n{transcript}\n{fence}\n\n")
    }

    /// The `context` object of a `terminal-command-context` reply.
    pub(crate) fn to_json(&self, intent: Intent) -> Value {
        json!({
            "command": self.command,
            "exit_code": self.exit_code,
            "cwd": self.cwd,
            "output": self.output,
            "truncated": self.truncated,
            "text": self.chat_text(intent),
        })
    }
}

/// The last `max` bytes of `text` at a character boundary, and whether any
/// were cut.
fn newest_bytes(text: &str, max: usize) -> (&str, bool) {
    if text.len() <= max {
        return (text, false);
    }
    let mut start = text.len() - max;
    while !text.is_char_boundary(start) {
        start += 1;
    }
    let tail = text.get(start..).unwrap_or(text);
    // Start on a whole line when there is one.
    (tail.split_once('\n').map_or(tail, |(_, rest)| rest), true)
}

fn longest_backtick_run(text: &str) -> usize {
    text.split(|c| c != '`').map(str::len).max().unwrap_or(0)
}

#[cfg(test)]
#[path = "command_context_tests.rs"]
mod tests;
