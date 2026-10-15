//! The session event stream `status wait` and `terminal <t> wait` wake on
//! (status/status_wait.rs, status/terminal_wait.rs). Each wakes, reads its
//! state again and waits for the next event, so an event is only a cue.
//!
//! The daemon ends a stream it can no longer follow with
//! `{"type":"stream_end","reason":"gap"}` (an outbound overflow, a journal
//! read error, a placement it could not restate: server/
//! session_event_stream.rs) and leaves the connection open. Its recovery
//! hint is a fresh snapshot, so the wait subscribes again: a new stream
//! starts with one, and the wait reads its state again, so a change during
//! the gap is never missed. A stream that ends before it delivered anything
//! (the daemon could not start it) fails the wait instead of subscribing in
//! a loop.

use std::io::BufReader;
use std::time::Instant;

use cmux_tui_core::platform::transport;
use serde_json::{Map, Value};

use super::super::resolve::{self, Failure, SocketRoute, answer_wait};
use super::super::wire;
use super::terminal_wait::past;

type Reader = BufReader<Box<dyn transport::Stream>>;

/// Why a wait stopped waiting for events.
pub(super) enum Stop {
    /// The deadline passed.
    TimedOut,
    /// Ctrl-C (or another shutdown signal).
    Interrupted,
    Failed(Failure),
}

pub(super) struct WaitEvents<'a> {
    socket: &'a SocketRoute<'a>,
    route: Map<String, Value>,
    events: Reader,
    /// Whether the current stream delivered anything since it opened.
    delivered: bool,
}

impl<'a> WaitEvents<'a> {
    /// Subscribes to the session of `params`. Call it before the first read:
    /// a change between that read and the subscription still wakes the wait
    /// (the stream starts with a snapshot).
    pub(super) fn open(
        socket: &'a SocketRoute<'a>,
        params: &Map<String, Value>,
        deadline: Option<Instant>,
    ) -> Result<Self, Stop> {
        let route = resolve::route(params);
        let events = subscribe(socket, &route, deadline)?;
        Ok(Self { socket, route, events, delivered: false })
    }

    /// Blocks until the next event, a new subscription after `stream_end`,
    /// or the deadline. `Ok(())` means: read the state again.
    pub(super) fn next(&mut self, deadline: Option<Instant>) -> Result<(), Stop> {
        let remaining = match deadline {
            None => None,
            Some(deadline) => match deadline.checked_duration_since(Instant::now()) {
                Some(remaining) if !remaining.is_zero() => Some(remaining),
                _ => return Err(Stop::TimedOut),
            },
        };
        if self.events.get_mut().set_read_timeout(remaining).is_err() {
            return Err(failed("cmux: cannot wait on the event stream".into()));
        }
        match wire::read_envelope(&mut self.events, false) {
            Ok(Some(envelope)) if envelope["type"] != "stream_end" => {
                self.delivered = true;
                Ok(())
            }
            _ if crate::shutdown_requested() => Err(Stop::Interrupted),
            Ok(Some(ended)) => self.subscribe_again(&ended, deadline),
            // The read timed out at the deadline: read the state once more
            // (a change may have landed just before it), then time out.
            Err(_) if past(deadline) => Ok(()),
            Ok(None) => Err(failed("cmux: the session's event stream ended".into())),
            Err(error) => Err(failed(error)),
        }
    }

    fn subscribe_again(&mut self, ended: &Value, deadline: Option<Instant>) -> Result<(), Stop> {
        let reason = ended["reason"].as_str().unwrap_or("unknown");
        if !self.delivered {
            return Err(failed(format!(
                "cmux: the session's event stream ended ({reason}) before its first event"
            )));
        }
        self.events = subscribe(self.socket, &self.route, deadline)?;
        self.delivered = false;
        Ok(())
    }
}

fn subscribe(
    socket: &SocketRoute<'_>,
    route: &Map<String, Value>,
    deadline: Option<Instant>,
) -> Result<Reader, Stop> {
    let opened = Instant::now() + answer_wait(deadline);
    let events = resolve::session_events(socket, route, opened).ok_or_else(|| {
        if past(deadline) {
            Stop::TimedOut
        } else {
            failed("cmux: the session's event stream did not open".into())
        }
    })?;
    // Ctrl-C shuts the stream down, which ends a wait without a timeout.
    wire::arm_signal_interrupt(events.get_ref().as_ref());
    Ok(events)
}

fn failed(message: String) -> Stop {
    Stop::Failed(Failure::Transport(message))
}
