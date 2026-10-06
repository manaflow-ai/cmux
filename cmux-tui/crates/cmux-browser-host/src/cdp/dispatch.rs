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
    std::thread::Builder::new()
        .name("cmux-browser-host-cdp-events".into())
        .spawn(move || {
            for item in rx {
                match item {
                    Dispatch::Event(event) => sink(event),
                    Dispatch::Flush(done) => {
                        let _ = done.send(());
                    }
                }
            }
        })
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
