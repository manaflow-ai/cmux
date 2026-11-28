//! Hybrid logical clocks (Kulkarni, Demirbas et al., "Logical Physical Clocks and Consistent
//! Snapshots in Globally Distributed Databases", 2014).
//!
//! A [`Stamp`] is (wall milliseconds, counter, actor). It follows the wall clock while the wall
//! clock moves forward, never goes backwards when it does not, and once a replica has
//! [observed](Clock::observe) a remote stamp, its next stamp is greater. Last-writer-wins then
//! means "the edit made last, as the people involved saw it", even across a phone whose clock is
//! a few seconds slow. The actor id breaks the last ties, so two stamps from different replicas
//! are never equal and every replica picks the same winner.

use std::fmt;

use serde::{Deserialize, Serialize};

/// Maximum amount by which a remote clock may move this clock ahead of its wall clock.
///
/// A stamp remains valid map data when it exceeds this bound, but it cannot make future local
/// stamps inherit an unbounded clock error. Five minutes covers normal mobile clock skew while
/// putting a finite bound on a misconfigured or malicious peer.
pub const MAX_DRIFT_MS: u64 = 5 * 60 * 1_000;

/// A replica's id: one per (device, process) that edits, e.g. `mac:<install id>`, `vm:<machine
/// id>`, `phone:<install id>`. It must be stable across restarts for the replica's own sequence
/// numbers to stay meaningful, and unique: two replicas sharing one lose edits to each other.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Actor(pub String);

impl Actor {
    pub fn new(id: impl Into<String>) -> Self {
        Self(id.into())
    }
}

impl fmt::Display for Actor {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// One edit's time. Ordered by `ms`, then `n`, then `actor` (the field order).
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct Stamp {
    /// Wall-clock milliseconds since the Unix epoch, or the largest seen if larger.
    pub ms: u64,
    /// Orders stamps within one millisecond.
    pub n: u32,
    pub actor: Actor,
}

/// A replica's clock. Pure: the caller passes the wall time.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Clock {
    actor: Actor,
    ms: u64,
    n: u32,
}

impl Clock {
    pub fn new(actor: Actor) -> Self {
        Self { actor, ms: 0, n: 0 }
    }

    pub fn actor(&self) -> &Actor {
        &self.actor
    }

    /// The stamp for a new local edit at wall time `wall_ms`: greater than every stamp this clock
    /// has made or observed.
    pub fn now(&mut self, wall_ms: u64) -> Stamp {
        if wall_ms > self.ms {
            self.ms = wall_ms;
            self.n = 0;
        } else if let Some(n) = self.n.checked_add(1) {
            self.n = n;
        } else {
            // 4 billion edits in one millisecond: borrow the next millisecond rather than wrap.
            self.ms += 1;
            self.n = 0;
        }
        Stamp { ms: self.ms, n: self.n, actor: self.actor.clone() }
    }

    /// Take a remote stamp into account, so the next [`now`](Self::now) orders after it. Returns
    /// how far ahead of `wall_ms` the remote stamp was (0 when not ahead). A remote stamp farther
    /// than [`MAX_DRIFT_MS`] is still valid map data, but does not move this clock forward.
    pub fn observe(&mut self, remote: &Stamp, wall_ms: u64) -> u64 {
        let ahead_ms = remote.ms.saturating_sub(wall_ms);
        if ahead_ms <= MAX_DRIFT_MS && (remote.ms, remote.n) > (self.ms, self.n) {
            self.ms = remote.ms;
            self.n = remote.n;
        }
        ahead_ms
    }
}

#[cfg(test)]
#[path = "hlc_tests.rs"]
mod tests;
