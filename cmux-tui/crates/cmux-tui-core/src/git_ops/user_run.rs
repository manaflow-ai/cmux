//! Runs git for `git.commit` and `git.push`: the user's own actions, so git
//! runs as it would in their terminal, with their config, hooks, filters,
//! signing, credential helper and SSH agent. Only what a daemon must never
//! do differs: wait for input or carry the daemon's git state.
//!
//! - Every inherited `GIT_*` variable is dropped (the daemon's environment
//!   never redirects or reconfigures git). Nothing is added through `-c`, so
//!   hooks see the user's config unchanged.
//! - git and its hooks run in a new session with no controlling terminal and
//!   stdin closed. `GIT_TERMINAL_PROMPT=0`, an empty `GIT_ASKPASS` (which
//!   also hides `core.askPass` and `SSH_ASKPASS`) and
//!   `SSH_ASKPASS_REQUIRE=never` stop every credential and passphrase prompt.
//! - git's own messages are in English (`LC_MESSAGES=C`) so failures can be
//!   classified; the user's other locale settings stay.
//! - One deadline covers every user run of an operation (reads through the
//!   read runner keep their own 20 s bound each; an operation makes a
//!   handful of them). Past it the session gets
//!   SIGTERM, so git removes its lock files, and SIGKILL after a short grace.
//! - Output is bounded: the first and the last 8 KiB of stderr are kept. A hook that leaves a background process holding the
//!   output pipes does not hold the reply: the pipes are read for a short
//!   grace after git exits.

use crate::supervised::{self, Fatal, ShutdownBehavior};
use cmux_threads::checked::sync as waits;
use std::collections::{BTreeMap, VecDeque};
use std::ffi::{OsStr, OsString};
use std::io::{ErrorKind, Read};
use std::path::Path;
use std::sync::{Arc, Mutex, PoisonError, mpsc};
use std::time::{Duration, Instant};

use cmux_process::{Child, Command, Stdio};

use super::run::GitFailure;

/// Hooks and a remote can be slow; a commit or push past this is stopped.
pub(super) const DEADLINE: Duration = Duration::from_secs(120);

/// The deadline of an operation that starts now.
pub(super) fn deadline() -> Instant {
    Instant::now() + DEADLINE
}
/// How long git has to remove its lock files after SIGTERM.
const TERMINATE_GRACE: Duration = Duration::from_secs(5);
/// How long the pipes are read after git exits.
const PIPE_GRACE: Duration = Duration::from_secs(2);
const MAX_STDOUT_BYTES: usize = 1024 * 1024;
/// Hook and git messages kept from stderr.
pub(super) const MAX_STDERR_BYTES: usize = 16 * 1024;

/// A finished run's exit and output, success or not: push reports per-ref
/// results on stdout even when it fails.
pub(super) struct UserRun {
    pub success: bool,
    /// The exit code; `None` when a signal ended git.
    pub code: Option<i32>,
    pub stdout: Vec<u8>,
    pub stderr: String,
}

impl UserRun {
    /// stderr, then stdout: what git and its hooks printed.
    pub(super) fn output(&self) -> String {
        let stdout = String::from_utf8_lossy(&self.stdout);
        let stdout = stdout.trim();
        match (self.stderr.is_empty(), stdout.is_empty()) {
            (_, true) => self.stderr.clone(),
            (true, false) => stdout.to_string(),
            (false, false) => format!("{}\n{stdout}", self.stderr),
        }
    }
}

/// git in one repository's top level, bounded by its operation's deadline.
pub(super) struct UserGit<'a> {
    pub root: &'a Path,
    pub deadline: Instant,
}

/// The budget of the queries that classify a refusal (which hooks exist),
/// so a run stopped at the deadline is still classified.
const CLASSIFY_BUDGET: Duration = Duration::from_secs(5);

impl UserGit<'_> {
    /// The same repository with a fresh, short budget for classifying a
    /// refusal.
    pub(super) fn for_classification(&self) -> UserGit<'_> {
        UserGit { root: self.root, deadline: Instant::now() + CLASSIFY_BUDGET }
    }

    /// Runs `git <arguments>`.
    pub(super) fn run<S: AsRef<OsStr>>(&self, arguments: &[S]) -> Result<UserRun, GitFailure> {
        self.run_with(arguments, &[])
    }

    /// Runs `git <arguments>` with `extra` set in its environment. The run
    /// may wait minutes on the user's hooks and remotes, so its work item
    /// gives back its lane slot meanwhile (`will_block`).
    pub(super) fn run_with<S: AsRef<OsStr>>(
        &self,
        arguments: &[S],
        extra: &[(&str, &str)],
    ) -> Result<UserRun, GitFailure> {
        cmux_threads::work::will_block(|| self.run_child(arguments, extra))
    }

    fn run_child<S: AsRef<OsStr>>(
        &self,
        arguments: &[S],
        extra: &[(&str, &str)],
    ) -> Result<UserRun, GitFailure> {
        let remaining = self.deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(GitFailure::TimedOut);
        }
        let mut command = Command::new("git");
        command
            .args(arguments)
            .current_dir(self.root)
            .env_clear()
            .envs(environment())
            .envs(extra.iter().copied())
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .qos_ceiling(cmux_threads::HELPER_CHILD);
        // A new session has no controlling terminal, so ssh and git cannot
        // prompt, and git leads the group the deadline stops.
        #[cfg(unix)]
        command.new_session();
        crate::request_path::note(crate::request_path::BlockingKind::ProcessSpawn);
        let mut child =
            command.spawn().map_err(|error| GitFailure::Unavailable(error.to_string()))?;
        let (Some(stdout), Some(stderr)) = (child.stdout.take(), child.stderr.take()) else {
            terminate(&mut child);
            return Err(GitFailure::Unavailable("git started without its output pipes".into()));
        };
        let stdout = Pipe::read(stdout, MAX_STDOUT_BYTES);
        let stderr = Pipe::read(stderr, MAX_STDERR_BYTES);
        let status = match child.wait_timeout(remaining) {
            Ok(Some(status)) => status,
            Ok(None) => {
                terminate(&mut child);
                return Err(GitFailure::TimedOut);
            }
            Err(error) => {
                terminate(&mut child);
                return Err(GitFailure::Unavailable(error.to_string()));
            }
        };
        let grace = Instant::now() + PIPE_GRACE;
        let stdout = stdout.collect(grace);
        let stderr = stderr.collect(grace);
        Ok(UserRun {
            success: status.success(),
            code: status.code(),
            stdout,
            stderr: String::from_utf8_lossy(&stderr).trim().to_string(),
        })
    }
}

