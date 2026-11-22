//! The daemon's state for remote-relay peers
//! (plans/cmux-next/server-remote-conversations.md sections 2, 5 and 10):
//! the verified peer of each remote connection, the pairing records that name
//! the server owner, and the offline revocation limits.
//!
//! Every lookup fails closed: a remote connection without a peer record, a
//! server without a pairing record and an install without a good check own
//! nothing and may open no stream.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

pub(crate) use cmux_link::stamp::LinkPeer;

/// Last good check older than this: new streams of the install are refused.
pub const REFUSE_NEW_STREAMS_AFTER: Duration = Duration::from_secs(24 * 60 * 60);
/// Last good check older than this: existing streams are closed too.
pub const CLOSE_STREAMS_AFTER: Duration = Duration::from_secs(72 * 60 * 60);
/// How often the link rechecks each paired install with the control plane.
pub const RECHECK_INTERVAL: Duration = Duration::from_secs(5 * 60);

/// The conversation participant of a paired install (decision D-B). Never
/// `user_local`.
pub(crate) fn remote_participant(install: &str) -> String {
    format!("remote_{install}")
}

/// The stored pairing records of this server (`cmux server pair` writes
/// them). The owner is the `user` of the pairing record.
pub trait PairingRecords: Send + Sync {
    /// The server owner, or `None` when the server is not paired.
    fn owner_user(&self) -> Option<String>;
    /// Delete the pairing record of `install` (revocation).
    fn delete(&self, install: &str);
}

/// The time source of the revocation limits, injected so tests can move it.
pub trait RevocationClock: Send + Sync {
    fn now(&self) -> Instant;
}

struct MonotonicClock;

impl RevocationClock for MonotonicClock {
    fn now(&self) -> Instant {
        Instant::now()
    }
}

/// What the revocation state allows for one install right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum StreamPolicy {
    /// New and existing streams are served.
    Serve,
    /// New streams are refused; existing streams stay (24 hours offline).
    RefuseNew,
    /// Every stream is closed (72 hours offline, revoked, or never checked).
    Close,
}

#[derive(Debug, Clone, Copy)]
enum InstallCheck {
    Good(Instant),
    Revoked,
}

/// The offline revocation limits (section 10, decision D-D). A check that
/// could not reach the cloud is not recorded, so it changes nothing.
pub(crate) struct Revocation {
    clock: Arc<dyn RevocationClock>,
    checks: BTreeMap<String, InstallCheck>,
}

impl Default for Revocation {
    fn default() -> Self {
        Self { clock: Arc::new(MonotonicClock), checks: BTreeMap::new() }
    }
}

impl Revocation {
    pub(crate) fn set_clock(&mut self, clock: Arc<dyn RevocationClock>) {
        self.clock = clock;
    }

    /// The control plane confirmed `install` now.
    pub(crate) fn record_good_check(&mut self, install: &str) {
        if !matches!(self.checks.get(install), Some(InstallCheck::Revoked)) {
            self.checks.insert(install.to_string(), InstallCheck::Good(self.clock.now()));
        }
    }

    /// The control plane said `install` is revoked. Revocation is final.
    pub(crate) fn record_revoked(&mut self, install: &str) {
        self.checks.insert(install.to_string(), InstallCheck::Revoked);
    }

    /// The time of `install`'s last good check (tests).
    #[cfg(test)]
    pub(crate) fn good_check_time(&self, install: &str) -> Option<Instant> {
        match self.checks.get(install) {
            Some(InstallCheck::Good(at)) => Some(*at),
            _ => None,
        }
    }

    /// The policy of `install` at the current clock. An install that was
    /// never checked is closed (fail closed).
    pub(crate) fn policy(&self, install: &str) -> StreamPolicy {
        match self.checks.get(install) {
            None | Some(InstallCheck::Revoked) => StreamPolicy::Close,
            Some(InstallCheck::Good(at)) => {
                let age = self.clock.now().saturating_duration_since(*at);
                if age > CLOSE_STREAMS_AFTER {
                    StreamPolicy::Close
                } else if age > REFUSE_NEW_STREAMS_AFTER {
                    StreamPolicy::RefuseNew
                } else {
                    StreamPolicy::Serve
                }
            }
        }
    }
}

