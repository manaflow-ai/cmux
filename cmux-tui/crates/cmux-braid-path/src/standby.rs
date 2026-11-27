//! Warm standbys from race losers (RFD 0164 slice B3). A dial's race often connects more than
//! one attempt: the winner, and a slower attempt on another path that answers after it. [`race`]
//! drops that one. [`Standby`] keeps it instead, one per peer and path kind, under a budget, for
//! the next dial to that peer: when the live path dies, the reconnect takes the standby (one
//! liveness check, no round trip) instead of racing again from cold.
//!
//! Budget: at most [`Standby::max_held`] in all (the oldest goes first) and each for at most
//! [`Standby::ttl`], under a NAT's idle lifetime, so a held one is not silently dead.
//! `CMUX_BRAID_STANDBY=0` turns the pool off (the A/B for its numbers).
//!
//! [`race`]: crate::race

use std::net::SocketAddr;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// The environment switch: `CMUX_BRAID_STANDBY=0` keeps no standbys.
pub const ENV_SWITCH: &str = "CMUX_BRAID_STANDBY";
/// How long one is held: under the 30 s UDP NAT timeout RFC 4787 allows at its shortest, so the
/// same budget serves a UDP path; a TCP path's NAT lasts far longer.
pub const DEFAULT_TTL: Duration = Duration::from_secs(25);
/// How many are held in all, across peers.
pub const DEFAULT_MAX_HELD: usize = 8;

/// A path kind for an address: its family. A path that dies takes its family with it more
/// often than not (a black-holed IPv6, an IPv4 NAT that dropped its mappings), so the standby
/// worth keeping is the other one.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Family {
    V4,
    V6,
}

impl Family {
    #[must_use]
    pub fn of(address: &SocketAddr) -> Self {
        if address.is_ipv6() { Self::V6 } else { Self::V4 }
    }
}

struct Held<K, P, T> {
    key: K,
    kind: P,
    value: T,
    at: Instant,
}

/// Standbys per peer `K` and path kind `P` (module docs).
pub struct Standby<K, P, T> {
    held: Mutex<Vec<Held<K, P, T>>>,
    max_held: usize,
    ttl: Duration,
    enabled: bool,
}

impl<K: PartialEq, P: PartialEq, T> Standby<K, P, T> {
    #[must_use]
    pub fn new(max_held: usize, ttl: Duration) -> Self {
        Self { held: Mutex::new(Vec::new()), max_held, ttl, enabled: max_held > 0 }
    }

    /// [`DEFAULT_MAX_HELD`] and [`DEFAULT_TTL`], off when `CMUX_BRAID_STANDBY=0`.
    #[must_use]
    pub fn from_env() -> Self {
        let enabled = std::env::var(ENV_SWITCH).map_or(true, |value| value.trim() != "0");
        Self { enabled, ..Self::new(DEFAULT_MAX_HELD, DEFAULT_TTL) }
    }

    #[must_use]
    pub fn enabled(&self) -> bool {
        self.enabled
    }

    #[must_use]
    pub fn max_held(&self) -> usize {
        self.max_held
    }

    #[must_use]
    pub fn ttl(&self) -> Duration {
        self.ttl
    }

    /// Standbys held now (the expired ones not counted).
    #[must_use]
    pub fn len(&self) -> usize {
        let mut held = self.lock();
        self.prune(&mut held);
        held.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Hold `value` as `key`'s standby of `kind`. It replaces the one of the same kind (the
    /// newer is the warmer); past the budget the oldest goes. A pool that is off drops it.
    pub fn put(&self, key: K, kind: P, value: T) {
        if !self.enabled {
            return;
        }
        let mut held = self.lock();
        self.prune(&mut held);
        held.retain(|h| !(h.key == key && h.kind == kind));
        while held.len() >= self.max_held && !held.is_empty() {
            held.remove(0);
        }
        held.push(Held { key, kind, value, at: Instant::now() });
    }

    /// Take `key`'s newest standby that `usable` accepts (a liveness check, the address still
    /// among the peer's). Every one it refuses is dropped: a dead standby is never offered twice.
    pub fn take(&self, key: &K, mut usable: impl FnMut(&P, &T) -> bool) -> Option<(P, T)> {
        if !self.enabled {
            return None;
        }
        let mut held = self.lock();
        self.prune(&mut held);
        while let Some(index) = held.iter().rposition(|h| h.key == *key) {
            let h = held.remove(index);
            if usable(&h.kind, &h.value) {
                return Some((h.kind, h.value));
            }
        }
        None
    }

    fn prune(&self, held: &mut Vec<Held<K, P, T>>) {
        let ttl = self.ttl;
        held.retain(|h| h.at.elapsed() < ttl);
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<Held<K, P, T>>> {
        self.held.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

#[cfg(test)]
#[path = "standby_tests.rs"]
mod tests;
