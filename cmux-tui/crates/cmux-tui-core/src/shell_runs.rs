//! Shell mode on this daemon's machine (`shell-runs-v1`): the commands a chat's `!` line runs
//! when the chat lives on this machine (a Cloud VM, an SSH host), so they run here, in the chat's
//! folder here, never on the Mac that shows the chat. The app's page sends `shell.run`,
//! `shell.read` and `shell.stop` to the app (which requires a key press or click for a run), and
//! the app forwards them as `shell-run`, `shell-read` and `shell-stop` (`server/shell_wire.rs`).
//!
//! Each command is the user's login shell running `-l -c command` in the folder, in its own
//! process group, stdin from /dev/null, stdout and stderr in one pipe, `TERM=dumb` and
//! `PAGER=cat` (output is shown as text, and no pager waits for keys). The same rules as the
//! app's own runner (`AgentPaneShell.swift`):
//!
//! - Bounded: at most [`MAX_RUNNING`] commands run per scope (one chat pane) and
//!   [`MAX_RUNNING_TOTAL`] on the daemon; each keeps the last [`MAX_BUFFER`] bytes of output;
//!   finished runs past [`MAX_KEPT`] per scope (or [`MAX_KEPT_TOTAL`] in all) are dropped oldest
//!   first. A read answers at most [`MAX_READ`] bytes.
//! - A read is a long poll: it answers when there is output after `after` or the command ended,
//!   else after [`READ_WAIT`]. At most [`MAX_WAITING_READS`] wait at once.
//! - Stop is Ctrl-C: SIGINT to the group, then SIGTERM and SIGKILL [`STOP_ESCALATION`] apart to
//!   what is left.
//! - After the shell exits its pipe may drain for [`DRAIN_AFTER_EXIT`]; a background child that
//!   keeps the pipe open does not hold the run open past it.
//! - The connection that started a run closing hangs it up (SIGHUP), as a closed terminal does;
//!   its output stays readable by id.
//!
//! Idle, nothing runs: per running command one thread blocks in `waitpid` and one in `poll` on
//! its pipe; every wait (a read's, Stop's escalation, the drain) is one condvar wait with a
//! deadline.

use std::collections::{HashMap, VecDeque};
use std::io::Read;
use std::os::fd::{AsFd, AsRawFd, OwnedFd};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use crate::panic_free::RecoverPoison;

/// The capability `identify` advertises for `shell-run`, `shell-read` and `shell-stop`.
pub(crate) const CAPABILITY: &str = "shell-runs-v1";
pub(crate) const MAX_RUNNING: usize = 4;
pub(crate) const MAX_RUNNING_TOTAL: usize = 16;
pub(crate) const MAX_KEPT: usize = 16;
pub(crate) const MAX_KEPT_TOTAL: usize = 64;
pub(crate) const MAX_BUFFER: usize = 1 << 20;
pub(crate) const MAX_READ: usize = 256 << 10;
pub(crate) const READ_WAIT: Duration = Duration::from_secs(10);
pub(crate) const MAX_WAITING_READS: usize = 32;
/// The longest command text and scope name a run takes.
pub(crate) const MAX_COMMAND_BYTES: usize = 64 << 10;
pub(crate) const MAX_SCOPE_BYTES: usize = 128;
const STOP_ESCALATION: Duration = Duration::from_secs(2);
const DRAIN_AFTER_EXIT: Duration = Duration::from_millis(250);
const PIPE_READ_BYTES: usize = 64 << 10;

/// Why a request did nothing. Answered to the app as its code (`as_str`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Refusal {
    TooMany,
    FolderMissing,
    SpawnFailed,
    UnknownRun,
    Busy,
    Invalid,
}

impl Refusal {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::TooMany => "too_many",
            Self::FolderMissing => "folder_missing",
            Self::SpawnFailed => "spawn_failed",
            Self::UnknownRun => "unknown_run",
            Self::Busy => "busy",
            Self::Invalid => "invalid",
        }
    }
}

/// How a command ended: its exit code, or the signal that ended it; neither when it is unknown.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) struct Exit {
    pub(crate) code: Option<i32>,
    pub(crate) signal: Option<i32>,
}

/// One read's answer: output from `after` (whole UTF-8 characters only while it runs), the
/// offset to read from next, whether output before `after` was dropped, and the exit once the
/// command ended and every byte was read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Chunk {
    pub(crate) output: String,
    pub(crate) next: u64,
    pub(crate) truncated: bool,
    pub(crate) exit: Option<Exit>,
}

