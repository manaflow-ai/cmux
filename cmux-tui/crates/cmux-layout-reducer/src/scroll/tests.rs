//! The Swift tests of the column scroll reducer, ported 1:1 as this module's
//! corpus (the Rust rule is proved equal before Swift calls it):
//!
//! - live suites: BesideColumnRevealTests, ColumnAddFocusTests (focus
//!   scroll), ColumnCloseClampVelocityTests, ScrollAreaGeometryTests
//!   (`focusRevealsAPaneScrolledOutOfItsArea`, on a hand-built area: its
//!   geometry half is B2);
//! - suites deleted in 36f2381bf1a6 and dcc8cad9829b (2026-10-09), restored
//!   from history: ColumnScrollRulesTests, ColumnScrollRevealTests,
//!   ColumnScrollGestureTests, ColumnScrollRestoreTests,
//!   ColumnScrollLayoutTests, ColumnScrollResizeDragTests. One expectation
//!   predates #22059 (7cbe1bc91a4c, a close clamps the camera into the new
//!   strip) and takes today's Swift result; it says so where it is.
//!
//! Strips are built like the Swift `makeStrip`: columns `c<name>` with one
//! pane `p<name>` each, laid left to right with `gap` before, between and
//! after them, 600 pt tall.

use super::*;
use crate::{ColumnId, PaneId};
use cmux_motion::{MotionSpring, SpringParameters, advance_spring};

/// The id of a test name ("0", "12", "n", "a"): digits are themselves.
fn key(name: &str) -> u64 {
    name.parse().unwrap_or_else(|_| 900 + name.bytes().map(u64::from).sum::<u64>())
}

fn c(name: &str) -> ColumnId {
    10_000 + key(name)
}

fn p(name: &str) -> PaneId {
    20_000 + key(name)
}

fn make_strip_ids(widths: &[f64], ids: &[&str], viewport: f64, gap: f64) -> ColumnStrip {
    let mut strip = ColumnStrip::new(viewport, viewport, gap);
    let mut x = gap;
    for (width, name) in widths.iter().zip(ids) {
        let frame = Rect::new(x, 0., *width, 600.);
        strip.push_framed(c(name), frame, &[(p(name), frame)]);
        x += width + gap;
    }
    strip.content_width = if strip.columns.is_empty() { viewport } else { x };
    strip
}

fn make_strip(widths: &[f64]) -> ColumnStrip {
    let names: Vec<String> = (0..widths.len()).map(|i| i.to_string()).collect();
    let ids: Vec<&str> = names.iter().map(String::as_str).collect();
    make_strip_ids(widths, &ids, 1000., 8.)
}

fn sync(
    strip: &ColumnStrip,
    focused: &str,
    source: ColumnFocusSource,
    animated: bool,
) -> ColumnScrollEvent {
    ColumnScrollEvent::Sync {
        strip: strip.clone(),
        focused: Some(p(focused)),
        source,
        animated,
        reveals: true,
        anchor: None,
    }
}

/// A state placed on `strip` with `focused` at rest.
fn settled(strip: &ColumnStrip, focused: &str, mode: CenterFocusedColumn) -> ColumnScrollState {
    let mut state = ColumnScrollState::new();
    state.mode = mode;
    state.reduce(sync(strip, focused, ColumnFocusSource::Programmatic, false));
    state
}

fn settled_never(strip: &ColumnStrip, focused: &str) -> ColumnScrollState {
    settled(strip, focused, CenterFocusedColumn::Never)
}

fn focus(state: &mut ColumnScrollState, pane: &str, source: ColumnFocusSource, animated: bool) {
    let Some(strip) = state.strip.clone() else { return };
    state.reduce(sync(&strip, pane, source, animated));
}

fn focus_key(state: &mut ColumnScrollState, pane: &str) {
    focus(state, pane, ColumnFocusSource::Keyboard, true);
}

fn step(
    state: &mut ColumnScrollState,
    dt: f64,
    parameters: SpringParameters,
    epsilon: f64,
) -> bool {
    let spring = &mut state.spring;
    advance_spring(&mut spring.value, &mut spring.velocity, spring.target, dt, parameters, epsilon)
}

/// Steps the spring at 120 Hz until it rests; returns every presented value.
fn run_to_rest(state: &mut ColumnScrollState) -> Vec<f64> {
    let mut values = Vec::new();
    for _ in 0..600 {
        let moving = step(state, 1. / 120., MotionSpring::Scroll.base(), 0.25);
        values.push(state.spring.value);
        if !moving {
            break;
        }
    }
    values
}

const FOCUS_SPRING: SpringParameters = SpringParameters::new(0.22, 0.9);

/// Screen x of a column's leading edge at the presented offset.
fn screen_x(state: &ColumnScrollState, column: &str) -> Option<f64> {
    let strip = state.strip.as_ref()?;
    strip.index_of(c(column)).map(|i| strip.columns[i].frame.min_x() - state.spring.value)
}

const SOURCES: [ColumnFocusSource; 4] = [
    ColumnFocusSource::Keyboard,
    ColumnFocusSource::Pointer,
    ColumnFocusSource::Programmatic,
    ColumnFocusSource::Scroll,
];

// MARK: ColumnScrollRulesTests

#[test]
fn rules_content_that_fits_never_scrolls() {
    let strip = make_strip(&[400., 500.]);
    for mode in
        [CenterFocusedColumn::Never, CenterFocusedColumn::Always, CenterFocusedColumn::OnOverflow]
    {
        for source in SOURCES {
            let mut state = settled(&strip, "0", mode);
            state.reduce(sync(&strip, "1", source, false));
            assert_eq!(state.spring.target, 0., "mode {mode:?} source {source:?}");
            state.reduce(sync(&strip, "0", source, false));
            assert_eq!(state.spring.target, 0., "mode {mode:?} source {source:?}");
        }
    }
}