/// The inherited environment without git state or prompts, plus the
/// settings that keep a run non-interactive.
fn environment() -> BTreeMap<OsString, OsString> {
    let mut inherited: BTreeMap<OsString, OsString> = std::env::vars_os().collect();
    inherited.retain(|name, _| {
        !name.as_encoded_bytes().starts_with(b"GIT_") && name != "SSH_ASKPASS" && name != "LANGUAGE"
    });
    // LC_ALL would override LC_MESSAGES; keep its character set.
    if let Some(all) = inherited.remove(OsStr::new("LC_ALL")) {
        inherited.entry("LC_CTYPE".into()).or_insert(all);
    }
    for (name, value) in [
        ("GIT_TERMINAL_PROMPT", "0"),
        ("GIT_ASKPASS", ""),
        ("SSH_ASKPASS_REQUIRE", "never"),
        ("GIT_EDITOR", "true"),
        ("GIT_SEQUENCE_EDITOR", "true"),
        ("GIT_PAGER", "cat"),
        ("LC_MESSAGES", "C"),
    ] {
        inherited.insert(name.into(), value.into());
    }
    inherited
}

/// SIGTERM to git's session, so git removes its lock files, then SIGKILL to
/// whatever is left once git exits or the grace ends.
fn terminate(child: &mut Child) {
    signal(child, libc_signal::TERM);
    let exited = matches!(child.wait_timeout(TERMINATE_GRACE), Ok(Some(_)));
    signal(child, libc_signal::KILL);
    if !exited {
        let _ = child.kill();
        let _ = child.wait();
    }
}

mod libc_signal {
    #[cfg(unix)]
    pub const TERM: i32 = libc::SIGTERM;
    #[cfg(unix)]
    pub const KILL: i32 = libc::SIGKILL;
    #[cfg(not(unix))]
    pub const TERM: i32 = 15;
    #[cfg(not(unix))]
    pub const KILL: i32 = 9;
}

#[cfg(unix)]
fn signal(child: &Child, signal: i32) {
    if let Ok(group) = libc::pid_t::try_from(child.id()) {
        // SAFETY: `kill` takes plain integers; the group is the session git
        // leads.
        unsafe {
            libc::kill(-group, signal);
        }
    }
}

#[cfg(not(unix))]
fn signal(child: &mut Child, _signal: i32) {
    let _ = child.kill();
}

/// One output pipe, read on its own thread. It keeps the first and the last
/// half of `limit` bytes, so a long hook output keeps its end, where the
/// error usually is.
struct Pipe {
    kept: Arc<Mutex<Kept>>,
    done: mpsc::Receiver<()>,
}

#[derive(Default)]
struct Kept {
    head: Vec<u8>,
    tail: VecDeque<u8>,
    dropped: bool,
}

impl Pipe {
    fn read(mut reader: impl Read + Send + 'static, limit: usize) -> Self {
        let kept = Arc::new(Mutex::new(Kept::default()));
        let (sender, done) = mpsc::channel();
        let buffer = Arc::clone(&kept);
        let half = limit / 2;
        // A thread that does not start drops `sender`: `collect` returns at once with nothing kept.
        let _ = supervised::spawn_at(
            "git-run-pipe",
            cmux_threads::caller_qos(cmux_threads::ThreadQos::Utility),
            Fatal,
            ShutdownBehavior::Continue,
            move || {
                let mut chunk = [0_u8; 16 * 1024];
                loop {
                    match reader.read(&mut chunk) {
                        Ok(0) => break,
                        Ok(read) => {
                            // A reader that claims more than the chunk broke Read's contract.
                            let Some(bytes) = chunk.get(..read) else { break };
                            let mut kept = buffer.lock().unwrap_or_else(PoisonError::into_inner);
                            let room = half.saturating_sub(kept.head.len());
                            let (head, rest) = bytes.split_at(read.min(room));
                            kept.head.extend_from_slice(head);
                            kept.tail.extend(rest.iter().copied());
                            while kept.tail.len() > half {
                                kept.tail.pop_front();
                                kept.dropped = true;
                            }
                        }
                        Err(error) if error.kind() == ErrorKind::Interrupted => {}
                        Err(_) => break,
                    }
                }
                let _ = sender.send(());
            },
        );
        Self { kept, done }
    }

    /// What was kept by the time the pipe closed, or by `grace`.
    fn collect(self, grace: Instant) -> Vec<u8> {
        let _ = waits::recv_timeout(&self.done, grace.saturating_duration_since(Instant::now()));
        let kept = self.kept.lock().unwrap_or_else(PoisonError::into_inner);
        let mut bytes = kept.head.clone();
        if kept.dropped {
            bytes.extend_from_slice(b"\n[...]\n");
        }
        bytes.extend(kept.tail.iter().copied());
        bytes
    }
}
