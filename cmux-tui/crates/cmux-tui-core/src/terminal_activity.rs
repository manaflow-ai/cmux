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
//! count, `owed_prompts`), and a partial line stays in the editor. Anything unknown
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
    /// them. More than one owed at an `A` means a line was typed ahead and
    /// waits unread for the line editor, so that prompt is not idle. A shell
    /// that prints more than one `A` per line only makes this less strict
    /// than the line count, never stricter than the old rule.
    owed_prompts: u32,
    /// The shell printed its first prompt: the first `A` answers the spawn,
    /// not a line, so input typed before it stays owed.
    prompted: bool,
    /// A Return was written while a command ran (between `C` and `D`): the
    /// program read it, or it waits for the shell as a typed-ahead line. Its
    /// end decides ([`Self::settle_command_input`]).
    typed_while_running: bool,
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
    /// Counts marks and inputs, so a foreground check that raced one of them
    /// is dropped ([`Self::record_foreground`]).
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
                false
            }
            ShellMark::CommandEnd { .. } => {
                self.settle_command_input();
                self.end();
                false
            }
            ShellMark::PromptStart => {
                self.settle_command_input();
                self.end();
                self.prompt_since_ms.get_or_insert(now_ms);
                if self.prompted {
                    self.owed_prompts = self.owed_prompts.saturating_sub(1);
                } else {
                    self.prompted = true;
                }
                // Input written before this `A` was parsed but after the
                // shell printed it waits unread for the line editor: a line
                // typed ahead (still owed) or a partial one.
                self.input_after_prompt = self.owed_prompts > 0 || self.unsubmitted;
                true
            }
            ShellMark::InputStart => false,
        }
    }

    /// A command ended (`D`, or an `A` with no `D`): a Return typed while it
    /// ran is a line typed ahead for the shell, unless the command took the
    /// terminal for interaction (an editor, a REPL, ssh: `interactive`), which
    /// read its own keys.
    fn settle_command_input(&mut self) {
        if self.busy_since_ms.is_none() {
            return;
        }
        if self.interactive {
            self.unsubmitted = false;
        } else if self.typed_while_running {
            self.owed_prompts = self.owed_prompts.saturating_add(1);
        }
        self.typed_while_running = false;
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
                        self.typed_while_running = true;
                    } else {
                        self.owed_prompts = self.owed_prompts.saturating_add(1);
                    }
                    self.unsubmitted = false;
                }
                // Ctrl-C: at the prompt the shell drops the line and prompts
                // again; to a running command the terminal sends SIGINT and
                // flushes its unread input.
                0x03 if !self.in_paste => {
                    if running {
                        self.typed_while_running = false;
                    } else {
                        self.owed_prompts = self.owed_prompts.saturating_add(1);
                    }
                    self.unsubmitted = false;
                }
                // Ctrl-Z and Ctrl-\: to a running command a signal that
                // flushes its unread input; the line editor ignores them.
                0x1a | 0x1c if !self.in_paste => {
                    if running {
                        self.typed_while_running = false;
                        self.unsubmitted = false;
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
    /// when an idle fact may have been published ([`Self::retract_idle`]), so
    /// the caller asks for a publication.
    pub(crate) fn note_input(&mut self, bytes: &[u8]) -> bool {
        let was_idle = self.idle_since();
        self.epoch = self.epoch.wrapping_add(1);
        self.input_after_prompt = true;
        self.note_input_lines(bytes);
        // The last check was of the shell before this input: it says nothing now.
        self.shell_foreground = None;
        self.foreground_leader = None;
        self.retract_idle(was_idle)
    }

    /// After a note that ended idle: true when an idle fact may have left in
    /// a record, so a publication must say it ended. Any record build reads
    /// the idle fact from memory (a cwd upsert, a progress upsert), not only
    /// the one that marks it published; an idle fact that was true before the
    /// note counts as published, so the next `take_change` sends its end.
    fn retract_idle(&mut self, was_idle: Option<u64>) -> bool {
        if self.published.3.is_none() {
            self.published.3 = was_idle;
        }
        self.published.3.is_some()
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
        let was_idle = self.idle_since();
        self.epoch = self.epoch.wrapping_add(1);
        self.unseen_input = true;
        self.retract_idle(was_idle)
    }

    /// The epoch to hand [`Self::record_foreground`] when the shell sits at a
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

    /// Records a foreground check started at `epoch`
    /// ([`Self::foreground_check_due`]): `holds` is whether the terminal's
    /// own shell held the foreground. A mark or input since then drops it.
    pub(crate) fn record_foreground(&mut self, epoch: u64, holds: bool) {
        self.record_foreground_leader(epoch, holds, None);
    }

    /// Drops the last foreground check and starts a new epoch (a reconnect that kept this daemon's state): the
    /// shell is not idle until a new check.
    pub(crate) fn forget_foreground_check(&mut self) {
        self.shell_foreground = None;
        self.foreground_leader = None;
        self.epoch = self.epoch.wrapping_add(1);
    }

    /// [`Self::record_foreground`] with the foreground group leader the check
    /// saw (`None`: the lookup failed).
    pub(crate) fn record_foreground_leader(
        &mut self,
        epoch: u64,
        holds: bool,
        leader: Option<u32>,
    ) {
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
    /// shell's after the last mark, no input since the `A`.
    pub(crate) fn idle_since(&self) -> Option<u64> {
        if self.busy_since_ms.is_some()
            || self.input_after_prompt
            || self.unseen_input
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
        // The host's shell printed its prompts already; what was typed ahead
        // there is unknown, and `input_after_prompt` holds until the next `A`.
        self.prompted = true;
        self.owed_prompts = 0;
        self.typed_while_running = false;
        self.unsubmitted = false;
        self.in_paste = false;
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
        self.unsubmitted = previous.unsubmitted;
        self.in_paste = previous.in_paste;
        self.unseen_input = previous.unseen_input;
    }

    /// The published facts: command, prompt and idle shell.
    fn facts(&self) -> (Option<u64>, bool, Option<u64>, Option<u64>) {
        (self.busy_since_ms, self.interactive, self.prompt_since_ms, self.idle_since())
    }

    /// Whether the command, prompt or idle-shell fact changed, or the last
    /// output moved a whole interval past the one published, since the last
    /// call (marks it taken).
    pub(crate) fn take_change(&mut self) -> bool {
        let changed = self.facts() != self.published || self.output_moved();
        if changed {
            self.published = self.facts();
            self.published_output_ms = self.last_output_ms;
        }
        changed
    }

    /// [`Self::take_change`] without marking it taken, or a foreground check
    /// is due (the publication runs it first).
    pub(crate) fn has_change(&self) -> bool {
        self.facts() != self.published
            || self.output_moved()
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

    /// A shell at its prompt, its foreground checked as its own.
    fn idle_at(since_ms: u64) -> ShellActivity {
        let mut activity = ShellActivity::default();
        activity.observe(ShellMark::PromptStart, since_ms);
        activity.observe(ShellMark::InputStart, since_ms);
        let epoch = activity.foreground_check_due().expect("a prompt asks for a check");
        activity.record_foreground(epoch, true);
        activity
    }

    #[test]
    fn shell_idle_a_prompt_is_idle_only_after_its_foreground_check() {
        let mut activity = ShellActivity::default();
        activity.observe(ShellMark::PromptStart, 1_000);
        assert_eq!(activity.prompt_since(), Some(1_000));
        assert_eq!(activity.idle_since(), None, "unchecked is not idle");
        assert!(activity.has_change(), "the due check asks for a publication");
        let epoch = activity.foreground_check_due().unwrap();
        activity.record_foreground(epoch, false);
        assert_eq!(activity.idle_since(), None, "another group holds the terminal");
        assert_eq!(activity.foreground_check_due(), None, "checked once per mark");
        // The next mark asks again.
        activity.observe(ShellMark::InputStart, 1_001);
        let epoch = activity.foreground_check_due().unwrap();
        activity.record_foreground(epoch, true);
        assert_eq!(activity.idle_since(), Some(1_000));
    }

    #[test]
    fn shell_idle_input_ends_idle_until_the_next_prompt() {
        let mut activity = idle_at(1_000);
        assert!(activity.take_change());
        assert!(activity.note_input(b"ls"), "published idle: the input asks for a publication");
        assert_eq!(activity.idle_since(), None);
        assert_eq!(activity.prompt_since(), Some(1_000), "the prompt fact stands");
        assert_eq!(activity.foreground_check_due(), None, "no check while input is pending");
        assert!(activity.take_change());
        assert!(!activity.note_input(b"\r"), "already published not idle");
        // A nested prompt's mark (or the shell's own) clears the input, and
        // its check decides.
        activity.observe(ShellMark::PromptStart, 2_000);
        let epoch = activity.foreground_check_due().unwrap();
        activity.record_foreground(epoch, false);
        assert_eq!(activity.idle_since(), None);
    }

    /// The shell's next prompt after `bytes` were typed at an idle prompt and
    /// `prompts` prompt marks came: whether that prompt asks for its check.
    fn checked_after(mut activity: ShellActivity, prompts: &[u64]) -> ShellActivity {
        for at in prompts {
            activity.observe(ShellMark::PromptStart, *at);
        }
        activity
    }

    /// Review 3, finding 2: a line typed ahead (written before the shell's
    /// `A` for the line before it was parsed) waits unread for the line
    /// editor, so that prompt is not idle; the prompt after it is.
    #[test]
    fn shell_idle_a_line_typed_ahead_keeps_the_next_prompt_not_idle() {
        let mut activity = idle_at(1_000);
        activity.note_input(b"true\r");
        activity.note_input(b"sleep 600\r");
        let activity = checked_after(activity, &[2_000]);
        assert_eq!(activity.foreground_check_due(), None, "sleep 600 is still unread");
        assert_eq!(activity.idle_since(), None);
        let activity = checked_after(activity, &[3_000]);
        assert!(activity.foreground_check_due().is_some(), "both lines answered");
    }

    /// One write with two lines (a paste without bracketed paste, `send`).
    #[test]
    fn shell_idle_two_lines_in_one_write_owe_two_prompts() {
        let mut activity = idle_at(1_000);
        activity.note_input(b"true\rsleep 600\r");
        assert_eq!(checked_after(activity, &[2_000]).foreground_check_due(), None);
    }

    #[test]
    fn shell_idle_a_line_typed_before_the_first_prompt_is_owed() {
        let mut activity = ShellActivity::default();
        activity.note_input(b"sleep 600\r");
        let activity = checked_after(activity, &[1_000]);
        assert_eq!(activity.foreground_check_due(), None, "the first prompt answers the spawn");
        let activity = checked_after(activity, &[2_000]);
        assert!(activity.foreground_check_due().is_some());
    }

    #[test]
    fn shell_idle_a_line_typed_while_a_command_runs_is_typed_ahead() {
        let mut activity = idle_at(1_000);
        activity.note_input(b"make\r");
        activity.observe(ShellMark::CommandStart, 1_100);
        activity.note_input(b"sleep 600\r");
        activity.observe(ShellMark::CommandEnd { exit_code: None }, 1_200);
        let activity = checked_after(activity, &[1_300]);
        assert_eq!(activity.foreground_check_due(), None, "sleep 600 waits for the shell");
        assert!(checked_after(activity, &[1_400]).foreground_check_due().is_some());
    }

    #[test]
    fn shell_idle_keys_an_interactive_command_read_are_not_typed_ahead() {
        let mut activity = idle_at(1_000);
        activity.note_input(b"vim\r");
        activity.observe(ShellMark::CommandStart, 1_100);
        activity.note_modes(TerminalModes { exclusive: true, line: false });
        activity.note_input(b"ihello\x1b:wq\r");
        activity.observe(ShellMark::CommandEnd { exit_code: None }, 1_200);
        let activity = checked_after(activity, &[1_300]);
        assert!(activity.foreground_check_due().is_some(), "vim read its own keys");
    }

    #[test]
    fn shell_idle_ctrl_c_to_a_command_drops_what_was_typed_ahead() {
        let mut activity = idle_at(1_000);
        activity.note_input(b"make\r");
        activity.observe(ShellMark::CommandStart, 1_100);
        activity.note_input(b"sleep 600\r");
        activity.note_input(b"\x03");
        activity.observe(ShellMark::CommandEnd { exit_code: None }, 1_200);
        let activity = checked_after(activity, &[1_300]);
        assert!(activity.foreground_check_due().is_some(), "the interrupt flushed the input");
    }

    /// The stopped-job integration test's shell has no `C`: Ctrl-Z is no line.
    #[test]
    fn shell_idle_ctrl_z_is_not_a_line() {
        let mut activity = idle_at(1_000);
        activity.note_input(b"sleep 600\r");
        activity.note_input(b"\x1a");
        assert!(checked_after(activity, &[2_000]).foreground_check_due().is_some());
    }

    #[test]
    fn shell_idle_a_partial_line_keeps_the_prompt_not_idle() {
        let mut activity = idle_at(1_000);
        activity.note_input(b"ls\rech");
        let activity = checked_after(activity, &[2_000]);
        assert_eq!(activity.foreground_check_due(), None, "`ech` waits in the line editor");
    }

    #[test]
    fn shell_idle_line_breaks_in_a_bracketed_paste_are_not_lines() {
        let mut activity = idle_at(1_000);
        activity.note_input(b"\x1b[200~echo a\necho b\n\x1b[201~");
        activity.note_input(b"\r");
        let activity = checked_after(activity, &[2_000]);
        assert!(activity.foreground_check_due().is_some(), "one Return, one prompt");
    }

    /// Review 3, finding 3: a record built before any `take_change` (a cwd
    /// upsert) can carry the idle fact; input after it still sends its end.
    #[test]
    fn shell_idle_input_retracts_an_idle_fact_no_take_change_marked() {
        let mut activity = idle_at(1_000);
        assert!(activity.idle_since().is_some(), "a record built now says idle");
        assert!(activity.note_input(b"x"), "the input asks for a publication");
        assert!(activity.take_change(), "the publication sends the end of idle");
        let mut activity = idle_at(1_000);
        assert!(activity.note_unseen_input());
        assert!(activity.take_change());
    }

    /// Review 2, finding 6: a reconnect without host state checks again.
    #[test]
    fn shell_idle_a_forgotten_check_is_not_idle_until_checked_again() {
        let mut activity = idle_at(1_000);
        let stale = activity.foreground_check_epoch().unwrap();
        activity.forget_foreground_check();
        assert_eq!(activity.idle_since(), None);
        activity.record_foreground(stale, true);
        assert_eq!(activity.idle_since(), None, "a check from before the reconnect");
        let epoch = activity.foreground_check_due().expect("a new check is due");
        activity.record_foreground(epoch, true);
        assert_eq!(activity.idle_since(), Some(1_000));
    }

    #[test]
    fn shell_idle_a_check_that_raced_a_mark_or_input_is_dropped() {
        let mut activity = ShellActivity::default();
        activity.observe(ShellMark::PromptStart, 1_000);
        let stale = activity.foreground_check_due().unwrap();
        activity.observe(ShellMark::InputStart, 1_001);
        activity.record_foreground(stale, true);
        assert_eq!(activity.idle_since(), None, "a check from before the mark");
        let stale = activity.foreground_check_due().unwrap();
        activity.note_input(b"x");
        activity.record_foreground(stale, true);
        assert_eq!(activity.idle_since(), None, "a check from before the input");
    }

    #[test]
    fn shell_idle_each_publication_checks_a_published_idle_again() {
        let mut activity = idle_at(1_000);
        assert!(activity.take_change());
        assert_eq!(activity.foreground_check_due(), None, "the mark's check ran");
        // A later publication (output, a directory change) checks again: a
        // job took the terminal with no mark or input the daemon saw.
        let epoch = activity.foreground_check_epoch().expect("an idle fact is checked again");
        activity.record_foreground(epoch, false);
        assert_eq!(activity.idle_since(), None);
        assert!(activity.take_change(), "the publication drops the idle fact");
        assert_eq!(activity.foreground_check_epoch(), None, "nothing to check while not idle");
    }

    #[test]
    fn shell_idle_unseen_input_ends_idle_for_good() {
        let mut activity = idle_at(1_000);
        assert!(activity.take_change());
        assert!(activity.note_unseen_input(), "published idle: asks for a publication");
        assert_eq!(activity.idle_since(), None);
        activity.observe(ShellMark::PromptStart, 2_000);
        assert_eq!(activity.foreground_check_due(), None, "no new prompt makes it idle again");
        assert_eq!(activity.idle_since(), None);
        // A reconnect inside this daemon keeps it.
        let mut reconnected = ShellActivity::default();
        reconnected.restore(activity.snapshot());
        reconnected.keep_output_of(&activity);
        reconnected.observe(ShellMark::PromptStart, 3_000);
        assert_eq!(reconnected.foreground_check_due(), None);
    }

    #[test]
    fn shell_idle_a_replayed_prompt_is_not_idle_until_a_new_one() {
        let mut activity = ShellActivity::default();
        // A ring replay ends at an old prompt; input after it is unknown.
        activity.observe(ShellMark::PromptStart, 1_000);
        activity.note_replayed_output();
        assert_eq!(activity.prompt_since(), Some(1_000));
        assert_eq!(activity.foreground_check_due(), None);
        assert_eq!(activity.idle_since(), None);
        // The shell's next prompt, after the replay.
        activity.observe(ShellMark::PromptStart, 2_000);
        let epoch = activity.foreground_check_due().expect("a live prompt asks for a check");
        activity.record_foreground(epoch, true);
        assert!(activity.idle_since().is_some());
    }

    #[test]
    fn shell_idle_spawned_shell_is_an_interactive_shell_only() {
        assert!(spawned_shell(&["/bin/zsh".into()]));
        assert!(spawned_shell(&["-bash".into()]));
        assert!(spawned_shell(&["bash".into(), "--posix".into()]), "the integrated bash");
        let rcfile = ["/bin/bash", "--noprofile", "--rcfile", "/tmp/rc", "-i"];
        assert!(spawned_shell(&rcfile.map(String::from)));
        assert!(!spawned_shell(&["ssh".into(), "host".into()]), "a terminal that runs ssh");
        let docker = ["docker", "exec", "-it", "c", "bash"];
        assert!(!spawned_shell(&docker.map(String::from)));
        assert!(!spawned_shell(&["bash".into(), "-c".into(), "a; b".into()]));
        assert!(!spawned_shell(&["bash".into(), "-lc".into(), "a".into()]));
        assert!(!spawned_shell(&["fish".into(), "--command".into(), "a".into()]));
        assert!(!spawned_shell(&["fish".into(), "--command=a".into()]), "review 3: --command=");
        assert!(!spawned_shell(&["elvish".into(), "--execute=a".into()]));
        assert!(!spawned_shell(&["bash".into(), "script.sh".into()]), "a script");
        assert!(!spawned_shell(&[]));
    }

    #[test]
    fn shell_idle_a_running_command_is_never_idle() {
        let mut activity = idle_at(1_000);
        activity.observe(ShellMark::CommandStart, 1_500);
        assert_eq!(activity.idle_since(), None);
        assert_eq!(activity.foreground_check_due(), None);
    }

    #[test]
    fn shell_idle_a_host_state_is_not_idle_until_its_next_prompt() {
        let previous = idle_at(1_000);
        let mut restored = ShellActivity::default();
        restored.restore(previous.snapshot());
        assert_eq!(restored.prompt_since(), Some(1_000));
        assert_eq!(restored.idle_since(), None, "input written before the adoption is unknown");
        assert_eq!(restored.foreground_check_due(), None);
        // A reconnect inside this daemon keeps what it knows about input.
        let mut reconnected = ShellActivity::default();
        reconnected.restore(previous.snapshot());
        reconnected.keep_output_of(&previous);
        assert!(reconnected.foreground_check_due().is_some(), "checked again, then idle");
    }

    #[test]
    fn shell_idle_same_program_matches_the_spawned_file_name_only() {
        assert!(same_program("/bin/bash", "/bin/bash"));
        assert!(same_program("-bash", "/usr/bin/bash"));
        assert!(same_program("/bin/zsh", "zsh"));
        assert!(
            !same_program("bash --rcfile x", "/bin/bash"),
            "an argv, not an image: never trusted"
        );
        assert!(!same_program("/bin/dash", "/bin/bash"), "an exec'd shell");
        assert!(!same_program("ssh", "/bin/zsh"));
        assert!(!same_program("/bin/bash", ""));
    }

    #[test]
    fn last_output_json_names_the_time_as_a_decimal_string() {
        assert_eq!(last_output_json(1_792_000_000_123), json!({"at_ms": "1792000000123"}));
    }
}
