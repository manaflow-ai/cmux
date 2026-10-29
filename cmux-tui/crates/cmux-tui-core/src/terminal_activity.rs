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
//! `shell_idle` is the stricter fact a close may trust without asking: the
//! terminal's own shell sits at that prompt. A prompt mark alone does not say
//! so. A nested shell with its own integration (ssh, `docker exec`) prints
//! its prompt while ssh holds the terminal; a command typed a moment ago has
//! not reached its `C` yet; a shell without integration that replaced the
//! integrated one (`exec bash`) never ends the old prompt. So `shell_idle`
//! holds only while (1) the PTY's foreground process group leader is the
//! terminal's own process (the PTY child, or the shell login(1) started for
//! it) and still runs the spawned program (an `exec` of another program
//! fails it), checked after the last prompt mark (`A` or `B`), with no child
//! process (job control off runs jobs in the shell's own group; a background
//! or stopped job dies with the terminal) and, on Linux, one thread (its
//! children list is per thread), and (2) no input was written to the terminal
//! since the last `A`, and none may wait unread for the line editor: an `A`
//! parsed after a line was typed ahead answers the line before it (the prompt
//! count, `owed_prompts`), and a partial line stays in the editor. Only a
//! prompt the shell draws for a new line answers a typed line: a Return no
//! prompt answers (a `read`, a password, a continuation line, fish 4's Ctrl-C)
//! stays owed, so that terminal asks on every close until it restarts. No
//! kernel fact can pay it (review 6 of cp/daemon-foreground-state: a line
//! editor waiting at its prompt and one asleep in a Return hook after it read
//! a line look the same to the kernel). Anything unknown
//! counts as not idle: no check yet, a check that failed, a terminal whose
//! spawned program is not an interactive shell (`cmux run ssh host`), input
//! the daemon did not see (a terminal adopted from another daemon: from the
//! PTY holder until its first `A` after the replayed ring; for good once a
//! renderer grant was minted for it or its terminal host was adopted, since
//! a grant's holder writes to the host directly), and Windows, where a
//! console has no foreground process group.
//!
//! The check reads the process table (`/proc`, proc_pidinfo), so the output
//! thread's parse never runs it: a mark asks for it, and the terminal's publication
//! on the work lane runs it before it publishes ([`ShellActivity::foreground_check_due`]).
//! When the terminal work pool is full, a local terminal's reader runs that
//! publication itself, after its parse, as it does the registry commit beside it.
//! Every later publication pass while it says idle checks again, first,
//! before any part of the pass publishes the record
//! ([`ShellActivity::foreground_check_epoch`]); a read (`terminal.list`,
//! `terminal.show`) or a full projection gives the fact as checked at the
//! terminal's last publication.
//! Input clears the fact in memory in the input's own turn, before the bytes
//! are written, and queues the publication that tells clients; that record
//! leaves after the bytes. Known limit: a published idle fact is checked again
//! only when a publication runs, so a job the shell starts with no mark, no
//! input and no output (zsh `sched`, a `TRAPALRM` job) is not seen until one.
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
    /// Input was written to the terminal since the last `A`, or may have
    /// been (state taken from a terminal host), or an `A` came while input
    /// may still wait unread for the shell (typed ahead, see `owed_prompts`).
    input_after_prompt: bool,
    /// Lines submitted at the shell's prompt (a Return or Ctrl-C written while
    /// no command runs) whose prompt has not come yet: an `A` answers one of
    /// them. Any still owed at an `A` may be a line typed ahead that waits
    /// unread for the line editor, so that prompt is not idle. A Return no
    /// prompt answers (a `read`, a password, a continuation line, fish's
    /// Ctrl-C) leaves one owed for good: never idle again (fails safe). Only
    /// an `A` the shell drew for a new line pays, never the same prompt drawn
    /// again (a redraw: zsh's `A;redraw=1` in PS1 on `reset-prompt`, a
    /// resize, a transient prompt at accept). A shell that sends `C` or `D`
    /// marks every new prompt with one first (Ghostty's bash and zsh
    /// integrations send `D` before each prompt), so there only an `A` after
    /// a `C` or `D` pays ([`Self::command_since_prompt`]); a shell that sends
    /// only `A` and `B` has no such mark, so there an `A` after a line typed
    /// at the prompt pays ([`Self::line_since_prompt`]).
    owed_prompts: u32,
    /// A line was submitted at the prompt (a Return or Ctrl-C), or a command
    /// started, since the last `A` (an `A`/`B`-only shell's new prompt).
    line_since_prompt: bool,
    /// A `C` or `D` came since the last `A`: the next `A` is a new prompt.
    command_since_prompt: bool,
    /// The shell sent a `C` or `D`: it marks its new prompts with one, so an
    /// `A` without one is a redraw. Set for good once seen. A host's state
    /// does not carry it: a reconnect keeps this daemon's
    /// ([`Self::keep_output_of`]); a terminal created from a host's state has
    /// seen no mark (a fresh host) or reads not idle for good (one adopted
    /// from another daemon: `unseen_input`).
    sends_command_marks: bool,
    /// The shell printed its first prompt: the first `A` answers the spawn,
    /// not a line, so input typed before it stays owed.
    prompted: bool,
    /// Returns written while a command ran (between `C` and `D`): the
    /// program read them, or each waits for the shell as a typed-ahead line.
    /// Its end decides ([`Self::settle_command_input`]).
    typed_while_running: u32,
    /// Bytes were written after the last Return (a partial line, or a key
    /// the daemon cannot read as a Return: an unknown fallback key, a kitty
    /// keyboard protocol Enter): the next prompt's line editor may hold them.
    unsubmitted: bool,
    /// Inside a bracketed paste (`CSI 200~` .. `CSI 201~`): its line breaks
    /// are text for the line editor, not Returns.
    in_paste: bool,
    /// Whether the terminal's own shell held the foreground when checked
    /// after the last mark; `None` until checked.
    shell_foreground: Option<bool>,
    /// The PTY's foreground group leader that check saw (`foreground_check`
    /// in the record, so a client and a test read what the daemon decided
    /// from, not only whether `shell_idle` is there).
    foreground_leader: Option<u32>,
    /// An idle fact went out in a record (any record build reads it, not only
    /// the publication that marks it published), so its end must go out too.
    idle_exposed: bool,
    /// Counts marks and inputs, so a foreground check that raced one of them
    /// is dropped ([`Self::record_foreground_check`]).
    epoch: u64,
    /// Input may reach the PTY without this daemon seeing it: a renderer
    /// grant (its holder writes Input and Paste frames to the terminal host
    /// directly), or a host adopted from another daemon, whose grants and
    /// their connections this daemon cannot know. For the terminal's life.
    unseen_input: bool,
    /// When the terminal last printed anything.
    last_output_ms: Option<u64>,
    published: (Option<u64>, bool, Option<u64>, Option<u64>),
    published_output_ms: Option<u64>,
}

