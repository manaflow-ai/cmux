//! Shared PTY allocation and command spawning for cmux runtimes.
//!
//! The Unix backend avoids optional PTY device-name resolution and supports
//! descriptor-pinned working directories. Non-Unix platforms use
//! portable-pty's native backend.

// The crash ratchet keeps this crate at zero production panics
// (plans/cmux-next/crash-elimination.md section 6).
#![cfg_attr(
    not(test),
    deny(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::unreachable,
        clippy::todo,
        clippy::unimplemented,
        clippy::exit
    )
)]

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
#[cfg(unix)]
use std::fs::File;
use std::io;
#[cfg(unix)]
use std::os::fd::{FromRawFd, OwnedFd};
use std::path::{Path, PathBuf};
#[cfg(unix)]
use std::sync::Arc;

pub use portable_pty::{Child, ChildKiller, ExitStatus, MasterPty, PtySize};

#[cfg(all(test, unix))]
mod env_tests;
#[cfg(target_vendor = "apple")]
mod input_queue;
#[cfg(unix)]
mod macos;
#[cfg(unix)]
mod open_files;
#[cfg(unix)]
pub use open_files::{
    OPEN_FILE_LIMIT_CEILING, OpenFileLimit, original_open_file_limit, raise_open_file_limit,
    restore_open_file_limit, restore_open_file_limit_in_child,
};

/// Stable classification for failures at the PTY allocation boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PtyOpenErrorKind {
    /// The operating system cannot allocate another PTY or required file
    /// descriptor until existing resources are released.
    CapacityExhausted,
    /// The operating system rejected PTY allocation for another reason.
    Other,
}

/// A PTY allocation failure that preserves both its machine-readable class
/// and the original operating-system error.
#[derive(Debug)]
pub struct PtyOpenError {
    kind: PtyOpenErrorKind,
    source: io::Error,
}

impl PtyOpenError {
    pub fn from_io(source: io::Error) -> Self {
        let kind = if is_capacity_exhaustion(&source) {
            PtyOpenErrorKind::CapacityExhausted
        } else {
            PtyOpenErrorKind::Other
        };
        Self { kind, source }
    }

    pub fn kind(&self) -> PtyOpenErrorKind {
        self.kind
    }

    pub fn is_capacity_exhausted(&self) -> bool {
        self.kind == PtyOpenErrorKind::CapacityExhausted
    }
}

impl fmt::Display for PtyOpenError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.kind {
            PtyOpenErrorKind::CapacityExhausted => write!(
                f,
                "PTY capacity exhausted; close unused terminals or tmux sessions and retry: {}",
                self.source
            ),
            PtyOpenErrorKind::Other => write!(f, "failed to open PTY: {}", self.source),
        }
    }
}

impl std::error::Error for PtyOpenError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(&self.source)
    }
}

#[cfg(unix)]
fn is_capacity_exhaustion(error: &io::Error) -> bool {
    matches!(
        error.raw_os_error(),
        Some(libc::ENXIO | libc::ENOSPC | libc::EMFILE | libc::ENFILE | libc::EAGAIN)
    )
}

#[cfg(not(unix))]
fn is_capacity_exhaustion(error: &io::Error) -> bool {
    matches!(error.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::OutOfMemory)
}

/// The terminal identity every cmux terminal child gets, whatever the daemon
/// inherited or a caller passed: `echo $TERM_PROGRAM` says `cmux`, and
/// `TERM_PROGRAM_VERSION` is cmux's version (the workspace version every
/// bundled CLI carries). Every path that starts a terminal child sets these
/// after the command's own values ([`PtyCommand::env`] or the spelled-out
/// environment map), so they win over a daemon that started with Ghostty's
/// identity (a Cloud daemon) and over an older app's launch env.
///
/// `TERM` stays `xterm-256color` (or the opted-in `xterm-ghostty`), and
/// `COLORTERM=truecolor` and `GHOSTTY_RESOURCES_DIR` stay as they were, so
/// programs that query the terminal (XTVERSION still answers `ghostty`, the
/// kitty keyboard protocol, synchronized output) or read those keep working.
/// Claude Code and Codex key Ghostty features on `TERM_PROGRAM=ghostty`, and a
/// Ghostty version turns off their copy-on-select fallback (cmux#22585), so
/// their wrappers start them with `TERM_PROGRAM=ghostty` and no version
/// (`cmux-tui` `agent_terminal_identity`).
pub const TERMINAL_IDENTITY: [(&str, &str); 2] =
    [("TERM_PROGRAM", "cmux"), ("TERM_PROGRAM_VERSION", env!("CARGO_PKG_VERSION"))];

impl PtyCommand {
    /// Sets [`TERMINAL_IDENTITY`] on this command, over any earlier value.
    pub fn terminal_identity(&mut self) {
        for (key, value) in TERMINAL_IDENTITY {
            self.env(key, value);
        }
    }
}

/// The subset of process configuration needed by both cmux PTY runtimes.
#[derive(Debug, Clone)]
pub struct PtyCommand {
    program: String,
    args: Vec<String>,
    cwd: Option<PathBuf>,
    #[cfg(unix)]
    cwd_descriptor: Option<Arc<File>>,
    environment: BTreeMap<String, String>,
    /// Keys the child must not have, applied after `environment`, so an
    /// inherited value is dropped as well as a set one.
    removed_environment: BTreeSet<String>,
    clean_environment: bool,
}

