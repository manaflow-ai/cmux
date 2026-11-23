use super::*;

fn trade_input(delta: f64) -> TradeInput {
    // Two half-strip columns on a 1000 pt strip with 8 pt gaps, at 2x, the camera at rest at 0.
    TradeInput {
        is_columns: true,
        strip_width: 1000.0,
        gap: 8.0,
        scale: 2.0,
        delta,
        left_min_x: 8.0,
        left_max_x: 500.0,
        left_width: 492.0,
        right_min_x: 508.0,
        right_max_x: 1000.0,
        right_width: 492.0,
        left_minimum_width: 200.0,
        right_minimum_width: 200.0,
        left_fraction: 0.5,
        right_fraction: 0.5,
        strip_offset: None,
        uncovered_min_x: 0.0,
        uncovered_max_x: 1000.0,
        strip_min_x: 0.0,
    }
}

#[test]
fn swift_min_and_max_keep_the_first_value_on_a_tie_and_on_nan() {
    assert!(swift_min(f64::NAN, 1.0).is_nan());
    assert_eq!(swift_min(1.0, f64::NAN), 1.0);
    assert!(swift_max(f64::NAN, 1.0).is_nan());
    assert_eq!(swift_max(1.0, f64::NAN), 1.0);
    assert!(swift_max(-0.0, 0.0).is_sign_positive());
    assert!(swift_min(-0.0, 0.0).is_sign_negative());
}

#[test]
fn a_ratio_needs_room_for_both_minimums() {
    assert_eq!(ratio(1001.0, 1.0, 200.0, 300.0), Some(Bounds { lower: 0.2, upper: 0.7 }));
    assert_eq!(ratio(1001.0, 1.0, 500.0, 500.0), Some(Bounds { lower: 0.5, upper: 0.5 }));
    assert_eq!(ratio(1001.0, 1.0, 500.0, 501.0), None);
    assert_eq!(ratio(1.0, 1.0, 0.0, 0.0), None);
    assert_eq!(ratio(f64::NAN, 1.0, 0.0, 0.0), None);
}

#[test]
fn a_column_width_starts_at_its_minimum_and_a_docked_column_has_none() {
    let bounds = column_width(true, false, 1008.0, 192.0, 8.0).expect("strip column");
    assert_eq!(bounds, Bounds { lower: 0.2, upper: 1.0 });
    assert_eq!(column_width(true, true, 1008.0, 192.0, 8.0), None);
    assert_eq!(column_width(false, false, 1008.0, 192.0, 8.0), None);
    assert_eq!(column_width(true, false, 0.0, 192.0, 8.0), None);
    // A minimum wider than the strip keeps the widest share.
    assert_eq!(
        column_width(true, false, 1008.0, 5000.0, 8.0),
        Some(Bounds { lower: 1.0, upper: 1.0 })
    );
}

#[test]
fn a_docked_dock_stops_at_the_room_the_strip_leaves() {
    let side =
        |is_target, is_docked, width| DockSide { is_target, is_band: false, is_docked, width };
    let alone = dock_width([side(true, true, 300.0)], 2000.0, 0.0, 200.0).expect("dock");
    assert_eq!(alone, Bounds { lower: 0.1, upper: 0.75 });
    // Two docked docks: each at most 40 %, and no wider than the window less 400 pt and the other dock.
    let both = dock_width([side(true, true, 300.0), side(false, true, 900.0)], 2000.0, 0.0, 200.0)
        .expect("dock");
    assert_eq!(both, Bounds { lower: 0.1, upper: 0.35 });
    let band = DockSide { is_target: true, is_band: true, is_docked: true, width: 300.0 };
    assert_eq!(dock_width([band], 2000.0, 0.0, 200.0), None);
    assert_eq!(dock_width([side(false, true, 300.0)], 2000.0, 0.0, 200.0), None);
}

#[test]
fn a_trade_moves_whole_pixels_and_stops_at_a_minimum() {
    let right = trade(&trade_input(0.1)).expect("a press right");
    assert_eq!(right.move_points, 99.0);
    let left = trade(&trade_input(-0.1)).expect("a press left");
    assert_eq!(left.move_points, -99.0);
    // The right column can give at most 492 - 200 points.
    let far = trade(&trade_input(0.9)).expect("a press right to the minimum");
    assert_eq!(far.move_points, 292.0);
    let mut at_minimum = trade_input(0.1);
    at_minimum.right_width = 200.0;
    assert_eq!(trade(&at_minimum), None);
    assert_eq!(trade(&trade_input(0.0)), None);
    assert_eq!(trade(&trade_input(0.0001)), None);
}

