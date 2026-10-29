//! The driver's event thread: driver events go to the sink from it, in
//! order, so a sink that answers an event with a driver call cannot block
//! the CDP reader. A flush lets a call wait until the events sent before it
//! reached the sink (a file chooser's event before its input's reply).

use super::driver::Inner;
use crate::driver::EventSink;
use crate::protocol::{DriverError, DriverEvent};
use std::sync::{PoisonError, mpsc};
use std::time::Duration;

/// What the event thread gets: an event for the sink, or a flush to answer
/// once the events before it went to the sink.
pub(super) enum Dispatch {
    Event(DriverEvent),
    Flush(mpsc::SyncSender<()>),
}

/// Starts the event thread for `sink`.
pub(super) fn start(sink: EventSink) -> Result<mpsc::Sender<Dispatch>, DriverError> {
    let (tx, rx) = mpsc::channel::<Dispatch>();
    // supervise-allow: the driver's event thread, ending when its sender drops; a sink that panics loses that one event, and the thread delivers the next.
    cmux_threads::spawn(
        "cmux-browser-host-cdp-events",
        cmux_threads::ThreadQos::UserInitiated,
        move || {
            for item in rx {
                match item {
                    Dispatch::Event(event) => {
                        let delivered =
                            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| sink(event)));
                        if delivered.is_err() {
                            eprintln!("cmux-browser-host: a driver event handler panicked");
                        }
                    }
                    Dispatch::Flush(done) => {
                        let _ = done.send(());
                    }
                }
            }
        },
    )
    .map_err(|e| DriverError::closed(format!("could not start the event thread: {e}")))?;
    Ok(tx)
}

impl Inner {
    /// Sends a driver event made off the reader thread (a follow-up's).
    pub(super) fn emit(&self, event: DriverEvent) {
        let _ =
            self.events.lock().unwrap_or_else(PoisonError::into_inner).send(Dispatch::Event(event));
    }

    /// Waits (at most `wait`) until the sink took every event sent so far.
    pub(super) fn flush_events(&self, wait: Duration) {
        let (done, flushed) = mpsc::sync_channel(1);
        let sent =
            self.events.lock().unwrap_or_else(PoisonError::into_inner).send(Dispatch::Flush(done));
        if sent.is_ok() {
            let _ = flushed.recv_timeout(wait);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    /// A sink that panics on one event loses that event only: the thread
    /// delivers the next event and answers a flush.
    #[test]
    fn a_panicking_sink_loses_one_event_and_the_thread_keeps_serving() {
        let (seen_tx, seen) = mpsc::channel();
        let sink: EventSink = Arc::new(move |event: DriverEvent| {
            assert_ne!(event.name, "boom", "the sink failed");
            let _ = seen_tx.send(event.name);
        });
        let events = start(sink).unwrap();
        let event = |name: &str| {
            Dispatch::Event(DriverEvent { name: name.into(), payload: serde_json::Value::Null })
        };
        events.send(event("boom")).unwrap();
        events.send(event("after")).unwrap();
        let (done, flushed) = mpsc::sync_channel(1);
        events.send(Dispatch::Flush(done)).unwrap();
        let wait = Duration::from_secs(10);
        assert_eq!(flushed.recv_timeout(wait), Ok(()));
        assert_eq!(seen.recv_timeout(wait).as_deref(), Ok("after"));
    }
}