#[test]
fn rules_focusing_a_fully_visible_column_does_not_scroll() {
    let strip = make_strip(&[400., 400., 400.]);
    let mut state = settled_never(&strip, "2");
    let offset = state.spring.target;
    assert!(offset > 0.);
    for source in SOURCES.into_iter().filter(|s| *s != ColumnFocusSource::Scroll) {
        let mut copy = state.clone();
        copy.reduce(sync(&strip, "1", source, false));
        assert_eq!(copy.spring.target, offset, "source {source:?}");
    }
    state.reduce(sync(&strip, "2", ColumnFocusSource::Programmatic, false));
    assert_eq!(state.spring.target, offset, "a repeated snapshot does not scroll");
}

#[test]
fn rules_a_reveal_moves_only_as_far_as_needed() {
    let strip = make_strip(&[400., 400., 400.]);
    let mut state = settled_never(&strip, "0");
    assert_eq!(state.spring.target, 0.);
    state.reduce(sync(&strip, "2", ColumnFocusSource::Keyboard, false));
    let p2 = strip.columns[2].frame;
    let expected = strip.clamp(p2.max_x() + strip.padding(p2.w()) - strip.visible_width());
    assert!((state.spring.target - expected).abs() < 0.5);
}

// MARK: ColumnScrollRevealTests (viewport 1000, gap 8; 600 pt columns at 8, 616, 1224)

fn wide3() -> ColumnStrip {
    make_strip(&[600., 600., 600.])
}

#[test]
fn reveal_first_placement_is_instant_and_minimal() {
    let state = settled_never(&wide3(), "2");
    assert_eq!(state.spring.value, 832.);
    assert_eq!(state.spring.target, 832.);
}

#[test]
fn reveal_keyboard_focus_scrolls_the_least_amount() {
    let mut state = settled_never(&wide3(), "0");
    focus_key(&mut state, "1");
    // Right edge plus the gap at the viewport edge: 1216 + 8 - 1000.
    assert_eq!(state.spring.target, 224.);
    assert_eq!(state.spring.value, 0.);
    run_to_rest(&mut state);
    focus_key(&mut state, "0");
    assert_eq!(state.spring.target, 0.);
}

#[test]
fn reveal_a_visible_column_never_scrolls() {
    let mut state = settled_never(&make_strip(&[300., 300., 300., 300.]), "0");
    for pane in ["2", "1", "0"] {
        focus(&mut state, pane, ColumnFocusSource::Keyboard, true);
        assert_eq!(state.spring.target, 0.);
        focus(&mut state, pane, ColumnFocusSource::Pointer, true);
        assert_eq!(state.spring.target, 0.);
    }
}

#[test]
fn reveal_click_on_a_partly_visible_column_reveals_it_minimally_even_when_centering() {
    let mut state = settled(&wide3(), "0", CenterFocusedColumn::Always);
    focus(&mut state, "1", ColumnFocusSource::Pointer, true);
    assert_eq!(state.spring.target, 224.);
    run_to_rest(&mut state);
    // A later keyboard focus uses the mode again.
    focus_key(&mut state, "2");
    assert_eq!(state.spring.target, 832.);
}

#[test]
fn reveal_first_and_last_columns_clamp_to_the_strip_ends() {
    let mut state = settled(&wide3(), "1", CenterFocusedColumn::Always);
    focus_key(&mut state, "0");
    assert_eq!(state.spring.target, 0.);
    focus_key(&mut state, "2");
    assert_eq!(state.spring.target, 832.);
}

#[test]
fn reveal_always_centers_the_focused_column() {
    let mut state =
        settled(&make_strip(&[400., 400., 400., 400.]), "0", CenterFocusedColumn::Always);
    focus_key(&mut state, "2");
    // c2 spans 824...1224, midX 1024.
    assert_eq!(state.spring.target, 524.);
}

#[test]
fn reveal_on_overflow_centers_only_when_both_columns_cannot_share() {
    let mut state = settled(&wide3(), "0", CenterFocusedColumn::OnOverflow);
    focus_key(&mut state, "1");
    // c0 + c1 + gaps = 1224 > 1000: center c1 (midX 916).
    assert_eq!(state.spring.target, 416.);

    let narrow_strip = make_strip(&[300., 300., 300., 300., 300.]);
    let mut narrow = settled(&narrow_strip, "2", CenterFocusedColumn::OnOverflow);
    focus_key(&mut narrow, "3");
    // c2 + c3 fit together: minimal reveal of c3 (932...1232).
    assert_eq!(narrow.spring.target, 240.);
}

#[test]
fn reveal_different_widths_align_the_nearer_edge() {
    let mut state = settled_never(&make_strip(&[300., 900., 200., 500.]), "0");
    focus_key(&mut state, "1");
    assert_eq!(state.spring.target, 224.);
    run_to_rest(&mut state);
    focus_key(&mut state, "3");
    assert_eq!(state.spring.target, 940.);
    run_to_rest(&mut state);
    focus_key(&mut state, "2");
    assert_eq!(state.spring.target, 940.);
}