impl PtyCommand {
    pub fn new(program: impl Into<String>) -> Self {
        Self {
            program: program.into(),
            args: Vec::new(),
            cwd: None,
            #[cfg(unix)]
            cwd_descriptor: None,
            environment: BTreeMap::new(),
            removed_environment: BTreeSet::new(),
            clean_environment: false,
        }
    }

    pub fn args<I, S>(&mut self, args: I)
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.args.extend(args.into_iter().map(Into::into));
    }

    pub fn cwd(&mut self, cwd: impl AsRef<Path>) {
        self.cwd = Some(cwd.as_ref().to_owned());
        #[cfg(unix)]
        {
            self.cwd_descriptor = None;
        }
    }

    #[cfg(unix)]
    pub fn cwd_descriptor(&mut self, directory: File) {
        self.cwd = None;
        self.cwd_descriptor = Some(Arc::new(directory));
    }

    pub fn env(&mut self, key: impl Into<String>, value: impl Into<String>) {
        let key = key.into();
        self.removed_environment.remove(&key);
        self.environment.insert(key, value.into());
    }

    /// The child must not see `key`, whether this command set it or the
    /// parent would pass it down. Wins over an earlier [`Self::env`] of the
    /// same key; a later `env` wins over this.
    pub fn env_remove(&mut self, key: impl Into<String>) {
        let key = key.into();
        self.environment.remove(&key);
        self.removed_environment.insert(key);
    }

    pub fn env_clear(&mut self) {
        self.clean_environment = true;
        self.environment.clear();
    }
}

/// An allocated PTY whose slave has not yet spawned its child.
pub struct PtyPair {
    master: Box<dyn MasterPty + Send>,
    slave: platform::Slave,
}

impl PtyPair {
    /// Duplicate the master descriptor before spawning so a reader can poll
    /// its own owned descriptor without borrowing a handle that another
    /// thread may close. `F_DUPFD_CLOEXEC` keeps the duplicate out of child
    /// exec environments without a descriptor-inheritance race.
    #[cfg(unix)]
    pub fn try_clone_reader_descriptor(&self) -> anyhow::Result<OwnedFd> {
        let source = self
            .master
            .as_raw_fd()
            .ok_or_else(|| anyhow::anyhow!("PTY master does not expose a reader descriptor"))?;
        loop {
            // SAFETY: `source` is owned by this still-live PTY pair. The
            // successful fcntl call returns a new descriptor we immediately
            // wrap in OwnedFd.
            let descriptor = unsafe { libc::fcntl(source, libc::F_DUPFD_CLOEXEC, 0) };
            if descriptor >= 0 {
                // SAFETY: ownership transfers from fcntl to OwnedFd exactly
                // once on a successful call.
                return Ok(unsafe { OwnedFd::from_raw_fd(descriptor) });
            }
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(anyhow::anyhow!("failed to duplicate PTY reader: {error}"));
        }
    }

    /// Spawn the command, close the parent's slave descriptor, and return the
    /// master and child as one ownership-safe unit.
    pub fn spawn(self, command: PtyCommand) -> anyhow::Result<SpawnedPty> {
        if command.program.trim().is_empty() {
            anyhow::bail!("PTY command program must not be empty");
        }
        let Self { master, slave } = self;
        let child = platform::spawn(&slave, command)?;
        drop(slave);
        Ok(SpawnedPty { master, child })
    }
}

pub struct SpawnedPty {
    pub master: Box<dyn MasterPty + Send>,
    pub child: Box<dyn Child + Send + Sync>,
}

#[cfg(windows)]
pub mod windows_jobs;

pub fn open(size: PtySize) -> anyhow::Result<PtyPair> {
    let (master, slave) = platform::open(size)?;
    Ok(PtyPair { master, slave })
}

/// Wrap an inherited PTY master, for example one received from a process
/// that held it, as a master of a session this process did not spawn. Its
/// writer never sends end-of-file to that session when dropped.
#[cfg(unix)]
pub fn adopt_master(master: OwnedFd) -> anyhow::Result<Box<dyn MasterPty + Send>> {
    macos::adopt_master(master)
}

#[cfg(unix)]
mod platform {
    pub(crate) use super::macos::{Slave, open, spawn};
}

#[cfg(not(unix))]
mod platform {
    use portable_pty::{CommandBuilder, SlavePty, native_pty_system};

    use super::{Child, MasterPty, PtyCommand, PtySize};

    pub(crate) struct Slave(Box<dyn SlavePty + Send>);

    pub(crate) fn open(size: PtySize) -> anyhow::Result<(Box<dyn MasterPty + Send>, Slave)> {
        let pair = native_pty_system().openpty(size)?;
        Ok((pair.master, Slave(pair.slave)))
    }

    pub(crate) fn spawn(
        slave: &Slave,
        command: PtyCommand,
    ) -> anyhow::Result<Box<dyn Child + Send + Sync>> {
        let mut builder = CommandBuilder::new(command.program);
        if command.clean_environment {
            builder.env_clear();
        }
        builder.args(command.args);
        if let Some(cwd) = command.cwd {
            builder.cwd(cwd);
        }
        for (key, value) in command.environment {
            builder.env(key, value);
        }
        for key in command.removed_environment {
            builder.env_remove(key);
        }
        let child = slave.0.spawn_command(builder)?;
        Ok(Box::new(super::windows_jobs::JobChild::new(child)))
    }
}

#[cfg(all(test, unix))]
mod tests;