/// What a read finds without waiting: the answer, or a permit to wait for one.
pub(crate) enum ReadStart {
    Ready(Chunk),
    Wait(WaitPermit),
}

/// One of [`MAX_WAITING_READS`]; returned when dropped.
pub(crate) struct WaitPermit {
    shared: Arc<Shared>,
}

impl Drop for WaitPermit {
    fn drop(&mut self) {
        let mut state = self.shared.state.lock().recover_poison();
        state.waiting_reads = state.waiting_reads.saturating_sub(1);
    }
}

/// The shell, home folder and environment changes runs start with; tests choose them.
#[derive(Debug, Clone)]
pub(crate) struct Config {
    pub(crate) shell: PathBuf,
    pub(crate) home: PathBuf,
}

impl Config {
    /// The daemon's own: `$SHELL` when it is an absolute executable, else bash or sh; `$HOME`.
    pub(crate) fn from_process() -> Self {
        let shell = std::env::var_os("SHELL")
            .map(PathBuf::from)
            .filter(|shell| shell.is_absolute() && is_executable(shell))
            .or_else(|| {
                ["/bin/bash", "/bin/sh"]
                    .map(PathBuf::from)
                    .into_iter()
                    .find(|shell| is_executable(shell))
            })
            .unwrap_or_else(|| PathBuf::from("/bin/sh"));
        let home =
            std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"));
        Self { shell, home }
    }
}

fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path)
        .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
}

pub(crate) struct ShellRuns {
    shared: Arc<Shared>,
    config: Config,
}

impl Default for ShellRuns {
    fn default() -> Self {
        Self::new(Config::from_process())
    }
}

struct Shared {
    state: Mutex<State>,
    changed: Condvar,
}

#[derive(Default)]
struct State {
    runs: HashMap<String, Run>,
    /// Ids oldest first.
    order: VecDeque<String>,
    waiting_reads: usize,
}

struct Run {
    scope: String,
    client: u64,
    pgid: i32,
    buffer: VecDeque<u8>,
    /// The absolute offset of `buffer`'s first byte (what was dropped before it).
    base: u64,
    exit: Option<Exit>,
    output_closed: bool,
    stopping: bool,
    /// The write end of the reader's wake pipe: dropping it ends the reader (the drain after
    /// exit gave up, or the run was dropped).
    wake: Option<OwnedFd>,
}

impl Run {
    fn end(&self) -> u64 {
        self.base + self.buffer.len() as u64
    }

    fn finished(&self) -> bool {
        self.exit.is_some() && self.output_closed
    }

    fn has_news(&self, after: u64) -> bool {
        self.end() > after || self.finished()
    }
}

impl ShellRuns {
    pub(crate) fn new(config: Config) -> Self {
        Self {
            shared: Arc::new(Shared { state: Mutex::default(), changed: Condvar::new() }),
            config,
        }
    }

    /// Starts `command` in `cwd` (the home folder when `None`; `~` and `~/…` are in it) for
    /// `scope` (one chat pane) on connection `client`, and returns its id.
    #[cfg(test)]
    pub(crate) fn run(
        &self,
        scope: &str,
        client: u64,
        command: &str,
        cwd: Option<&str>,
    ) -> Result<String, Refusal> {
        self.run_as(scope, client, command, cwd, None)
    }

