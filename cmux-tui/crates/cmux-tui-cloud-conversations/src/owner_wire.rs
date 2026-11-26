//! Owner sockets of other daemon services on the same lease (the feed
//! client's `/v1/wire/feed`, plans/cmux-next/feed-page.md): the service
//! opens the socket through this link's backend with the lease's bearer, so
//! the token never leaves this crate, and waits for a new lease the same
//! way this link's own drivers do (cancellable, no sleep).

use std::time::{Duration, Instant};

use super::{CloudConversations, CloudEvent, CloudWire, ConnectError};

/// One open owner socket and the lease generation it was opened with.
pub struct OwnerWire {
    pub wire: Box<dyn CloudWire>,
    /// Compare with [`CloudConversations::lease_generation`]: a new lease
    /// means the socket reconnects with the new token.
    pub generation: u64,
    /// The cloud user id (JWT `sub`) of the lease, unverified.
    pub account: Option<String>,
}

/// Why an owner socket did not open.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OwnerWireError {
    /// No lease: wait for a sign-in.
    SignedOut,
    /// The lease expired: wait for a new one (announced to the app).
    Expired,
    /// The upgrade was answered 401: this token is refused, wait for another.
    Unauthenticated,
    /// 403, 404 or 410: the owner refuses this principal.
    Forbidden,
    /// The network or the owner is down: retry after a backoff.
    Unavailable(String),
}

impl CloudConversations {
    /// Opens `path` (`/v1/wire/feed`) on the lease's origin with its bearer.
    /// The error carries the lease generation it saw, for
    /// [`Self::wait_lease_change`].
    pub fn open_owner_wire(&self, path: &str) -> Result<OwnerWire, (OwnerWireError, u64)> {
        let generation = self.inner.generation();
        let session = match self.inner.stream_session() {
            Ok(session) => session,
            Err("signed_out") => return Err((OwnerWireError::SignedOut, generation)),
            Err(_) => return Err((OwnerWireError::Expired, generation)),
        };
        let url = session.ws_url(path);
        match self.inner.backend.connect(&url, session.bearer(), session.client_version.as_deref())
        {
            Ok(wire) => Ok(OwnerWire {
                wire,
                generation: session.generation,
                account: session.account.clone(),
            }),
            Err(ConnectError::Unauthenticated) => {
                Err((OwnerWireError::Unauthenticated, session.generation))
            }
            Err(ConnectError::Forbidden) => Err((OwnerWireError::Forbidden, session.generation)),
            Err(ConnectError::Unavailable(reason)) => {
                Err((OwnerWireError::Unavailable(reason), session.generation))
            }
        }
    }

    /// The current lease generation (it moves on every set and clear).
    pub fn lease_generation(&self) -> u64 {
        self.inner.generation()
    }

    /// Waits up to `timeout` for the lease generation to move past
    /// `generation`, for a shutdown, or for [`Self::wake_lease_waiters`].
    pub fn wait_lease_change(&self, generation: u64, timeout: Duration) {
        let deadline = Instant::now() + timeout;
        loop {
            let seen = self.inner.signal_now();
            if self.inner.generation() != generation
                || self.inner.shutdown.load(std::sync::atomic::Ordering::SeqCst)
            {
                return;
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return;
            }
            self.inner.wait(seen, left);
            // Any signal ends the wait (a waker asked for it, or the lease moved).
            if self.inner.signal_now() != seen {
                return;
            }
        }
    }

    /// Ends every [`Self::wait_lease_change`] now (its caller stops).
    pub fn wake_lease_waiters(&self) {
        self.inner.notify();
    }

    /// An owner socket's upgrade was refused (401) on lease `generation`:
    /// the app hears `cloud-session-needed {reason: "unauthenticated"}` and
    /// renews the lease, as for this link's own sockets.
    pub fn report_unauthenticated(&self, generation: u64) {
        let expires_at = {
            let lease = self.inner.lease.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            match &lease.session {
                Some(session) if lease.generation == generation => session.expires_at,
                _ => return,
            }
        };
        self.inner.emit(CloudEvent::SessionNeeded {
            reason: "unauthenticated",
            expires_at: Some(expires_at),
        });
    }
}
