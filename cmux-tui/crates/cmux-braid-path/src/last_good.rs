//! The route that last won per peer and network, how fast it connected, and which routes are
//! broken on this network.
//!
//! A dial that remembers its winner puts it first next time and starts the backup after 1.5
//! times its connect time instead of a fixed stagger: on a dual-stack network whose IPv6 is
//! black-holed, the reconnect goes straight to IPv4 instead of waiting out the dead IPv6
//! attempt again. An entry lasts [`LastGood::ttl`]; a peer whose every attempt failed is
//! forgotten.
//!
//! Winners are kept per network ([`Fingerprint`], the routing table's IPv4 source and IPv6
//! /64), as Chromium keeps QUIC's per network: the leg that won at home is not
//! the one tried first on a café's Wi-Fi that blocks UDP, and back home the home winner leads
//! again. A route that fails on a network is marked broken there with exponential backoff
//! (Chromium's broken alternative services: [`BROKEN_FIRST`], doubling each failure, at most
//! [`BROKEN_LONGEST`]); while broken it is raced late, after every route that is not, never
//! skipped. A success clears its mark, and a change of network clears every mark.
use std::collections::HashMap;
use std::fmt;
use std::hash::Hash;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::network::Fingerprint;

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

/// How long a route that failed on this network is raced late the first time (Chromium's
/// broken alternative service: 5 minutes).
pub const BROKEN_FIRST: Duration = Duration::from_secs(5 * 60);
/// The most doublings of [`BROKEN_FIRST`] (5 min × 2^8 = 21 h 20 min): past it a route that
/// keeps failing stays late for that long each time.
const BROKEN_MAX_DOUBLINGS: u32 = 8;
/// The longest a route stays broken after one more failure.
pub const BROKEN_LONGEST: Duration =
    Duration::from_secs(BROKEN_FIRST.as_secs() << BROKEN_MAX_DOUBLINGS);

/// A route that failed on the current network.
#[derive(Clone, Debug)]
struct Broken<A> {
    target: A,
    /// Failures in a row on this network; each doubles the backoff.
    strikes: u32,
    /// Raced late until then.
    until: tokio::time::Instant,
}

/// Which network the process is on now (`None`: not known, one shared bucket).
type NetworkProbe = Arc<dyn Fn() -> Option<Fingerprint> + Send + Sync>;

struct State<K, A> {
    /// The network the last call saw; a different one clears `broken`.
    network: Option<Fingerprint>,
    entries: HashMap<(Option<Fingerprint>, K), Remembered<A>>,
    broken: HashMap<K, Vec<Broken<A>>>,
}

/// Last good route per key and network, shared by every dial in the process.
pub struct LastGood<K, A> {
    ttl: Duration,
    enabled: bool,
    /// The dial's name in the per-leg record ([`crate::legs`]).
    name: &'static str,
    probe: NetworkProbe,
    state: Mutex<State<K, A>>,
}

impl<K, A> fmt::Debug for LastGood<K, A> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("LastGood")
            .field("name", &self.name)
            .field("ttl", &self.ttl)
            .field("enabled", &self.enabled)
            .finish()
    }
}

/// The environment switch: `CMUX_BRAID_LAST_GOOD=0` turns the memory off (every dial as
/// before this crate), for a before/after measurement or if it misbehaves.
pub const ENV_SWITCH: &str = "CMUX_BRAID_LAST_GOOD";

/// How long a winner is trusted: networks change (Wi-Fi to cellular, a VPN up) but a reconnect
/// within minutes is usually on the same one.
pub const DEFAULT_TTL: Duration = Duration::from_secs(10 * 60);

impl<K: Eq + Hash + Clone, A: Clone + PartialEq> LastGood<K, A> {
    /// A memory whose entries last `ttl`, enabled, with every dial on one network (tests, and
    /// callers that key by network themselves). [`Self::from_env`] reads the real one.
    #[must_use]
    pub fn new(ttl: Duration) -> Self {
        Self {
            ttl,
            enabled: true,
            name: "dial",
            probe: Arc::new(|| None),
            state: Mutex::new(State {
                network: None,
                entries: HashMap::new(),
                broken: HashMap::new(),
            }),
        }
    }

    /// A memory with [`DEFAULT_TTL`] on this computer's network ([`Fingerprint::current`]), off
    /// when [`ENV_SWITCH`] is `0`.
    #[must_use]
    pub fn from_env() -> Self {
        let enabled = std::env::var(ENV_SWITCH).map_or(true, |value| value.trim() != "0");
        Self { enabled, ..Self::new(DEFAULT_TTL).on_network(Fingerprint::current) }
    }

    /// This memory, reading the network it is on from `probe` before each use.
    #[must_use]
    pub fn on_network(
        mut self,
        probe: impl Fn() -> Option<Fingerprint> + Send + Sync + 'static,
    ) -> Self {
        self.probe = Arc::new(probe);
        self
    }

    /// This memory, its races counted under `name` in the per-leg record ([`crate::legs`]).
    #[must_use]
    pub fn named(mut self, name: &'static str) -> Self {
        self.name = name;
        self
    }

    /// The dial's name in the per-leg record.
    #[must_use]
    pub fn name(&self) -> &'static str {
        self.name
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

