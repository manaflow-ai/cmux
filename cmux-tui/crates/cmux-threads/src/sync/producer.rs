//! A channel's producer and the override its waiters start on it (task 238;
//! the rule is in the [`super`] module doc).

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use crate::qos::ThreadQos;
use crate::qos::boost::{self, Override};
use crate::registry::{self, Row};

/// Overrides channel waiters started on their producers, the ones they
/// ended, and the waits on a lower producer that started none (Linux, a
/// refusal, or a producer that exited).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ProducerBoosts {
    pub started: u64,
    pub ended: u64,
    pub unboosted: u64,
}

impl ProducerBoosts {
    /// Overrides in force: waits that boosted their producer and have not
    /// ended.
    pub fn open(&self) -> u64 {
        self.started.saturating_sub(self.ended)
    }
}

#[derive(Debug, Default)]
struct Counters {
    started: AtomicU64,
    ended: AtomicU64,
    unboosted: AtomicU64,
}

impl Counters {
    const fn new() -> Self {
        Self { started: AtomicU64::new(0), ended: AtomicU64::new(0), unboosted: AtomicU64::new(0) }
    }

    fn read(&self) -> ProducerBoosts {
        // Ended first: a reader never sees more ends than starts.
        let ended = self.ended.load(Ordering::Relaxed);
        ProducerBoosts {
            started: self.started.load(Ordering::Relaxed),
            ended,
            unboosted: self.unboosted.load(Ordering::Relaxed),
        }
    }
}

static PROCESS: Counters = Counters::new();

/// The producer boosts of every channel in the process.
pub fn producer_boosts() -> ProducerBoosts {
    PROCESS.read()
}

/// The channel's producer record: senders write it, receivers wait on it.
pub(super) type Shared = Arc<Producer>;

/// The producer of one channel, shared by its senders and receivers.
#[derive(Debug, Default)]
pub(super) struct Producer {
    /// The [`Row::key`] of the registered thread that sent last, 0 when an
    /// unregistered thread did or none has.
    last: AtomicU64,
    counters: Counters,
}

impl Producer {
    /// Records the calling thread as the producer; called on every send.
    #[inline]
    pub(super) fn sent(&self) {
        let key = registry::current_key();
        if self.last.load(Ordering::Relaxed) != key {
            self.last.store(key, Ordering::Relaxed);
        }
    }

    /// The calling thread waits for the next message until the result drops.
    pub(super) fn wait(&self) -> ProducerWait<'_> {
        ProducerWait { producer: self, active: self.boost() }
    }

    /// This channel's producer boosts.
    pub(super) fn boosts(&self) -> ProducerBoosts {
        self.counters.read()
    }

    fn boost(&self) -> Option<Override> {
        let (id, sent_at) = registry::unpack_key(self.last.load(Ordering::Relaxed));
        if id == 0 {
            return None;
        }
        let consumer = boost::current_class()?;
        if sent_at >= consumer {
            return None;
        }
        match registry::with_live_row(id, |row| lift(row, consumer)) {
            Some(Lift::NotLower) => None,
            Some(Lift::Started(active)) => {
                self.count(|counters| &counters.started);
                Some(active)
            }
            Some(Lift::Unboosted) | None => {
                self.count(|counters| &counters.unboosted);
                None
            }
        }
    }

    fn count(&self, counter: fn(&Counters) -> &AtomicU64) {
        counter(&self.counters).fetch_add(1, Ordering::Relaxed);
        counter(&PROCESS).fetch_add(1, Ordering::Relaxed);
    }
}

enum Lift {
    /// The producer runs at the waiter's class or above now.
    NotLower,
    Started(Override),
    Unboosted,
}

/// Raises the live producer `row` to the waiter's `consumer` class. Runs
/// under the registry lock: one override start, no wait.
fn lift(row: &Row, consumer: ThreadQos) -> Lift {
    if row.class() >= consumer {
        return Lift::NotLower;
    }
    if !boost::ENDS_AFTER_TARGET_EXITS {
        return Lift::Unboosted;
    }
    boost::start(boost::target_of(row.native()), consumer).map_or(Lift::Unboosted, Lift::Started)
}

/// A wait for a channel's next message; ends the producer's override, if it
/// started one, when it drops. The producer may have exited by then (see
/// `boost::ENDS_AFTER_TARGET_EXITS`).
pub(super) struct ProducerWait<'a> {
    producer: &'a Producer,
    active: Option<Override>,
}

impl Drop for ProducerWait<'_> {
    fn drop(&mut self) {
        if let Some(active) = self.active.take() {
            boost::end(active);
            self.producer.count(|counters| &counters.ended);
        }
    }
}

#[cfg(test)]
#[path = "producer_tests.rs"]
mod tests;
