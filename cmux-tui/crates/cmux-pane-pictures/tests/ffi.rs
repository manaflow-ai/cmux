//! The C ABI round-trips and refuses null.

use cmux_pane_pictures::ffi::*;
use std::ptr;

const WATCHED: u32 = 1;
const UNWATCHED: u32 = 2;
const DAMAGED: u32 = 3;

#[test]
fn round_trip() {
    assert_eq!(cmux_pane_pictures_abi_version(), CMUX_PANE_PICTURES_ABI_VERSION);
    assert_eq!(CMUX_PANE_PICTURES_TERMINAL_GAP_MS, 200);
    assert_eq!(CMUX_PANE_PICTURES_PAGE_GAP_MS, 500);
    let s = cmux_pane_pictures_schedule_new(0);
    // SAFETY: `s` is live and used by this thread only.
    unsafe {
        assert_eq!(cmux_pane_pictures_schedule_note(s, DAMAGED, 10), CMUX_PANE_PICTURES_NOT_DUE);
        assert!(cmux_pane_pictures_schedule_note(s, WATCHED, 20) >= 0);
        assert_eq!(cmux_pane_pictures_schedule_generation(s), 1);
        assert_eq!(cmux_pane_pictures_schedule_take_due(s, 20), 1);
        assert_eq!(cmux_pane_pictures_schedule_take_due(s, 21), CMUX_PANE_PICTURES_NOT_DUE);
        assert_eq!(cmux_pane_pictures_schedule_finish(s, 1, 1, 30), CMUX_PANE_PICTURES_NOT_DUE);
        assert!(cmux_pane_pictures_schedule_is_current(s));
        // A page schedule's gap is 500 ms.
        assert_eq!(cmux_pane_pictures_schedule_note(s, DAMAGED, 40), 20 + 500);
        // Unknown event and outcome change nothing.
        assert_eq!(cmux_pane_pictures_schedule_note(s, 99, 40), 520);
        assert_eq!(cmux_pane_pictures_schedule_finish(s, 2, 99, 40), 520);
        assert_eq!(cmux_pane_pictures_schedule_note(s, UNWATCHED, 50), CMUX_PANE_PICTURES_NOT_DUE);
        cmux_pane_pictures_schedule_free(s);
    }
}

#[test]
fn explicit_gap_and_failure() {
    let s = cmux_pane_pictures_schedule_new(CMUX_PANE_PICTURES_TERMINAL_GAP_MS);
    // SAFETY: live schedule, one thread.
    unsafe {
        cmux_pane_pictures_schedule_note(s, WATCHED, 0);
        cmux_pane_pictures_schedule_note(s, DAMAGED, 0);
        assert_eq!(cmux_pane_pictures_schedule_take_due(s, 1000), 1);
        assert_eq!(cmux_pane_pictures_schedule_finish(s, 1, 2, 1000), 1000 + 400);
        assert_eq!(cmux_pane_pictures_schedule_finish(s, 1, 3, 1001), CMUX_PANE_PICTURES_NOT_DUE);
        cmux_pane_pictures_schedule_free(s);
    }
}

#[test]
fn null_is_refused() {
    // SAFETY: null is allowed by every function.
    unsafe {
        assert_eq!(cmux_pane_pictures_schedule_note(ptr::null_mut(), 1, 0), -1);
        assert_eq!(cmux_pane_pictures_schedule_take_due(ptr::null_mut(), 0), -1);
        assert_eq!(cmux_pane_pictures_schedule_finish(ptr::null_mut(), 1, 1, 0), -1);
        assert!(!cmux_pane_pictures_schedule_is_current(ptr::null()));
        assert_eq!(cmux_pane_pictures_schedule_generation(ptr::null()), 0);
        cmux_pane_pictures_schedule_free(ptr::null_mut());
    }
}

#[test]
fn header_gaps_match_the_defaults() {
    assert_eq!(CMUX_PANE_PICTURES_TERMINAL_GAP_MS, cmux_pane_pictures::schedule::TERMINAL_GAP_MS);
    assert_eq!(CMUX_PANE_PICTURES_PAGE_GAP_MS, cmux_pane_pictures::schedule::PAGE_GAP_MS);
}