#[test]
fn reveal_a_column_wider_than_the_view_aligns_its_left_edge_or_keeps_the_pane_visible() {
    let base = make_strip(&[400., 1400., 400.]);
    let wide = base.columns[1].frame;
    let left = Rect::new(wide.min_x(), 0., 696., 600.);
    let right = Rect::new(wide.min_x() + 704., 0., 696., 600.);
    // c1's panes are pa and pb instead of p1.
    let mut strip = ColumnStrip::new(base.viewport_width, base.content_width, base.gap);
    for index in 0..base.columns.len() {
        let column = &base.columns[index];
        if index == 1 {
            strip.push_framed(column.id, column.frame, &[(p("a"), left), (p("b"), right)]);
        } else {
            strip.push_column(column.id, column.frame, base.column_panes(index).iter().copied());
        }
    }
    let mut state = settled_never(&strip, "0");
    focus_key(&mut state, "a");
    assert_eq!(state.spring.target, wide.min_x());
    run_to_rest(&mut state);
    focus_key(&mut state, "b");
    // pb 1120...1816: least scroll that shows it.
    assert_eq!(state.spring.target, right.max_x() + 8. - 1000.);
    run_to_rest(&mut state);
    focus_key(&mut state, "b");
    assert_eq!(state.spring.target, right.max_x() + 8. - 1000.);
    focus_key(&mut state, "a");
    assert_eq!(state.spring.target, wide.min_x());
}

#[test]
fn reveal_a_fast_focus_sequence_retargets_from_the_presented_value() {
    let mut state = settled_never(&wide3(), "0");
    focus_key(&mut state, "1");
    for _ in 0..6 {
        step(&mut state, 1. / 120., FOCUS_SPRING, 0.25);
    }
    let midway = state.spring.value;
    let velocity = state.spring.velocity;
    assert!(midway > 0. && midway < 224.);
    focus_key(&mut state, "2");
    focus_key(&mut state, "1");
    focus_key(&mut state, "2");
    // No jump and no queue: same presented value and velocity, newest target.
    assert_eq!(state.spring.value, midway);
    assert_eq!(state.spring.velocity, velocity);
    assert_eq!(state.spring.target, 832.);
    let values = run_to_rest(&mut state);
    assert_eq!(values.last().copied(), Some(832.));
    assert!(values.windows(2).all(|w| w[1] >= w[0] - 0.5));
}

#[test]
fn reveal_reduce_motion_or_off_snaps() {
    let mut state = settled_never(&wide3(), "0");
    focus(&mut state, "2", ColumnFocusSource::Keyboard, false);
    assert_eq!(state.spring.value, 832.);
}

/// A snapped reveal reports the jump so the strip scrollbar shows as it would
/// for the spring's frames; an animated one runs frames instead.
#[test]
fn reveal_a_snapped_reveal_reports_the_jump() {
    let mut snapped = settled_never(&wide3(), "0");
    assert!(snapped.reduce(sync(&wide3(), "2", ColumnFocusSource::Keyboard, false)).snapped);
    let mut animated = settled_never(&wide3(), "0");
    let effects = animated.reduce(sync(&wide3(), "2", ColumnFocusSource::Keyboard, true));
    assert!(!effects.snapped);
    assert!(effects.needs_frames);
}

#[test]
fn reveal_a_sync_that_keeps_the_offset_reports_no_jump() {
    let strip = make_strip(&[300., 300., 300.]);
    let mut state = settled_never(&strip, "0");
    assert!(!state.reduce(sync(&strip, "1", ColumnFocusSource::Keyboard, false)).snapped);
    assert!(!state.reduce(sync(&strip, "1", ColumnFocusSource::Keyboard, false)).snapped);
}

#[test]
fn reveal_center_request_centers_once() {
    let mut state = settled_never(&make_strip(&[400., 400., 400., 400.]), "0");
    state.reduce(ColumnScrollEvent::Center { pane: p("1"), animated: false });
    assert_eq!(state.spring.value, 116.);
}

// MARK: ColumnScrollGestureTests

fn four() -> ColumnStrip {
    make_strip(&[400., 400., 400., 400.])
}

/// Drags by `total` points over `steps` events 8 ms apart, from `start`.
fn drag(state: &mut ColumnScrollState, total: f64, steps: usize, start: f64) -> f64 {
    state.reduce(ColumnScrollEvent::GestureBegan);
    let mut time = start;
    for _ in 0..steps {
        time += 0.008;
        state.reduce(ColumnScrollEvent::GestureChanged { delta_x: -total / steps as f64, time });
    }
    time
}

fn snap_offsets(strip: &ColumnStrip, mode: CenterFocusedColumn) -> Vec<f64> {
    snaps(strip, mode).iter().map(|snap| snap.offset).collect()
}

#[test]
fn gesture_takes_over_an_automatic_scroll_where_it_is() {
    let mut state = settled_never(&four(), "0");
    focus_key(&mut state, "3");
    for _ in 0..5 {
        step(&mut state, 1. / 120., FOCUS_SPRING, 0.25);
    }
    let presented = state.spring.value;
    state.reduce(ColumnScrollEvent::GestureBegan);
    assert_eq!(state.spring.value, presented);
    assert_eq!(state.spring.target, presented);
    assert_eq!(state.spring.velocity, 0.);
}

#[test]
fn gesture_focus_changes_during_a_gesture_do_not_fight_it() {
    let mut state = settled_never(&four(), "0");
    drag(&mut state, 100., 10, 0.);
    let value = state.spring.value;
    focus_key(&mut state, "3");
    let five = make_strip(&[400., 400., 400., 400., 400.]);
    state.reduce(sync(&five, "3", ColumnFocusSource::Programmatic, true));
    assert_eq!(state.spring.value, value);
    assert_eq!(state.spring.target, value);
}

