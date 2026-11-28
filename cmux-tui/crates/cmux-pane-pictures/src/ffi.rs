//! The C ABI of the pane pictures for the macOS app (`include/cmux_pane_pictures.h`, Swift module
//! `CCmuxPanePicturesFFI`), linked into the app through cmux-app-ffi.
//!
//! One schedule per tab a hover card shows (`crate::schedule`). A capture: `take_due` returns a
//! generation (not -1), capture and encode, then `finish` it (1 done, 2 failed, 3 unavailable).
//! The caller passes the clock (`now_ms`, monotonic milliseconds) and arms one timer at the due
//! time `note` and `finish` return. A schedule is used by one thread at a time. No function
//! unwinds across the boundary.

use crate::schedule::{Event, Outcome, PAGE_GAP_MS, PictureSchedule};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// Bumped on any change to a type or a function.
pub const CMUX_PANE_PICTURES_ABI_VERSION: u32 = 1;
/// The reply when no capture is due (`note`, `take_due`, `finish`).
pub const CMUX_PANE_PICTURES_NOT_DUE: i64 = -1;
/// The default gap between capture starts for a terminal tab (200 ms).
pub const CMUX_PANE_PICTURES_TERMINAL_GAP_MS: u64 = 200;
/// The default gap between capture starts for a page tab: browser, chat, markdown (500 ms).
pub const CMUX_PANE_PICTURES_PAGE_GAP_MS: u64 = 500;

/// One tab's thumbnail schedule.
pub struct CmuxPanePictureSchedule {
    inner: PictureSchedule,
}

fn guard<T>(fallback: T, body: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(fallback)
}

fn reply(ms: Option<u64>) -> i64 {
    ms.and_then(|ms| i64::try_from(ms).ok()).unwrap_or(CMUX_PANE_PICTURES_NOT_DUE)
}

/// The ABI version of this library.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_pane_pictures_abi_version() -> u32 {
    CMUX_PANE_PICTURES_ABI_VERSION
}

/// A new tab's schedule (unwatched, undamaged, no picture); `gap_ms` 0 takes the page default
/// (500 ms). Free it with `cmux_pane_pictures_schedule_free`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_pane_pictures_schedule_new(gap_ms: u64) -> *mut CmuxPanePictureSchedule {
    let gap = if gap_ms == 0 { PAGE_GAP_MS } else { gap_ms };
    Box::into_raw(Box::new(CmuxPanePictureSchedule { inner: PictureSchedule::new(gap) }))
}

/// Frees a schedule; null does nothing.
///
/// # Safety
/// `schedule` is null or from `cmux_pane_pictures_schedule_new`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_pane_pictures_schedule_free(schedule: *mut CmuxPanePictureSchedule) {
    if !schedule.is_null() {
        // SAFETY: from `Box::into_raw` in `cmux_pane_pictures_schedule_new`, freed once.
        drop(unsafe { Box::from_raw(schedule) });
    }
}

/// Records `event` (1 watched, 2 unwatched, 3 damaged) at `now_ms` and returns when a capture may
/// start, in the same clock's milliseconds (a past time means now), or
/// `CMUX_PANE_PICTURES_NOT_DUE`. An unknown event changes nothing.
///
/// # Safety
/// `schedule` is null or a live schedule used by no other thread during the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_pane_pictures_schedule_note(
    schedule: *mut CmuxPanePictureSchedule,
    event: u32,
    now_ms: u64,
) -> i64 {
    // SAFETY: caller contract.
    let Some(schedule) = (unsafe { schedule.as_mut() }) else { return CMUX_PANE_PICTURES_NOT_DUE };
    guard(CMUX_PANE_PICTURES_NOT_DUE, || {
        reply(match Event::from_raw(event) {
            Some(event) => schedule.inner.note(event, now_ms),
            None => schedule.inner.due_at(),
        })
    })
}

/// When a capture is due at `now_ms`: the generation the started capture is of (the schedule now
/// has it in flight; end it with `cmux_pane_pictures_schedule_finish`), else
/// `CMUX_PANE_PICTURES_NOT_DUE`.
///
/// # Safety
/// As `cmux_pane_pictures_schedule_note`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_pane_pictures_schedule_take_due(
    schedule: *mut CmuxPanePictureSchedule,
    now_ms: u64,
) -> i64 {
    // SAFETY: caller contract.
    let Some(schedule) = (unsafe { schedule.as_mut() }) else { return CMUX_PANE_PICTURES_NOT_DUE };
    guard(CMUX_PANE_PICTURES_NOT_DUE, || reply(schedule.inner.take_due(now_ms)))
}

/// A capture of `generation` ended: `outcome` 1 done (the picture was kept), 2 failed (retry after
/// a backoff), 3 unavailable (no retry until the tab is damaged or watched again). Returns when the
/// next capture may start, or `CMUX_PANE_PICTURES_NOT_DUE`. An unknown outcome changes nothing.
///
/// # Safety
/// As `cmux_pane_pictures_schedule_note`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_pane_pictures_schedule_finish(
    schedule: *mut CmuxPanePictureSchedule,
    generation: u64,
    outcome: u32,
    now_ms: u64,
) -> i64 {
    // SAFETY: caller contract.
    let Some(schedule) = (unsafe { schedule.as_mut() }) else { return CMUX_PANE_PICTURES_NOT_DUE };
    guard(CMUX_PANE_PICTURES_NOT_DUE, || {
        reply(match Outcome::from_raw(outcome) {
            Some(outcome) => schedule.inner.finish(generation, outcome, now_ms),
            None => schedule.inner.due_at(),
        })
    })
}

/// True when the kept picture shows the tab's current content: a reopened card draws it with no
/// capture. False for a null schedule.
///
/// # Safety
/// As `cmux_pane_pictures_schedule_note`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_pane_pictures_schedule_is_current(
    schedule: *const CmuxPanePictureSchedule,
) -> bool {
    // SAFETY: caller contract.
    unsafe { schedule.as_ref() }.is_some_and(|s| s.inner.is_current())
}

/// The tab's content generation (each damage adds one); 0 for a null schedule.
///
/// # Safety
/// As `cmux_pane_pictures_schedule_note`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_pane_pictures_schedule_generation(
    schedule: *const CmuxPanePictureSchedule,
) -> u64 {
    // SAFETY: caller contract.
    unsafe { schedule.as_ref() }.map_or(0, |s| s.inner.generation())
}
