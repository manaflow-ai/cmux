//! Version vectors over dots, for have/want delta sync.
//!
//! Every edit gets a [`Dot`]: its replica and that replica's next sequence number. A [`Vv`] maps
//! each replica to the highest sequence whose effect a state includes: "covers (a, 7)" means the
//! state holds edit 7 of `a` or an edit that replaced it. A reconnect sends the receiver's `Vv`
//! and gets back only the entries whose dots it does not cover (git's have/want negotiation, at
//! the granularity of one edit), so the bytes moved follow the edits missed, not the state's size.

use std::cmp::Ordering;
use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::hlc::Actor;

/// One edit's identity: its replica and that replica's sequence number (from 1).
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct Dot {
    pub actor: Actor,
    pub seq: u64,
}

/// Replica -> the highest sequence covered. Absent is 0.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Vv(BTreeMap<Actor, u64>);

impl Vv {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn get(&self, actor: &Actor) -> u64 {
        self.0.get(actor).copied().unwrap_or(0)
    }

    pub fn set(&mut self, actor: Actor, seq: u64) {
        if seq == 0 {
            self.0.remove(&actor);
        } else {
            self.0.insert(actor, seq);
        }
    }

    pub fn covers(&self, dot: &Dot) -> bool {
        self.get(&dot.actor) >= dot.seq
    }

    /// The pointwise maximum.
    pub fn join(&mut self, other: &Vv) {
        for (actor, &seq) in &other.0 {
            let mine = self.0.entry(actor.clone()).or_insert(0);
            *mine = (*mine).max(seq);
        }
    }

    /// Covers everything `other` covers.
    pub fn dominates(&self, other: &Vv) -> bool {
        other.0.iter().all(|(actor, &seq)| self.get(actor) >= seq)
    }

    /// `Some` when one covers the other (or they are equal), `None` when each has edits the other
    /// lacks (concurrent).
    pub fn partial_cmp_vv(&self, other: &Vv) -> Option<Ordering> {
        match (self.dominates(other), other.dominates(self)) {
            (true, true) => Some(Ordering::Equal),
            (true, false) => Some(Ordering::Greater),
            (false, true) => Some(Ordering::Less),
            (false, false) => None,
        }
    }

    /// How many edits this covers in all: a total order for picking among concurrent vectors.
    pub fn total(&self) -> u64 {
        self.0.values().fold(0u64, |sum, &seq| sum.saturating_add(seq))
    }

    pub fn iter(&self) -> impl Iterator<Item = (&Actor, u64)> {
        self.0.iter().map(|(a, &s)| (a, s))
    }

    /// The pointwise minimum of several: what all of them cover (for dropping tombstones).
    pub fn meet(all: &[Vv]) -> Vv {
        let Some((first, rest)) = all.split_first() else {
            return Vv::new();
        };
        let mut out = first.clone();
        out.0.retain(|actor, seq| {
            for other in rest {
                *seq = (*seq).min(other.get(actor));
            }
            *seq > 0
        });
        out
    }
}

impl<const N: usize> From<[(&str, u64); N]> for Vv {
    fn from(pairs: [(&str, u64); N]) -> Self {
        let mut vv = Vv::new();
        for (actor, seq) in pairs {
            vv.set(Actor::new(actor), seq);
        }
        vv
    }
}

#[cfg(test)]
#[path = "vv_tests.rs"]
mod tests;