    /// ``run``, under the id the caller chose (`run_` and 32 lowercase hex digits, one no run
    /// has), or a new random one when `None`. A caller that chose the id can stop the command
    /// even when the start's answer never reached it (a stalled link).
    pub(crate) fn run_as(
        &self,
        scope: &str,
        client: u64,
        command: &str,
        cwd: Option<&str>,
        chosen: Option<&str>,
    ) -> Result<String, Refusal> {
        if command.trim().is_empty()
            || command.len() > MAX_COMMAND_BYTES
            || scope.len() > MAX_SCOPE_BYTES
            || chosen.is_some_and(|id| !is_run_id(id))
        {
            return Err(Refusal::Invalid);
        }
        let folder = self.folder(cwd).ok_or(Refusal::FolderMissing)?;
        let mut state = self.shared.state.lock().recover_poison();
        let running = |scoped: bool| {
            state
                .runs
                .values()
                .filter(|run| run.exit.is_none() && (!scoped || run.scope == scope))
                .count()
        };
        if running(true) >= MAX_RUNNING || running(false) >= MAX_RUNNING_TOTAL {
            return Err(Refusal::TooMany);
        }
        let id = match chosen {
            Some(id) if state.runs.contains_key(id) => return Err(Refusal::Invalid),
            Some(id) => id.to_owned(),
            None => new_id().ok_or(Refusal::SpawnFailed)?,
        };
        let (output, input) = std::io::pipe().map_err(|_| Refusal::SpawnFailed)?;
        let (wake_reader, wake_writer) = std::io::pipe().map_err(|_| Refusal::SpawnFailed)?;
        let stderr = input.try_clone().map_err(|_| Refusal::SpawnFailed)?;
        let mut builder = cmux_process::Command::new(&self.config.shell);
        builder
            .args(["-l", "-c", command])
            .current_dir(&folder)
            .stdin(cmux_process::Stdio::null())
            .stdout(OwnedFd::from(input))
            .stderr(OwnedFd::from(stderr))
            .process_group(0)
            .env("TERM", "dumb")
            .env("PAGER", "cat")
            .env("GIT_PAGER", "cat");
        // A command is the user's, not a terminal of this daemon: it never speaks as one.
        for key in crate::daemon_env::DAEMON_OWNED_ENV_KEYS {
            builder.env_remove(key);
        }
        let child = builder.spawn().map_err(|_| Refusal::SpawnFailed)?;
        // The builder held the pipe's write ends; the reader sees EOF only once they close.
        drop(builder);
        let pgid = i32::try_from(child.id()).map_err(|_| Refusal::SpawnFailed)?;
        state.runs.insert(
            id.clone(),
            Run {
                scope: scope.to_owned(),
                client,
                pgid,
                buffer: VecDeque::new(),
                base: 0,
                exit: None,
                output_closed: false,
                stopping: false,
                wake: Some(OwnedFd::from(wake_writer)),
            },
        );
        state.order.push_back(id.clone());
        evict(&mut state, scope);
        drop(state);
        if !self.watch(&id, child, OwnedFd::from(output), OwnedFd::from(wake_reader)) {
            // No thread to reap it: end it now rather than leave it unreaped.
            signal_group(pgid, libc::SIGKILL);
            let mut state = self.shared.state.lock().recover_poison();
            state.runs.remove(&id);
            state.order.retain(|kept| *kept != id);
            return Err(Refusal::SpawnFailed);
        }
        Ok(id)
    }

    /// The pipe's reader and the exit's waiter, each on its own thread; false when one did not start.
    fn watch(
        &self,
        id: &str,
        mut child: cmux_process::Child,
        output: OwnedFd,
        wake: OwnedFd,
    ) -> bool {
        let reader_shared = self.shared.clone();
        let reader_id = id.to_owned();
        let reader = std::thread::Builder::new()
            .name("shell-run-output".into())
            .spawn(move || read_output(&reader_shared, &reader_id, output, wake));
        if reader.is_err() {
            return false;
        }
        let waiter_shared = self.shared.clone();
        let waiter_id = id.to_owned();
        let waiter = std::thread::Builder::new().name("shell-run-exit".into()).spawn(move || {
            let exit = match child.wait() {
                Ok(status) => {
                    use std::os::unix::process::ExitStatusExt;
                    Exit { code: status.code(), signal: status.signal() }
                }
                Err(_) => Exit::default(),
            };
            finish(&waiter_shared, &waiter_id, exit);
        });
        if waiter.is_err() {
            // The reader ends once the group is killed and the pipe closes.
            return false;
        }
        true
    }

    /// Output after `after` now, or a permit to wait for some ([`Self::wait_read`]).
    pub(crate) fn start_read(&self, id: &str, after: u64) -> Result<ReadStart, Refusal> {
        let mut state = self.shared.state.lock().recover_poison();
        let run = state.runs.get(id).ok_or(Refusal::UnknownRun)?;
        if run.has_news(after) {
            return Ok(ReadStart::Ready(chunk(run, after)));
        }
        if state.waiting_reads >= MAX_WAITING_READS {
            return Err(Refusal::Busy);
        }
        state.waiting_reads += 1;
        Ok(ReadStart::Wait(WaitPermit { shared: self.shared.clone() }))
    }

