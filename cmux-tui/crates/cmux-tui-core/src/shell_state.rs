//! A freed (parked) terminal's shell state: what the person left in the
//! shell (variables, functions, aliases, options, traps, directory stack,
//! umask, history), saved before the shell ends and given to the new shell
//! of the restarted tab (plans/cmux-next/sidebar-recents-and-freeing-DESIGN.md
//! Part 2; Leo, 2026-11-19: freeing on by default only when "nobody can see a
//! difference").
//!
//! Files, per terminal, in the session's private `shell-state` directory
//! (0700, beside the output store; every file 0600). The shell learns its
//! prefix from [`SHELL_STATE_ENV`]:
//!
//! - `<id>.request`: the daemon's nonce for one save.
//! - `<id>.history`, then `<id>.state`: written by the shell's integration
//!   (`shell_integration/shell-state.bash`, `.zsh`). The state file's first
//!   line says `ok` or `unsaveable <why>`, its last line `# end <nonce>` is
//!   the ack: a file without it is incomplete.
//! - `<id>.restore`, `<id>.restore-history`: the same files handed to the
//!   restarted tab's new shell ([`ShellStateDir::take_for_restore`]), which
//!   reads them after the person's startup files and deletes them.
//!
//! A save is a signal, not output: the daemon writes the request and sends
//! the shell SIGWINCH. The integration traps it; readline and zle catch
//! SIGWINCH, so the trap runs at once at the prompt, and its default
//! disposition is to ignore it, so a program without the trap is unharmed.
//! The daemon waits for the ack at most [`SAVE_TIMEOUT`]: no ack, no saved
//! state. Nothing is written per prompt; a shell costs a file test per
//! resize.
//!
//! Lifecycle: a request is removed when its wait ends; a restore's files are
//! deleted by the shell that reads them, and a respawn that does not restore
//! removes stale ones; the files of a terminal that left the session go with
//! the output store's prune (at start, after a terminal closed, once a day).

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::resource::TerminalPublicId;

/// The shell's path prefix for its state files (`<dir>/<terminal id>`).
pub(crate) const SHELL_STATE_ENV: &str = "CMUX_TUI_SHELL_STATE";

/// The longest wait for a shell's ack.
pub(crate) const SAVE_TIMEOUT: Duration = Duration::from_millis(500);

/// How often a wait reads the state files.
const POLL: Duration = Duration::from_millis(5);

/// The directory name under the session's registry directory.
pub(crate) const DIRECTORY: &str = "shell-state";

const REQUEST: &str = "request";
const STATE: &str = "state";
const HISTORY: &str = "history";
const RESTORE: &str = "restore";
const RESTORE_HISTORY: &str = "restore-history";
const SUFFIXES: [&str; 5] = [REQUEST, STATE, HISTORY, RESTORE, RESTORE_HISTORY];

/// What a shell answered to one save request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum SaveOutcome {
    /// The state file is complete and holds the shell's state.
    Saved,
    /// The shell answered that its state cannot be restored (`jobs`, an
    /// `open-fd-N` the person opened, a shell the integration cannot save).
    Unsaveable(String),
    /// No answer in time: no integration, a busy shell, no such process.
    NoAck,
}

/// One session's shell-state directory.
#[derive(Debug, Clone)]
pub(crate) struct ShellStateDir {
    root: PathBuf,
}

impl ShellStateDir {
    pub(crate) fn new(root: PathBuf) -> Self {
        Self { root }
    }

    /// The prefix a terminal's shell gets in [`SHELL_STATE_ENV`], after the
    /// directory exists and is private. `None` when it cannot be made so.
    pub(crate) fn prefix(&self, terminal: &TerminalPublicId) -> Option<PathBuf> {
        self.ensure().ok()?;
        Some(self.root.join(terminal.as_str()))
    }

    fn path(&self, terminal: &TerminalPublicId, suffix: &str) -> PathBuf {
        self.root.join(format!("{}.{suffix}", terminal.as_str()))
    }

