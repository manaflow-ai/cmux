//! `PaneCloseAim`, ported from the Swift `PaneCloseAimTests`: a Close Tab
//! press is aimed at the pane that was on screen when it was made (Leo
//! 2026-10-21, Lawrence 2026-10-23).

use cmux_focus_core::close_aim::{PaneCloseAim, Press};

fn key(time: f64) -> Press {
    Press { time, is_key: true, is_repeat: false }
}

fn repeat(time: f64) -> Press {
    Press { time, is_key: true, is_repeat: true }
}

/// Before the frame showing `a` was presented, a press is aimed at `b`; a
/// repeat of the held key that emptied `b` is too; a fresh press after that
/// frame closes in `a`.
#[test]
fn a_press_is_aimed_at_the_pane_on_screen_when_it_was_made() {
    let mut aim = PaneCloseAim::new();
    // No pane emptied: every press closes.
    assert!(!aim.aims_at_emptied_pane(key(1.0), Some("b")));
    aim.pane_emptied("b", key(10.0));
    // The focus has not left `b`: the press acts on `b` as on any pane.
    assert!(!aim.aims_at_emptied_pane(key(10.001), Some("b")));
    let moved = aim.pane_moved(Some("b"), Some("a"));
    // Moved, not yet presented: aimed at `b`.
    assert!(aim.aims_at_emptied_pane(key(10.002), Some("a")));
    aim.presented(moved, 10.020);
    // Made before the frame was presented: still aimed at `b`.
    assert!(aim.aims_at_emptied_pane(key(10.010), Some("a")));
    // A repeat of the held key that emptied `b`, after the frame: the same
    // press.
    assert!(aim.aims_at_emptied_pane(repeat(10.5), Some("a")));
    // A fresh press after the frame: closes in `a`; the hold it starts
    // closes in `a` too.
    assert!(!aim.aims_at_emptied_pane(key(10.6), Some("a")));
    assert!(!aim.aims_at_emptied_pane(repeat(10.7), Some("a")));
}

/// A close emptied by a click (no held key), and a focus the person moved
/// since, aim nowhere else.
#[test]
fn a_press_after_the_person_moved_the_focus_is_theirs() {
    let mut aim = PaneCloseAim::new();
    aim.pane_emptied("b", Press { time: 10.0, is_key: false, is_repeat: false });
    let moved = aim.pane_moved(Some("b"), Some("a"));
    // A stale stamp for an older move changes nothing.
    aim.presented(moved.wrapping_sub(1), 10.001);
    assert_eq!(aim.last_move().and_then(|m| m.presented_at), None);
    // The person clicked pane `c` before the frame showed `a`: their next
    // press is theirs.
    aim.pane_moved(Some("a"), Some("c"));
    assert!(!aim.aims_at_emptied_pane(key(10.002), Some("c")));
    assert_eq!(aim.emptied(), None);
}

/// Review 2 (2026-10-24): after a close emptied `b` and the focus went to
/// `a`, a Cmd-D moves the focus to the new pane `c` the person made: every
/// later press is theirs, however quick (Cmd-D, Cmd-Shift-D, Cmd-W six times
/// at 40 ms closes six times).
#[test]
fn a_new_pane_the_person_made_ends_the_aim() {
    let mut aim = PaneCloseAim::new();
    aim.pane_emptied("b", key(10.0));
    let moved = aim.pane_moved(Some("b"), Some("a"));
    aim.presented(moved, 10.02);
    aim.pane_moved(Some("a"), Some("c"));
    let closes = (0..6)
        .filter(|press| !aim.aims_at_emptied_pane(key(10.04 + f64::from(*press) * 0.04), Some("c")))
        .count();
    assert_eq!(closes, 6);
}

/// A second presentation stamp for the same move changes nothing.
#[test]
fn only_the_first_presentation_stamp_counts() {
    let mut aim = PaneCloseAim::new();
    let moved = aim.pane_moved(Some("b"), Some("a"));
    aim.presented(moved, 1.0);
    aim.presented(moved, 2.0);
    assert_eq!(aim.last_move().and_then(|m| m.presented_at), Some(1.0));
}
