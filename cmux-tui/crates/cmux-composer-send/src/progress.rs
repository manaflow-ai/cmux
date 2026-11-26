//! A send's deadline counted from its last progress, not from when it began.
//!
//! Leo, 2026-11-24: "10s timeout for messages being sendsble is a shame. if it's making good
//! progress, it shiukd be allowed to keep going?"
//!
//! Every wait on the phone's send path (a write the link has not taken, an answer the Mac has
//! not given, a link that is still coming up) is bounded by a stall: silence since the later of
//! when it began and the link's last progress. Progress is anything that shows the link moving:
//! bytes heard from the Mac, a write taken, an answer, a chunk acked, the link advancing a step
//! (connected, served). A wait that keeps hearing progress keeps going; one that hears nothing
//! for its bound gives up, exactly as long after the last progress as it used to after its start.
//!
//! [`LinkProgress`] is the one clock: one per link (or per channel whose stall must not hide
//! behind other traffic on the link, such as the terminal's input lane). Its owner feeds it today
//! from what it reads; the transport can publish its own last-progress instant into the same
//! [`LinkProgress::progressed`] later, and every verdict here stays as it is.
//! [`crate::chat::PromptOutbox`] measures each prompt's hold with the same
//! [`stalled_since`].

use std::time::{Duration, Instant};

/// Since when a wait that began at `started` has heard no progress: the later of the two.
pub fn stalled_since(started: Instant, last_progress: Option<Instant>) -> Instant {
    last_progress.map_or(started, |at| at.max(started))
}

/// Where a wait stands against its stall bound.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stall {
    /// Still moving: it gives up after `left` more silence (look again then).
    Moving { left: Duration },
    /// No progress for the whole bound: give up.
    Stalled,
}

/// A wait begun at `started`, bounded by `stall` of silence, at `now`.
pub fn stall_verdict(
    started: Instant,
    last_progress: Option<Instant>,
    stall: Duration,
    now: Instant,
) -> Stall {
    let silent = now.saturating_duration_since(stalled_since(started, last_progress));
    match stall.checked_sub(silent) {
        Some(left) if !left.is_zero() => Stall::Moving { left },
        _ => Stall::Stalled,
    }
}

/// The last progress one link (or channel) made. Monotonic: an older report never moves it back.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct LinkProgress {
    last: Option<Instant>,
}

impl LinkProgress {
    pub const fn new() -> LinkProgress {
        LinkProgress { last: None }
    }

    /// The link made progress at `now`.
    pub fn progressed(&mut self, now: Instant) {
        if self.last.is_none_or(|at| at < now) {
            self.last = Some(now);
        }
    }

    pub fn last(&self) -> Option<Instant> {
        self.last
    }

    /// A wait on this link begun at `started`, bounded by `stall` of silence, at `now`.
    pub fn verdict(&self, started: Instant, stall: Duration, now: Instant) -> Stall {
        stall_verdict(started, self.last, stall, now)
    }
}

/// Why keys held for a detached terminal are dropped now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HeldKeysExpiry {
    /// The terminal's reconnect gave up.
    GaveUp,
    /// The Mac was offline and the link made no progress for the hold, since the later of the
    /// key, the Mac going offline and the link's last progress.
    Offline,
    /// A key waited past the ceiling: it is not typed into whatever runs minutes later, however
    /// the link is doing (a staleness bound on the person's intent, not a wait on the link).
    Ceiling,
}

/// Keys typed at `typed_at` and held for a detached terminal, at `now`: why they go, or `None`
/// while they wait for the attach. `offline_since`: when the Mac was called offline, while it is.
pub fn held_keys_expiry(
    typed_at: &[Instant],
    now: Instant,
    gave_up: bool,
    offline_since: Option<Instant>,
    last_progress: Option<Instant>,
    hold: Duration,
    ceiling: Duration,
) -> Option<HeldKeysExpiry> {
    if typed_at.is_empty() {
        return None;
    }
    if gave_up {
        return Some(HeldKeysExpiry::GaveUp);
    }
    if let Some(offline) = offline_since
        && typed_at.iter().any(|&typed| {
            stall_verdict(typed.max(offline), last_progress, hold, now) == Stall::Stalled
        })
    {
        return Some(HeldKeysExpiry::Offline);
    }
    if typed_at.iter().any(|&typed| now.saturating_duration_since(typed) >= ceiling) {
        return Some(HeldKeysExpiry::Ceiling);
    }
    None
}

#[cfg(test)]
#[path = "progress_tests.rs"]
mod tests;
