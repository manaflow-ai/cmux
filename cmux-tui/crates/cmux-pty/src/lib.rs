//! Shared PTY allocation and command spawning for cmux runtimes.
//!
//! The Unix backend avoids optional PTY device-name resolution and supports
//! descriptor-pinned working directories. Non-Unix platforms use
//! portable-pty's native backend.

// Threads start through cmux_threads (named, registered, at a declared QoS):
// plans/cmux-next/chrome-parity/p02-threads.md, tasks 213-218.
#![cfg_attr(not(test), deny(clippy::disallowed_methods))]
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

#[cfg(any(windows, test))]
mod console_ctrl_c;
pub mod input_queue;
#[cfg(unix)]
mod macos;
#[cfg(unix)]
mod open_files;
#[cfg(unix)]
pub use macos::NativePtyChild;
#[cfg(unix)]
pub use open_files::{
    OPEN_FILE_LIMIT_CEILING, OpenFileLimit, original_open_file_limit, raise_open_file_limit,
    restore_open_file_limit,
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
        // The child inherits the spawning process's ignore-Ctrl+C attribute,
        // which a CREATE_NEW_PROCESS_GROUP start sets; clear it so Ctrl+C in
        // the terminal reaches the child (console_ctrl_c.rs).
        super::console_ctrl_c::set_for_the_next_child().map_err(|error| {
            anyhow::anyhow!("failed to let the terminal's child process Ctrl+C: {error}")
        })?;
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
        let output = cmux_process::Command::new(std::env::current_exe()?)
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

    /// A `/bin/sleep 30` spawned on a new PTY.
    fn spawn_sleeper() -> SpawnedPty {
        let pair = open(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 }).unwrap();
        let mut command = PtyCommand::new("/bin/sleep");
        command.args(["30"]);
        pair.spawn(command).unwrap()
    }

    /// macOS: a PTY child spawned from a UserInteractive thread runs at
    /// QOS_CLASS_DEFAULT, not the thread's class (p02-threads task 223), and
    /// the thread keeps its class.
    #[cfg(target_vendor = "apple")]
    #[test]
    fn a_pty_child_of_a_user_interactive_thread_runs_at_default() {
        use cmux_threads::process::probe;
        use cmux_threads::{LiveQos, QosChange, ThreadQos, current, set_current};

        let default = probe::base_priority_at(ThreadQos::Default).unwrap();
        let interactive = probe::base_priority_at(ThreadQos::UserInteractive).unwrap();
        assert_ne!(default, interactive);
        let child = std::thread::spawn(|| {
            assert_eq!(set_current(ThreadQos::UserInteractive), QosChange::Applied);
            let mut spawned = spawn_sleeper();
            let pid = spawned.child.process_id().unwrap() as libc::pid_t;
            let priority = probe::first_thread_base_priority(pid);
            spawned.child.kill().unwrap();
            let _ = spawned.child.wait();
            assert_eq!(current(), LiveQos::Class(ThreadQos::UserInteractive));
            priority.unwrap()
        })
        .join()
        .unwrap();
        assert_eq!(child, default, "child {child}: default {default}, ui {interactive}");
    }

    /// Linux: a PTY child keeps the spawning thread's nice value, as before.
    #[cfg(target_os = "linux")]
    #[test]
    fn a_pty_child_keeps_the_threads_nice_value_on_linux() {
        let nice_of = |pid: libc::pid_t| {
            // SAFETY: the raw syscall returns 20 - nice (1..=40).
            let raw = unsafe {
                libc::syscall(libc::SYS_getpriority, libc::PRIO_PROCESS, pid as libc::c_long)
            };
            assert!(raw > 0, "getpriority({pid}): {}", io::Error::last_os_error());
            20 - raw as i32
        };
        std::thread::spawn(move || {
            // SAFETY: gettid has no preconditions.
            let tid = unsafe { libc::gettid() };
            let mut spawned = spawn_sleeper();
            let pid = spawned.child.process_id().unwrap() as libc::pid_t;
            let (parent, child) = (nice_of(tid), nice_of(pid));
            spawned.child.kill().unwrap();
            let _ = spawned.child.wait();
            assert_eq!(child, parent);
        })
        .join()
        .unwrap();
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
            let output = cmux_process::Command::new(std::env::current_exe().unwrap())
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

    /// Read the PTY until `marker` appears or the child's side closes.
    fn read_until(reader: &mut dyn io::Read, marker: &str) -> String {
        let mut output = Vec::new();
        let mut buffer = [0u8; 1024];
        while !String::from_utf8_lossy(&output).contains(marker) {
            match reader.read(&mut buffer) {
                Ok(0) | Err(_) => break,
                Ok(count) => output.extend_from_slice(&buffer[..count]),
            }
        }
        String::from_utf8_lossy(&output).into_owned()
    }

    /// The PTY is its child's controlling terminal, with the child's group in
    /// the foreground, so the 0x03 Ctrl-C writes makes the line discipline
    /// send SIGINT to the child (dogfood chrome-parity-v1 on macOS: "ctrl c
    /// is broken"). The child is a copy of this test binary that reports its
    /// own terminal (`tcgetpgrp(0)`, -1 when its session has no controlling
    /// terminal) and then waits to be interrupted; it opens no terminal
    /// itself, as zsh does not (zsh opens its tty with O_NOCTTY, and then runs
    /// with no job control and no Ctrl-C). A thread drains the PTY all along,
    /// as the daemon does: a session leader that exits waits for its terminal's
    /// output (the `^C` echo) to drain.
    #[test]
    fn a_pty_child_has_the_pty_as_controlling_terminal_and_gets_sigint_from_ctrl_c() {
        const CHILD: &str = "CMUX_PTY_CTTY_CHILD";
        const NAME: &str =
            "tests::a_pty_child_has_the_pty_as_controlling_terminal_and_gets_sigint_from_ctrl_c";
        if std::env::var_os(CHILD).is_some() {
            // SAFETY: plain queries of this process and its fd 0.
            let (pid, pgrp, foreground) =
                unsafe { (libc::getpid(), libc::getpgrp(), libc::tcgetpgrp(0)) };
            println!("ctty-report pid={pid} pgrp={pgrp} foreground={foreground} end");
            // test harness: wait for the parent's Ctrl-C (SIGINT ends this process)
            std::thread::sleep(std::time::Duration::from_secs(30));
            return;
        }
        let pair = open(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 }).unwrap();
        let mut command = PtyCommand::new(std::env::current_exe().unwrap().to_string_lossy());
        command.args(["--exact", NAME, "--nocapture", "--test-threads=1"]);
        command.env(CHILD, "1");
        let mut spawned = pair.spawn(command).unwrap();
        let pid = spawned.child.process_id().unwrap() as libc::pid_t;
        let mut reader = spawned.master.try_clone_reader().unwrap();
        let (report_tx, report_rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut output = Vec::new();
            let mut buffer = [0u8; 1024];
            let mut sent = false;
            loop {
                match reader.read(&mut buffer) {
                    Ok(0) | Err(_) => break,
                    Ok(count) => output.extend_from_slice(&buffer[..count]),
                }
                let text = String::from_utf8_lossy(&output);
                if !sent && let Some(line) = text.lines().find(|line| line.contains(" end")) {
                    sent = true;
                    let _ = report_tx.send(line.to_string());
                }
            }
        });
        let report = report_rx
            .recv_timeout(std::time::Duration::from_secs(30))
            .expect("the child never reported its terminal");

        let mut writer = spawned.master.take_writer().unwrap();
        writer.write_all(b"\x03").unwrap();
        writer.flush().unwrap();
        let child: &mut dyn Child = &mut *spawned.child;
        let child = child.downcast_mut::<NativePtyChild>().expect("a native PTY child");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        let status = loop {
            if let Some(status) = child.try_wait_native().unwrap() {
                break Some(status);
            }
            if std::time::Instant::now() >= deadline {
                break None;
            }
            // test harness: poll the child's end for a bounded time
            std::thread::sleep(std::time::Duration::from_millis(20));
        };
        if status.is_none() {
            let _ = spawned.child.kill();
        }
        use std::os::unix::process::ExitStatusExt as _;
        assert!(
            report.contains(&format!("pid={pid} pgrp={pid} foreground={pid} ")),
            "the PTY is not the child's controlling terminal with its group in the foreground: \
             {report}"
        );
        assert_eq!(
            status.and_then(|status| status.signal()),
            Some(libc::SIGINT),
            "Ctrl-C (0x03) did not interrupt the PTY child: {status:?}; {report}"
        );
    }

    /// `kill` of a child that ignores the hangup: SIGHUP, then SIGKILL
    /// after the grace, so the child ends anyway.
    #[test]
    fn kill_ends_a_child_that_ignores_the_hangup() {
        let pair = open(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 }).unwrap();
        let mut command = PtyCommand::new("/bin/sh");
        command.args(["-c", "trap '' HUP; echo ready; exec sleep 30"]);
        let mut spawned = pair.spawn(command).unwrap();
        let mut reader = spawned.master.try_clone_reader().unwrap();
        assert!(read_until(&mut *reader, "ready").contains("ready"));

        let started = std::time::Instant::now();
        spawned.child.kill().unwrap();
        let status = spawned.child.wait().unwrap();
        assert!(!status.success(), "{status:?}");
        assert!(started.elapsed() < std::time::Duration::from_secs(10), "{:?}", started.elapsed());
    }

    /// `kill` of a child that dies of the hangup returns once it ended.
    #[test]
    fn kill_ends_a_child_on_the_hangup() {
        let pair = open(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 }).unwrap();
        let mut command = PtyCommand::new("/bin/sh");
        command.args(["-c", "echo ready; exec sleep 30"]);
        let mut spawned = pair.spawn(command).unwrap();
        let mut reader = spawned.master.try_clone_reader().unwrap();
        assert!(read_until(&mut *reader, "ready").contains("ready"));

        spawned.child.kill().unwrap();
        let status = spawned.child.try_wait().unwrap().expect("the child ended within the kill");
        assert!(!status.success(), "{status:?}");
    }

    /// After the daemon raised its open-file limit, a shell it starts on a
    /// PTY gets the limit the daemon started with (Linux: setrlimit in the
    /// child; macOS: the `ulimit` launcher). Runs in a re-executed copy of
    /// this test binary, so the lowered and raised limits stay there.
    #[test]
    fn a_pty_child_gets_the_open_file_limit_from_before_the_raise() {
        const CHILD: &str = "CMUX_PTY_OPEN_FILE_LIMIT_CHILD";
        const NAME: &str = "tests::a_pty_child_gets_the_open_file_limit_from_before_the_raise";
        if std::env::var_os(CHILD).is_none() {
            let output = cmux_process::Command::new(std::env::current_exe().unwrap())
                .args([NAME, "--exact", "--nocapture"])
                .env(CHILD, "1")
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "{NAME} failed in its own process:\nstdout:\n{}\nstderr:\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            return;
        }
        let mut limit = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
        // SAFETY: valid storage for one rlimit; only this re-run process
        // changes its soft limit.
        unsafe {
            assert_eq!(libc::getrlimit(libc::RLIMIT_NOFILE, &raw mut limit), 0);
            assert!(limit.rlim_max >= 1_024, "hard limit {}", limit.rlim_max);
            limit.rlim_cur = 200;
            assert_eq!(libc::setrlimit(libc::RLIMIT_NOFILE, &raw const limit), 0);
        }
        let raised = raise_open_file_limit(1_024).unwrap();
        assert_eq!(raised, OpenFileLimit { before: 200, after: 1_024 });
        assert_eq!(original_open_file_limit(), Some(200));

        let pair = open(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 }).unwrap();
        let mut command = PtyCommand::new("/bin/sh");
        command.args(["-c", "echo limit=$(ulimit -S -n)."]);
        let mut spawned = pair.spawn(command).unwrap();
        let mut reader = spawned.master.try_clone_reader().unwrap();
        let output = read_until(&mut *reader, ".");
        assert!(spawned.child.wait().unwrap().success());
        assert!(output.contains("limit=200."), "{output}");
    }
}