impl ShellActivity {
    /// Apply one mark seen at `now_ms`. Returns true when the mark starts a
    /// new prompt, which clears any OSC 9;4 progress the finished command
    /// left behind.
    pub(crate) fn observe(&mut self, mark: ShellMark, now_ms: u64) -> bool {
        // Every mark asks for a new foreground check: after `A` the shell
        // may still run its prompt hooks as foreground jobs, and `B` (the
        // prompt drawn, the line editor reading) is when it holds the
        // terminal itself.
        self.shell_foreground = None;
        self.foreground_leader = None;
        self.epoch = self.epoch.wrapping_add(1);
        match mark {
            ShellMark::CommandStart => {
                self.busy_since_ms.get_or_insert(now_ms);
                self.prompt_since_ms = None;
                self.line_since_prompt = true;
                self.command_since_prompt = true;
                self.sends_command_marks = true;
                false
            }
            ShellMark::CommandEnd { .. } => {
                self.settle_command_input();
                self.end();
                self.command_since_prompt = true;
                self.sends_command_marks = true;
                false
            }
            ShellMark::PromptStart => {
                self.settle_command_input();
                self.end();
                self.prompt_since_ms.get_or_insert(now_ms);
                let new_prompt = if self.sends_command_marks {
                    self.command_since_prompt
                } else {
                    self.line_since_prompt
                };
                if !self.prompted {
                    self.prompted = true;
                } else if new_prompt {
                    self.owed_prompts = self.owed_prompts.saturating_sub(1);
                }
                self.line_since_prompt = false;
                self.command_since_prompt = false;
                // Input written before this `A` was parsed but after the
                // shell printed it may wait unread for the line editor: a
                // line still owed (typed ahead) or a partial one.
                self.input_after_prompt = self.owed_prompts > 0 || self.unsubmitted;
                true
            }
            // A secondary prompt (`A;k=s`, `A;k=c`): a continuation prompt
            // (PS2: an open quote, a heredoc, a `for` loop over lines) or a later
            // line of a multi-line PS1 (kitty marks those the same way). No mark
            // tells them apart for sure (a `B`, the only bound of a primary
            // prompt, can come from a nested shell, and an integration may send
            // none), so every one keeps the shell not idle until a primary `A`,
            // and none pays a line: a count paid by a PS1 line goes low and reads
            // a typed-ahead line idle. A Return a continuation prompt answers
            // stays owed (the accepted cost: the close asks), and a multi-line
            // PS1 with secondary marks never reads idle.
            ShellMark::SecondaryPromptStart => {
                self.input_after_prompt = true;
                false
            }
            // A right prompt (zsh's RPROMPT) is drawn with the primary prompt,
            // after its `B`: it answers no line.
            ShellMark::RightPromptStart => false,
            ShellMark::InputStart => false,
        }
    }

