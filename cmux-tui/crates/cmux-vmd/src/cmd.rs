//! Processes the daemon runs: short commands (`ip`, `nft`, `cp`) on the blocking pool, and the
//! Firecracker processes it owns.
//!
//! A Firecracker outlives the daemon on purpose (a restart reattaches), so its pid is checked
//! through its API socket's peer credentials before any signal: a recycled pid is never touched,
//! and nothing reads `/proc`.

use std::io::Write as _;
use std::path::Path;
use std::process::Output;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use cmux_process::{Command, Stdio};

/// Run `cmd` to its end on the blocking pool, feeding it `stdin` when given.
pub async fn output(mut cmd: Command, stdin: Option<Vec<u8>>) -> Result<Output> {
    tokio::task::spawn_blocking(move || -> Result<Output> {
        let Some(input) = stdin else {
            return Ok(cmd.output()?);
        };
        cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        let mut child = cmd.spawn()?;
        if let Some(mut pipe) = child.stdin.take() {
            pipe.write_all(&input)?;
        }
        Ok(child.wait_with_output()?)
    })
    .await
    .context("command task")?
}

/// The pid of the Firecracker listening on `dir/api.sock`, from the socket's peer credentials.
pub async fn firecracker_pid(dir: &Path) -> Option<u32> {
    let connect = tokio::net::UnixStream::connect(dir.join("api.sock"));
    let stream = tokio::time::timeout(Duration::from_secs(1), connect).await.ok()?.ok()?;
    stream.peer_cred().ok()?.pid().and_then(|p| u32::try_from(p).ok())
}

/// Reap `pid` if it is our exited child. True when it was reaped.
pub fn reap(pid: u32) -> bool {
    let Ok(p) = libc::pid_t::try_from(pid) else { return false };
    let mut status = 0;
    // SAFETY: waitpid(2) on one pid with WNOHANG; `status` is a valid out pointer.
    unsafe { libc::waitpid(p, &raw mut status, libc::WNOHANG) == p }
}

fn gone(pid: libc::pid_t) -> bool {
    // SAFETY: kill(2) with signal 0 sends nothing; it only reports whether the pid exists.
    let rc = unsafe { libc::kill(pid, 0) };
    rc != 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
}

/// SIGKILL the Firecracker behind `dir` when it is still `pid`, then wait (3 s at most) for it to
/// go.
pub async fn kill_firecracker(dir: &Path, pid: u32) {
    if firecracker_pid(dir).await != Some(pid) {
        return;
    }
    let Ok(p) = libc::pid_t::try_from(pid) else { return };
    // SAFETY: kill(2) on the pid that serves this machine's API socket right now.
    unsafe {
        libc::kill(p, libc::SIGKILL);
    }
    let start = Instant::now();
    while start.elapsed() < Duration::from_secs(3) {
        if reap(pid) || gone(p) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
}
