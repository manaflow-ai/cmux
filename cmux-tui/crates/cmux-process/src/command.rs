//! The builder: `std::process::Command`'s shape, a spawn that passes on no
//! descriptor by accident.

use std::collections::BTreeMap;
use std::ffi::{OsStr, OsString};
use std::io;
#[cfg(unix)]
use std::os::fd::{BorrowedFd, OwnedFd, RawFd};
use std::path::{Path, PathBuf};
use std::process::{ExitStatus, Output};

use crate::child::Child;
use crate::stdio::Stdio;

/// A process to start, as `std::process::Command`.
///
/// On macOS [`Command::spawn`] gives the child descriptors 0-2 and the ones
/// named with [`Command::inherit_fd`], and no other (the crate docs say why).
#[derive(Debug)]
pub struct Command {
    pub(crate) program: OsString,
    pub(crate) arg0: Option<OsString>,
    pub(crate) args: Vec<OsString>,
    pub(crate) env_clear: bool,
    /// `None`: removed.
    pub(crate) env: BTreeMap<OsString, Option<OsString>>,
    pub(crate) cwd: Option<PathBuf>,
    pub(crate) stdin: Option<Stdio>,
    /// [`Command::open_stdin_path`]: a path the child opens read-write as
    /// descriptor 0.
    pub(crate) stdin_path: Option<PathBuf>,
    pub(crate) stdout: Option<Stdio>,
    pub(crate) stderr: Option<Stdio>,
    pub(crate) process_group: Option<i32>,
    pub(crate) new_session: bool,
    /// (descriptor, the number the child gets it at).
    #[cfg(unix)]
    pub(crate) inherit: Vec<(OwnedFd, RawFd)>,
}

impl Command {
    /// A command that runs `program` (a path, or a name looked up in the
    /// child's `PATH`).
    pub fn new(program: impl AsRef<OsStr>) -> Self {
        Self {
            program: program.as_ref().to_owned(),
            arg0: None,
            args: Vec::new(),
            env_clear: false,
            env: BTreeMap::new(),
            cwd: None,
            stdin: None,
            stdin_path: None,
            stdout: None,
            stderr: None,
            process_group: None,
            new_session: false,
            #[cfg(unix)]
            inherit: Vec::new(),
        }
    }

    /// Add one argument.
    pub fn arg(&mut self, arg: impl AsRef<OsStr>) -> &mut Self {
        self.args.push(arg.as_ref().to_owned());
        self
    }

    /// Add arguments.
    pub fn args<I, S>(&mut self, args: I) -> &mut Self
    where
        I: IntoIterator<Item = S>,
        S: AsRef<OsStr>,
    {
        self.args.extend(args.into_iter().map(|arg| arg.as_ref().to_owned()));
        self
    }

    /// The child's `argv[0]`, when it should differ from the program.
    pub fn arg0(&mut self, arg0: impl AsRef<OsStr>) -> &mut Self {
        self.arg0 = Some(arg0.as_ref().to_owned());
        self
    }

    /// Set one environment variable.
    pub fn env(&mut self, key: impl AsRef<OsStr>, value: impl AsRef<OsStr>) -> &mut Self {
        self.env.insert(key.as_ref().to_owned(), Some(value.as_ref().to_owned()));
        self
    }

    /// Set environment variables.
    pub fn envs<I, K, V>(&mut self, vars: I) -> &mut Self
    where
        I: IntoIterator<Item = (K, V)>,
        K: AsRef<OsStr>,
        V: AsRef<OsStr>,
    {
        for (key, value) in vars {
            self.env(key, value);
        }
        self
    }

    /// Remove one environment variable.
    pub fn env_remove(&mut self, key: impl AsRef<OsStr>) -> &mut Self {
        self.env.insert(key.as_ref().to_owned(), None);
        self
    }

    /// Start from an empty environment (the variables set after still apply).
    pub fn env_clear(&mut self) -> &mut Self {
        self.env_clear = true;
        self.env.clear();
        self
    }