    fn ensure(&self) -> io::Result<()> {
        match fs::create_dir_all(&self.root) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error),
        }
        let metadata = fs::symlink_metadata(&self.root)?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(io::Error::other("the shell-state directory is not a directory"));
        }
        crate::platform::restrict_directory(&self.root)
    }

    /// Starts a save: removes the last answer and writes a new nonce.
    fn begin(&self, terminal: &TerminalPublicId) -> io::Result<String> {
        self.ensure()?;
        let _ = fs::remove_file(self.path(terminal, STATE));
        let nonce = new_nonce()?;
        let path = self.path(terminal, REQUEST);
        let temp = self.root.join(format!(".{}.request.tmp", terminal.as_str()));
        let _ = fs::remove_file(&temp);
        let written = (|| {
            let mut file = fs::OpenOptions::new().write(true).create_new(true).open(&temp)?;
            crate::platform::restrict_file(&temp)?;
            file.write_all(format!("{nonce}\n").as_bytes())?;
            fs::rename(&temp, &path)
        })();
        if written.is_err() {
            let _ = fs::remove_file(&temp);
        }
        written.map(|()| nonce)
    }

    /// The shell's answer to the request with `nonce`, once it is complete.
    fn answer(&self, terminal: &TerminalPublicId, nonce: &str) -> Option<SaveOutcome> {
        let text = fs::read_to_string(self.path(terminal, STATE)).ok()?;
        parse_answer(&text, nonce)
    }

    fn end(&self, terminal: &TerminalPublicId) {
        let _ = fs::remove_file(self.path(terminal, REQUEST));
    }

    /// Whether the terminal's last save is complete and saveable.
    fn saved(&self, terminal: &TerminalPublicId) -> bool {
        fs::read_to_string(self.path(terminal, STATE))
            .ok()
            .and_then(|text| {
                let nonce = text.lines().last()?.strip_prefix("# end ")?.to_owned();
                parse_answer(&text, &nonce)
            })
            .is_some_and(|outcome| outcome == SaveOutcome::Saved)
    }

    /// Whether the terminal's last save is complete, saveable and at most
    /// `age` old.
    pub(crate) fn saved_within(&self, terminal: &TerminalPublicId, age: Duration) -> bool {
        let written = fs::metadata(self.path(terminal, STATE)).and_then(|meta| meta.modified());
        written.is_ok_and(|written| written.elapsed().is_ok_and(|elapsed| elapsed <= age))
            && self.saved(terminal)
    }

    /// Hands a parked terminal's saved state to its next shell: its complete,
    /// saveable state file (and history) become the restore files. Without
    /// one, stale restore files are removed, so a shell never restores an
    /// older state. Returns whether the next shell restores.
    pub(crate) fn take_for_restore(&self, terminal: &TerminalPublicId) -> bool {
        let restore = self.path(terminal, RESTORE);
        let restore_history = self.path(terminal, RESTORE_HISTORY);
        let _ = fs::remove_file(&restore);
        let _ = fs::remove_file(&restore_history);
        let _ = fs::remove_file(self.path(terminal, REQUEST));
        if !self.saved(terminal) {
            let _ = fs::remove_file(self.path(terminal, STATE));
            let _ = fs::remove_file(self.path(terminal, HISTORY));
            return false;
        }
        let history = self.path(terminal, HISTORY);
        if history.is_file() && fs::rename(&history, &restore_history).is_err() {
            let _ = fs::remove_file(&history);
        }
        fs::rename(self.path(terminal, STATE), &restore).is_ok()
    }

    /// Removes every file of `terminal` (a respawn that is not a parked tab's
    /// restart: its shell starts fresh).
    pub(crate) fn discard(&self, terminal: &TerminalPublicId) {
        for suffix in SUFFIXES {
            let _ = fs::remove_file(self.path(terminal, suffix));
        }
    }

    /// Removes the files of terminals not in `live` (a request's temporary
    /// file included), and leftovers that name no terminal. Returns how
    /// many files went.
    pub(crate) fn remove_unowned(&self, live: &HashSet<TerminalPublicId>) -> usize {
        let Ok(entries) = fs::read_dir(&self.root) else { return 0 };
        let mut removed = 0_usize;
        for entry in entries.flatten() {
            let name = entry.file_name();
            let Some(name) = name.to_str() else { continue };
            let owner = name.trim_start_matches('.').split('.').next().unwrap_or_default();
            let keep = TerminalPublicId::parse(owner).is_ok_and(|id| live.contains(&id));
            if !keep && entry.file_type().is_ok_and(|kind| kind.is_file()) {
                removed += usize::from(fs::remove_file(entry.path()).is_ok());
            }
        }
        removed
    }
}