    /// A command ended (`D`, or an `A` with no `D`): a Return typed while it
    /// ran may be a line typed ahead for the shell, and a partial line may
    /// wait for its line editor. The daemon cannot tell keys the command read
    /// (an editor, ssh, a REPL) from keys typed after it quit, so both stay
    /// owed (`owed_prompts`; the close asks).
    fn settle_command_input(&mut self) {
        if self.busy_since_ms.is_none() {
            return;
        }
        self.owed_prompts = self.owed_prompts.saturating_add(self.typed_while_running);
        self.typed_while_running = 0;
    }

    /// Reads input `bytes` for the lines they submit ([`Self::owed_prompts`]).
    /// Empty: a key the daemon cannot read (counts as a partial line).
    fn note_input_lines(&mut self, bytes: &[u8]) {
        const PASTE_START: &[u8] = b"\x1b[200~";
        const PASTE_END: &[u8] = b"\x1b[201~";
        if bytes.is_empty() {
            self.unsubmitted = true;
            return;
        }
        let running = self.busy_since_ms.is_some();
        // A running command that took the terminal for interaction (an editor,
        // ssh) reads raw: a signal key is a byte it reads, and the kernel
        // flushes nothing typed ahead.
        let flushes = running && !self.interactive;
        let mut at = 0;
        while at < bytes.len() {
            let rest = &bytes[at..];
            if rest.starts_with(PASTE_START) || rest.starts_with(PASTE_END) {
                self.in_paste = rest.starts_with(PASTE_START);
                self.unsubmitted = true;
                at += PASTE_START.len();
                continue;
            }
            match bytes[at] {
                b'\r' | b'\n' if !self.in_paste => {
                    if running {
                        self.typed_while_running = self.typed_while_running.saturating_add(1);
                    } else {
                        self.owed_prompts = self.owed_prompts.saturating_add(1);
                        self.line_since_prompt = true;
                    }
                    self.unsubmitted = false;
                }
                // Ctrl-C: at the prompt the shell drops the line and prompts
                // again; to a running command that reads cooked the terminal
                // sends SIGINT and flushes its unread input.
                0x03 if !self.in_paste => {
                    if flushes {
                        self.typed_while_running = 0;
                        self.unsubmitted = false;
                    } else if !running {
                        self.owed_prompts = self.owed_prompts.saturating_add(1);
                        self.line_since_prompt = true;
                        self.unsubmitted = false;
                    } else {
                        self.unsubmitted = true;
                    }
                }
                // Ctrl-Z and Ctrl-\: to a running command that reads cooked a
                // signal that flushes its unread input; the line editor ignores
                // them, and a raw program reads them.
                0x1a | 0x1c if !self.in_paste => {
                    if flushes {
                        self.typed_while_running = 0;
                        self.unsubmitted = false;
                    } else if running {
                        self.unsubmitted = true;
                    }
                }
                _ => self.unsubmitted = true,
            }
            at += 1;
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

    /// Notes input `bytes` written to the terminal (keys, a paste, a `send`;
    /// empty for a key the daemon cannot read), before they are written: until
    /// the prompt that answers its lines the shell is not idle. Returns true
    /// when an idle fact may have gone out ([`Self::idle_went_out`]), so
    /// the caller asks for a publication.
    pub(crate) fn note_input(&mut self, bytes: &[u8]) -> bool {
        self.epoch = self.epoch.wrapping_add(1);
        self.input_after_prompt = true;
        self.note_input_lines(bytes);
        // The last check was of the shell before this input: it says nothing now.
        self.shell_foreground = None;
        self.foreground_leader = None;
        self.idle_went_out()
    }

    /// Whether an idle fact left in a record (published, or read by any record
    /// build: [`Self::expose_idle`]), so a publication must say it ended.
    fn idle_went_out(&self) -> bool {
        self.published.3.is_some() || self.idle_exposed
    }

    /// [`Self::idle_since`] for a record build: the fact it reads may leave in
    /// that record (a cwd or progress upsert, a read), so its end is published
    /// whenever it ends ([`Self::take_change`]).
    pub(crate) fn expose_idle(&mut self) -> Option<u64> {
        let idle = self.idle_since();
        self.idle_exposed |= idle.is_some();
        idle
    }

    /// Notes output a restarted daemon replays from the holder's ring: its
    /// prompt marks are old, and the input the last daemon wrote after them
    /// is unknown, so the shell is not idle until a prompt after the replay.
    pub(crate) fn note_replayed_output(&mut self) {
        self.epoch = self.epoch.wrapping_add(1);
        self.input_after_prompt = true;
        self.shell_foreground = None;
        self.foreground_leader = None;
    }

    /// Notes that input may reach the PTY without this daemon seeing it
    /// (see `unseen_input`): the shell is never idle again. Returns true
    /// when the published facts still say idle, so the caller asks for a
    /// publication.
    pub(crate) fn note_unseen_input(&mut self) -> bool {
        self.epoch = self.epoch.wrapping_add(1);
        self.unseen_input = true;
        self.idle_went_out()
    }

    /// The epoch to hand [`Self::record_foreground_check`] when the shell sits at a
    /// prompt with no input since and its foreground was not checked since
    /// the last mark; `None` when no check would change the facts.
    pub(crate) fn foreground_check_due(&self) -> Option<u64> {
        (self.busy_since_ms.is_none()
            && self.prompt_since_ms.is_some()
            && !self.input_after_prompt
            && !self.unseen_input
            && self.shell_foreground.is_none())
        .then_some(self.epoch)
    }

    /// The epoch of the foreground check a publication runs before it
    /// publishes: one is due ([`Self::foreground_check_due`]), or the facts
    /// say idle, which each publication checks again, so a published idle
    /// fact is always one checked at its publication (a job that took the
    /// terminal with no mark or input the daemon saw fails it). `None`: no
    /// check would change the facts.
    pub(crate) fn foreground_check_epoch(&self) -> Option<u64> {
        self.foreground_check_due().or_else(|| self.idle_since().map(|_| self.epoch))
    }

    /// [`Self::record_foreground_check`] with no leader: the tests' form (the
    /// daemon always passes the leader its check saw).
    #[cfg(test)]
    pub(crate) fn record_foreground(&mut self, epoch: u64, holds: bool) {
        self.record_foreground_check(epoch, holds, None);
    }

    /// Drops the last foreground check and starts a new epoch (a reconnect that kept this daemon's state): the
    /// shell is not idle until a new check.
    pub(crate) fn forget_foreground_check(&mut self) {
        self.shell_foreground = None;
        self.foreground_leader = None;
        self.epoch = self.epoch.wrapping_add(1);
    }

    /// Records a foreground check started at `epoch`
    /// ([`Self::foreground_check_due`]): `holds` is whether the terminal's own
    /// shell held the foreground and `leader` the foreground group leader it
    /// saw (`None`: the lookup failed). A mark or input since then drops it.
    pub(crate) fn record_foreground_check(&mut self, epoch: u64, holds: bool, leader: Option<u32>) {
        if epoch == self.epoch {
            self.shell_foreground = Some(holds);
            self.foreground_leader = leader;
        }
    }

    /// The last foreground check after the last mark: whether the terminal's
    /// own shell held the foreground (and no other process shares its group),
    /// and the leader it saw. `None` until checked.
    pub(crate) fn foreground_check(&self) -> Option<(bool, Option<u32>)> {
        self.shell_foreground.map(|own| (own, self.foreground_leader))
    }

    /// Since when the terminal's own shell sits idle at its prompt (the
    /// prompt's `A` time): at a prompt, its foreground checked as the
    /// shell's after the last mark, no input since the `A`, and no line owed a
    /// prompt.
    pub(crate) fn idle_since(&self) -> Option<u64> {
        if self.busy_since_ms.is_some()
            || self.input_after_prompt
            || self.unseen_input
            || self.owed_prompts > 0
            || self.shell_foreground != Some(true)
        {
            return None;
        }
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
    /// next `take_change`. The host's state does not say whether input was
    /// written since its prompt (another daemon wrote it), so the shell is
    /// not idle until its next `A`.
    pub(crate) fn restore(&mut self, snapshot: ShellActivitySnapshot) {
        self.busy_since_ms = snapshot.busy_since_ms;
        self.interactive = snapshot.busy_since_ms.is_some() && snapshot.interactive;
        self.line_modes_armed = snapshot.busy_since_ms.is_some() && snapshot.line_modes_armed;
        self.prompt_since_ms = snapshot.prompt_since_ms;
        self.input_after_prompt = true;
        // A host whose shell drew a prompt or ran a command: its first prompt
        // is behind it, and what was typed ahead there is unknown
        // (`input_after_prompt` holds until the next `A`). A fresh host's first
        // snapshot has neither: its shell's first `A` answers the spawn.
        self.prompted = snapshot.prompt_since_ms.is_some() || snapshot.busy_since_ms.is_some();
        self.owed_prompts = 0;
        self.typed_while_running = 0;
        self.unsubmitted = false;
        self.in_paste = false;
        self.line_since_prompt = false;
        self.command_since_prompt = false;
        self.shell_foreground = None;
        self.foreground_leader = None;
        self.epoch = self.epoch.wrapping_add(1);
    }

    /// Keeps what this daemon knows that the host's state does not carry:
    /// `previous`'s last output, so a reconnect neither drops it nor pushes
    /// it again, and whether input was written since the prompt (this
    /// daemon wrote all of it).
    pub(crate) fn keep_output_of(&mut self, previous: &ShellActivity) {
        self.last_output_ms = previous.last_output_ms;
        self.published_output_ms = previous.published_output_ms;
        self.input_after_prompt = previous.input_after_prompt;
        self.owed_prompts = previous.owed_prompts;
        self.prompted = previous.prompted;
        self.typed_while_running = previous.typed_while_running;
        self.line_since_prompt = previous.line_since_prompt;
        self.command_since_prompt = previous.command_since_prompt;
        self.sends_command_marks = previous.sends_command_marks;
        self.unsubmitted = previous.unsubmitted;
        self.in_paste = previous.in_paste;
        self.unseen_input = previous.unseen_input;
        self.idle_exposed = previous.idle_exposed;
    }

    /// The published facts: command, prompt and idle shell.
    fn facts(&self) -> (Option<u64>, bool, Option<u64>, Option<u64>) {
        (self.busy_since_ms, self.interactive, self.prompt_since_ms, self.idle_since())
    }

    /// Whether the command, prompt or idle-shell fact changed, or the last
    /// output moved a whole interval past the one published, since the last
    /// call (marks it taken).
    pub(crate) fn take_change(&mut self) -> bool {
        let facts = self.facts();
        // An idle fact a record build read went out even if this never marked
        // it published: its end goes out as a change.
        let retracted = self.idle_exposed && facts.3.is_none();
        let changed = facts != self.published || self.output_moved() || retracted;
        if changed {
            self.published = facts;
            self.published_output_ms = self.last_output_ms;
            self.idle_exposed = facts.3.is_some();
        }
        changed
    }

    /// [`Self::take_change`] without marking it taken, or a foreground check
    /// is due (the publication runs it first).
    pub(crate) fn has_change(&self) -> bool {
        self.facts() != self.published
            || self.output_moved()
            || (self.idle_exposed && self.idle_since().is_none())
            || self.foreground_check_due().is_some()
    }

    /// The last output moved a whole interval past the one published.
    fn output_moved(&self) -> bool {
        match (self.last_output_ms, self.published_output_ms) {
            (Some(last), Some(published)) => {
                last < published || last - published >= OUTPUT_PUBLISH_INTERVAL_MS
            }
            (last, published) => last != published,
        }
    }
}

/// Whether `running`, the program the kernel exec'd for the terminal's
/// foreground leader (macOS's image path, proc_pidpath; Linux's command name,
/// the exec'd file's name; never an argv a program can rewrite), is the
/// program `spawned` (the terminal's argv[0])
/// names: the same file name, a login shell's leading `-` aside. A program
/// `exec`ed in the shell's place is not.
#[cfg_attr(not(unix), allow(dead_code))]
pub(crate) fn same_program(running: &str, spawned: &str) -> bool {
    fn file_name(path: &str) -> &str {
        path.rsplit('/').next().unwrap_or(path).trim_start_matches('-')
    }
    let spawned = file_name(spawned);
    if spawned.is_empty() {
        return false;
    }
    file_name(running) == spawned
}

/// Whether `command`, the argv the daemon spawned for a terminal, is an
/// interactive shell: a known shell with no command (`-c`, `--command`) and
/// no script of its own (a word that is not an option, other than the file
/// of `--rcfile` or `--init-file`). Only a shell's prompt can be idle: a terminal that runs ssh
/// or `docker exec` itself shows the remote shell's prompt marks while its
/// own program holds the foreground, and `bash -c 'a; b'` runs its commands
/// in its own process group.
#[cfg_attr(not(unix), allow(dead_code))]
pub(crate) fn spawned_shell(command: &[String]) -> bool {
    const SHELLS: &[&str] =
        &["bash", "zsh", "fish", "sh", "dash", "ksh", "mksh", "tcsh", "csh", "nu", "elvish"];
    let Some((program, arguments)) = command.split_first() else { return false };
    let name = program.rsplit('/').next().unwrap_or(program).trim_start_matches('-');
    if !SHELLS.contains(&name) {
        return false;
    }
    let mut arguments = arguments.iter();
    while let Some(argument) = arguments.next() {
        if argument == "--rcfile" || argument == "--init-file" {
            arguments.next();
            continue;
        }
        let short_command =
            argument.starts_with('-') && !argument.starts_with("--") && argument.contains('c');
        let script = !argument.starts_with('-') && !argument.starts_with('+');
        let long_command = ["--command", "--execute"].iter().any(|option| {
            argument == option
                || argument.strip_prefix(option).is_some_and(|rest| rest.starts_with('='))
        });
        if short_command || script || long_command {
            return false;
        }
    }
    true
}

/// The `activity` field of a terminal record.
pub(crate) fn activity_json(state: CommandActivity, since_ms: u64) -> Value {
    json!({"state": state.as_str(), "since_ms": since_ms.to_string()})
}

/// The `prompt` field of a terminal record.
pub(crate) fn prompt_json(since_ms: u64) -> Value {
    json!({"since_ms": since_ms.to_string()})
}

/// The `shell_idle` field of a terminal record (its prompt's time).
pub(crate) fn shell_idle_json(since_ms: u64) -> Value {
    json!({"since_ms": since_ms.to_string()})
}

/// The `foreground_check` field of a terminal record: the daemon's last
/// foreground check behind `shell_idle` (`own`; `leader`, null when the lookup
/// failed).
pub(crate) fn foreground_check_json(own: bool, leader: Option<u32>) -> Value {
    json!({"own": own, "leader": leader})
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
mod tests;