    /// Output after `after`, waiting up to `wait` (at most [`READ_WAIT`]) for some.
    pub(crate) fn wait_read(
        &self,
        _permit: &WaitPermit,
        id: &str,
        after: u64,
        wait: Duration,
    ) -> Result<Chunk, Refusal> {
        let deadline = Instant::now() + wait.min(READ_WAIT);
        let mut state = self.shared.state.lock().recover_poison();
        loop {
            let run = state.runs.get(id).ok_or(Refusal::UnknownRun)?;
            let now = Instant::now();
            if run.has_news(after) || now >= deadline {
                return Ok(chunk(run, after));
            }
            state = self.shared.changed.wait_timeout(state, deadline - now).recover_poison().0;
        }
    }

    /// Output after `after`, waiting up to `wait` for some (tests and in-process callers).
    #[cfg(test)]
    pub(crate) fn read(&self, id: &str, after: u64, wait: Duration) -> Result<Chunk, Refusal> {
        match self.start_read(id, after)? {
            ReadStart::Ready(chunk) => Ok(chunk),
            ReadStart::Wait(permit) => self.wait_read(&permit, id, after, wait),
        }
    }

    /// Interrupts the command's process group, as Ctrl-C in a terminal does; what ignores it is
    /// terminated, then killed. A command that already ended is left as it is.
    pub(crate) fn stop(&self, id: &str) -> Result<(), Refusal> {
        let mut state = self.shared.state.lock().recover_poison();
        let run = state.runs.get_mut(id).ok_or(Refusal::UnknownRun)?;
        if run.exit.is_some() || run.stopping {
            return Ok(());
        }
        run.stopping = true;
        let pgid = run.pgid;
        signal_group(pgid, libc::SIGINT);
        drop(state);
        let shared = self.shared.clone();
        let id = id.to_owned();
        let escalation =
            std::thread::Builder::new().name("shell-run-stop".into()).spawn(move || {
                for signal in [libc::SIGTERM, libc::SIGKILL] {
                    let deadline = Instant::now() + STOP_ESCALATION;
                    let mut state = shared.state.lock().recover_poison();
                    loop {
                        // Gone or ended: the group may no longer be this command's.
                        if state.runs.get(&id).is_none_or(|run| run.exit.is_some()) {
                            return;
                        }
                        let now = Instant::now();
                        if now >= deadline {
                            break;
                        }
                        state =
                            shared.changed.wait_timeout(state, deadline - now).recover_poison().0;
                    }
                    signal_group(pgid, signal);
                }
            });
        if escalation.is_err() {
            // No thread to escalate: kill it now rather than leave a command that ignores SIGINT.
            signal_group(pgid, libc::SIGKILL);
        }
        Ok(())
    }

    /// Connection `client` closed: its running commands get a hangup, as a closed terminal sends.
    pub(crate) fn client_left(&self, client: u64) {
        let state = self.shared.state.lock().recover_poison();
        for run in state.runs.values().filter(|run| run.client == client && run.exit.is_none()) {
            signal_group(run.pgid, libc::SIGHUP);
            signal_group(run.pgid, libc::SIGCONT);
        }
    }

    fn folder(&self, cwd: Option<&str>) -> Option<PathBuf> {
        let folder = match cwd {
            None | Some("" | "~") => self.config.home.clone(),
            Some(path) => match path.strip_prefix("~/") {
                Some(rest) => self.config.home.join(rest),
                None => PathBuf::from(path),
            },
        };
        (folder.is_absolute() && folder.is_dir()).then_some(folder)
    }

    #[cfg(test)]
    fn kept(&self) -> usize {
        self.shared.state.lock().recover_poison().runs.len()
    }
}

fn new_id() -> Option<String> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).ok()?;
    Some(format!("run_{}", bytes.iter().map(|byte| format!("{byte:02x}")).collect::<String>()))
}

/// A run id as ``new_id`` makes them: `run_` and 32 lowercase hex digits.
fn is_run_id(id: &str) -> bool {
    id.strip_prefix("run_").is_some_and(|hex| {
        hex.len() == 32 && hex.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
    })
}

fn signal_group(pgid: i32, signal: i32) {
    if pgid > 1 {
        // SAFETY: kill(2) takes plain integers; a negative pid names the process group.
        unsafe { libc::kill(-pgid, signal) };
    }
}

/// Drops finished runs, oldest first, past the scope's and the daemon's caps. Running ones stay
/// (their count is capped at the start).
fn evict(state: &mut State, scope: &str) {
    loop {
        let in_scope = state
            .order
            .iter()
            .filter(|id| state.runs.get(*id).is_some_and(|run| run.scope == scope))
            .count();
        let over_scope = in_scope > MAX_KEPT;
        if !over_scope && state.order.len() <= MAX_KEPT_TOTAL {
            return;
        }
        let victim = state.order.iter().position(|id| {
            state
                .runs
                .get(id)
                .is_some_and(|run| run.exit.is_some() && (!over_scope || run.scope == scope))
        });
        let Some(index) = victim else { return };
        if let Some(id) = state.order.remove(index) {
            state.runs.remove(&id);
        }
    }
}

