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
    /// how far ahead of `wall_ms` the remote stamp was (0 when not ahead): a host can log or show
    /// a replica whose clock is far off, but the stamp is still taken, because refusing it would
    /// leave replicas disagreeing forever.
    pub fn observe(&mut self, remote: &Stamp, wall_ms: u64) -> u64 {
        if (remote.ms, remote.n) > (self.ms, self.n) {
            self.ms = remote.ms;
            self.n = remote.n;
        }
        remote.ms.saturating_sub(wall_ms)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn clock(id: &str) -> Clock {
        Clock::new(Actor::new(id))
    }

    #[test]
    fn stamps_never_go_backwards_when_the_wall_clock_does() {
        let mut c = clock("a");
        let first = c.now(1_000);
        let second = c.now(900);
        let third = c.now(900);
        assert!(first < second && second < third, "{first:?} {second:?} {third:?}");
        assert_eq!(second.ms, 1_000);
    }

    #[test]
    fn an_edit_after_seeing_a_remote_one_orders_after_it_even_with_a_slow_clock() {
        let mut fast = clock("fast");
        let mut slow = clock("slow");
        let theirs = fast.now(10_000);
        slow.observe(&theirs, 2_000);
        let mine = slow.now(2_001);
        assert!(mine > theirs);
    }

    #[test]
    fn observe_reports_how_far_ahead_a_remote_clock_runs() {
        let mut c = clock("a");
        let ahead = Stamp { ms: 5_000, n: 0, actor: Actor::new("b") };
        assert_eq!(c.observe(&ahead, 1_000), 4_000);
        assert_eq!(c.observe(&ahead, 9_000), 0);
    }

    #[test]
    fn the_actor_breaks_ties() {
        let a = Stamp { ms: 1, n: 0, actor: Actor::new("a") };
        let b = Stamp { ms: 1, n: 0, actor: Actor::new("b") };
        assert!(a < b);
    }

    #[test]
    fn the_counter_overflow_borrows_the_next_millisecond() {
        let mut c = clock("a");
        c.ms = 7;
        c.n = u32::MAX;
        let s = c.now(7);
        assert_eq!((s.ms, s.n), (8, 0));
    }
}
