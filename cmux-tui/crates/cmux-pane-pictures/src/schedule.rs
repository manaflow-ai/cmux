//! One tab's thumbnail schedule: a capture is due only after the tab's content changed (damage),
//! never on a timer. The first damage after a quiet spell is due at once (leading edge); after that
//! at most one capture starts per gap, a burst of damage is one trailing capture, and at most one
//! capture is in flight. Nothing is due while no card watches the tab.
//!
//! No clock and no timers: the caller passes `now_ms` (monotonic milliseconds) and arms one timer
//! at [`PictureSchedule::due_at`], then asks [`PictureSchedule::take_due`] when it fires.

/// Default gap for a terminal tab.
pub const TERMINAL_GAP_MS: u64 = 200;
/// Default gap for a page tab (browser, chat, markdown): its capture costs the main thread a
/// Chromium encode.
pub const PAGE_GAP_MS: u64 = 500;

/// The largest backoff multiplier (8x the gap).
const MAX_BACKOFF: u64 = 8;

/// A schedule event, as the C ABI numbers it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum Event {
    /// A card shows the tab; clears `unavailable`.
    Watched = 1,
    /// No card shows the tab.
    Unwatched = 2,
    /// The tab's content changed.
    Damaged = 3,
}

impl Event {
    pub fn from_raw(raw: u32) -> Option<Self> {
        Some(match raw {
            1 => Self::Watched,
            2 => Self::Unwatched,
            3 => Self::Damaged,
            _ => return None,
        })
    }
}

/// How a started capture ended, as the C ABI numbers it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum Outcome {
    /// The picture was captured and kept.
    Done = 1,
    /// The capture failed: retried after a backoff.
    Failed = 2,
    /// The engine cannot picture the tab now (a hidden Chromium page): no retry until damage or
    /// a new watch.
    Unavailable = 3,
}

impl Outcome {
    pub fn from_raw(raw: u32) -> Option<Self> {
        Some(match raw {
            1 => Self::Done,
            2 => Self::Failed,
            3 => Self::Unavailable,
            _ => return None,
        })
    }
}

/// One tab's thumbnail schedule. A new one is unwatched, undamaged and has no picture.
#[derive(Debug, Clone)]
pub struct PictureSchedule {
    gap_ms: u64,
    watched: bool,
    /// Bumped by each damage.
    generation: u64,
    /// The generation the kept picture shows.
    captured: Option<u64>,
    /// The generation a started capture is of.
    in_flight: Option<u64>,
    last_start_ms: Option<u64>,
    /// The generation at which the engine said it cannot picture the tab.
    unavailable: Option<u64>,
    /// Consecutive failures.
    failures: u32,
}

impl PictureSchedule {
    pub fn new(gap_ms: u64) -> Self {
        Self {
            gap_ms,
            watched: false,
            generation: 0,
            captured: None,
            in_flight: None,
            last_start_ms: None,
            unavailable: None,
            failures: 0,
        }
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// True when the kept picture shows the current content (a reopened card draws it with no
    /// capture).
    pub fn is_current(&self) -> bool {
        self.captured == Some(self.generation)
    }

    /// The gap before the next start: the gap doubled per consecutive failure, at most 8x.
    fn backoff_gap(&self) -> u64 {
        let factor = 1_u64.checked_shl(self.failures).unwrap_or(MAX_BACKOFF).min(MAX_BACKOFF);
        self.gap_ms.saturating_mul(factor)
    }

    /// When the next capture may start, in the caller's clock: 0 (already past) when none ever
    /// started, else the last start plus the gap. `None` when nothing is wanted: unwatched, a
    /// capture in flight, the kept picture is current, or the engine cannot picture this content.
    /// The caller compares it with now.
    pub fn due_at(&self) -> Option<u64> {
        if !self.watched
            || self.in_flight.is_some()
            || self.is_current()
            || self.unavailable == Some(self.generation)
        {
            return None;
        }
        Some(self.last_start_ms.map_or(0, |start| start.saturating_add(self.backoff_gap())))
    }

    /// Records `event` and returns [`Self::due_at`]. `now_ms` is unused today (kept so every call
    /// carries the clock).
    pub fn note(&mut self, event: Event, _now_ms: u64) -> Option<u64> {
        match event {
            Event::Watched => {
                self.watched = true;
                self.unavailable = None;
            }
            Event::Unwatched => self.watched = false,
            Event::Damaged => self.generation = self.generation.saturating_add(1),
        }
        self.due_at()
    }

    /// When a capture is due at `now_ms`: marks it in flight with the current generation and
    /// returns that generation.
    pub fn take_due(&mut self, now_ms: u64) -> Option<u64> {
        if self.due_at()? > now_ms {
            return None;
        }
        self.in_flight = Some(self.generation);
        self.last_start_ms = Some(now_ms);
        Some(self.generation)
    }

    /// A started capture of `generation` ended. A stale finish (an older generation than the
    /// current one) still keeps a Done picture if it is newer than the kept one.
    pub fn finish(&mut self, generation: u64, outcome: Outcome, _now_ms: u64) -> Option<u64> {
        // Only the capture in flight moves the backoff: a stale or repeated finish must not.
        let current = self.in_flight == Some(generation);
        if current {
            self.in_flight = None;
        }
        match outcome {
            Outcome::Done => {
                self.captured = Some(self.captured.map_or(generation, |c| c.max(generation)));
                self.failures = 0;
            }
            Outcome::Failed if current => self.failures = self.failures.saturating_add(1),
            Outcome::Failed => {}
            Outcome::Unavailable => {
                self.unavailable = Some(generation);
                self.failures = 0;
            }
        }
        self.due_at()
    }
}