#[test]
fn gesture_release_snaps_to_a_column_edge_and_keeps_a_visible_focus() {
    let mut state = settled_never(&four(), "1");
    let end = drag(&mut state, 150., 30, 0.);
    let effects =
        state.reduce(ColumnScrollEvent::GestureEnded { time: end + 0.2, animated: false });
    // Slow release near 150: snaps to an edge, c1 (416...816) still shows.
    assert!(snap_offsets(&four(), CenterFocusedColumn::Never).contains(&state.spring.value));
    assert_eq!(effects.focus, None);
    assert!(effects.report_on_settle);
}

#[test]
fn gesture_scrolling_the_focus_off_screen_focuses_a_visible_column() {
    let mut state = settled_never(&four(), "0");
    let end = drag(&mut state, 640., 20, 0.);
    let effects =
        state.reduce(ColumnScrollEvent::GestureEnded { time: end + 0.2, animated: false });
    assert_eq!(state.spring.value, 640.);
    // Forward gesture: the farthest fully visible column (c3) takes focus.
    assert_eq!(effects.focus, Some(p("3")));
    // The model's echo of that focus does not scroll.
    state.reduce(sync(&four(), "3", ColumnFocusSource::Scroll, true));
    assert_eq!(state.spring.target, 640.);
}

#[test]
fn gesture_rubber_band_past_the_ends_springs_back() {
    let mut state = settled_never(&four(), "0");
    let end = drag(&mut state, -300., 10, 0.);
    assert!(state.spring.value < 0. && state.spring.value > -300.);
    state.reduce(ColumnScrollEvent::GestureEnded { time: end + 0.2, animated: true });
    assert_eq!(state.spring.target, 0.);
    run_to_rest(&mut state);
    assert_eq!(state.spring.value, 0.);
}

#[test]
fn gesture_a_fling_advances_at_least_one_snap_and_carries_velocity() {
    let mut state = settled_never(&four(), "0");
    let end = drag(&mut state, 40., 4, 0.);
    state.reduce(ColumnScrollEvent::GestureEnded { time: end + 0.001, animated: true });
    assert!(state.spring.target > 40.);
    assert!(state.spring.velocity > 300.);
}

#[test]
fn gesture_wheel_notches_step_snaps_and_keep_the_focus_visible() {
    let mut state = settled_never(&four(), "0");
    let effects = state.reduce(ColumnScrollEvent::Wheel { direction: 1, animated: false });
    assert_eq!(state.spring.value, 232.);
    // c0 left the view: the farthest visible column forward takes focus.
    assert_eq!(effects.focus, Some(p("2")));
    for _ in 0..6 {
        state.reduce(ColumnScrollEvent::Wheel { direction: 1, animated: false });
    }
    assert_eq!(state.spring.value, 640.);
    assert_ne!(state.focused_pane, Some(p("0")));
    state.reduce(ColumnScrollEvent::Wheel { direction: -1, animated: false });
    assert!(state.spring.value < 640.);
}

#[test]
fn gesture_always_mode_snaps_to_column_centers() {
    // Centers 208, 616, 1024, 1432 minus 500, clamped to 0...640.
    assert_eq!(snap_offsets(&four(), CenterFocusedColumn::Always), vec![0., 116., 524., 640.]);
}

#[test]
fn gesture_never_mode_snaps_to_edges() {
    let strip = make_strip_ids(&[600., 500., 400.], &["0", "1", "2"], 1000., 0.);
    assert_eq!(snap_offsets(&strip, CenterFocusedColumn::Never), vec![0., 100., 500.]);
}

#[test]
fn gesture_on_overflow_snaps_to_centers_beside_wide_neighbors() {
    // Neighbors overflow: edges beside them snap to centers (566), ends clamp.
    let strip = make_strip(&[700., 700., 700.]);
    assert_eq!(snap_offsets(&strip, CenterFocusedColumn::OnOverflow), vec![0., 566., 1132.]);
}

// MARK: ColumnScrollRestoreTests

fn restore_before() -> ColumnStrip {
    make_strip_ids(&[1000., 550., 550.], &["0", "1", "3"], 1000., 8.)
}

/// c0 (full width), c1 focused at rest, then c2 opened right of c1.
fn opened() -> (ColumnScrollState, ColumnStrip) {
    let mut state = settled_never(&restore_before(), "1");
    let after = make_strip_ids(&[1000., 550., 550., 550.], &["0", "1", "2", "3"], 1000., 8.);
    state.reduce(sync(&after, "2", ColumnFocusSource::Keyboard, false));
    (state, after)
}

#[test]
fn restore_closing_the_focused_just_opened_column_restores_the_offset() {
    let start = settled_never(&restore_before(), "1").spring.target;
    let (mut state, _) = opened();
    state.reduce(sync(&restore_before(), "1", ColumnFocusSource::Programmatic, false));
    assert_eq!(state.spring.target, start);
}

#[test]
fn restore_closing_the_just_opened_column_after_going_back_does_not_scroll() {
    let (mut state, strip) = opened();
    state.reduce(sync(&strip, "1", ColumnFocusSource::Keyboard, false));
    let x = screen_x(&state, "1");
    state.reduce(sync(&restore_before(), "1", ColumnFocusSource::Programmatic, false));
    assert_eq!(screen_x(&state, "1"), x);
}

// MARK: ColumnScrollLayoutTests

fn ids_strip(widths: &[f64], ids: &[&str]) -> ColumnStrip {
    make_strip_ids(widths, ids, 1000., 8.)
}

