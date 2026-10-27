//! The driver's event thread: driver events go to the sink from it, in
//! order, so a sink that answers an event with a driver call cannot block
//! the CDP reader. A flush lets a call wait until the events sent before it
//! reached the sink (a file chooser's event before its input's reply).

use super::driver::Inner;
use crate::driver::EventSink;
use crate::event_cap::{EVENTS_DROPPED_EVENT, EventCap};
use crate::protocol::{DriverError, DriverEvent};
use std::sync::{PoisonError, mpsc};
use std::time::Duration;

/// What the event thread gets: an event for the sink, or a flush to answer
/// once the events before it went to the sink.
pub(super) enum Dispatch {
    Event(DriverEvent),
    Flush(mpsc::SyncSender<()>),
}

/// The event thread's queue. Events are capped ([`EventCap`]): past the cap
/// a new event is dropped and counted, so the CDP reader never waits and a
/// slow sink never grows the queue without limit. A flush always gets in.
pub(super) struct EventQueue {
    tx: mpsc::Sender<Dispatch>,
    cap: EventCap,
}

impl EventQueue {
    /// Queues `event`, or drops and counts it while the queue is full.
    pub(super) fn event(&self, event: DriverEvent) {
        if self.cap.admit() && self.tx.send(Dispatch::Event(event)).is_err() {
            self.cap.release();
        }
    }

    /// Queues a flush; `false` once the event thread ended.
    pub(super) fn flush(&self, done: mpsc::SyncSender<()>) -> bool {
        self.tx.send(Dispatch::Flush(done)).is_ok()
    }
}

/// Starts the event thread for `sink`, with a queue of `cap` events
/// ([`crate::event_cap::EVENT_QUEUE_CAP`] outside tests).
pub(super) fn start(sink: EventSink, cap: usize) -> Result<EventQueue, DriverError> {
    let cap = EventCap::new(cap);
    // unbounded-allow: events hold at most `cap` places (`EventQueue::event` drops and counts the
    // rest); flushes are one per caller waiting in `flush_events`
    let (tx, rx) = mpsc::channel::<Dispatch>();
    let taken = cap.clone();
    std::thread::Builder::new()
        .name("cmux-browser-host-cdp-events".into())
        .spawn(move || {
            for item in rx {
                match item {
                    Dispatch::Event(event) => {
                        let dropped = taken.taken();
                        sink(event);
                        if let Some(payload) = dropped {
                            sink(DriverEvent { name: EVENTS_DROPPED_EVENT.to_owned(), payload });
                        }
                    }
                    Dispatch::Flush(done) => {
                        let _ = done.send(());
                    }
                }
            }
        })
        .map_err(|e| DriverError::closed(format!("could not start the event thread: {e}")))?;
    Ok(EventQueue { tx, cap })
}

impl Inner {
    /// Sends a driver event made off the reader thread (a follow-up's).
    pub(super) fn emit(&self, event: DriverEvent) {
        self.events.lock().unwrap_or_else(PoisonError::into_inner).event(event);
    }

    /// Waits (at most `wait`) until the sink took every event sent so far.
    pub(super) fn flush_events(&self, wait: Duration) {
        let (done, flushed) = mpsc::sync_channel(1);
        let sent = self.events.lock().unwrap_or_else(PoisonError::into_inner).flush(done);
        if sent {
            let _ = flushed.recv_timeout(wait);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    fn event(name: &str) -> DriverEvent {
        DriverEvent { name: name.to_owned(), payload: serde_json::Value::Null }
    }

    #[test]
    fn a_slow_sink_drops_events_past_the_cap_and_reports_them() {
        // The sink holds the first event until the test lets it go, so the
        // queue fills behind it.
        let (entered_tx, entered) = mpsc::sync_channel::<()>(1);
        let (release, held) = mpsc::sync_channel::<()>(1);
        let gate = Mutex::new((entered_tx, held));
        let (seen_tx, seen) = mpsc::channel::<String>();
        let seen_tx = Mutex::new(seen_tx);
        let sink: EventSink = Arc::new(move |e: DriverEvent| {
            if e.name == "first" {
                let gate = gate.lock().unwrap();
                let _ = gate.0.send(());
                let _ = gate.1.recv();
            }
            let _ = seen_tx.lock().unwrap().send(e.name);
        });
        let queue = start(sink, 2).unwrap();
        queue.event(event("first"));
        entered.recv_timeout(Duration::from_secs(10)).unwrap();
        // The sink is busy: two events fill the queue, the third is dropped.
        queue.event(event("a"));
        queue.event(event("b"));
        queue.event(event("c"));
        release.send(()).unwrap();
        let (flushed_tx, flushed) = mpsc::sync_channel(1);
        assert!(queue.flush(flushed_tx));
        flushed.recv_timeout(Duration::from_secs(10)).unwrap();
        let names: Vec<String> = seen.try_iter().collect();
        assert_eq!(names, ["first", "a", EVENTS_DROPPED_EVENT, "b"]);
    }

    #[test]
    fn a_flush_gets_in_while_events_are_dropped() {
        let (release, held) = mpsc::sync_channel::<()>(1);
        let held = Mutex::new(held);
        let sink: EventSink = Arc::new(move |_| {
            let _ = held.lock().unwrap().recv();
        });
        let queue = start(sink, 1).unwrap();
        for _ in 0..8 {
            queue.event(event("e"));
        }
        let (flushed_tx, flushed) = mpsc::sync_channel(1);
        assert!(queue.flush(flushed_tx), "a full queue still takes a flush");
        // A closed channel ends every wait of the sink.
        drop(release);
        flushed.recv_timeout(Duration::from_secs(10)).unwrap();
    }
}
