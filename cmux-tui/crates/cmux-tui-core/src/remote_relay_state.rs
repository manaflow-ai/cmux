//! The daemon's state for remote-relay peers
//! (plans/cmux-next/server-remote-conversations.md sections 2, 5 and 10):
//! the verified peer of each remote connection, the pairing records that name
//! the server owner, and the offline revocation limits.
//!
//! Every lookup fails closed: a remote connection without a peer record, a
//! server without a pairing record and an install without a good check own
//! nothing and may open no stream.

use std::collections::BTreeMap;
use std::sync::PoisonError;
use std::sync::{Arc, Mutex};
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

/// The remote-relay state on the conversation host.
#[derive(Default)]
pub(crate) struct RemoteRelayState {
    /// The verified link peer of each remote connection (memory only).
    pub(crate) peers: Mutex<BTreeMap<u64, LinkPeer>>,
    pub(crate) pairing: Mutex<Option<Arc<dyn PairingRecords>>>,
    pub(crate) revocation: Mutex<Revocation>,
}

impl RemoteRelayState {
    pub(crate) fn peer(&self, client: u64) -> Option<LinkPeer> {
        self.peers.lock().unwrap_or_else(PoisonError::into_inner).get(&client).cloned()
    }

    pub(crate) fn owner_user(&self) -> Option<String> {
        let pairing = self.pairing.lock().unwrap_or_else(PoisonError::into_inner).clone();
        pairing.and_then(|records| records.owner_user())
    }

    /// The remote connections of `install`.
    pub(crate) fn clients_of(&self, install: &str) -> Vec<u64> {
        let peers = self.peers.lock().unwrap_or_else(PoisonError::into_inner);
        peers.iter().filter(|(_, peer)| peer.install == install).map(|(c, _)| *c).collect()
    }
}