#[cfg(all(test, windows))]
mod windows_tests {
    use std::io::{Read, Write};
    use std::sync::mpsc::{self, RecvTimeoutError};
    use std::time::{Duration, Instant};

    use super::*;

    const NAME: &str = "windows_tests::a_pty_child_processes_ctrl_c_from_a_spawner_that_ignores_it";
    const PROBE: &str = "CMUX_PTY_CTRL_C_PROBE";
    const SLEEPER: &str = "CMUX_PTY_CTRL_C_SLEEPER";
    /// The exit code of a process the default Ctrl+C handler ended.
    const STATUS_CONTROL_C_EXIT: u32 = 0xC000_013A;

    /// A 0x03 written to the terminal ends its child even when the spawning
    /// process ignores Ctrl+C. The probe runs in a re-executed copy of this
    /// test binary started the way the terminal owner starts
    /// (`DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP`, local_owner.rs), which
    /// sets its ignore-Ctrl+C attribute. Its PTY child is a third copy that
    /// prints a line and sleeps with the default Ctrl+C handler; before the
    /// fix it inherited the attribute and slept on.
    #[test]
    fn a_pty_child_processes_ctrl_c_from_a_spawner_that_ignores_it()
    -> Result<(), Box<dyn std::error::Error>> {
        if std::env::var_os(SLEEPER).is_some() {
            println!("sleeper-ready");
            std::thread::sleep(Duration::from_secs(60));
            return Ok(());
        }
        if std::env::var_os(PROBE).is_some() {
            println!("probe: {}", interrupt_a_pty_child()?);
            return Ok(());
        }
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
        let output = cmux_process::Command::new(std::env::current_exe()?)
            .args(["--exact", NAME, "--nocapture", "--test-threads=1"])
            .env(PROBE, "1")
            .creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP)
            .output()?;
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        let line = stdout
            .lines()
            .find_map(|line| line.split("probe: ").nth(1))
            .ok_or_else(|| format!("the probe reported nothing: {stdout}{stderr}"))?;
        assert_eq!(line.trim(), format!("exited {STATUS_CONTROL_C_EXIT:#x}"), "{stdout}{stderr}");
        Ok(())
    }

    /// Spawn the sleeper on a PTY, write 0x03 once it is ready, and say how
    /// it ended.
    fn interrupt_a_pty_child() -> Result<String, Box<dyn std::error::Error>> {
        let pair = open(PtySize { rows: 24, cols: 120, pixel_width: 0, pixel_height: 0 })?;
        let mut command = PtyCommand::new(std::env::current_exe()?.to_string_lossy());
        command.args(["--exact", NAME, "--nocapture", "--test-threads=1"]);
        command.env(SLEEPER, "1");
        let mut spawned = pair.spawn(command)?;
        let mut reader = spawned.master.try_clone_reader()?;
        let mut writer = spawned.master.take_writer()?;
        let (sender, chunks) = mpsc::channel();
        std::thread::spawn(move || {
            let mut buffer = [0u8; 4096];
            while let Ok(count) = reader.read(&mut buffer) {
                if count == 0 || sender.send(buffer[..count].to_vec()).is_err() {
                    break;
                }
            }
        });
        let deadline = Instant::now() + Duration::from_secs(30);
        let mut output = Vec::new();
        let (mut answered, mut interrupted) = (false, false);
        while Instant::now() < deadline {
            if let Some(status) = spawned.child.try_wait()? {
                return Ok(format!("exited {:#x}", status.exit_code()));
            }
            match chunks.recv_timeout(Duration::from_millis(100)) {
                Ok(chunk) => output.extend_from_slice(&chunk),
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => {
                    let status = spawned.child.wait()?;
                    return Ok(format!("output closed, then exited {:#x}", status.exit_code()));
                }
            }
            let text = String::from_utf8_lossy(&output);
            // portable-pty's PSEUDOCONSOLE_INHERIT_CURSOR asks the terminal
            // for the cursor position first; answer as a terminal would.
            if !answered && text.contains("\x1b[6n") {
                writer.write_all(b"\x1b[1;1R")?;
                writer.flush()?;
                answered = true;
            }
            if !interrupted && text.contains("sleeper-ready") {
                writer.write_all(b"\x03")?;
                writer.flush()?;
                interrupted = true;
            }
        }
        spawned.child.kill()?;
        let text = String::from_utf8_lossy(&output).escape_debug().to_string();
        Ok(format!("still running after 30 s (0x03 written: {interrupted}): {text}"))
    }
}
