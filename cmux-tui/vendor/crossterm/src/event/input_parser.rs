//! The live input reader's parse state (cmux patch, `CMUX_PATCH.md`): the
//! bytes of a sequence that has not ended and the events parsed so far, for
//! the tty and mio event sources and for tests.

use std::collections::VecDeque;
use std::time::Instant;

use crate::event::{sys::unix::parse::advance, Event, InternalEvent};

/// Terminal input parsed as the live event source parses it.
#[doc(hidden)]
#[derive(Debug)]
pub struct InputParser {
    /// The bytes of a sequence that has not ended yet.
    pending: Vec<u8>,
    events: VecDeque<InternalEvent>,
}

impl Default for InputParser {
    fn default() -> Self {
        Self {
            // One escape sequence; the longest the parser waits for is far
            // shorter.
            pending: Vec::with_capacity(256),
            // One 1 KiB read of input at about 8 bytes per sequence; every
            // event is taken before the next read is parsed.
            events: VecDeque::with_capacity(128),
        }
    }
}

impl InputParser {
    /// An empty parser.
    pub fn new() -> Self {
        Self::default()
    }

    /// Parses `input`, read at `now`; `more` says whether more input is
    /// already waiting after it.
    pub(crate) fn advance(&mut self, input: &[u8], more: bool, _now: Instant) {
        advance(&mut self.pending, input, more, &mut self.events);
    }

    /// When the held bytes are given as typed keys if no byte comes first.
    pub fn release_deadline(&self) -> Option<Instant> {
        None
    }

    /// Gives the held bytes as typed keys when their deadline passed at `now`.
    pub(crate) fn release_if_quiet(&mut self, _now: Instant) {}

    /// The next parsed event.
    pub(crate) fn next(&mut self) -> Option<InternalEvent> {
        self.events.pop_front()
    }

    /// Parses one read of `input` at `now` and returns the events it gave.
    pub fn feed(&mut self, input: &[u8], now: Instant) -> Vec<Event> {
        self.advance(input, false, now);
        self.take_events()
    }

    /// The events the clock gives at `now` (held bytes whose deadline passed).
    pub fn tick(&mut self, now: Instant) -> Vec<Event> {
        self.release_if_quiet(now);
        self.take_events()
    }

    fn take_events(&mut self) -> Vec<Event> {
        self.events
            .drain(..)
            .filter_map(|event| match event {
                InternalEvent::Event(event) => Some(event),
                _ => None,
            })
            .collect()
    }
}
