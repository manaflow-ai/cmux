//! The live input reader's parse state (cmux patch, `CMUX_PATCH.md`): the
//! bytes of a sequence that has not ended and the events parsed so far, for
//! the tty and mio event sources and for tests.
//!
//! Alt+] and a digit (`ESC ] 1`, `ESC ] 1 1`) may be the start of a host
//! color reply (`ESC ] 1 1 ; rgb:… ST`), so the parser holds them for the
//! next byte. When no byte comes for [`HELD_REPLY_QUIET`], they are typed
//! keys: Alt+] and the digits. The time comes in as `now` on each call, so
//! tests give it and never wait.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use crate::event::{
    scan_host_reply, sys::unix::parse::advance, Event, HostReply, InternalEvent, KeyCode,
    KeyEvent, KeyModifiers,
};

/// How long held Alt+] digits wait for the next byte. A host writes its
/// color reply at once; a person types the next key much later.
const HELD_REPLY_QUIET: Duration = Duration::from_millis(50);

/// Where a host color reply's text starts: after `ESC ] 1 0 ;` or
/// `ESC ] 1 1 ;`. A held start this long has reply text and is never typed.
const REPLY_TEXT_START: usize = 5;

/// Terminal input parsed as the live event source parses it.
#[doc(hidden)]
#[derive(Debug)]
pub struct InputParser {
    /// The bytes of a sequence that has not ended yet.
    pending: Vec<u8>,
    events: VecDeque<InternalEvent>,
    /// When the held Alt+] digits in `pending` become keys: the quiet time
    /// after the last byte read.
    release_at: Option<Instant>,
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
            release_at: None,
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
    pub(crate) fn advance(&mut self, input: &[u8], more: bool, now: Instant) {
        advance(&mut self.pending, input, more, &mut self.events);
        // Each byte starts the quiet time again.
        self.release_at = self.holds_alt_digits().then(|| now + HELD_REPLY_QUIET);
    }

    /// When the held Alt+] digits become typed keys if no byte comes first;
    /// `None` when nothing is held.
    pub fn release_deadline(&self) -> Option<Instant> {
        self.release_at
    }

    /// Gives the held Alt+] digits as typed keys when their quiet time ended
    /// at `now`.
    pub(crate) fn release_if_quiet(&mut self, now: Instant) {
        match self.release_at {
            Some(release_at) if now >= release_at => self.release_at = None,
            _ => return,
        }
        if !self.holds_alt_digits() {
            return;
        }
        let held: Vec<u8> = self.pending.drain(..).collect();
        self.events.push_back(InternalEvent::Event(Event::Key(KeyEvent::new(
            KeyCode::Char(']'),
            KeyModifiers::ALT,
        ))));
        // The digits are keys of their own, with nothing after them.
        advance(&mut self.pending, held.get(2..).unwrap_or_default(), false, &mut self.events);
    }

    /// How long an event source may wait for input at `now`: `leftover` of
    /// its caller's timeout (`None`: no limit), and no later than when the
    /// held Alt+] digits become keys.
    pub(crate) fn wait_limit(&self, leftover: Option<Duration>, now: Instant) -> Option<Duration> {
        let Some(release_at) = self.release_at else { return leftover };
        let until_release = release_at.saturating_duration_since(now);
        Some(leftover.map_or(until_release, |leftover| leftover.min(until_release)))
    }

    /// Whether `pending` is Alt+] and up to two digits that may start a
    /// host color reply, with no reply text yet.
    fn holds_alt_digits(&self) -> bool {
        self.pending.len() < REPLY_TEXT_START
            && scan_host_reply(&self.pending) == HostReply::Partial
    }

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