/// A remote-relay lock (one field of [`RemoteRelayState`], or the client
/// registry that names remote connections).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RelayLock {
    Peers,
    Pairing,
    Revocation,
    Clients,
    /// The conversation bindings (client to agent participant).
    Bindings,
}

/// Why a remote-relay admission or revocation step did not run as asked.
/// A panic poisoned one of the relay's locks: the state behind it is not
/// trusted, so the step fails closed. An admission is denied; a revocation
/// closes every remote stream, because the poisoned state cannot say which
/// streams belong to the install.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RelayStateError {
    Poisoned(RelayLock),
}

impl std::fmt::Display for RelayStateError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Poisoned(lock) => write!(formatter, "remote relay {lock:?} lock is poisoned"),
        }
    }
}

impl std::error::Error for RelayStateError {}

/// Why a remote stream was not bound to its peer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BindRefused {
    /// The install may not open new streams (revoked, never checked, or past
    /// the 24 h offline limit).
    Policy,
    /// A relay lock is poisoned (fail closed).
    State(RelayStateError),
}

impl From<RelayStateError> for BindRefused {
    fn from(error: RelayStateError) -> Self {
        Self::State(error)
    }
}

/// `mutex` locked for an admission or revocation decision: a poisoned lock
/// is an error, never its possibly half-updated value.
pub(crate) fn lock_checked<T>(
    mutex: &Mutex<T>,
    lock: RelayLock,
) -> Result<MutexGuard<'_, T>, RelayStateError> {
    mutex.lock().map_err(|_| RelayStateError::Poisoned(lock))
}

/// The remote-relay state on the conversation host.
#[derive(Default)]
pub(crate) struct RemoteRelayState {
    /// The verified link peer of each remote connection (memory only).
    pub(crate) peers: Mutex<BTreeMap<u64, LinkPeer>>,
    pub(crate) pairing: Mutex<Option<Arc<dyn PairingRecords>>>,
    pub(crate) revocation: Mutex<Revocation>,
}

impl RemoteRelayState {
    /// The peer record of `client`; an error when the peers lock is
    /// poisoned (callers fail closed).
    pub(crate) fn peer_checked(&self, client: u64) -> Result<Option<LinkPeer>, RelayStateError> {
        Ok(lock_checked(&self.peers, RelayLock::Peers)?.get(&client).cloned())
    }

    /// The peer record of `client` (tests). A poisoned peers lock gives
    /// `None`.
    #[cfg(test)]
    pub(crate) fn peer(&self, client: u64) -> Option<LinkPeer> {
        self.peer_checked(client).ok().flatten()
    }

    /// The server owner from the pairing records; an error when the pairing
    /// lock is poisoned (callers deny).
    pub(crate) fn owner_user(&self) -> Result<Option<String>, RelayStateError> {
        let pairing = lock_checked(&self.pairing, RelayLock::Pairing)?.clone();
        Ok(pairing.and_then(|records| records.owner_user()))
    }

    /// The remote connections of `install`.
    pub(crate) fn clients_of(&self, install: &str) -> Result<Vec<u64>, RelayStateError> {
        let peers = lock_checked(&self.peers, RelayLock::Peers)?;
        Ok(peers.iter().filter(|(_, peer)| peer.install == install).map(|(c, _)| *c).collect())
    }

    /// Every connection that has a peer record, for a close of all remote
    /// streams.
    pub(crate) fn all_peer_clients(&self) -> Vec<u64> {
        // Safety: this list only closes streams; a poisoned map can name a
        // stale id, and closing a stale id does nothing.
        self.peers.lock().unwrap_or_else(PoisonError::into_inner).keys().copied().collect()
    }
}