/// Swift's expectation was `value == 832` (the camera stayed past the new
/// end and sprang back). Since #22059 (7cbe1bc91a4c) a close clamps the
/// presented camera into the new strip and the view carries the panes from
/// where they showed, so the camera is at the new end at once.
#[test]
fn layout_closing_the_rightmost_column_clamps_the_camera_to_the_new_end() {
    let mut state = settled_never(&wide3(), "2");
    assert_eq!(state.spring.value, 832.);
    let effects =
        state.reduce(sync(&make_strip(&[600., 600.]), "1", ColumnFocusSource::Programmatic, true));
    assert_eq!(state.spring.value, 224.);
    assert_eq!(state.spring.target, 224.);
    assert!(!effects.needs_frames);
    // Settled: no empty space right of the last column.
    assert_eq!(screen_x(&state, "1").map(|x| x + 600. + 8.), Some(1000.));
}

#[test]
fn layout_closing_the_rightmost_column_without_animation_snaps() {
    let mut state = settled_never(&wide3(), "2");
    state.reduce(sync(&make_strip(&[600., 600.]), "1", ColumnFocusSource::Programmatic, false));
    assert_eq!(state.spring.value, 224.);
}

#[test]
fn layout_closing_a_column_left_of_the_focus_keeps_the_focused_column_still() {
    let mut state = settled_never(&wide3(), "2");
    let before = screen_x(&state, "2");
    let effects = state.reduce(sync(
        &ids_strip(&[600., 600.], &["0", "2"]),
        "2",
        ColumnFocusSource::Programmatic,
        true,
    ));
    assert_eq!(screen_x(&state, "2"), before);
    assert_eq!(state.spring.target, state.spring.value);
    assert!(!effects.needs_frames);
}

#[test]
fn layout_closing_the_focused_middle_column_reveals_its_successor_minimally() {
    let mut state = settled_never(&wide3(), "0");
    focus_key(&mut state, "1");
    run_to_rest(&mut state);
    assert_eq!(state.spring.value, 224.);
    // The daemon focuses the right neighbor, which slid into place (616...1216).
    state.reduce(sync(
        &ids_strip(&[600., 600.], &["0", "2"]),
        "2",
        ColumnFocusSource::Programmatic,
        true,
    ));
    assert_eq!(state.spring.value, 224.);
    assert_eq!(state.spring.target, 224.);
}

#[test]
fn layout_closing_the_focused_leftmost_column_does_not_scroll() {
    let mut state = settled_never(&wide3(), "0");
    state.reduce(sync(
        &ids_strip(&[600., 600.], &["1", "2"]),
        "1",
        ColumnFocusSource::Programmatic,
        true,
    ));
    assert_eq!(state.spring.value, 0.);
    assert_eq!(state.spring.target, 0.);
}

#[test]
fn layout_opening_a_column_right_of_the_focus_reveals_it_and_closing_it_restores_the_view() {
    let mut state = settled_never(&four(), "0");
    focus_key(&mut state, "2");
    run_to_rest(&mut state);
    focus_key(&mut state, "1");
    run_to_rest(&mut state);
    assert_eq!(state.spring.value, 232.);
    // New 600 pt column right of c1, focused.
    let opened = ids_strip(&[400., 400., 600., 400., 400.], &["0", "1", "n", "2", "3"]);
    state.reduce(sync(&opened, "n", ColumnFocusSource::Programmatic, true));
    assert_eq!(screen_x(&state, "1"), Some(184.));
    assert_eq!(state.spring.target, 432.);
    run_to_rest(&mut state);
    // Closing it returns focus left and restores the old view (the restore
    // point), not merely a minimal reveal (408).
    state.reduce(sync(&four(), "1", ColumnFocusSource::Programmatic, true));
    assert_eq!(state.spring.target, 232.);
}

#[test]
fn layout_focusing_elsewhere_forgets_the_restore_point() {
    let mut state = settled_never(&four(), "1");
    let opened = ids_strip(&[400., 400., 600., 400., 400.], &["0", "1", "n", "2", "3"]);
    state.reduce(sync(&opened, "n", ColumnFocusSource::Programmatic, false));
    assert!(state.restore.is_some());
    focus(&mut state, "3", ColumnFocusSource::Keyboard, false);
    assert!(state.restore.is_none());
}

#[test]
fn layout_opening_a_column_left_of_the_focus_keeps_the_focused_column_still() {
    let mut state = settled_never(&wide3(), "2");
    let before = screen_x(&state, "2");
    let strip = ids_strip(&[600., 300., 600., 600.], &["0", "n", "1", "2"]);
    state.reduce(sync(&strip, "2", ColumnFocusSource::Programmatic, true));
    assert_eq!(screen_x(&state, "2"), before);
}

#[test]
fn layout_widening_the_focused_column_at_the_right_edge_reveals_its_new_edge() {
    let mut state = settled_never(&make_strip(&[600., 600.]), "1");
    assert_eq!(state.spring.value, 224.);
    state.reduce(sync(&make_strip(&[600., 800.]), "1", ColumnFocusSource::Programmatic, true));
    assert_eq!(state.spring.target, 424.);
}

#[test]
fn layout_resizing_a_column_left_of_the_focus_keeps_the_focused_column_still() {
    let mut state = settled_never(&wide3(), "2");
    let before = screen_x(&state, "2");
    state.reduce(sync(
        &make_strip(&[400., 600., 600.]),
        "2",
        ColumnFocusSource::Programmatic,
        true,
    ));
    assert_eq!(screen_x(&state, "2"), before);
    assert_eq!(state.spring.target, 632.);
}

