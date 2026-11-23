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
}

impl Forward {
    /// Forwards `remote_socket` on the ssh host `host`, and waits (up to 30s) until it is up.
    pub(crate) async fn open(host: &str, remote_socket: &str) -> Result<Self> {
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
        let spawned = tokio::process::Command::new("ssh")
            .args(forward_argv(host, &local, remote_socket))
            .stdin(std::process::Stdio::null())
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
        // Dropped on every early return below: ssh killed, the folder removed.
        let mut fwd = Self { local, dir, ssh };
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
    /// Ends the forward and waits for its ssh to exit, so it leaves no zombie behind while the
    /// caller goes on (a move of several chats waits minutes on the next one's turn).
    pub(crate) async fn close(mut self) {
        let _ = self.ssh.kill().await;
    }
}

impl Drop for Forward {
    fn drop(&mut self) {
        reap(&mut self.ssh);
        let _ = std::fs::remove_dir_all(&self.dir);
    }
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
