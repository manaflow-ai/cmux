//! The daemon owns the Native receiving process and its exact remote entry.
//! Root role completion means the child has exited, not just acknowledged drain.

use std::io;
use std::os::fd::AsRawFd as _;
use std::path::Path;
use std::process::Command;
use std::sync::Arc;

use cmux_link::caller::SupervisedChild;
use cmux_tui_core::Mux;
use cmux_tui_core::server::RemoteEntryServer;
use tokio::net::UnixStream;

struct NativeChild {
    child: Arc<SupervisedChild>,
    entry: Option<RemoteEntryServer>,
    lifetime: Option<UnixStream>,
    control: Option<UnixStream>,
}

impl NativeChild {
    async fn start(
        _command: Command,
        _mux: &Arc<Mux>,
        _session: &Path,
        _frame: &[u8],
    ) -> anyhow::Result<Self> {
        anyhow::bail!("cloud.receiver.supervision_unavailable")
    }

    async fn stop(mut self) -> anyhow::Result<()> {
        use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
        drop(self.entry.take());
        let control = self.control.as_mut().ok_or_else(|| io::Error::other("no child control"))?;
        let graceful = tokio::time::timeout(std::time::Duration::from_secs(8), async {
            control.shutdown().await?;
            if control.read_u8().await? != 2 {
                anyhow::bail!("cloud.receiver.invalid_drain_ack");
            }
            wait_child(&self.child).await?;
            anyhow::Ok(())
        })
        .await;
        // Drop is also the failure/cancellation path. An acknowledgement
        // cannot substitute for reaping, even with a retained verifier Arc.
        match graceful {
            Ok(result) => result,
            Err(_) => {
                Err(io::Error::new(io::ErrorKind::TimedOut, "cloud.receiver.stop_timeout").into())
            }
        }
    }
}

impl Drop for NativeChild {
    fn drop(&mut self) {
        drop(self.entry.take());
        for stream in [&self.control, &self.lifetime].into_iter().flatten() {
            // SAFETY: shutdown acts only on this owned connected socket.
            let _ = unsafe { libc::shutdown(stream.as_raw_fd(), libc::SHUT_RDWR) };
        }
        let _ = self.child.kill_and_wait();
    }
}

async fn wait_child(child: &SupervisedChild) -> io::Result<std::process::ExitStatus> {
    use std::os::fd::{FromRawFd as _, OwnedFd};
    if let Some(status) = child.try_wait()? {
        return Ok(status);
    }
    // The pid comes only from our retained Child. Recheck after opening:
    // another entry thread may have reaped it while opening the exit watch.
    // SAFETY: pidfd_open accepts this pid and flags zero, returning an owned fd.
    let raw = unsafe { libc::syscall(libc::SYS_pidfd_open, child.id(), 0) };
    let opened = if raw < 0 {
        Err(io::Error::last_os_error())
    } else {
        // SAFETY: raw is the fresh descriptor returned by pidfd_open.
        Ok(unsafe { OwnedFd::from_raw_fd(raw as i32) })
    };
    if let Some(status) = child.try_wait()? {
        return Ok(status);
    }
    let fd = tokio::io::unix::AsyncFd::new(opened?)?;
    let _ready = fd.readable().await?;
    child.try_wait()?.ok_or_else(|| io::Error::other("cloud.receiver.exit_not_reaped"))
}

#[cfg(test)]
mod tests;
