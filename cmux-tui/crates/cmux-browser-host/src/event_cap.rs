//! The cap on driver events waiting in a queue. The page drives how many
//! events come (console lines, requests), and the producers (the CDP reader,
//! the event thread) must never wait, so past the cap an event is dropped and
//! counted, and the consumer reports the count once as an
//! [`EVENTS_DROPPED_EVENT`]. Chrome bounds the console messages it keeps for
//! DevTools the same way (`kMaxConsoleMessageCount`,
//! v8/src/inspector/v8-console-message.cc).

use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};

/// The event that reports events dropped at a full queue:
/// `{"count": <events dropped>}`.
pub const EVENTS_DROPPED_EVENT: &str = "events.dropped";

/// Events one queue holds before it drops new ones.
pub(crate) const EVENT_QUEUE_CAP: usize = 4096;

/// Shared by a queue's producers and its consumer.
#[derive(Clone)]
pub(crate) struct EventCap {
    counts: Arc<Counts>,
}

struct Counts {
    cap: usize,
    queued: AtomicUsize,
    dropped: AtomicU64,
}

impl EventCap {
    pub(crate) fn new(cap: usize) -> EventCap {
        EventCap {
            counts: Arc::new(Counts {
                cap,
                queued: AtomicUsize::new(0),
                dropped: AtomicU64::new(0),
            }),
        }
    }

    /// Takes a place for one event; `false` when the queue is full, and the
    /// caller drops the event (it is counted).
    pub(crate) fn admit(&self) -> bool {
        let c = &self.counts;
        let admitted = c
            .queued
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |q| (q < c.cap).then_some(q + 1))
            .is_ok();
        if !admitted {
            c.dropped.fetch_add(1, Ordering::AcqRel);
        }
        admitted
    }

    /// Gives back the place of an event that was admitted but never queued
    /// (its receiver was gone).
    pub(crate) fn release(&self) {
        self.counts.queued.fetch_sub(1, Ordering::AcqRel);
    }

    /// The consumer took one admitted event. Returns the marker to deliver
    /// after it when events were dropped since the last marker. A drop
    /// happens only while the queue is full, so an event taken after it
    /// always carries its count.
    pub(crate) fn taken(&self) -> Option<Value> {
        self.release();
        let dropped = self.counts.dropped.swap(0, Ordering::AcqRel);
        (dropped > 0).then(|| json!({ "count": dropped }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn past_the_cap_events_are_dropped_and_reported_once() {
        let cap = EventCap::new(2);
        assert!(cap.admit());
        assert!(cap.admit());
        assert!(!cap.admit(), "a full queue drops the event");
        assert!(!cap.admit());
        assert_eq!(cap.taken(), Some(json!({ "count": 2 })), "the next event taken reports drops");
        assert_eq!(cap.taken(), None, "the count is reported once");
        assert!(cap.admit(), "a taken event frees its place");
    }

    #[test]
    fn a_released_place_is_free_again() {
        let cap = EventCap::new(1);
        assert!(cap.admit());
        cap.release();
        assert!(cap.admit());
        assert_eq!(cap.taken(), None);
    }
}
