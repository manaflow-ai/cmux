//! The route that last won per peer, and how fast it connected.
//!
//! A dial that remembers its winner puts it first next time and starts the backup after 1.5
//! times its connect time instead of a fixed stagger: on a dual-stack network whose IPv6 is
//! black-holed, the reconnect goes straight to IPv4 instead of waiting out the dead IPv6
//! attempt again. An entry lasts [`LastGood::ttl`]; a peer whose every attempt failed is
//! forgotten.

use std::collections::HashMap;
use std::hash::Hash;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// One remembered winner.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Remembered<A> {
    /// The target that won.
    pub target: A,
    /// How long its connect took.
    pub connect: Duration,
    /// When it won.
    pub at: Instant,
}

/// Last good route per key, shared by every dial in the process.
#[derive(Debug)]
pub struct LastGood<K, A> {
    ttl: Duration,
    enabled: bool,
    entries: Mutex<HashMap<K, Remembered<A>>>,
}

/// The environment switch: `CMUX_BRAID_LAST_GOOD=0` turns the memory off (every dial as
/// before this crate), for a before/after measurement or if it misbehaves.
pub const ENV_SWITCH: &str = "CMUX_BRAID_LAST_GOOD";

/// How long a winner is trusted: networks change (Wi-Fi to cellular, a VPN up) but a reconnect
/// within minutes is usually on the same one.
pub const DEFAULT_TTL: Duration = Duration::from_secs(10 * 60);

impl<K: Eq + Hash, A: Clone + PartialEq> LastGood<K, A> {
    /// A memory whose entries last `ttl`, enabled.
    #[must_use]
    pub fn new(ttl: Duration) -> Self {
        Self { ttl, enabled: true, entries: Mutex::new(HashMap::new()) }
    }

    /// A memory with [`DEFAULT_TTL`], off when [`ENV_SWITCH`] is `0`.
    #[must_use]
    pub fn from_env() -> Self {
        let enabled = std::env::var(ENV_SWITCH).map_or(true, |value| value.trim() != "0");
        Self { enabled, ..Self::new(DEFAULT_TTL) }
    }

    /// How long an entry lasts.
    #[must_use]
    pub fn ttl(&self) -> Duration {
        self.ttl
    }

    /// Whether the memory is on.
    #[must_use]
    pub fn enabled(&self) -> bool {
        self.enabled
    }

    /// `candidates` with the remembered winner for `key` first (the rest in their order), and
    /// its connect time. Unchanged, with no time, when nothing fresh is remembered or the
    /// winner is not among the candidates (the resolver's answer moved).
    #[must_use]
    pub fn order(&self, key: &K, candidates: &[A]) -> (Vec<A>, Option<Duration>) {
        let mut ordered = candidates.to_vec();
        let Some(remembered) = self.get(key) else { return (ordered, None) };
        let Some(position) = ordered.iter().position(|candidate| *candidate == remembered.target)
        else {
            return (ordered, None);
        };
        let winner = ordered.remove(position);
        ordered.insert(0, winner);
        (ordered, Some(remembered.connect))
    }

    /// The fresh entry for `key`, if any.
    #[must_use]
    pub fn get(&self, key: &K) -> Option<Remembered<A>> {
        if !self.enabled {
            return None;
        }
        let mut entries = self.entries.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let fresh = entries.get(key).is_some_and(|entry| entry.at.elapsed() < self.ttl);
        if !fresh {
            entries.remove(key);
            return None;
        }
        entries.get(key).cloned()
    }

    /// Remembers that `target` won for `key` in `connect`.
    pub fn record(&self, key: K, target: A, connect: Duration) {
        if !self.enabled {
            return;
        }
        let mut entries = self.entries.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        entries.insert(key, Remembered { target, connect, at: Instant::now() });
    }

    /// Forgets `key` (every attempt failed: the remembered route is no better than any other).
    pub fn forget(&self, key: &K) {
        let mut entries = self.entries.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        entries.remove(key);
    }
}

#[cfg(test)]
#[path = "last_good_tests.rs"]
mod tests;