/// Parses a state file `text` written for `nonce`: `None` while it is
/// incomplete or answers another request.
fn parse_answer(text: &str, nonce: &str) -> Option<SaveOutcome> {
    let end = format!("# end {nonce}\n");
    if nonce.is_empty() || !text.ends_with(&end) {
        return None;
    }
    let header = text.lines().next()?;
    let rest = header.strip_prefix("# cmux-tui shell state 1 ")?;
    let mut words = rest.split_whitespace();
    let _shell = words.next()?;
    match words.next()? {
        "ok" => Some(SaveOutcome::Saved),
        "unsaveable" => Some(SaveOutcome::Unsaveable(words.collect::<Vec<_>>().join(" "))),
        _ => None,
    }
}

fn new_nonce() -> io::Result<String> {
    let mut bytes = [0u8; 12];
    getrandom::fill(&mut bytes).map_err(|_| io::Error::other("no random bytes for a nonce"))?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

/// Asks each shell in `targets` (terminal, shell pid) to save its state and
/// waits for all answers together, at most `timeout`. `signal` delivers the
/// request (SIGWINCH to the pid; a test's own function).
pub(crate) fn save_all(
    dir: &ShellStateDir,
    targets: &[(TerminalPublicId, u32)],
    timeout: Duration,
    signal: &dyn Fn(u32) -> bool,
) -> HashMap<TerminalPublicId, SaveOutcome> {
    let mut outcomes = HashMap::new();
    let mut waiting = Vec::new();
    for (terminal, pid) in targets {
        match dir.begin(terminal) {
            Ok(nonce) if signal(*pid) => waiting.push((terminal.clone(), nonce)),
            _ => {
                dir.end(terminal);
                outcomes.insert(terminal.clone(), SaveOutcome::NoAck);
            }
        }
    }
    let deadline = Instant::now() + timeout;
    loop {
        waiting.retain(|(terminal, nonce)| match dir.answer(terminal, nonce) {
            Some(outcome) => {
                outcomes.insert(terminal.clone(), outcome);
                false
            }
            None => true,
        });
        let now = Instant::now();
        if waiting.is_empty() || now >= deadline {
            break;
        }
        std::thread::sleep(POLL.min(deadline - now));
    }
    for (terminal, _) in waiting {
        outcomes.insert(terminal, SaveOutcome::NoAck);
    }
    for (terminal, _) in targets {
        dir.end(terminal);
    }
    outcomes
}

/// SIGWINCH to the shell `pid`. Only the shell itself, never its group: a
/// program the shell runs is not asked.
#[cfg(unix)]
pub(crate) fn signal_shell(pid: u32) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else { return false };
    if pid <= 1 {
        return false;
    }
    // SAFETY: kill has no memory preconditions; SIGWINCH's default action
    // is to be ignored.
    unsafe { libc::kill(pid, libc::SIGWINCH) == 0 }
}

#[cfg(not(unix))]
pub(crate) fn signal_shell(_pid: u32) -> bool {
    false
}

/// The pid to ask for a terminal whose top-level PTY child is `pid`: its
/// shell while the shell holds the terminal (itself, or the shell under
/// login(1)); `None` while a program it started runs in front.
pub(crate) fn shell_pid(pid: u32) -> Option<u32> {
    if !crate::platform::shell_holds_foreground(pid) {
        return None;
    }
    crate::platform::foreground_leader(pid)
}

/// The directory of a session whose registry lives in `registry_directory`.
pub(crate) fn directory_in(registry_directory: &Path) -> ShellStateDir {
    ShellStateDir::new(registry_directory.join(DIRECTORY))
}

#[cfg(test)]
#[path = "shell_state_tests.rs"]
mod tests;