    /// The child's working directory.
    pub fn current_dir(&mut self, dir: impl AsRef<Path>) -> &mut Self {
        self.cwd = Some(dir.as_ref().to_owned());
        self
    }

    /// The child's stdin (default: inherit; `output` defaults to null).
    /// Replaces an earlier [`Command::open_stdin_path`].
    pub fn stdin(&mut self, stdio: impl Into<Stdio>) -> &mut Self {
        self.stdin = Some(stdio.into());
        self.stdin_path = None;
        self
    }

    /// Have the child open `path` read-write as its descriptor 0, and make
    /// its stdout and stderr copies of it (unless [`Command::stdout`] or
    /// [`Command::stderr`] set them). With [`Command::new_session`] and a
    /// terminal path (a PTY slave), that terminal becomes the child's
    /// controlling terminal: a session leader with none acquires the first
    /// terminal it opens (macOS and Linux). The shell spawn of a PTY uses it,
    /// as `cmux-mux2`'s `spawn_pty` does (`posix_spawn_file_actions_addopen`
    /// on 0, then `adddup2` 0 to 1 and 2 on macOS). A failed open is the
    /// spawn's error. Replaces an earlier [`Command::stdin`].
    pub fn open_stdin_path(&mut self, path: impl AsRef<Path>) -> &mut Self {
        self.stdin_path = Some(path.as_ref().to_owned());
        self.stdin = None;
        self
    }

    /// The child's stdout (default: inherit; `output` defaults to piped).
    pub fn stdout(&mut self, stdio: impl Into<Stdio>) -> &mut Self {
        self.stdout = Some(stdio.into());
        self
    }

    /// The child's stderr (default: inherit; `output` defaults to piped).
    pub fn stderr(&mut self, stdio: impl Into<Stdio>) -> &mut Self {
        self.stderr = Some(stdio.into());
        self
    }

    /// Put the child in process group `pgid` (0: a new group led by the
    /// child), as `std::os::unix::process::CommandExt::process_group`.
    pub fn process_group(&mut self, pgid: i32) -> &mut Self {
        self.process_group = Some(pgid);
        self
    }

    /// Make the child the leader of a new session (`setsid`), with no
    /// controlling terminal.
    pub fn new_session(&mut self) -> &mut Self {
        self.new_session = true;
        self
    }