#[test]
fn layout_moving_the_focused_column_keeps_the_camera_then_reveals_it() {
    let mut state = settled_never(&four(), "0");
    focus_key(&mut state, "2");
    run_to_rest(&mut state);
    assert_eq!(state.spring.value, 232.);
    // Move c2 right: order 0, 1, 3, 2. c2 is now 1232...1632.
    let moved = ids_strip(&[400., 400., 400., 400.], &["0", "1", "3", "2"]);
    state.reduce(sync(&moved, "2", ColumnFocusSource::Programmatic, true));
    assert_eq!(state.spring.value, 232.);
    assert_eq!(state.spring.target, 640.);
    run_to_rest(&mut state);
    // Move it left again: 824...1224 is visible at 640, nothing scrolls.
    state.reduce(sync(&four(), "2", ColumnFocusSource::Programmatic, true));
    assert_eq!(state.spring.target, 640.);
}

#[test]
fn layout_window_resize_keeps_the_focused_column_in_place_then_fits() {
    let mut state = settled_never(&wide3(), "0");
    focus(&mut state, "1", ColumnFocusSource::Keyboard, false);
    assert_eq!(screen_x(&state, "1"), Some(392.));
    let wider = make_strip_ids(&[720., 720., 720.], &["0", "1", "2"], 1200., 8.);
    state.reduce(sync(&wider, "1", ColumnFocusSource::Programmatic, false));
    assert_eq!(screen_x(&state, "1"), Some(392.));
    // Narrower window: c1 no longer fits where it was; fit it.
    let narrower = make_strip_ids(&[480., 480., 480.], &["0", "1", "2"], 800., 8.);
    state.reduce(sync(&narrower, "1", ColumnFocusSource::Programmatic, false));
    let x = screen_x(&state, "1").unwrap_or(-1.);
    assert!(x >= 8. && x + 480. + 8. <= 800.);
}

#[test]
fn layout_switching_to_a_split_screen_or_empty_strip_clamps_to_zero() {
    let mut state = settled_never(&wide3(), "2");
    state.reduce(ColumnScrollEvent::Sync {
        strip: make_strip(&[]),
        focused: None,
        source: ColumnFocusSource::Programmatic,
        animated: true,
        reveals: true,
        anchor: None,
    });
    assert_eq!(state.spring.target, 0.);
}

/// ColumnScrollResizeDragTests: a column-edge drag keeps the view and fits
/// the focused column once the drag ends.
#[test]
fn layout_live_resize_holds_the_view_and_reveals_at_the_end() {
    let mut state = settled_never(&make_strip(&[600., 600.]), "1");
    state.reduce(ColumnScrollEvent::Sync {
        strip: make_strip(&[600., 800.]),
        focused: Some(p("1")),
        source: ColumnFocusSource::Programmatic,
        animated: false,
        reveals: false,
        anchor: None,
    });
    assert_eq!(state.spring.value, 224.);
    assert!(state.reveal_deferred);
    state.reduce(sync(&make_strip(&[600., 800.]), "1", ColumnFocusSource::Programmatic, true));
    assert_eq!(state.spring.target, 424.);
}

/// A resize drag anchors the camera on the column under the drag
/// (d6e8f497ccae): its leading edge stays put while it widens, though the
/// focused column right of it moves.
#[test]
fn layout_a_resize_drag_anchors_the_camera_on_the_dragged_column() {
    let mut state = settled_never(&wide3(), "2");
    let before = screen_x(&state, "1");
    state.reduce(ColumnScrollEvent::Sync {
        strip: make_strip(&[600., 700., 600.]),
        focused: Some(p("2")),
        source: ColumnFocusSource::Programmatic,
        animated: false,
        reveals: false,
        anchor: Some(c("1")),
    });
    assert_eq!(screen_x(&state, "1"), before);
}

// MARK: BesideColumnRevealTests

/// A strip behind a 400 pt chat dock on a 1000 pt window: two 600 pt
/// terminals, and a 600 pt diff column added past them.
fn beside_strip(columns: usize) -> ColumnStrip {
    let content = columns as f64 * 616. - 16.;
    let mut strip = ColumnStrip::new(1000., content, 16.);
    for index in 0..columns {
        let name = index.to_string();
        let frame = Rect::new(index as f64 * 616., 0., 600., 800.);
        strip.push_column(c(&name), frame, [StripPane { id: p(&name), frame: None, listed: true }]);
    }
    strip.leading_cover = 400.;
    strip
}

#[test]
fn beside_the_new_column_scrolls_into_view_and_focus_stays_in_the_chat() {
    let chat = p("chat");
    let mut state = ColumnScrollState::new();
    let event = |strip: ColumnStrip| ColumnScrollEvent::Sync {
        strip,
        focused: Some(chat),
        source: ColumnFocusSource::Programmatic,
        animated: false,
        reveals: true,
        anchor: None,
    };
    state.reduce(event(beside_strip(2)));
    state.reduce(event(beside_strip(3)));
    let diff = beside_strip(3).columns[2].frame;
    // Before: the diff's column starts past the window's right edge.
    assert!(state.spring.target + 1000. <= diff.min_x());

    state.reduce(ColumnScrollEvent::Reveal { pane: p("2"), animated: false });
    let start = state.spring.target + 400.;
    let end = state.spring.target + 1000.;
    assert!(start <= diff.min_x() + 0.5 && diff.max_x() <= end + 0.5);
    assert_eq!(state.focused_pane, Some(chat));
    // The next snapshot, focus still in the chat, keeps it there.
    state.reduce(event(beside_strip(3)));
    assert!(state.spring.target + 400. <= diff.min_x() + 0.5);
}

