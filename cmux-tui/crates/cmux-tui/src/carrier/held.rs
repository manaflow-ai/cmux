//! `carrier serve`'s one session per machine: the first accepted connection
//! dials it, and every connection after it opens its own mux control stream
//! on it instead of dialing again. A session is dialed again only when the
//! held one is gone: the daemon no longer has it (past its resume lease),
//! its reader failed for good, a credential for another person replaced
//! the one it was dialed with, or it sat with no stream for the idle time.
//!
//! The dial runs under the slot's lock, so connections accepted while it
//! runs wait for it and share its session; one whose own deadline passes
//! while it waits fails at `ticket`. A failed dial fails only its own
//! connection: the next waiting one dials itself, as each did before.
//!
//! Idle close: when a session's last stream ends, it is closed once it has
//! carried no stream for [`DEFAULT_IDLE`] (one timer per idle spell, which
//! does nothing if a stream started meanwhile). A machine nothing uses
//! keeps no relay links open; the next connection dials as before.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::time::Duration;

use cmux_remote::bridge::OpenedMuxControl;
use cmux_remote::connection::ClientConnection;
use cmux_remote::service::ServiceMultiplexer;
use tokio::sync::Mutex;
use tokio::time::Instant;

use super::client::Dialed;
use super::contract::{Failure, Step, Vmk};

/// How long a session with no stream stays open: the daemon's default
/// resume lease, so a burst of uploads or file asks rides one session.
pub(super) const DEFAULT_IDLE: Duration = Duration::from_secs(120);

/// The held session and how many connections it carries.
pub(super) struct Held {
    connection: Arc<ClientConnection>,
    multiplexer: Arc<ServiceMultiplexer>,
    vmk: Option<Vmk>,
    streams: AtomicUsize,
    /// Bumped by each stream start: an idle close armed before it does
    /// nothing.
    epoch: AtomicU64,
    /// No new stream may start on it (another person's credential, idle).
    retired: AtomicBool,
    closed: AtomicBool,
}

impl Held {
    fn alive(&self) -> bool {
        !self.retired.load(Ordering::Acquire)
            && !self.closed.load(Ordering::Acquire)
            && !self.connection.session_unavailable()
            && !self.multiplexer.session_unavailable()
            && self.multiplexer.subscribe_fatal().borrow().is_none()
    }

    /// Closes the session once, however many callers ask.
    async fn close(&self) {
        if self.closed.swap(true, Ordering::AcqRel) {
            return;
        }
        self.multiplexer.shutdown().await;
        let _ = self.connection.close().await;
    }
}

type Shared = Arc<Mutex<Option<Arc<Held>>>>;

/// The machine's session, if one is held.
pub(super) struct Slot {
    held: Shared,
    idle: Duration,
}

/// One connection's claim on the held session. [`Lease::end`] gives it
/// back; the last one back arms the idle close (or closes a retired
/// session at once).
pub(super) struct Lease {
    held: Arc<Held>,
    slot: Shared,
    idle: Duration,
}

/// A connection's mux control stream, ready to carry.
pub(super) struct Stream {
    pub mux: OpenedMuxControl,
    pub vmk: Option<Vmk>,
    pub lease: Lease,
    /// Whether this connection dialed the session (else it rode a held one).
    pub dialed: bool,
}

impl Slot {
    pub(super) fn new(idle: Duration) -> Self {
        Self { held: Arc::new(Mutex::new(None)), idle }
    }

    fn lease(&self, held: &Arc<Held>) -> Lease {
        held.streams.fetch_add(1, Ordering::AcqRel);
        held.epoch.fetch_add(1, Ordering::AcqRel);
        Lease { held: held.clone(), slot: self.held.clone(), idle: self.idle }
    }

