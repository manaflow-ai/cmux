//! Shared PTY allocation and command spawning for cmux runtimes.
//!
//! The Unix backend avoids optional PTY device-name resolution and supports
//! descriptor-pinned working directories. Non-Unix platforms use
//! portable-pty's native backend.

use std::collections::BTreeMap;
#[cfg(unix)]
use std::fs::File;
use std::path::{Path, PathBuf};
#[cfg(unix)]
use std::sync::Arc;

pub use portable_pty::{Child, ChildKiller, ExitStatus, MasterPty, PtySize};

#[cfg(unix)]
mod macos;

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
    use std::fs::File;
    #[cfg(target_os = "linux")]
    use std::io;
    use std::os::fd::{AsRawFd, FromRawFd};

    use super::*;

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
