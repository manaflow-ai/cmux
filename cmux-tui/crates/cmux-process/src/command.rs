//! The builder: `std::process::Command`'s shape, a spawn that passes on no
//! descriptor by accident.

use std::collections::BTreeMap;
use std::ffi::{OsStr, OsString};
use std::io;
#[cfg(unix)]
use std::os::fd::{BorrowedFd, OwnedFd, RawFd};
use std::path::{Path, PathBuf};
use std::process::{ExitStatus, Output};

use cmux_threads::ThreadQos;

use crate::child::Child;
use crate::stdio::Stdio;

/// A process to start, as `std::process::Command`.
///
/// On macOS [`Command::spawn`] gives the child descriptors 0-2 and the ones
/// named with [`Command::inherit_fd`], and no other (the crate docs say why),
/// unless [`Command::inherit_like_std`] asks for std's inheritance.
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
    /// macOS: [`Command::inherit_like_std`].
    #[cfg(target_vendor = "apple")]
    pub(crate) inherit_like_std: bool,
    /// [`Command::current_dir_fd`]: the child's working directory, as a
    /// descriptor. Replaces `cwd`.
    #[cfg(unix)]
    pub(crate) cwd_fd: Option<OwnedFd>,
    /// [`Command::isolate`].
    #[cfg(all(unix, not(target_vendor = "apple")))]
    pub(crate) isolate: bool,
    /// [`Command::process_group_fence`].
    #[cfg(target_os = "linux")]
    pub(crate) process_group_fence: bool,
    /// [`Command::open_file_limit`].
    #[cfg(unix)]
    pub(crate) open_file_limit: Option<u64>,
    /// [`Command::creation_flags`].
    #[cfg(windows)]
    pub(crate) creation_flags: u32,
    /// [`Command::qos_ceiling`].
    pub(crate) qos_ceiling: Option<ThreadQos>,
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
            #[cfg(target_vendor = "apple")]
            inherit_like_std: false,
            #[cfg(unix)]
            cwd_fd: None,
            #[cfg(all(unix, not(target_vendor = "apple")))]
            isolate: false,
            #[cfg(target_os = "linux")]
            process_group_fence: false,
            #[cfg(unix)]
            open_file_limit: None,
            #[cfg(windows)]
            creation_flags: 0,
            qos_ceiling: None,
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

    /// The variables this builder sets (`Some`) or removes (`None`), as
    /// `std::process::Command::get_envs`.
    pub fn get_envs(&self) -> impl Iterator<Item = (&OsStr, Option<&OsStr>)> {
        self.env.iter().map(|(key, value)| (key.as_os_str(), value.as_deref()))
    }

    /// The child's working directory. Replaces an earlier
    /// [`Command::current_dir_fd`].
    pub fn current_dir(&mut self, dir: impl AsRef<Path>) -> &mut Self {
        self.cwd = Some(dir.as_ref().to_owned());
        #[cfg(unix)]
        {
            self.cwd_fd = None;
        }
        self
    }

    /// The child's working directory is the directory open at `dir`
    /// (`fchdir`; macOS: `posix_spawn_file_actions_addfchdir_np`), so a
    /// rename or replacement of its path after it was opened does not move
    /// the child. Replaces an earlier [`Command::current_dir`].
    ///
    /// # Errors
    ///
    /// When `dir` cannot be duplicated (the builder keeps its own copy until
    /// the spawn).
    #[cfg(unix)]
    pub fn current_dir_fd(&mut self, dir: BorrowedFd<'_>) -> io::Result<&mut Self> {
        self.cwd_fd = Some(dir.try_clone_to_owned()?);
        self.cwd = None;
        Ok(self)
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
    /// terminal it opens, and the child asks for it with `TIOCSCTTY`. The
    /// shell spawn of a PTY uses it. On macOS such a child is forked, not
    /// `posix_spawn`ed: posix_spawn opens the path before its `setsid`, and
    /// the terminal then never becomes the controlling one (no SIGINT from
    /// Ctrl-C). A failed open, or a terminal that cannot become the
    /// controlling one, is the spawn's error. Replaces an earlier
    /// [`Command::stdin`].
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

    /// Give the child on Linux what the macOS spawn always gives it: every
    /// descriptor other than 0-2 and the [`Command::inherit_fd`] ones closes
    /// at the exec, also one opened without close-on-exec (by a C library,
    /// say), and every signal starts at its default disposition with an empty
    /// mask (std keeps an ignored signal ignored and the spawning thread's
    /// mask; a shell started with SIGINT ignored never dies of Ctrl-C).
    /// Chromium's `LaunchProcess` does both on every Linux launch
    /// (base/process/launch_posix.cc: `CloseSuperfluousFds`,
    /// `ResetChildSignalHandlersToDefaults`). On Linux it costs a fork where
    /// std would `posix_spawn`, so it is for children that run arbitrary
    /// programs for a long time (a terminal's shell). macOS does this for
    /// every spawn; Windows has neither.
    pub fn isolate(&mut self) -> &mut Self {
        #[cfg(all(unix, not(target_vendor = "apple")))]
        {
            self.isolate = true;
        }
        self
    }

    /// Linux: the child and every process it starts can never leave the
    /// process group they start in: `setsid` and `setpgid` fail with EPERM
    /// (a seccomp filter, with `no_new_privs`). A process scope uses it so a
    /// hook cannot escape the group the scope kills. Set after the child's
    /// own [`Command::new_session`] and [`Command::process_group`].
    #[cfg(target_os = "linux")]
    pub fn process_group_fence(&mut self) -> &mut Self {
        self.process_group_fence = true;
        self
    }

    /// The child's soft `RLIMIT_NOFILE` (at most its hard limit), set before
    /// its program runs. Linux: `setrlimit` before the exec. macOS:
    /// `posix_spawn` cannot set a limit, so the child is `/bin/sh -c
    /// 'ulimit -S -n N; exec "$@"'` that execs the program in the same
    /// process (same pid, session and terminal); the program's `argv[0]` is
    /// then its resolved path, and a [`Command::arg0`] makes the spawn fail
    /// with `InvalidInput`.
    #[cfg(unix)]
    pub fn open_file_limit(&mut self, soft: u64) -> &mut Self {
        self.open_file_limit = Some(soft);
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

    /// Start the child as `std::process::Command` does: it keeps every
    /// descriptor of this process that is not close-on-exec, and the signals
    /// this process ignores stay ignored (only `SIGPIPE` resets to its
    /// default, and the signal mask empties). For the CLI's transparent
    /// wrappers only (`cmux status run -- CMD` and the like), which cannot know
    /// which descriptors (`/dev/fd/N`, a make jobserver) or ignored signals
    /// (`nohup`) the person handed them. Never in the daemon: there a
    /// descriptor received but not yet close-on-exec would reach the child
    /// (crate docs). Linux and Windows always start children this way.
    pub fn inherit_like_std(&mut self) -> &mut Self {
        #[cfg(target_vendor = "apple")]
        {
            self.inherit_like_std = true;
        }
        self
    }

    /// The highest QoS class any thread of the child may run at, Utility or
    /// Background ([`ThreadQos`] order): a helper (git, ss/netstat, hooks)
    /// names `cmux_threads::HELPER_CHILD`, so it never competes with the
    /// echo or request thread that started it. macOS:
    /// `posix_spawnattr_set_qos_class_np`, which takes only those classes;
    /// the spawning thread's class is not touched. Linux and Windows: no
    /// effect; the child keeps its creator's nice value. A higher class
    /// makes the spawn fail with `InvalidInput`.
    pub fn qos_ceiling(&mut self, qos: ThreadQos) -> &mut Self {
        self.qos_ceiling = Some(qos);
        self
    }

    /// Windows: the process creation flags (`DETACHED_PROCESS`,
    /// `CREATE_NEW_PROCESS_GROUP`, ...), as
    /// `std::os::windows::process::CommandExt::creation_flags`.
    #[cfg(windows)]
    pub fn creation_flags(&mut self, flags: u32) -> &mut Self {
        self.creation_flags = flags;
        self
    }

    /// Replace this process with the program, as
    /// `std::os::unix::process::CommandExt::exec`: returns only when that
    /// failed. The new image keeps what `execve` keeps, as with
    /// [`Command::inherit_like_std`]: every descriptor that is not
    /// close-on-exec, and the ignored signals (on macOS `posix_spawn` with
    /// `POSIX_SPAWN_SETEXEC`). For the CLI's re-exec and passthroughs; the
    /// daemon never replaces itself.
    #[cfg(unix)]
    pub fn exec(&mut self) -> io::Error {
        #[cfg(target_vendor = "apple")]
        {
            crate::spawn_apple::exec(self)
        }
        #[cfg(not(target_vendor = "apple"))]
        {
            use std::os::unix::process::CommandExt;
            match self.std_command() {
                Ok(mut command) => command.exec(),
                Err(error) => error,
            }
        }
    }

    /// Start the child. Returns once it runs its program (an exec failure is
    /// this call's error). The streams and descriptors given are used up, as
    /// std does with a `Stdio` it owns.
    pub fn spawn(&mut self) -> io::Result<Child> {
        if self.qos_ceiling.is_some_and(|qos| qos > ThreadQos::Utility) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "qos_ceiling: a spawn ceiling is Utility or Background",
            ));
        }
        #[cfg(target_vendor = "apple")]
        {
            // posix_spawn runs its file actions before POSIX_SPAWN_SETSID
            // (xnu bsd/kern/kern_exec.c, posix_spawn: exec_handle_file_actions,
            // then setsid_internal after the image activation), so the child
            // opens the terminal while it still is in this process's session,
            // where it cannot become its controlling terminal (TIOCSCTTY needs
            // a session leader), and the new session then has none: the line
            // discipline sends no SIGINT for Ctrl-C and the shell has no job
            // control. No file action sets a controlling terminal, so such a
            // child takes the fork path (setsid, open, TIOCSCTTY), as Ghostty
            // and node-pty's spawn helper do.
            if self.wants_controlling_terminal() {
                return self.spawn_std();
            }
            crate::spawn_apple::spawn(self)
        }
        #[cfg(not(target_vendor = "apple"))]
        {
            self.spawn_std()
        }
    }

    /// Whether the child opens a terminal ([`Command::open_stdin_path`]) as
    /// the leader of a new session ([`Command::new_session`]): that terminal
    /// becomes its controlling terminal.
    #[cfg(unix)]
    fn wants_controlling_terminal(&self) -> bool {
        self.new_session && self.stdin_path.is_some()
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
    /// process opens close-on-exec atomically, so nothing leaks. macOS takes
    /// it only for a child with a controlling terminal: a fork whose child
    /// marks every descriptor but its own close-on-exec before the exec
    /// (`isolate`), so it passes on what `posix_spawn` would.
    fn spawn_std(&mut self) -> io::Result<Child> {
        let child = self.std_command()?.spawn()?;
        #[cfg(unix)]
        {
            self.inherit.clear();
            self.cwd_fd = None;
        }
        #[cfg(target_vendor = "apple")]
        {
            // std's handle neither waits nor kills on drop; the pid is
            // reaped through `Child` as every macOS child is.
            let mut child = child;
            let pid = libc::pid_t::try_from(child.id())
                .map_err(|_| io::Error::from_raw_os_error(libc::ESRCH))?;
            Ok(Child::from_pid(pid, child.stdin.take(), child.stdout.take(), child.stderr.take()))
        }
        #[cfg(not(target_vendor = "apple"))]
        {
            Ok(Child::from_std(child))
        }
    }

    /// Whether the std path's child gets [`Command::isolate`]'s sweep and
    /// signal reset: as asked on Linux; on macOS always, unless
    /// [`Command::inherit_like_std`] asked for std's inheritance.
    #[cfg(unix)]
    fn isolates(&self) -> bool {
        #[cfg(target_vendor = "apple")]
        {
            !self.inherit_like_std
        }
        #[cfg(not(target_vendor = "apple"))]
        {
            self.isolate
        }
    }

    /// The `std::process::Command` of the std path; the streams given are
    /// moved into it.
    fn std_command(&mut self) -> io::Result<std::process::Command> {
        // Before the streams are moved: stdout and stderr not set become
        // copies of an opened stdin path.
        #[cfg(unix)]
        let (stdout_set, stderr_set) = (self.stdout.is_some(), self.stderr.is_some());
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
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(self.creation_flags);
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
            #[cfg(target_os = "linux")]
            let fence = self.process_group_fence;
            #[cfg(not(target_os = "linux"))]
            let fence = false;
            if self.new_session
                || !self.inherit.is_empty()
                || self.stdin_path.is_some()
                || self.cwd_fd.is_some()
                || self.isolates()
                || fence
                || self.open_file_limit.is_some()
            {
                // The std path has no posix_spawn file actions: what the
                // child needs beyond std goes in one pre_exec hook (only
                // async-signal-safe calls on data prepared here; the
                // descriptors are this builder's copies).
                crate::fd::lift_sources_above_targets(&mut self.inherit)?;
                let setup = crate::child_setup::ChildSetup {
                    new_session: self.new_session,
                    cwd_fd: self.cwd_fd.as_ref().map(std::os::fd::AsRawFd::as_raw_fd),
                    sweep: self.isolates().then(crate::child_setup::DescriptorSweep::new),
                    // (path, also onto 1, also onto 2): stdout and stderr not
                    // set become copies of the opened descriptor.
                    stdin_path: match &self.stdin_path {
                        Some(path) => Some((
                            std::ffi::CString::new(std::os::unix::ffi::OsStrExt::as_bytes(
                                path.as_os_str(),
                            ))
                            .map_err(|_| {
                                io::Error::new(io::ErrorKind::InvalidInput, "a NUL byte in a path")
                            })?,
                            !stdout_set,
                            !stderr_set,
                        )),
                        None => None,
                    },
                    inherit: self
                        .inherit
                        .iter()
                        .map(|(fd, at)| (std::os::fd::AsRawFd::as_raw_fd(fd), *at))
                        .collect(),
                    process_group_fence: fence,
                    open_file_limit: self.open_file_limit,
                    controlling_terminal: self.wants_controlling_terminal(),
                    // A posix_spawn child starts at Default, or at its
                    // ceiling (`posix_spawnattr_set_qos_class_np`).
                    #[cfg(target_vendor = "apple")]
                    qos_class: self
                        .qos_ceiling
                        .map_or(libc::qos_class_t::QOS_CLASS_DEFAULT, ThreadQos::qos_class),
                };
                // SAFETY: `ChildSetup::run` makes only async-signal-safe
                // calls, allocates nothing, and touches only the child's own
                // descriptors, signal dispositions and seccomp filter.
                unsafe {
                    // pre-exec-allow: ChildSetup::run makes only raw syscalls on prepared data
                    command.pre_exec(move || setup.run());
                }
            }
        }
        Ok(command)
    }
}
