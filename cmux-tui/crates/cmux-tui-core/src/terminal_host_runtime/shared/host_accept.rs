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

use crate::backoff::Backoff;

use super::super::sys::{self, HostStream};
use super::host_serve::serve_client;
use super::host_shared::HostShared;

/// The first wait after a failed accept; it doubles up to [`MAX_BACKOFF`].
/// Longer than a remote listener's (10 ms to 250 ms): a terminal host is one
/// process per terminal, so a host short of descriptors waits more.
const FIRST_BACKOFF: Duration = Duration::from_millis(20);
const MAX_BACKOFF: Duration = Duration::from_secs(1);

/// The accept loop's spacing after an error; `reset` once a client is handed off.
pub(crate) fn accept_backoff() -> Backoff {
    Backoff::new(FIRST_BACKOFF, MAX_BACKOFF).with_jitter(0.0)
}

/// Note `error` (one log line per streak) and wait until the next backoff
/// passes or the waker reports a lifecycle change (terminal exit, last
/// client stream closed), which the loop checks next.
pub(crate) fn wait_after_error(backoff: &mut Backoff, shared: &HostShared, error: &std::io::Error) {
    if backoff.attempts() == 0 {
        eprintln!("terminal-host: accepting a client failed; retrying: {error}");
    }
    let deadline = Instant::now() + backoff.next_delay();
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
}

/// Hand an accepted client to its own thread. An error drops this client
/// only; the caller backs off and keeps serving the terminal.
pub(crate) fn serve_accepted(shared: &Arc<HostShared>, stream: HostStream) -> std::io::Result<()> {
    // Accepted sockets inherit O_NONBLOCK from the listener on macOS. Client
    // protocol threads use blocking framed reads, so normalize it here.
    stream.set_nonblocking(false)?;
    sys::size_client_send_buffer(&stream);
    let host = shared.clone();
    thread::Builder::new().name("terminal-host-client".into()).spawn(move || {
        let _ = serve_client(host, stream);
    })?;
    Ok(())
}