fn read_output(shared: &Shared, id: &str, output: OwnedFd, wake: OwnedFd) {
    let mut file = std::fs::File::from(output);
    let mut bytes = vec![0u8; PIPE_READ_BYTES];
    loop {
        let mut fds = [
            libc::pollfd { fd: file.as_fd().as_raw_fd(), events: libc::POLLIN, revents: 0 },
            libc::pollfd { fd: wake.as_raw_fd(), events: libc::POLLIN, revents: 0 },
        ];
        // SAFETY: `fds` is a live array of two pollfd for the call's duration.
        // wakeup-allow: blocks with no timeout until the pipe has bytes or closes, or the drain gives up.
        let ready = unsafe { libc::poll(fds.as_mut_ptr(), 2, -1) };
        if ready < 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            break;
        }
        if fds[1].revents != 0 {
            break;
        }
        match file.read(&mut bytes) {
            Ok(0) => break,
            Ok(count) => append(shared, id, bytes.get(..count).unwrap_or_default()),
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => break,
        }
    }
    let mut state = shared.state.lock().recover_poison();
    if let Some(run) = state.runs.get_mut(id) {
        run.output_closed = true;
    }
    drop(state);
    shared.changed.notify_all();
}

fn append(shared: &Shared, id: &str, bytes: &[u8]) {
    let mut state = shared.state.lock().recover_poison();
    if let Some(run) = state.runs.get_mut(id) {
        run.buffer.extend(bytes);
        if run.buffer.len() > MAX_BUFFER {
            let drop = run.buffer.len() - MAX_BUFFER;
            run.buffer.drain(..drop);
            run.base += drop as u64;
        }
    }
    drop(state);
    shared.changed.notify_all();
}

/// The shell exited: record it, then give its pipe [`DRAIN_AFTER_EXIT`] to close before the
/// reader is told to stop.
fn finish(shared: &Shared, id: &str, exit: Exit) {
    let mut state = shared.state.lock().recover_poison();
    let Some(run) = state.runs.get_mut(id) else { return };
    run.exit = Some(exit);
    shared.changed.notify_all();
    let deadline = Instant::now() + DRAIN_AFTER_EXIT;
    loop {
        let Some(run) = state.runs.get_mut(id) else { return };
        if run.output_closed {
            run.wake = None;
            return;
        }
        let now = Instant::now();
        if now >= deadline {
            run.output_closed = true;
            // Closing the write end wakes the reader's poll (POLLHUP), which then lets the pipe go.
            run.wake = None;
            drop(state);
            shared.changed.notify_all();
            return;
        }
        state = shared.changed.wait_timeout(state, deadline - now).recover_poison().0;
    }
}

fn chunk(run: &Run, after: u64) -> Chunk {
    let start = after.clamp(run.base, run.end());
    let skip = usize::try_from(start - run.base).unwrap_or(usize::MAX);
    let available = run.buffer.len().saturating_sub(skip);
    let mut bytes: Vec<u8> = run.buffer.iter().skip(skip).take(MAX_READ).copied().collect();
    let complete = run.finished() && bytes.len() == available;
    if !complete {
        bytes.truncate(utf8_complete(&bytes));
    }
    Chunk {
        next: start + bytes.len() as u64,
        output: String::from_utf8_lossy(&bytes).into_owned(),
        truncated: after < run.base,
        exit: if complete { run.exit } else { None },
    }
}

/// How many leading bytes of `bytes` end on a whole UTF-8 character.
pub(crate) fn utf8_complete(bytes: &[u8]) -> usize {
    let count = bytes.len();
    for (back, &byte) in bytes.iter().rev().take(4).enumerate() {
        if byte & 0xC0 != 0x80 {
            let length = match byte {
                0x00..=0x7F => 1,
                0xF0..=0xFF => 4,
                0xE0..=0xEF => 3,
                0xC0..=0xDF => 2,
                _ => 1,
            };
            return if back + 1 >= length { count } else { count - back - 1 };
        }
    }
    count
}

#[cfg(test)]
#[path = "shell_runs/tests.rs"]
mod tests;
