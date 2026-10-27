//! The remote sidecar ends with its mux. A thread blocks on a read of one
//! connection to the mux socket, with no read timeout, and the mux closing
//! it ends the read; the sidecar used to read with a 250 ms timeout and
//! re-check the socket path on every timeout.

use std::io::{self, Read};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::{Arc, Mutex, PoisonError};

use anyhow::Context;

const THREAD_NAME: &str = "remote-sidecar-mux-monitor";

/// The sidecar's connection to the mux socket at `path`.
pub(super) fn open(path: &Path) -> anyhow::Result<UnixStream> {
    super::connect_same_user_socket(path)
        .with_context(|| format!("cannot attach remote sidecar to mux socket {}", path.display()))
}

/// Watches one mux connection; [`crate::wake_headless`] tells when it ends.
pub(super) struct MuxMonitor {
    ended: Arc<Mutex<Option<io::Result<()>>>>,
}

impl MuxMonitor {
    /// Starts the thread that reads `stream` until the mux closes it.
    pub(super) fn start(mut stream: UnixStream) -> io::Result<Self> {
        let ended = Arc::new(Mutex::new(None));
        let outcome = Arc::clone(&ended);
        cmux_threads::spawn(THREAD_NAME, cmux_threads::ThreadQos::Utility, move || {
            let closed = wait_for_close(&mut stream);
            *outcome.lock().unwrap_or_else(PoisonError::into_inner) = Some(closed);
            crate::wake_headless();
        })?;
        Ok(Self { ended })
    }

    /// Whether the connection has ended.
    pub(super) fn ended(&self) -> bool {
        self.ended.lock().unwrap_or_else(PoisonError::into_inner).is_some()
    }

    /// How the connection ended: `None` while it runs, `Some(Ok)` when the
    /// mux closed it, `Some(Err)` when the read failed otherwise.
    pub(super) fn take(&self) -> Option<io::Result<()>> {
        self.ended.lock().unwrap_or_else(PoisonError::into_inner).take()
    }
}

/// Blocks until the peer closes `stream`: `Ok` on its close, the error when
/// the read fails in another way. What the peer sends is read and dropped.
pub(super) fn wait_for_close(stream: &mut impl Read) -> io::Result<()> {
    let mut buffer = [0_u8; 64];
    loop {
        match stream.read(&mut buffer) {
            Ok(0) => return Ok(()),
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::BrokenPipe
                        | io::ErrorKind::ConnectionAborted
                        | io::ErrorKind::ConnectionReset
                        | io::ErrorKind::NotConnected
                ) =>
            {
                return Ok(());
            }
            Err(error) => return Err(error),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write;
    use std::os::unix::net::{UnixListener, UnixStream};

    use super::{MuxMonitor, open, wait_for_close};

    #[test]
    fn the_monitor_read_ends_when_the_peer_closes_and_drops_what_it_sends() {
        let (mut monitor, mut mux) = UnixStream::pair().unwrap();
        mux.write_all(b"ignored").unwrap();
        drop(mux);
        wait_for_close(&mut monitor).unwrap();
    }

    #[test]
    fn sidecar_mux_monitor_wakes_the_sidecar_when_the_connected_server_closes() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("mux.sock");
        let listener = UnixListener::bind(&path).unwrap();
        let stream = open(&path).unwrap();
        let (accepted, _) = listener.accept().unwrap();
        let monitor = MuxMonitor::start(stream).unwrap();
        assert!(!monitor.ended(), "the connection is open");
        drop(accepted);
        crate::wait_until_woken(|| monitor.ended());
        assert!(matches!(monitor.take(), Some(Ok(()))));
    }
}
