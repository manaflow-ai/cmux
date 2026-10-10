//! A terminal-host process started ahead of its terminal (R81).

use super::*;

/// A terminal-host process started before its terminal exists (R81: a
/// new tab then skips the process start, most of its launch). It has run
/// only `exec` and waits on its bootstrap pipe: no identity, no PTY, no
/// child, no timers, so it uses no CPU. Dropping it exact-kills it; a
/// daemon exit closes its pipe, and the host exits.
pub(crate) struct StandbyTerminalHost {
    pub(crate) process: SpawnedHostProcess,
    pub(crate) stdin: std::process::ChildStdin,
    pub(crate) stdout: std::process::ChildStdout,
    pub(crate) host_pid: u32,
}

impl StandbyTerminalHost {
    pub(crate) fn spawn() -> anyhow::Result<Self> {
        // Exec the daemon's own running build (open inode on Linux): after an
        // in-place binary upgrade, resolving the executable path yields
        // "<path> (deleted)" and exec fails, which broke every new tab/split
        // on a long-lived daemon. This also guarantees daemon and host can
        // never run skewed builds.
        // On macOS: its content-addressed copy outside the app bundle, with no
        // path in its command line (host_exe.rs, cx-0tgl LF).
        let child = crate::host_exe::spawn_host(|command| {
            command
                .args(["__terminal-host", "--bootstrap-stdio"])
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                // A host outlives its daemon, so it must not retain a daemon
                // log pipe whose EOF is itself used as a lifecycle signal.
                .stderr(Stdio::null());
            // A durable host must not share the daemon's controlling
            // terminal, session, or process group. Otherwise a shell hangup
            // or group interrupt intended for the daemon can also kill every
            // hosted PTY.
            // SAFETY: setsid(2) is async-signal-safe and touches no Rust
            // state in the post-fork child. A freshly forked child is not a
            // process-group leader, so failure is an actual launch error.
            unsafe {
                command.pre_exec(|| {
                    if libc::setsid() < 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                    // The host and the shell it owns get the limit cmux
                    // started with (setrlimit(2) is async-signal-safe).
                    cmux_pty::restore_open_file_limit_in_child()
                });
            }
        })
        .context("spawn terminal-host process")?;
        let mut process = SpawnedHostProcess { child: Some(child) };
        let host_pid = process.child_mut().id();
        // A Cloud daemon's unit stop must not end its hosts (host_scope.rs).
        host_scope::place_host(host_pid);
        let stdin =
            process.child_mut().stdin.take().context("open terminal-host bootstrap stdin")?;
        let stdout =
            process.child_mut().stdout.take().context("open terminal-host bootstrap stdout")?;
        Ok(Self { process, stdin, stdout, host_pid })
    }

    /// A stand-in for tests: `cat` also waits on its stdin and exits at EOF.
    #[cfg(test)]
    pub(crate) fn spawn_stand_in() -> anyhow::Result<Self> {
        let mut command = Command::new("cat");
        command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null());
        let mut process = SpawnedHostProcess { child: Some(command.spawn()?) };
        let host_pid = process.child_mut().id();
        let stdin = process.child_mut().stdin.take().context("stand-in stdin")?;
        let stdout = process.child_mut().stdout.take().context("stand-in stdout")?;
        Ok(Self { process, stdin, stdout, host_pid })
    }

    /// The process id, for tests.
    #[cfg(test)]
    pub(crate) fn pid(&self) -> u32 {
        self.host_pid
    }

    /// False once the process has exited (killed, or crashed before use).
    pub(crate) fn is_alive(&mut self) -> bool {
        matches!(self.process.child_mut().try_wait(), Ok(None))
    }
}
