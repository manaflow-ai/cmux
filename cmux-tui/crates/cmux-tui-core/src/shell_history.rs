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
//! turns it on. Freeing idle terminals (`workspaces.freeing.enabled`, also
//! off by default) turns on [`Recording::LastCommand`]: each tracker keeps
//! only its newest finished command in memory, and a parked tab's kept
//! record stores that one row (`kept_tabs.last_command_json`) for its
//! restored marker line. A command line can hold secrets, so finished commands are
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

/// What a terminal's tracker does with OSC 133 marks.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Recording {
    /// Marks are dropped and no screen text is read.
    Off,
    /// Only the newest finished command is kept, in memory
    /// ([`CommandTracker::last`]), for a parked tab's record.
    LastCommand,
    /// Every finished command goes to the history store, and the newest is
    /// kept as with [`Recording::LastCommand`].
    History,
}

/// Per-terminal state between marks.
#[derive(Debug, Default)]
pub(crate) struct CommandTracker {
    running: Option<RunningCommand>,
    /// The newest finished command that had a command line.
    last: Option<FinishedCommand>,
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

    /// Forgets a running command and the last one (recording turned off).
    pub(crate) fn reset(&mut self) {
        self.running = None;
        self.last = None;
    }

    /// The newest finished command that had a command line.
    pub(crate) fn last(&self) -> Option<&FinishedCommand> {
        self.last.as_ref()
    }

    /// The command a park ends: the one that runs now, as ended at `now_ms`
    /// with no status, else the newest finished one. A freed shell types it
    /// again on show (`workspaces.freeing.runningCommands: relaunch`).
    pub(crate) fn kept(&self, now_ms: u64) -> Option<FinishedCommand> {
        let running = self.running.as_ref().filter(|running| running.command.is_some());
        let Some(running) = running else { return self.last.clone() };
        Some(FinishedCommand {
            command: running.command.clone(),
            cwd: running.cwd.clone(),
            exit_code: None,
            started_at_ms: running.started_at_ms,
            duration_ms: now_ms.saturating_sub(running.started_at_ms),
        })
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
        let finished = FinishedCommand {
            command: running.command,
            cwd: running.cwd,
            exit_code,
            started_at_ms: running.started_at_ms,
            duration_ms: now_ms.saturating_sub(running.started_at_ms),
        };
        if finished.command.is_some() {
            self.last = Some(finished.clone());
        }
        Some(finished)
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

#[cfg(test)]
mod tests {
    use super::{CommandScreen, CommandTracker, ShellMark, clean_command};

    /// A screen whose submitted input is `input`.
    struct Typed(&'static str);

    impl CommandScreen for Typed {
        fn input_text(&mut self) -> Option<String> {
            Some(self.0.to_owned())
        }

        fn cwd(&mut self) -> Option<String> {
            None
        }
    }

    #[test]
    fn the_tracker_keeps_the_last_command_with_a_line_until_reset() {
        let mut tracker = CommandTracker::default();
        tracker.apply(ShellMark::CommandStart, 1_000, &mut Typed("npm test"));
        tracker.apply(ShellMark::CommandEnd { exit_code: Some(1) }, 4_000, &mut Typed(""));
        let last = tracker.last().expect("a finished command is kept");
        assert_eq!(last.command.as_deref(), Some("npm test"));
        assert_eq!((last.exit_code, last.started_at_ms, last.duration_ms), (Some(1), 1_000, 3_000));
        // A command with no line (a leading space hides it) keeps the older one.
        tracker.apply(ShellMark::CommandStart, 5_000, &mut Typed(" secret"));
        tracker.apply(ShellMark::CommandEnd { exit_code: Some(0) }, 6_000, &mut Typed(""));
        assert_eq!(tracker.last().and_then(|last| last.command.as_deref()), Some("npm test"));
        tracker.reset();
        assert!(tracker.last().is_none(), "turning recording off forgets the last command");
    }

    #[test]
    fn leading_space_commands_are_not_recorded() {
        assert_eq!(clean_command(" pnpm test"), None);
        assert_eq!(clean_command("\tpnpm test"), None);
        assert_eq!(clean_command("pnpm test"), Some("pnpm test".to_owned()));
    }
}