    /// The state, with the network read now: on a different network than the last call saw,
    /// every broken mark is cleared (a route that failed on the old network gets a fresh try).
    fn state(&self) -> (std::sync::MutexGuard<'_, State<K, A>>, Option<Fingerprint>) {
        let network = (self.probe)();
        let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if state.network != network {
            state.network = network;
            state.broken.clear();
        }
        (state, network)
    }

    /// `candidates` with the remembered winner for `key` on this network first, then the rest
    /// in their order, routes broken on this network last (still raced, only late), and the
    /// winner's connect time. No winner first, with no time, when nothing fresh is remembered,
    /// the winner is not among the candidates (the resolver's answer moved), or it is broken.
    #[must_use]
    pub fn order(&self, key: &K, candidates: &[A]) -> (Vec<A>, Option<Duration>) {
        if !self.enabled {
            return (candidates.to_vec(), None);
        }
        let now = tokio::time::Instant::now();
        let (mut state, network) = self.state();
        let broken: Vec<A> = state
            .broken
            .get(key)
            .map(|marks| {
                marks
                    .iter()
                    .filter(|mark| mark.until > now)
                    .map(|mark| mark.target.clone())
                    .collect()
            })
            .unwrap_or_default();
        let winner = fresh(&mut state, network, key, self.ttl)
            .filter(|winner| !broken.contains(&winner.target));
        drop(state);
        let (late, mut ordered): (Vec<A>, Vec<A>) =
            candidates.iter().cloned().partition(|candidate| broken.contains(candidate));
        let mut lead = None;
        if let Some(winner) = winner
            && let Some(position) = ordered.iter().position(|candidate| *candidate == winner.target)
        {
            let first = ordered.remove(position);
            ordered.insert(0, first);
            lead = Some(winner.connect);
        }
        ordered.extend(late);
        (ordered, lead)
    }

    /// The fresh entry for `key` on this network, if any.
    #[must_use]
    pub fn get(&self, key: &K) -> Option<Remembered<A>> {
        if !self.enabled {
            return None;
        }
        let (mut state, network) = self.state();
        fresh(&mut state, network, key, self.ttl)
    }

    /// Whether `target` is broken for `key` on this network now.
    #[must_use]
    pub fn is_broken(&self, key: &K, target: &A) -> bool {
        let now = tokio::time::Instant::now();
        let (state, _) = self.state();
        state.broken.get(key).is_some_and(|marks| {
            marks.iter().any(|mark| mark.target == *target && mark.until > now)
        })
    }

    /// Remembers that `target` won for `key` on this network in `connect`, and clears its
    /// broken mark.
    pub fn record(&self, key: K, target: A, connect: Duration) {
        if !self.enabled {
            return;
        }
        let (mut state, network) = self.state();
        if let Some(marks) = state.broken.get_mut(&key) {
            marks.retain(|mark| mark.target != target);
        }
        state.entries.insert((network, key), Remembered { target, connect, at: Instant::now() });
    }

    /// `target` failed for `key` on this network (refused, timed out, unreachable): it is
    /// raced late for [`BROKEN_FIRST`], doubled for each failure in a row since, and stops
    /// being this network's winner when it was.
    pub fn failed(&self, key: &K, target: &A) {
        if !self.enabled {
            return;
        }
        let now = tokio::time::Instant::now();
        let (mut state, network) = self.state();
        let winner_key = (network, key.clone());
        if state.entries.get(&winner_key).is_some_and(|winner| winner.target == *target) {
            state.entries.remove(&winner_key);
        }
        let marks = state.broken.entry(key.clone()).or_default();
        let strikes = match marks.iter_mut().find(|mark| mark.target == *target) {
            Some(mark) => {
                // A failure while still marked (another dial's attempt already in flight)
                // does not double the backoff again.
                if mark.until <= now {
                    mark.strikes = mark.strikes.saturating_add(1);
                }
                mark.strikes
            }
            None => {
                marks.push(Broken { target: target.clone(), strikes: 1, until: now });
                1
            }
        };
        let backoff = broken_for(strikes);
        if let Some(mark) = marks.iter_mut().find(|mark| mark.target == *target) {
            mark.until = mark.until.max(now + backoff);
        }
    }

    /// Forgets `key` on this network (every attempt failed: the remembered route is no better
    /// than any other).
    pub fn forget(&self, key: &K) {
        let (mut state, network) = self.state();
        state.entries.remove(&(network, key.clone()));
    }
}

/// How long a route is raced late after its `strikes`th failure in a row: [`BROKEN_FIRST`],
/// doubled for each failure before it, at most [`BROKEN_LONGEST`].
#[must_use]
pub fn broken_for(strikes: u32) -> Duration {
    BROKEN_FIRST * (1_u32 << strikes.saturating_sub(1).min(BROKEN_MAX_DOUBLINGS))
}

fn fresh<K: Eq + Hash + Clone, A: Clone>(
    state: &mut State<K, A>,
    network: Option<Fingerprint>,
    key: &K,
    ttl: Duration,
) -> Option<Remembered<A>> {
    let entry_key = (network, key.clone());
    let fresh = state.entries.get(&entry_key).is_some_and(|entry| entry.at.elapsed() < ttl);
    if !fresh {
        state.entries.remove(&entry_key);
        return None;
    }
    state.entries.get(&entry_key).cloned()
}

#[cfg(test)]
#[path = "last_good_tests.rs"]
mod tests;
