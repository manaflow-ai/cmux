//! An `ssh -L` forward of another machine's daemon socket to a private socket here, so a client
//! here talks to that daemon as its own local client does. `acpmux session move` uses it for the
//! move, and the source's watch (`hub/transfer_watch.rs`) to ask the target how a move ended
//! once the move's client went away.

use anyhow::{Context as _, Result, bail};
use std::path::{Path, PathBuf};

/// A live forward. Ends (ssh killed, its folder removed) when dropped.
pub(crate) struct Forward {
    /// The socket here that reaches the remote daemon.
    pub local: PathBuf,
    dir: PathBuf,
    ssh: tokio::process::Child,
    /// Its recorded owner, dropped after `drop` kills `ssh`: cancels the forward on any shared
    /// master and removes the record (`ssh_forward_owners.rs`).
    _owner: crate::ssh_forward_owners::Owner,
}

impl Forward {
    /// Forwards `remote_socket` on the ssh host `host`, and waits (up to 30s) until it is up.
    pub(crate) async fn open(host: &str, remote_socket: &str) -> Result<Self> {
        let ledger = crate::ssh_forward_owners::ledger_dir(&crate::config::home());
        Self::open_with(std::ffi::OsStr::new("ssh"), &ledger, host, remote_socket).await
    }

    /// [`Forward::open`] with the ssh program and the owners' folder named (a test's stand-in).
    pub(crate) async fn open_with(
        ssh_program: &std::ffi::OsStr,
        ledger: &Path,
        host: &str,
        remote_socket: &str,
    ) -> Result<Self> {
        let host = crate::cli::hosts::checked_host(host)?;
        if !(remote_socket.starts_with('/') && crate::cli::hosts::plain_path(remote_socket)) {
            bail!("the remote socket {remote_socket:?} is not a plain absolute path");
        }
        // A short private folder: a Unix socket path has about 100 bytes, and TMPDIR is long.
        let dir = PathBuf::from(format!(
            "/tmp/acpmux-fwd-{}-{}",
            std::process::id(),
            uuid::Uuid::now_v7().simple()
        ));
        std::fs::create_dir(&dir)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))?;
        }
        let local = dir.join("d.sock");
        let spawned = tied_command(ssh_program, &forward_argv(host, &local, remote_socket))
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .context("spawn ssh");
        let ssh = match spawned {
            Ok(ssh) => ssh,
            Err(e) => {
                let _ = std::fs::remove_dir_all(&dir);
                return Err(e);
            }
        };
        // Recorded before anything waits on it: a start's sweep ends it if this process dies.
        let owner = crate::ssh_forward_owners::Owner::record(
            ssh_program,
            ledger,
            crate::ssh_forward_owners::Record {
                owner: std::process::id(),
                host: host.to_owned(),
                local: local.clone(),
                remote: remote_socket.to_owned(),
                opened: std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_secs())
                    .unwrap_or(0),
            },
        );
        // Dropped on every early return below: ssh killed, the forward cancelled on any
        // master, the folder and the record removed.
        let mut fwd = Self { local, dir, ssh, _owner: owner };
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(30);
        while !fwd.local.exists() {
            if let Some(status) = fwd.ssh.try_wait()? {
                bail!("ssh to {host} ended ({status}) before forwarding the daemon's socket");
            }
            if tokio::time::Instant::now() > deadline {
                bail!("ssh to {host} did not forward the daemon's socket within 30s");
            }
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
        Ok(fwd)
    }
}

impl Forward {
    #[cfg(test)]
    pub(crate) fn ssh_pid(&self) -> Option<u32> {
        self.ssh.id()
    }

    /// The owner dies without its drop running (SIGKILL): its end of the ssh's stdin closes.
    #[cfg(test)]
    pub(crate) fn owner_dies(mut self) {
        drop(self.ssh.stdin.take());
        std::mem::forget(self);
    }

    /// Ends the forward and waits for its ssh to exit, so it leaves no zombie behind while the
    /// caller goes on (a move of several chats waits minutes on the next one's turn).
    pub(crate) async fn close(mut self) {
        kill_group(&self.ssh);
        let _ = self.ssh.kill().await;
    }
}

impl Drop for Forward {
    fn drop(&mut self) {
        kill_group(&self.ssh);
        reap(&mut self.ssh);
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// Runs `ssh ARGV` tied to this process: under `sh` in a process group of its own, with its
/// stdin a pipe from here. When this process ends by any means (a SIGKILL runs no drop), the
/// pipe closes and `sh` kills the ssh; when the ssh ends, `sh` ends with its status.
fn tied_command(ssh_program: &std::ffi::OsStr, argv: &[String]) -> tokio::process::Command {
    const TIED: &str = r#"exec 3<&0
"$0" "$@" </dev/null &
s=$!
{ read _ <&3; kill $s 2>/dev/null; } &
r=$!
wait $s
st=$?
kill $r 2>/dev/null
exit $st"#;
    let mut command = tokio::process::Command::new("sh");
    command.arg("-c").arg(TIED).arg(ssh_program).args(argv);
    command.stdin(std::process::Stdio::piped());
    #[cfg(unix)]
    command.process_group(0);
    command
}

/// SIGKILL to the forward's whole group (`sh` and its ssh), while `child` is unreaped: its pid,
/// and so its group's id, cannot name another process yet.
fn kill_group(child: &tokio::process::Child) {
    #[cfg(unix)]
    if let Some(pid) = child.id().and_then(|p| libc::pid_t::try_from(p).ok()) {
        // SAFETY: a signal to the group this unreaped child leads.
        unsafe { libc::kill(-pid, libc::SIGKILL) };
    }
    #[cfg(not(unix))]
    let _ = child;
}

/// Kills `child` and reaps it (bounded, 2 s): `kill_on_drop` alone signals it but leaves it
/// unwaited, a defunct child of the move until its process ends.
pub(crate) fn reap(child: &mut tokio::process::Child) {
    if matches!(child.try_wait(), Ok(Some(_))) {
        return;
    }
    let _ = child.start_kill();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
    while std::time::Instant::now() < deadline {
        match child.try_wait() {
            Ok(None) => std::thread::sleep(std::time::Duration::from_millis(5)),
            _ => return,
        }
    }
}

/// `ssh -N -L LOCAL:REMOTE -- HOST`, failing at once when the forward cannot be made.
pub(crate) fn forward_argv(host: &str, local: &Path, remote: &str) -> Vec<String> {
    let mut argv: Vec<String> = [
        "-N",
        "-o",
        "BatchMode=yes",
        "-o",
        "ExitOnForwardFailure=yes",
        "-o",
        "StreamLocalBindUnlink=yes",
        "-o",
        "ServerAliveInterval=15",
        "-o",
        "ConnectTimeout=20",
        "-L",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    argv.push(format!("{}:{remote}", local.display()));
    argv.push("--".into());
    argv.push(host.to_owned());
    argv
}

#[cfg(test)]
mod tests {
    /// Item C: a forward's ssh, once dropped, is killed and reaped: no defunct child stays
    /// behind while the move goes on (`kill(pid, 0)` still finds a zombie).
    #[cfg(unix)]
    #[tokio::test]
    async fn a_dropped_child_is_reaped_not_left_defunct() {
        let mut child =
            tokio::process::Command::new("sleep").arg("60").kill_on_drop(true).spawn().unwrap();
        let pid = child.id().unwrap() as libc::pid_t;
        super::reap(&mut child);
        // SAFETY: signal 0 only checks that the pid exists.
        let alive = unsafe { libc::kill(pid, 0) } == 0;
        assert!(!alive, "the killed child {pid} is still in the process table");
    }
}
