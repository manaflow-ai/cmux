//! Reading a desktop fact again inside one call before refusing.
//!
//! Leo, 2026-11-22: "vacuous decisions like that should be just done and the
//! underlying problems should be done better at the root". A refusal whose
//! cause is a read that may pass a moment later (a value that changed while
//! it was read, two front-app readings that disagreed, an accessibility
//! attribute the app did not answer) is read again here a few times within a
//! short bound, so the agent is not handed a "try again" it can only accept.
//! Only reads are repeated: nothing that posts input or writes a value runs
//! twice (a closure that may have delivered input must not be passed here).
//!
//! This crate is MIT-licensed on its own, so it keeps this small loop rather
//! than depend on the daemon's `cmux_tui_util::retry`.

use std::time::{Duration, Instant};

/// How long one call reads a fact again before it refuses.
pub const REREAD_WAIT: Duration = Duration::from_millis(1500);
/// The first wait between two reads; each next wait doubles, up to [`MAX_STEP`].
pub const FIRST_STEP: Duration = Duration::from_millis(50);
/// The longest wait between two reads.
pub const MAX_STEP: Duration = Duration::from_millis(400);

/// Runs `read` until it gives `Some`, or `limit` has passed since the first
/// read (then `None`). Sleeps on this thread between reads.
pub fn reread<T>(limit: Duration, read: impl FnMut() -> Option<T>) -> Option<T> {
    reread_with(limit, std::thread::sleep, read)
}

/// [`reread`] that gives back the last error when every read failed.
pub fn reread_result<T, E>(
    limit: Duration,
    mut read: impl FnMut() -> Result<T, E>,
) -> Result<T, E> {
    let mut last: Option<E> = None;
    let got = reread(limit, || match read() {
        Ok(value) => Some(value),
        Err(error) => {
            last = Some(error);
            None
        }
    });
    match (got, last) {
        (Some(value), _) => Ok(value),
        (None, Some(error)) => Err(error),
        // Every `None` above set `last`, and reread reads at least once.
        (None, None) => read(),
    }
}

/// [`reread`] with its sleep given, for tests.
pub fn reread_with<T>(
    limit: Duration,
    mut sleep: impl FnMut(Duration),
    mut read: impl FnMut() -> Option<T>,
) -> Option<T> {
    let start = Instant::now();
    let mut spent = Duration::ZERO;
    let mut step = FIRST_STEP;
    loop {
        if let Some(value) = read() {
            return Some(value);
        }
        // The time slept (counted, so a test's sleep need not pass) and the
        // wall time, whichever is longer, is held to the bound.
        let elapsed = start.elapsed().max(spent);
        if elapsed >= limit {
            return None;
        }
        let wait = step.min(limit - elapsed);
        sleep(wait);
        spent += wait;
        step = (step * 2).min(MAX_STEP);
    }
}

#[cfg(test)]
#[path = "reread_tests.rs"]
mod tests;