#[test]
fn a_trade_stays_in_the_part_of_the_strip_the_window_shows() {
    let mut input = trade_input(0.1);
    input.strip_offset = Some(0.0);
    input.uncovered_max_x = 950.0;
    // 50 points of cover at the window's trailing edge: the divider may go 442 points right, the minimum stops it first.
    let answer = trade(&input).expect("a press right");
    assert_eq!(answer.move_points, 99.0);
    input.delta = 0.9;
    assert_eq!(trade(&input).expect("the press that reaches the edge").move_points, 292.0);
    // 400 points of cover: the right column's leading edge (508) may go to 600, no further.
    input.uncovered_max_x = 600.0;
    assert_eq!(trade(&input).expect("the press that reaches the cover").move_points, 92.0);
}

#[test]
fn a_trade_widths_are_what_the_daemon_keeps() {
    let answer = trade(&trade_input(0.1)).expect("a press right");
    for width in [answer.first.0, answer.first.1, answer.second.0, answer.second.1] {
        assert_eq!(f64::from(width as f32), width);
    }
}

fn rows(
    heights: &[i64],
    minimums: &[f64],
    pane_row: usize,
    rows_enabled: bool,
    delta: f64,
) -> Option<Vec<i64>> {
    let input = RowInput {
        heights,
        minimum_heights: minimums,
        pane_row,
        rows_enabled,
        column_height: 992.0,
        gap: 8.0,
        scale: 2.0,
        delta,
    };
    let mut out = vec![0; heights.len()];
    row_heights(&input, &mut out).then_some(out)
}

#[test]
fn a_row_press_trades_permille_with_the_row_below_or_above_the_last() {
    assert_eq!(rows(&[500, 500], &[64.0, 64.0], 0, true, 0.1), Some(vec![600, 400]));
    assert_eq!(rows(&[500, 500], &[64.0, 64.0], 1, true, -0.1), Some(vec![400, 600]));
    // One row has no edge to move; a press of no whole permille moves nothing.
    assert_eq!(rows(&[1000], &[64.0], 0, true, 0.1), None);
    assert_eq!(rows(&[500, 500], &[64.0, 64.0], 0, true, 0.0004), None);
}

#[test]
fn a_row_press_keeps_the_minimum_of_both_rows() {
    // The lower row needs 400 points: about 408 permille, so the upper row stops near 592.
    let grown = rows(&[500, 500], &[64.0, 400.0], 0, true, 0.5).expect("a press down");
    assert_eq!(grown[0] + grown[1], 1000);
    assert!(grown[1] >= 400, "{grown:?}");
    assert_eq!(rows(&grown, &[64.0, 400.0], 0, true, 0.1), None);
    // Up stops at the upper row's own minimum.
    let shrunk = rows(&[500, 500], &[300.0, 64.0], 0, true, -0.5).expect("a press up");
    assert!(shrunk[0] >= 300, "{shrunk:?}");
}

#[test]
fn a_scrolling_stack_sizes_the_upper_row_alone() {
    // 700 + 700 is a scrolling stack (rows enabled, over 1000): the press sizes the upper row only.
    assert_eq!(rows(&[700, 700], &[64.0, 64.0], 0, true, 0.1), Some(vec![800, 700]));
    // Never below the sum that fills the column: 1000 - 700.
    assert_eq!(rows(&[700, 700], &[64.0, 64.0], 0, true, -0.5), Some(vec![300, 700]));
    // With rows off the stack fills: the pair trades, in permille scaled by 1400 / 1000.
    assert_eq!(rows(&[700, 700], &[64.0, 64.0], 0, false, 0.1), Some(vec![840, 560]));
}

#[test]
fn a_row_input_that_does_not_fit_moves_nothing() {
    let input = RowInput {
        heights: &[500, 500],
        minimum_heights: &[64.0],
        pane_row: 0,
        rows_enabled: true,
        column_height: 992.0,
        gap: 8.0,
        scale: 2.0,
        delta: 0.1,
    };
    assert!(!row_heights(&input, &mut [0, 0]));
    let input = RowInput { minimum_heights: &[64.0, 64.0], pane_row: 2, ..input };
    assert!(!row_heights(&input, &mut [0, 0]));
    let input = RowInput { pane_row: 0, ..input };
    assert!(!row_heights(&input, &mut [0]));
}
