//! Errors of a terminal host's own listener (cx-0tgl LB).
//!
//! A host ends only by its owner's `Terminate` or its child's exit. A failed
//! `accept` (descriptor exhaustion, kernel memory), a failed
//! thread start for one client, or a failed `poll` is a condition of this
//! moment, never a reason to end the shell: the host drops that one client,
//! waits on its accept waker for a bounded, growing backoff (so a listener
//! that stays readable under `EMFILE` does not spin), and accepts again. An
//! aborted connection (`ECONNABORTED`) is retried at once, like `EINTR`.

use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use super::super::sys::HostStream;
use super::host_serve::serve_client;
use super::host_shared::HostShared;

/// The first wait after a failed accept; it doubles up to [`MAX_BACKOFF`].
const FIRST_BACKOFF: Duration = Duration::from_millis(20);
const MAX_BACKOFF: Duration = Duration::from_secs(1);

/// The accept loop's wait after an error.
pub(crate) struct AcceptBackoff {
    next: Duration,
    /// Errors since the last accepted client, for the one log line per streak.
    failures: u64,
}

impl AcceptBackoff {
    pub(crate) fn new() -> Self {
        Self { next: FIRST_BACKOFF, failures: 0 }
    }

    /// A client was handed off: the next error starts a new streak.
    pub(crate) fn reset(&mut self) {
        self.next = FIRST_BACKOFF;
        self.failures = 0;
    }

    /// Note `error` and wait until the backoff passes or the waker reports a
    /// lifecycle change (terminal exit, last client stream closed), which the
    /// loop checks next.
    pub(crate) fn after_error(&mut self, shared: &HostShared, error: &std::io::Error) {
        self.failures += 1;
        if self.failures == 1 {
            eprintln!("terminal-host: accepting a client failed; retrying: {error}");
        }
        let deadline = Instant::now() + self.next;
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                break;
            }
            match shared.accept_waker.wait_readable(remaining) {
                Ok(true) => {
                    shared.accept_waker.drain();
                    break;
                }
                Ok(false) => break,
                Err(error) if error.kind() != std::io::ErrorKind::Interrupted => {
                    // `poll` itself failed: wait out the backoff without the waker,
                    // so a lasting failure cannot spin.
                    thread::sleep(remaining);
                    break;
                }
                Err(_) => {}
            }
        }
        self.next = (self.next * 2).min(MAX_BACKOFF);
    }
}

/// Hand an accepted client to its own thread. An error drops this client
/// only; the caller backs off and keeps serving the terminal.
pub(crate) fn serve_accepted(shared: &Arc<HostShared>, stream: HostStream) -> std::io::Result<()> {
    // Accepted sockets inherit O_NONBLOCK from the listener on macOS. Client
    // protocol threads use blocking framed reads, so normalize it here.
    stream.set_nonblocking(false)?;
    let host = shared.clone();
    thread::Builder::new().name("terminal-host-client".into()).spawn(move || {
        let _ = serve_client(host, stream);
    })?;
    Ok(())
}