// MARK: ColumnAddFocusTests (focus scroll)

/// Four two-thirds columns on a 1200 pt strip (800 pt each, 16 pt gaps).
fn two_thirds_strip() -> ColumnStrip {
    let mut strip = ColumnStrip::new(1200., 4. * 816. + 16., 16.);
    for index in 0..4 {
        let name = index.to_string();
        let frame = Rect::new(16. + index as f64 * 816., 0., 800., 800.);
        strip.push_column(c(&name), frame, [StripPane { id: p(&name), frame: None, listed: true }]);
    }
    strip
}

/// Focus Column Right then Left: each scroll aligns the nearest edge, the
/// least that shows the focused column whole; a column already whole does
/// not scroll.
#[test]
fn add_focus_focusing_a_column_scrolls_the_least_that_shows_it_whole() {
    let strip = two_thirds_strip();
    let mut state = ColumnScrollState::new();
    state.reduce(sync(&strip, "0", ColumnFocusSource::Keyboard, false));
    assert_eq!(state.spring.target, 0.);
    state.reduce(sync(&strip, "1", ColumnFocusSource::Keyboard, false));
    // c1 ends at 1632; with its 16 pt padding the view's right edge goes to 1648.
    assert!((state.spring.target - (1648. - 1200.)).abs() < 0.5);
    assert!(strip.is_fully_visible(strip.columns[1].frame, state.spring.target));
    let at_right = state.spring.target;
    state.reduce(sync(&strip, "0", ColumnFocusSource::Keyboard, false));
    assert_eq!(state.spring.target, 0.);
    assert_eq!(at_right - state.spring.target, 448.);
    state.reduce(sync(&strip, "0", ColumnFocusSource::Keyboard, false));
    assert_eq!(state.spring.target, 0.);
}

// MARK: ColumnCloseClampVelocityTests

/// `count` half-width columns on a 1200 pt strip, no gaps.
fn half_strip(count: usize) -> ColumnStrip {
    let mut strip = ColumnStrip::new(1200., count as f64 * 600., 0.);
    for index in 1..=count {
        let name = index.to_string();
        let frame = Rect::new((index - 1) as f64 * 600., 0., 600., 800.);
        strip.push_column(c(&name), frame, [StripPane { id: p(&name), frame: None, listed: true }]);
    }
    strip
}

/// Four columns, focus on p1, the camera at `value` moving at `velocity`
/// toward `target`.
fn moving(value: f64, velocity: f64, target: f64) -> ColumnScrollState {
    let mut state = ColumnScrollState::new();
    state.reduce(sync(&half_strip(4), "1", ColumnFocusSource::Keyboard, false));
    state.spring = Spring { value, velocity, target };
    state
}

#[test]
fn clamp_a_close_keeps_a_velocity_back_into_the_strip() {
    // A center of p1 in flight: past the three-column strip's end (600), coming back.
    let mut state = moving(845., -14_854., 0.);
    state.reduce(sync(&half_strip(3), "1", ColumnFocusSource::Programmatic, true));
    assert_eq!(state.spring.value, 600.);
    assert_eq!(state.spring.velocity, -14_854.);
}

#[test]
fn clamp_a_close_stops_a_velocity_out_of_the_strip() {
    let mut state = moving(845., 3_000., 1_200.);
    state.reduce(sync(&half_strip(3), "1", ColumnFocusSource::Programmatic, true));
    assert_eq!(state.spring.value, 600.);
    assert_eq!(state.spring.velocity, 0.);
}

/// Two half-width columns fit the window: a camera coming back toward 0
/// would pass the leading edge, so it stops at 0.
#[test]
fn clamp_a_close_to_a_strip_that_fits_stops_the_camera_at_zero() {
    let mut state = moving(845., -14_854., 0.);
    state.reduce(sync(&half_strip(2), "1", ColumnFocusSource::Programmatic, true));
    assert_eq!(state.spring.value, 0.);
    assert_eq!(state.spring.velocity, 0.);
}

/// A layout sync never cuts a fling short while pane motion is off
/// (a24075c441eb): a sync that leaves the target where the camera put it
/// does not snap, even with `animated: false`.
#[test]
fn clamp_a_sync_that_keeps_the_target_never_snaps_a_fling() {
    let mut state = settled_never(&four(), "0");
    let end = drag(&mut state, 40., 4, 0.);
    state.reduce(ColumnScrollEvent::GestureEnded { time: end + 0.001, animated: true });
    let (value, target) = (state.spring.value, state.spring.target);
    state.reduce(sync(&four(), "3", ColumnFocusSource::Scroll, false));
    assert_eq!(state.spring.value, value, "the fling was cut short");
    assert_eq!(state.spring.target, target);
}

// MARK: ScrollAreaGeometryTests (focusRevealsAPaneScrolledOutOfItsArea)

/// A 400 pt window at x 200 over three 300 pt cells (p1 | p2 | p3).
fn area_cells() -> ColumnStrip {
    let mut cells = ColumnStrip::new(400., 900., 0.);
    for (index, name) in ["1", "2", "3"].iter().enumerate() {
        let frame = Rect::new(200. + index as f64 * 300., 0., 300., 800.);
        cells.push_framed(0, frame, &[(p(name), frame)]);
    }
    cells
}

