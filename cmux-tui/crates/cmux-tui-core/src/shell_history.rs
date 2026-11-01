//! Terminal command history from OSC 133 prompt marks
//! (`terminal-command-history-v1`, plans/cmux-next/history.md section 6).
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
//! default: nothing is stored and no screen text is read until a client
//! turns it on. A command line can hold secrets, so finished commands are
//! deletable rows in the workspace registry (`command_history_store`, with a
//! retention), never session journal records, readable by trusted local
//! clients only and capped at [`MAX_COMMAND_BYTES`]. No `C` mark is emitted
//! at a password prompt, so a typed password is never read. A terminal
//! finishes at most [`MAX_COMMANDS_PER_SECOND`] commands a second: a program
//! that prints marks in a loop cannot flood the store.

/// A reserved journal producer id. Development builds before
/// `terminal-command-history-v1` journaled commands under it; it stays
/// reserved so no plugin or client can append records that look like them.
pub(crate) const SHELL_PRODUCER_ID: &str = "cmux_shell";

/// Longest command line kept, in UTF-8 bytes (cut at a character boundary).
pub(crate) const MAX_COMMAND_BYTES: usize = 1024;
/// Longest working directory kept, in UTF-8 bytes; a longer one is dropped.
pub(crate) const MAX_CWD_BYTES: usize = 4096;
/// Marks waiting for the owner to take them; a reader that never drains
/// keeps only the newest.
pub(crate) const MAX_PENDING_MARKS: usize = 32;
/// Most finished commands one terminal records in one second; the rest drop.
pub(crate) const MAX_COMMANDS_PER_SECOND: usize = 10;
/// Finished commands waiting for the history worker; beyond it they drop.
pub(crate) const MAX_QUEUED_COMMANDS: usize = 256;
/// Rows scanned up from the cursor for the submitted input block.
pub(crate) const MAX_INPUT_ROWS: u32 = 32;

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
/// another host's directory, an unreadable report, or a path longer than
/// [`MAX_CWD_BYTES`] (no store keeps an unbounded program-supplied string).
pub(crate) fn command_cwd(report: &str) -> Option<String> {
    crate::platform::terminal_pwd_to_local_path(report)
        .map(|path| path.to_string_lossy().into_owned())
        .filter(|path| path.len() <= MAX_CWD_BYTES)
}

/// A command line as stored: trimmed, without control characters, cut to
/// [`MAX_COMMAND_BYTES`] at a character boundary; `None` when empty.
pub(crate) fn clean_command(text: &str) -> Option<String> {
    // Leading-space history entries are commonly used for commands a person
    // does not want retained. Drop them before trimming so suggestion ranking
    // cannot accidentally reintroduce a deliberately hidden command.
    if text.chars().next().is_some_and(|character| character.is_whitespace()) {
        return None;
    }
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

#[cfg(test)]
mod tests {
    use super::clean_command;

    #[test]
    fn leading_space_commands_are_not_recorded() {
        assert_eq!(clean_command(" pnpm test"), None);
        assert_eq!(clean_command("\tpnpm test"), None);
        assert_eq!(clean_command("pnpm test"), Some("pnpm test".to_owned()));
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
