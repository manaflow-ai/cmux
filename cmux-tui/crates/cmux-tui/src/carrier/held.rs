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
//! Identity: each session records who dialed it, the [`Identity`] of the
//! credential current when its dial began (the JWT `sub`, else a digest of
//! the whole credential), whichever source that credential came from: a
//! stdin token line, the token file (re-read on every connection) or the
//! environment. A connection rides the held session only when the current
//! credential's identity is the same, read again before the session is
//! picked, after a dial finishes and after a stream opens, so a dial or a
//! stream that another person's credential overtook is never handed out.
//! A session no longer current takes no new stream; the streams already on
//! it keep it until they end, and the last one closes it. Nothing here
//! waits on stdin, and stdin never waits on the slot.
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
    /// No new stream may start on it (idle, or no longer the current
    /// credential's).
    retired: AtomicBool,
    closed: AtomicBool,
    /// Who dialed it: the credential current when its dial began.
    identity: Option<Identity>,
}

impl Held {
    fn retired(&self) -> bool {
        self.retired.load(Ordering::Acquire)
    }

    /// Whether `now` (the current credential's identity) is the one that
    /// dialed it. A session whose dial had no readable credential is no
    /// one's to share.
    fn serves(&self, now: Option<&Identity>) -> bool {
        self.identity.is_some() && self.identity.as_ref() == now
    }

    fn alive(&self) -> bool {
        !self.retired()
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

/// Who a credential names (`answer::HttpSource::identity`).
pub(super) type Identity = String;

/// The current credential's identity, read afresh on each call.
pub(super) type IdentityNow = Arc<dyn Fn() -> Option<Identity> + Send + Sync>;

/// The machine's session, if one is held.
pub(super) struct Slot {
    held: Shared,
    idle: Duration,
    identity: IdentityNow,
}

/// One connection's claim on the held session. [`Lease::end`] gives it
/// back; the last one back arms the idle close (or closes a retired
/// session at once).
pub(super) struct Lease {
    held: Arc<Held>,
    slot: Shared,
    idle: Duration,
}

/// Why a connection got no stream. `dialed`: the failure is a dial's,
/// whose attempts wrote their own route and phases lines; otherwise it
/// came from the held session (or the wait for another connection's dial)
/// and nothing has logged it yet.
pub(super) struct Refused {
    pub failure: Failure,
    pub dialed: bool,
}

impl Refused {
    fn waiting(failure: Failure) -> Self {
        Self { failure, dialed: false }
    }
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
    pub(super) fn new(idle: Duration, identity: IdentityNow) -> Self {
        Self { held: Arc::new(Mutex::new(None)), idle, identity }
    }

    fn lease(&self, held: &Arc<Held>) -> Lease {
        held.streams.fetch_add(1, Ordering::AcqRel);
        held.epoch.fetch_add(1, Ordering::AcqRel);
        Lease { held: held.clone(), slot: self.held.clone(), idle: self.idle }
    }

    /// A mux control stream for one connection: on the held session when it
    /// is alive, else on a session `dial` makes (and the slot then holds).
    /// Everything stays inside `deadline`; `dial` keeps it itself.
    pub(super) async fn stream<F, Fut>(
        &self,
        deadline: Instant,
        mut dial: F,
    ) -> Result<Stream, Refused>
    where
        F: FnMut() -> Fut,
        Fut: Future<Output = Result<Dialed, Failure>>,
    {
        // A held session that turns out gone when its stream is refused is
        // dropped once and the next pass dials; a session retired while its
        // dial or its stream open was in flight is never handed out, and the
        // next pass dials with the current credential. The deadline bounds
        // every pass.
        let mut refused_once = false;
        loop {
            if Instant::now() >= deadline {
                return Err(Refused::waiting(Failure::deadline(Step::Ticket)));
            }
            let mut guard = tokio::time::timeout_at(deadline, self.held.lock())
                .await
                .map_err(|_| Refused::waiting(Failure::deadline(Step::Ticket)))?;
            let now = (self.identity)();
            match guard.as_ref() {
                Some(held) if held.alive() && held.serves(now.as_ref()) => {
                    let held = held.clone();
                    let lease = self.lease(&held);
                    drop(guard);
                    match on_held(&held, lease, deadline, &self.identity).await {
                        Ok(stream) => return Ok(stream),
                        Err(Some(failure)) => return Err(Refused::waiting(failure)),
                        Err(None) if held.retired() || !held.serves((self.identity)().as_ref()) => {
                            continue;
                        }
                        Err(None) if !refused_once => {
                            refused_once = true;
                            continue;
                        }
                        Err(None) => {
                            return Err(Refused::waiting(Failure::fatal(
                                Step::Handshake,
                                "the held session refused a stream twice",
                            )));
                        }
                    }
                }
                // Gone, or another person's: no new stream; its last stream
                // closes it.
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
            let Dialed { connection, multiplexer, mux, vmk } =
                dial().await.map_err(|failure| Refused { failure, dialed: true })?;
            let held = Arc::new(Held {
                connection,
                multiplexer,
                vmk,
                streams: AtomicUsize::new(0),
                epoch: AtomicU64::new(0),
                retired: AtomicBool::new(false),
                closed: AtomicBool::new(false),
                identity: now,
            });
            // Dialed with a credential another person's replaced meanwhile:
            // closed, never handed out.
            if (self.identity)() != held.identity {
                mux.close().await;
                held.close().await;
                continue;
            }
            let lease = self.lease(&held);
            *guard = Some(held);
            return Ok(Stream { mux, vmk, lease, dialed: true });
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

/// A stream on a held session. `Err(None)`: the session is gone or was
/// retired meanwhile (the caller dials); `Err(Some(_))`: this connection's
/// failure.
async fn on_held(
    held: &Arc<Held>,
    lease: Lease,
    deadline: Instant,
    identity: &IdentityNow,
) -> Result<Stream, Option<Failure>> {
    match tokio::time::timeout_at(deadline, OpenedMuxControl::open(&held.multiplexer)).await {
        // Retired, or another person's credential arrived, while the stream
        // opened: not handed out; the caller dials with the current one.
        Ok(Ok(mux)) if held.retired() || !held.serves(identity().as_ref()) => {
            mux.close().await;
            lease.end().await;
            Err(None)
        }
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
        if held.retired() {
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