    /// Give the child a copy of `fd` at descriptor number `at` (3 or more:
    /// 0-2 are [`Command::stdin`], [`Command::stdout`], [`Command::stderr`]).
    /// The only way a descriptor other than 0-2 reaches the child.
    ///
    /// # Errors
    ///
    /// When `fd` cannot be duplicated (the builder keeps its own copy until
    /// the spawn).
    #[cfg(unix)]
    pub fn inherit_fd(&mut self, fd: BorrowedFd<'_>, at: RawFd) -> io::Result<&mut Self> {
        if at < 3 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "inherit_fd: 0-2 are set with stdin, stdout and stderr",
            ));
        }
        self.inherit.push((fd.try_clone_to_owned()?, at));
        Ok(self)
    }

    /// Start the child. Returns once it runs its program (an exec failure is
    /// this call's error). The streams and descriptors given are used up, as
    /// std does with a `Stdio` it owns.
    pub fn spawn(&mut self) -> io::Result<Child> {
        #[cfg(target_vendor = "apple")]
        {
            crate::spawn_apple::spawn(self)
        }
        #[cfg(not(target_vendor = "apple"))]
        {
            self.spawn_std()
        }
    }

    /// Run the child to its end with stdin null and stdout and stderr
    /// captured (unless set), as `std::process::Command::output`.
    pub fn output(&mut self) -> io::Result<Output> {
        if self.stdin.is_none() && self.stdin_path.is_none() {
            self.stdin = Some(Stdio::null());
        }
        for stream in [&mut self.stdout, &mut self.stderr] {
            if stream.is_none() {
                *stream = Some(Stdio::piped());
            }
        }
        self.spawn()?.wait_with_output()
    }

    /// Run the child to its end with every stream inherited (unless set) and
    /// return its status, as `std::process::Command::status`.
    pub fn status(&mut self) -> io::Result<ExitStatus> {
        self.spawn()?.wait()
    }

    /// The std path (Linux, Windows): the kernel makes every descriptor this
    /// process opens close-on-exec atomically, so nothing leaks.
    #[cfg(not(target_vendor = "apple"))]
    fn spawn_std(&mut self) -> io::Result<Child> {
        let mut command = std::process::Command::new(&self.program);
        command.args(&self.args);
        if self.env_clear {
            command.env_clear();
        }
        for (key, value) in &self.env {
            match value {
                Some(value) => command.env(key, value),
                None => command.env_remove(key),
            };
        }
        if let Some(dir) = &self.cwd {
            command.current_dir(dir);
        }
        if let Some(stdio) = self.stdin.take() {
            command.stdin(stdio.into_std());
        }
        if let Some(stdio) = self.stdout.take() {
            command.stdout(stdio.into_std());
        }
        if let Some(stdio) = self.stderr.take() {
            command.stderr(stdio.into_std());
        }
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            if let Some(arg0) = &self.arg0 {
                command.arg0(arg0);
            }
            if let Some(pgid) = self.process_group {
                command.process_group(pgid);
            }
            if self.new_session || !self.inherit.is_empty() || self.stdin_path.is_some() {
                // The std path has no posix_spawn file actions: setsid and
                // each inherited descriptor go in a pre_exec hook (only
                // async-signal-safe calls; the copies are this builder's).
                let new_session = self.new_session;
                // (path, also onto 1, also onto 2): stdout and stderr not set
                // become copies of the opened descriptor.
                let stdin_path = match &self.stdin_path {
                    Some(path) => Some((
                        std::ffi::CString::new(std::os::unix::ffi::OsStrExt::as_bytes(
                            path.as_os_str(),
                        ))
                        .map_err(|_| {
                            io::Error::new(io::ErrorKind::InvalidInput, "a NUL byte in a path")
                        })?,
                        self.stdout.is_none(),
                        self.stderr.is_none(),
                    )),
                    None => None,
                };
                let inherit: Vec<(RawFd, RawFd)> = self
                    .inherit
                    .iter()
                    .map(|(fd, at)| (std::os::fd::AsRawFd::as_raw_fd(fd), *at))
                    .collect();
                // SAFETY: setsid, dup2 and fcntl are async-signal-safe and
                // touch only the child's own table.
                unsafe {
                    command.pre_exec(move || {
                        if new_session && libc::setsid() < 0 {
                            return Err(io::Error::last_os_error());
                        }
                        // After setsid: a terminal opened here becomes the
                        // controlling terminal of the new session.
                        if let Some((path, onto_out, onto_err)) = &stdin_path {
                            let fd = libc::open(path.as_ptr(), libc::O_RDWR);
                            if fd < 0 {
                                return Err(io::Error::last_os_error());
                            }
                            for (wanted, target) in [(true, 0), (*onto_out, 1), (*onto_err, 2)] {
                                if wanted && fd != target && libc::dup2(fd, target) < 0 {
                                    return Err(io::Error::last_os_error());
                                }
                            }
                            if fd > 2 {
                                libc::close(fd);
                            }
                        }
                        for &(fd, at) in &inherit {
                            let result = if fd == at {
                                libc::fcntl(fd, libc::F_SETFD, 0)
                            } else {
                                libc::dup2(fd, at)
                            };
                            if result < 0 {
                                return Err(io::Error::last_os_error());
                            }
                        }
                        Ok(())
                    });
                }
            }
        }
        let child = command.spawn()?;
        #[cfg(unix)]
        self.inherit.clear();
        Ok(Child::from_std(child))
    }
}
