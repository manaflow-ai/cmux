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
        // No pre_exec: std then starts the host with posix_spawn instead of
        // fork(), whose cost grew with every daemon thread (host_session.rs).
        // A durable host must not share the daemon's controlling terminal,
        // session, or process group (a shell hangup or group interrupt meant
        // for the daemon would kill every hosted PTY), and the host and its
        // shell get the open-file limit cmux started with: the host does
        // both as its first steps (`enter_terminal_host_process`).
        let session_env = host_session_env();
        let child = crate::host_exe::spawn_host(|command| {
            if let Some((name, value)) = &session_env {
                command.env(name, value);
            }
            command
                .args(["__terminal-host", "--bootstrap-stdio"])
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                // A host outlives its daemon, so it must not retain a daemon
                // log pipe whose EOF is itself used as a lifecycle signal.
                .stderr(Stdio::null());
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

    /// False once the process has exited (killed, or crashed before use).
    pub(crate) fn is_alive(&mut self) -> bool {
        matches!(self.process.child_mut().try_wait(), Ok(None))
    }
}
