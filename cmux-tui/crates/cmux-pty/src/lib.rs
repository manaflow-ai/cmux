//! Shared PTY allocation and command spawning for cmux runtimes.
//!
//! The Unix backend avoids optional PTY device-name resolution and supports
//! descriptor-pinned working directories. Non-Unix platforms use
//! portable-pty's native backend.

use std::collections::BTreeMap;
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

#[cfg(unix)]
mod macos;

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

/// The subset of process configuration needed by both cmux PTY runtimes.
#[derive(Debug, Clone)]
pub struct PtyCommand {
    program: String,
    args: Vec<String>,
    cwd: Option<PathBuf>,
    #[cfg(unix)]
    cwd_descriptor: Option<Arc<File>>,
    environment: BTreeMap<String, String>,
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
        self.environment.insert(key.into(), value.into());
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

pub fn open(size: PtySize) -> anyhow::Result<PtyPair> {
    let (master, slave) = platform::open(size)?;
    Ok(PtyPair { master, slave })
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
        slave.0.spawn_command(builder)
    }
}

#[cfg(all(test, unix))]
mod tests {
    use std::error::Error as _;
    use std::fs::File;
    use std::io;
    use std::os::fd::{AsRawFd, FromRawFd};

    use super::*;

    #[test]
    fn pty_capacity_errors_preserve_an_actionable_classification() {
        for errno in [libc::ENXIO, libc::ENOSPC, libc::EMFILE, libc::ENFILE, libc::EAGAIN] {
            let error = PtyOpenError::from_io(io::Error::from_raw_os_error(errno));
            assert_eq!(error.kind(), PtyOpenErrorKind::CapacityExhausted);
            assert!(error.is_capacity_exhausted());
            assert!(error.to_string().contains("PTY capacity exhausted"));
            assert!(error.source().is_some());
        }
    }

    #[test]
    fn unrelated_pty_open_errors_remain_distinguishable() {
        let error = PtyOpenError::from_io(io::Error::from_raw_os_error(libc::EBADF));
        assert_eq!(error.kind(), PtyOpenErrorKind::Other);
        assert!(!error.is_capacity_exhausted());
        assert!(error.to_string().contains("failed to open PTY"));
    }

    #[test]
    fn missing_program_fails_before_the_child_is_published() {
        let pair = open(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 }).unwrap();
        let result = pair.spawn(PtyCommand::new("/definitely/missing/cmux-pty-program"));

        if let Ok(mut spawned) = result {
            let status = spawned.child.wait().unwrap();
            panic!("missing PTY program was published as child status {status:?}");
        }
    }

    #[test]
    fn successful_exec_does_not_inherit_unmarked_parent_descriptors() {
        let source = File::open("/dev/null").unwrap();
        let descriptor = unsafe { libc::fcntl(source.as_raw_fd(), libc::F_DUPFD, 200) };
        assert!(descriptor >= 200);
        let inherited = unsafe { File::from_raw_fd(descriptor) };
        let flags = unsafe { libc::fcntl(inherited.as_raw_fd(), libc::F_GETFD) };
        assert_eq!(flags & libc::FD_CLOEXEC, 0);

        let pair = open(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 }).unwrap();
        let mut command = PtyCommand::new("/bin/sh");
        command.args(["-c", &format!("test ! -e /dev/fd/{descriptor}")]);
        let mut spawned = pair.spawn(command).unwrap();
        let status = spawned.child.wait().unwrap();

        assert!(status.success(), "child inherited parent descriptor {descriptor}: {status:?}");
        let parent_flags = unsafe { libc::fcntl(inherited.as_raw_fd(), libc::F_GETFD) };
        assert_eq!(
            parent_flags & libc::FD_CLOEXEC,
            0,
            "child cleanup changed the parent descriptor"
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn close_range_seccomp_fallback_keeps_pty_spawn_working() {
        const CHILD_ENV: &str = "CMUX_PTY_CLOSE_RANGE_SECCOMP_CHILD";
        if std::env::var_os(CHILD_ENV).is_none() {
            let output = std::process::Command::new(std::env::current_exe().unwrap())
                .arg("tests::close_range_seccomp_fallback_keeps_pty_spawn_working")
                .arg("--exact")
                .arg("--nocapture")
                .env(CHILD_ENV, "1")
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "PTY spawn failed when seccomp denied close_range:\nstdout:\n{}\nstderr:\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            return;
        }

        install_close_range_eperm_filter();
        let pair = open(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 }).unwrap();
        let mut command = PtyCommand::new("/bin/sh");
        command.args(["-c", "exit 0"]);
        let mut spawned = pair.spawn(command).expect("seccomp-compatible PTY spawn");
        assert!(spawned.child.wait().unwrap().success());
    }

    #[cfg(target_os = "linux")]
    fn install_close_range_eperm_filter() {
        let mut filter = [
            libc::sock_filter {
                code: (libc::BPF_LD | libc::BPF_W | libc::BPF_ABS) as u16,
                jt: 0,
                jf: 0,
                k: 0,
            },
            libc::sock_filter {
                code: (libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K) as u16,
                jt: 0,
                jf: 1,
                k: libc::SYS_close_range as u32,
            },
            libc::sock_filter {
                code: (libc::BPF_RET | libc::BPF_K) as u16,
                jt: 0,
                jf: 0,
                k: libc::SECCOMP_RET_ERRNO | libc::EPERM as u32,
            },
            libc::sock_filter {
                code: (libc::BPF_RET | libc::BPF_K) as u16,
                jt: 0,
                jf: 0,
                k: libc::SECCOMP_RET_ALLOW,
            },
        ];
        let program = libc::sock_fprog { len: filter.len() as u16, filter: filter.as_mut_ptr() };

        let no_new_privileges = unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) };
        assert_eq!(
            no_new_privileges,
            0,
            "PR_SET_NO_NEW_PRIVS failed: {}",
            io::Error::last_os_error()
        );
        let installed = unsafe {
            libc::prctl(
                libc::PR_SET_SECCOMP,
                libc::SECCOMP_MODE_FILTER,
                &program as *const libc::sock_fprog,
            )
        };
        assert_eq!(
            installed,
            0,
            "seccomp filter installation failed: {}",
            io::Error::last_os_error()
        );
    }
}