    /// A mux control stream for one connection: on the held session when it
    /// is alive, else on a session `dial` makes (and the slot then holds).
    /// Everything stays inside `deadline`; `dial` keeps it itself.
    pub(super) async fn stream<F, Fut>(&self, deadline: Instant, dial: F) -> Result<Stream, Failure>
    where
        F: FnOnce() -> Fut,
        Fut: std::future::Future<Output = Result<Dialed, Failure>>,
    {
        // At most twice: a held session that turns out gone when its stream
        // is refused is dropped and the next pass dials.
        for _ in 0..2 {
            let mut guard = tokio::time::timeout_at(deadline, self.held.lock())
                .await
                .map_err(|_| Failure::deadline(Step::Ticket))?;
            match guard.as_ref() {
                Some(held) if held.alive() => {
                    let held = held.clone();
                    let lease = self.lease(&held);
                    drop(guard);
                    match on_held(&held, lease, deadline).await {
                        Ok(stream) => return Ok(stream),
                        Err(Some(failure)) => return Err(failure),
                        Err(None) => continue,
                    }
                }
                Some(_) => {
                    if let Some(gone) = guard.take() {
                        gone.retired.store(true, Ordering::Release);
                        if gone.streams.load(Ordering::Acquire) == 0 {
                            gone.close().await;
                        }
                    }
                }
                None => {}
            }
            let Dialed { connection, multiplexer, mux, vmk } = dial().await?;
            let held = Arc::new(Held {
                connection,
                multiplexer,
                vmk,
                streams: AtomicUsize::new(0),
                epoch: AtomicU64::new(0),
                retired: AtomicBool::new(false),
                closed: AtomicBool::new(false),
            });
            let lease = self.lease(&held);
            *guard = Some(held);
            return Ok(Stream { mux, vmk, lease, dialed: true });
        }
        Err(Failure::fatal(Step::Handshake, "the held session refused a stream twice"))
    }

    /// Later connections dial a new session: a credential for another
    /// person replaced the one the held session was dialed with. Streams
    /// already on it keep it until they end.
    pub(super) async fn retire(&self) {
        let gone = self.held.lock().await.take();
        if let Some(gone) = gone {
            gone.retired.store(true, Ordering::Release);
            if gone.streams.load(Ordering::Acquire) == 0 {
                gone.close().await;
            }
        }
    }

    /// Closes the held session (serve is stopping).
    pub(super) async fn close(&self) {
        let held = self.held.lock().await.take();
        if let Some(held) = held {
            held.close().await;
        }
    }
}

/// A stream on a held session. `Err(None)`: the session is gone (the
/// caller dials); `Err(Some(_))`: this connection's failure.
async fn on_held(
    held: &Arc<Held>,
    lease: Lease,
    deadline: Instant,
) -> Result<Stream, Option<Failure>> {
    match tokio::time::timeout_at(deadline, OpenedMuxControl::open(&held.multiplexer)).await {
        Ok(Ok(mux)) => Ok(Stream { mux, vmk: held.vmk, lease, dialed: false }),
        Ok(Err(error)) => {
            lease.end().await;
            if held.alive() {
                Err(Some(Failure::fatal(
                    Step::Handshake,
                    format!("the daemon did not open its mux control stream: {error}"),
                )))
            } else {
                Err(None)
            }
        }
        // The session is resuming (the relay or the machine is away) and did
        // not come back before this connection's deadline.
        Err(_) => {
            lease.end().await;
            Err(Some(Failure::deadline(Step::Relay)))
        }
    }
}

impl Lease {
    /// The connection is done with the session.
    pub(super) async fn end(self) {
        let Self { held, slot, idle } = self;
        if held.streams.fetch_sub(1, Ordering::AcqRel) != 1 {
            return;
        }
        if held.retired.load(Ordering::Acquire) {
            held.close().await;
            return;
        }
        let armed = held.epoch.load(Ordering::Acquire);
        tokio::spawn(async move {
            tokio::time::sleep(idle).await;
            let mut guard = slot.lock().await;
            // A stream started since (or one is still open): not idle.
            if held.streams.load(Ordering::Acquire) != 0
                || held.epoch.load(Ordering::Acquire) != armed
            {
                return;
            }
            held.retired.store(true, Ordering::Release);
            if guard.as_ref().is_some_and(|current| Arc::ptr_eq(current, &held)) {
                *guard = None;
            }
            drop(guard);
            held.close().await;
        });
    }
}