#[test]
fn area_focus_reveals_a_pane_scrolled_out_of_its_area() {
    let mut scroll = ScrollAreaScroll::new();
    let strip = scroll.strip(area_cells(), 200.);
    assert_eq!(
        strip.columns.iter().map(|c| c.id).collect::<Vec<_>>(),
        vec![p("1"), p("2"), p("3")]
    );
    assert_eq!(strip.columns[0].frame.min_x(), 0.);
    scroll.state.reduce(sync(&strip, "3", ColumnFocusSource::Keyboard, false));
    let offset = scroll.state.spring.target;
    let pane = Rect::new(600., 0., 300., 800.);
    assert!(pane.min_x() >= offset - 0.5 && pane.max_x() <= offset + 400. + 0.5);
    assert!(offset <= strip.max_offset() + 0.5);
    // Back to the first pane: the area scrolls back.
    let strip = scroll.strip(area_cells(), 200.);
    scroll.state.reduce(sync(&strip, "1", ColumnFocusSource::Keyboard, false));
    assert!(scroll.state.spring.target < 0.5);
}

#[test]
fn area_an_empty_cell_takes_the_shared_empty_id() {
    let mut cells = ColumnStrip::new(400., 300., 0.);
    cells.push_column(7, Rect::new(0., 0., 300., 800.), []);
    let strip = ScrollAreaScroll::new().strip(cells, 0.);
    assert_eq!(strip.columns[0].id, EMPTY_AREA_CELL);
}

// MARK: RowScroll (rows.md V1, V2)

/// A column 400 pt tall at y 100 with 300 pt rows `ids` and 8 pt gaps.
fn rows(ids: &[u64]) -> ColumnStrip {
    let content = ids.len() as f64 * 308. - 8.;
    let mut rows = ColumnStrip::new(400., content, 8.);
    for (index, row) in ids.iter().enumerate() {
        let frame = Rect::new(0., 100. + index as f64 * 308., 500., 300.);
        rows.push_framed(*row, frame, &[(20_000 + row, frame)]);
    }
    rows
}

#[test]
fn rows_transpose_and_keep_a_slot_per_live_row() {
    let mut scroll = RowScroll::new();
    let strip = scroll.strip(rows(&[41, 42, 43]), 100.);
    assert_eq!(strip.axis, Axis::Vertical);
    assert_eq!(strip.columns.iter().map(|c| c.id).collect::<Vec<_>>(), vec![1, 2, 3]);
    assert_eq!(strip.columns[1].frame, Rect::new(308., 0., 300., 500.));
    assert_eq!(strip.pane_frame(1, 20_042), Some(Rect::new(308., 0., 300., 500.)));
    assert_eq!(scroll.row_for_slot(2), Some(42));
    // r1 leaves, r4 comes: r2 and r3 keep their slots, r4 gets a new one.
    let strip = scroll.strip(rows(&[42, 43, 44]), 100.);
    assert_eq!(strip.columns.iter().map(|c| c.id).collect::<Vec<_>>(), vec![2, 3, 4]);
    assert_eq!(scroll.row_for_slot(1), None);
}

/// A row camera keeps its vertical spring when a row closes: only the
/// horizontal strip clamps the presented camera (#22059).
#[test]
fn rows_a_close_keeps_the_vertical_spring() {
    let mut scroll = RowScroll::new();
    let strip = scroll.strip(rows(&[41, 42, 43]), 100.);
    scroll.state.reduce(ColumnScrollEvent::Sync {
        strip,
        focused: Some(20_043),
        source: ColumnFocusSource::Keyboard,
        animated: false,
        reveals: true,
        anchor: None,
    });
    assert_eq!(scroll.state.spring.value, 516.);
    let strip = scroll.strip(rows(&[41, 42]), 100.);
    scroll.state.reduce(ColumnScrollEvent::Sync {
        strip,
        focused: Some(20_042),
        source: ColumnFocusSource::Programmatic,
        animated: true,
        reveals: true,
        anchor: None,
    });
    assert_eq!(scroll.state.spring.value, 516.);
    assert_eq!(scroll.state.spring.target, 208.);
}

// MARK: ColumnStripGeometry (snap, wheel and rubber band)

#[test]
fn geometry_snap_target_and_adjacent_snap() {
    let snaps = [0., 232., 408., 640.];
    assert_eq!(snap_target(150., 0., &snaps), 232.);
    // A fast fling advances at least one snap in its direction.
    assert_eq!(snap_target(240., 400., &snaps), 408.);
    assert_eq!(snap_target(240., 310., &[0., 232., 640.]), 640.);
    assert_eq!(snap_target(400., -310., &[0., 408., 640.]), 0.);
    assert_eq!(snap_target(240., -400., &snaps), 0.);
    assert_eq!(snap_target(12., 0., &[]), 12.);
    assert_eq!(adjacent_snap(640., 1, &snaps), 640.);
    assert_eq!(adjacent_snap(0., -1, &snaps), 0.);
    assert_eq!(adjacent_snap(5., 1, &[]), 5.);
    assert_eq!(projected_offset(10., 1000.), 10. + 0.998 / (1. - 0.998));
}

#[test]
fn geometry_rubber_band_resists_past_both_ends() {
    assert_eq!(rubber_band(100., 1640., 1000.), 100.);
    let below = rubber_band(-300., 1640., 1000.);
    assert!((below - -(1. - 1. / 1.165) * 1000.).abs() < 1e-9);
    let above = rubber_band(940., 1640., 1000.);
    assert!(above > 640. && above < 940.);
}

#[test]
fn swift_min_and_max_keep_swift_order() {
    assert!(swift_max(f64::NAN, 0.).is_nan());
    assert_eq!(swift_max(0., f64::NAN), 0.);
    assert!(swift_min(f64::NAN, 1.).is_nan());
    assert_eq!(swift_min(1., f64::NAN), 1.);
    assert!(swift_max(0., -0.).is_sign_negative());
}
