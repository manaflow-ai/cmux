//! MEASURE BRANCH ONLY, never merged: the time of each part of one request on the thread that
//! handles it, and each hold of the mux state lock by that thread.
//!
//! A test calls [`begin`], runs one request on its own thread and calls [`end`]. A thread that
//! did not call `begin` records nothing.

// Only the measure test reads what the probe holds.
#![allow(dead_code)]

use std::cell::RefCell;
use std::panic::Location;
use std::time::{Duration, Instant};

/// What one request recorded.
#[derive(Default)]
pub(crate) struct Laps {
    /// `(part, time)` in the order in which the parts ended. A part whose name starts with `=`
    /// holds other parts.
    pub(crate) parts: Vec<(&'static str, Duration)>,
    /// `(file:line of the lock call, hold)` for each hold of the state lock.
    pub(crate) state_holds: Vec<(String, Duration)>,
}

thread_local! {
    static LAPS: RefCell<Option<Laps>> = const { RefCell::new(None) };
}

/// This thread records from now on.
pub(crate) fn begin() {
    LAPS.with(|slot| *slot.borrow_mut() = Some(Laps::default()));
}

/// What this thread recorded since [`begin`]; it records no more.
pub(crate) fn end() -> Laps {
    LAPS.with(|slot| slot.borrow_mut().take()).unwrap_or_default()
}

pub(crate) fn now() -> Instant {
    Instant::now()
}

/// The part `part` ran from `start` to now.
pub(crate) fn since(part: &'static str, start: Instant) {
    let elapsed = start.elapsed();
    let _ = LAPS.try_with(|slot| {
        if let Ok(mut slot) = slot.try_borrow_mut() {
            if let Some(laps) = slot.as_mut() {
                laps.parts.push((part, elapsed));
            }
        }
    });
}

/// This thread held the state lock for `held`; `site` took it.
pub(crate) fn state_hold(site: &'static Location<'static>, held: Duration) {
    let _ = LAPS.try_with(|slot| {
        if let Ok(mut slot) = slot.try_borrow_mut() {
            if let Some(laps) = slot.as_mut() {
                laps.state_holds.push((format!("{}:{}", site.file(), site.line()), held));
            }
        }
    });
}
