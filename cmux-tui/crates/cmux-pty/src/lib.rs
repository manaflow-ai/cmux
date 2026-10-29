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

/// Environment keys no cmux terminal child may see, whatever the daemon
/// inherited or a caller passed. Every path that starts a terminal child
/// applies these: pass them to [`PtyCommand::env_remove`] after the command's
/// own values, or drop them from a spelled-out environment map.
///
/// `TERM_PROGRAM_VERSION`: cmux keeps `TERM_PROGRAM=ghostty` so a child
/// detects a Ghostty-class terminal, but cmux forwards a full-screen TUI's
/// mouse reports instead of providing Ghostty's native selection, so a child
/// that reads a Ghostty version turns its own copy-on-select drag fallback
/// off (cmux#22585: Codex and Claude lose drag-to-copy). The daemon's own
/// environment carries it (`cmux-host::daemon_spec`), which is why every
/// child path has to drop it rather than merely not set it.
pub const UNSET_IN_TERMINAL_CHILDREN: &[&str] = &["TERM_PROGRAM_VERSION"];

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
mod tests {
    use std::error::Error as _;
    use std::fs::File;
    use std::io;
    use std::os::fd::{AsRawFd, FromRawFd};

    use super::*;

    /// A PTY child starts with default dispositions and an empty signal
    /// mask even when its parent ignores or blocks signals (a terminal host
    /// ignores HUP, INT and QUIT for itself). Ignored dispositions and the
    /// mask survive `exec`, so without the reset a shell would not die on a
    /// hangup or Ctrl-C. The probe runs in a re-executed copy of this test
    /// binary, so the parent-side SIG_IGN never touches other tests.
    ///
    /// The PTY child is a third copy of this binary that reads its own
    /// dispositions (`sigaction`) and mask (`pthread_sigmask`) and prints
    /// them as two hex bit sets. `ps -o ignored=,blocked=` cannot do this on
    /// macOS: its ps has no `ignored` keyword and prints its keyword list.
    #[test]
    fn a_pty_child_gets_default_signals_and_an_empty_mask_from_an_ignoring_parent()
    -> Result<(), Box<dyn std::error::Error>> {
        const PROBE: &str = "CMUX_PTY_SIGNAL_PROBE";
        const REPORT: &str = "CMUX_PTY_SIGNAL_REPORT";
        const NAME: &str =
            "tests::a_pty_child_gets_default_signals_and_an_empty_mask_from_an_ignoring_parent";
        let bit = |signal: libc::c_int| 1u64 << (signal - 1);
        if std::env::var_os(REPORT).is_some() {
            let (mut ignored, mut blocked) = (0u64, 0u64);
            // SAFETY: query-only sigaction and pthread_sigmask calls on
            // this process; null new-action and new-set pointers change
            // nothing.
            unsafe {
                let mut mask = std::mem::MaybeUninit::<libc::sigset_t>::uninit();
                libc::sigemptyset(mask.as_mut_ptr());
                assert_eq!(
                    libc::pthread_sigmask(libc::SIG_BLOCK, std::ptr::null(), mask.as_mut_ptr()),
                    0
                );
                // SIGKILL and SIGSTOP cannot be ignored, and macOS refuses
                // even a query of them with EINVAL.
                for signal in (1..32).filter(|&s| s != libc::SIGKILL && s != libc::SIGSTOP) {
                    let mut action = std::mem::MaybeUninit::<libc::sigaction>::zeroed();
                    assert_eq!(libc::sigaction(signal, std::ptr::null(), action.as_mut_ptr()), 0);
                    if action.assume_init().sa_sigaction == libc::SIG_IGN {
                        ignored |= bit(signal);
                    }
                    if libc::sigismember(mask.as_ptr(), signal) == 1 {
                        blocked |= bit(signal);
                    }
                }
            }
            println!("probe: {ignored:x} {blocked:x}");
            return Ok(());
        }
        if std::env::var_os(PROBE).is_some() {
            // SAFETY: SIG_IGN and sigprocmask on this probe process only.
            unsafe {
                for signal in [libc::SIGHUP, libc::SIGINT, libc::SIGQUIT, libc::SIGTERM] {
                    libc::signal(signal, libc::SIG_IGN);
                }
                let mut set = std::mem::MaybeUninit::<libc::sigset_t>::uninit();
                libc::sigemptyset(set.as_mut_ptr());
                libc::sigaddset(set.as_mut_ptr(), libc::SIGHUP);
                libc::pthread_sigmask(libc::SIG_BLOCK, set.as_ptr(), std::ptr::null_mut());
            }
            let pair = open(PtySize { rows: 24, cols: 120, pixel_width: 0, pixel_height: 0 })?;
            let mut command = PtyCommand::new(std::env::current_exe()?.to_string_lossy());
            command.args(["--exact", NAME, "--nocapture", "--test-threads=1"]);
            command.env(REPORT, "1");
            let mut spawned = pair.spawn(command)?;
            let mut reader = spawned.master.try_clone_reader()?;
            let mut output = Vec::new();
            let mut buffer = [0u8; 4096];
            while let Ok(count) = io::Read::read(&mut reader, &mut buffer) {
                if count == 0 {
                    break;
                }
                output.extend_from_slice(&buffer[..count]);
                if output.windows(6).any(|w| w == b"probe:") && output.ends_with(b"\n") {
                    break;
                }
            }
            let _ = spawned.child.wait();
            println!("{}", String::from_utf8_lossy(&output).trim());
            return Ok(());
        }
        let output = std::process::Command::new(std::env::current_exe()?)
            .args(["--exact", NAME, "--nocapture", "--test-threads=1"])
            .env(PROBE, "1")
            .output()?;
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        let line = stdout
            .lines()
            .find_map(|line| line.split("probe:").nth(1))
            .ok_or_else(|| format!("probe printed no masks: {stdout}{stderr}"))?;
        let masks = line
            .split_whitespace()
            .map(|hex| u64::from_str_radix(hex.trim_start_matches("0x"), 16))
            .collect::<Result<Vec<_>, _>>()?;
        assert_eq!(masks.len(), 2, "{line}");
        let (ignored, blocked) = (masks[0], masks[1]);
        let reset = [libc::SIGHUP, libc::SIGINT, libc::SIGQUIT, libc::SIGTERM];
        let reset = reset.into_iter().fold(0, |mask, signal| mask | bit(signal));
        assert_eq!(ignored & reset, 0, "child ignores {line}");
        assert_eq!(blocked, 0, "child blocks signals: {line}");
        Ok(())
    }

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
    fn empty_program_is_rejected_before_platform_spawn() {
        let pair = open(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 }).unwrap();
        let error = match pair.spawn(PtyCommand::new("")) {
            Ok(_) => panic!("empty PTY program was spawned"),
            Err(error) => error,
        };
        assert!(error.to_string().contains("program must not be empty"));
    }

    #[test]
    fn whitespace_only_program_is_rejected_before_platform_spawn() {
        let pair = open(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 }).unwrap();
        let error = match pair.spawn(PtyCommand::new(" \t\n")) {
            Ok(_) => panic!("whitespace-only PTY program was spawned"),
            Err(error) => error,
        };
        assert!(error.to_string().contains("program must not be empty"));
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
